import CoreAudio
import Foundation
import UAwakeCore

/// Whether the default output device is running (not necessarily audible), from Core Audio
/// `DeviceIsRunningSomewhere`. The per-device listener follows default-device changes.
public final class SystemAudioOutputMonitor: SignalMonitor, @unchecked Sendable {
    private let broadcaster = Broadcaster<Bool>()
    private let queue = DispatchQueue(label: "com.underscoretec.uawake.audio-output")
    private let lock = NSLock()
    private var value = false
    // Touched only on `queue` (and in `deinit`, when nothing else can).
    private var output = PropertyListeners<AudioObjectID, AudioObjectPropertyListenerBlock>()
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?

    public init() {
        queue.sync {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuild() }
            if AudioHAL.addListener(AudioHAL.systemObject, kAudioHardwarePropertyDefaultOutputDevice, queue, block) {
                defaultDeviceBlock = block
            }
            rebuild()
        }
    }

    deinit {
        if let defaultDeviceBlock {
            AudioHAL.removeListener(
                AudioHAL.systemObject, kAudioHardwarePropertyDefaultOutputDevice, queue, defaultDeviceBlock)
        }
        let queue = queue
        output.removeAll { AudioHAL.removeListener($0, kAudioDevicePropertyDeviceIsRunningSomewhere, queue, $1) }
    }

    public var current: Bool { lock.withLock { value } }

    public func updates() -> AsyncStream<Bool> {
        lock.withLock { broadcaster.stream(startingWith: value) }
    }

    /// On `queue`: moves the per-device listener to the current default output device, then refreshes.
    private func rebuild() {
        let queue = queue
        let target = AudioHAL.defaultOutputDevice().map { Set([$0]) } ?? []
        output.update(to: target) { id in
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            return AudioHAL.addListener(id, kAudioDevicePropertyDeviceIsRunningSomewhere, queue, block) ? block : nil
        } remove: {
            AudioHAL.removeListener($0, kAudioDevicePropertyDeviceIsRunningSomewhere, queue, $1)
        }
        refresh()
    }

    /// On `queue`: re-reads the watched device and yields the result if it changed.
    private func refresh() {
        let new = output.ids.contains(where: AudioHAL.isRunningSomewhere)
        lock.withLock {
            guard new != value else { return }
            value = new
            broadcaster.yield(new)
        }
    }
}
