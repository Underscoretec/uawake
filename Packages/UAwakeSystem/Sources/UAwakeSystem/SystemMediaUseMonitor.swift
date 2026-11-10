import CoreAudio
import CoreMediaIO
import Foundation
import UAwakeCore
import os

/// Whether any camera or microphone is in use by some process, from Core Audio and
/// CoreMediaIO `DeviceIsRunningSomewhere` property listeners. Event-driven; never opens a
/// device or reads audio or video.
public final class SystemMediaUseMonitor: SignalMonitor, @unchecked Sendable {
    private let broadcaster = Broadcaster<MediaUse>()
    private let queue = DispatchQueue(label: "com.underscoretec.uawake.media-use")
    private let lock = NSLock()
    private var value = MediaUse(cameraInUse: false, microphoneInUse: false)
    // Touched only on `queue` (and in `deinit`, when nothing else can).
    private var microphones = PropertyListeners<AudioObjectID, AudioObjectPropertyListenerBlock>()
    private var cameras = PropertyListeners<CMIOObjectID, CMIOObjectPropertyListenerBlock>()
    private var audioDevicesBlock: AudioObjectPropertyListenerBlock?
    private var cameraDevicesBlock: CMIOObjectPropertyListenerBlock?

    public init() {
        queue.sync {
            let audioBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuild() }
            if AudioHAL.addListener(AudioHAL.systemObject, kAudioHardwarePropertyDevices, queue, audioBlock) {
                audioDevicesBlock = audioBlock
            }
            let cameraBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuild() }
            if CMIO.addListener(CMIO.systemObject, kCMIOHardwarePropertyDevices, queue, cameraBlock) {
                cameraDevicesBlock = cameraBlock
            }
            rebuild()
        }
    }

    deinit {
        if let audioDevicesBlock {
            AudioHAL.removeListener(AudioHAL.systemObject, kAudioHardwarePropertyDevices, queue, audioDevicesBlock)
        }
        if let cameraDevicesBlock {
            CMIO.removeListener(CMIO.systemObject, kCMIOHardwarePropertyDevices, queue, cameraDevicesBlock)
        }
        let queue = queue
        microphones.removeAll {
            AudioHAL.removeListener($0, kAudioDevicePropertyDeviceIsRunningSomewhere, queue, $1)
        }
        cameras.removeAll { CMIO.removeListener($0, kCMIODevicePropertyDeviceIsRunningSomewhere, queue, $1) }
    }

    public var current: MediaUse { lock.withLock { value } }

    public func updates() -> AsyncStream<MediaUse> {
        lock.withLock { broadcaster.stream(startingWith: value) }
    }

    /// On `queue`: re-registers per-device listeners for the current device lists, then refreshes.
    private func rebuild() {
        let queue = queue
        let refreshBlock: () -> Void = { [weak self] in self?.refresh() }
        microphones.update(to: Set(AudioHAL.devices().filter(AudioHAL.hasInput))) { id in
            let block: AudioObjectPropertyListenerBlock = { _, _ in refreshBlock() }
            return AudioHAL.addListener(id, kAudioDevicePropertyDeviceIsRunningSomewhere, queue, block) ? block : nil
        } remove: {
            AudioHAL.removeListener($0, kAudioDevicePropertyDeviceIsRunningSomewhere, queue, $1)
        }
        cameras.update(to: Set(CMIO.devices())) { id in
            let block: CMIOObjectPropertyListenerBlock = { _, _ in refreshBlock() }
            return CMIO.addListener(id, kCMIODevicePropertyDeviceIsRunningSomewhere, queue, block) ? block : nil
        } remove: {
            CMIO.removeListener($0, kCMIODevicePropertyDeviceIsRunningSomewhere, queue, $1)
        }
        refresh()
    }

    /// On `queue`: re-reads every watched device and yields the result if it changed.
    private func refresh() {
        let new = Self.mediaUse(
            microphoneFlags: microphones.ids.map(AudioHAL.isRunningSomewhere),
            cameraFlags: cameras.ids.map(CMIO.isRunningSomewhere))
        lock.withLock {
            guard new != value else { return }
            value = new
            broadcaster.yield(new)
        }
    }

    static func mediaUse(microphoneFlags: [Bool], cameraFlags: [Bool]) -> MediaUse {
        MediaUse(cameraInUse: cameraFlags.contains(true), microphoneInUse: microphoneFlags.contains(true))
    }
}

/// Listener blocks per object, kept so each is removed with the block it was added with.
struct PropertyListeners<ID: Hashable, Block> {
    private(set) var blocks: [ID: Block] = [:]

    var ids: [ID] { Array(blocks.keys) }

    /// Removes listeners for objects not in `target` and adds them for new ones.
    /// `add` returns `nil` when registration failed; the object is retried on the next update.
    mutating func update(to target: Set<ID>, add: (ID) -> Block?, remove: (ID, Block) -> Void) {
        let change = Self.diff(from: Set(blocks.keys), to: target)
        for id in change.removed {
            if let block = blocks.removeValue(forKey: id) { remove(id, block) }
        }
        for id in change.added {
            if let block = add(id) { blocks[id] = block }
        }
    }

    mutating func removeAll(remove: (ID, Block) -> Void) {
        for (id, block) in blocks { remove(id, block) }
        blocks = [:]
    }

    static func diff(from old: Set<ID>, to new: Set<ID>) -> (added: Set<ID>, removed: Set<ID>) {
        (new.subtracting(old), old.subtracting(new))
    }
}

let systemLogger = Logger(subsystem: "com.underscoretec.uawake", category: "system")

/// Core Audio property reads and listeners. Only properties; never opens a device.
enum AudioHAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func devices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    static func addListener(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) -> Bool {
        var address = address(selector)
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status != noErr {
            systemLogger.warning("Core Audio listener \(selector) on \(object) failed: \(status)")
        }
        return status == noErr
    }

    static func removeListener(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = address(selector)
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

/// CoreMediaIO property reads and listeners. Only properties; never opens a device.
enum CMIO {
    static let systemObject = CMIOObjectID(kCMIOObjectSystemObject)

    static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func devices() -> [CMIOObjectID] {
        var address = address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(systemObject, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
        return status == noErr && running != 0
    }

    static func addListener(
        _ object: CMIOObjectID, _ selector: Int, _ queue: DispatchQueue,
        _ block: @escaping CMIOObjectPropertyListenerBlock
    ) -> Bool {
        var address = address(selector)
        let status = CMIOObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status != noErr {
            systemLogger.warning("CoreMediaIO listener \(selector) on \(object) failed: \(status)")
        }
        return status == noErr
    }

    static func removeListener(
        _ object: CMIOObjectID, _ selector: Int, _ queue: DispatchQueue,
        _ block: @escaping CMIOObjectPropertyListenerBlock
    ) {
        var address = address(selector)
        CMIOObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
