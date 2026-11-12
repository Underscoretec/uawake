import AppKit
import Carbon.HIToolbox
import CoreAudio
import CoreBluetooth
import CoreLocation
import CoreMediaIO
import CoreWLAN
import Darwin
import EventKit
import IOBluetooth
import IOKit
import IOKit.pwr_mgt
import ServiceManagement
import UAwakeCore
import UAwakeSystem

struct Probe: Identifiable, Sendable {
    let id: String
    let title: String
    let release: String
    /// `interactive` is true for the Run button: the probe may show permission prompts.
    let run: @MainActor @Sendable (_ interactive: Bool) async -> ProbeOutcome

    static let all: [Probe] = [
        Probe(
            id: "hotkey", title: "Global hotkey ⌃⌥⌘U (Carbon RegisterEventHotKey)", release: "0.1", run: Probes.hotkey),
        Probe(
            id: "deviceState", title: "Battery, power source, Low Power Mode, thermal", release: "0.1",
            run: Probes.deviceState),
        Probe(
            id: "lifecycle", title: "Fast user switching and sleep/wake notifications", release: "0.1",
            run: Probes.lifecycle),
        Probe(id: "loginItem", title: "SMAppService.mainApp login item", release: "0.1", run: Probes.loginItem),
        Probe(id: "launchAgent", title: "SMAppService.agent with KeepAlive", release: "1.3", run: Probes.launchAgent),
        Probe(
            id: "runningApps", title: "Running apps and frontmost app (NSWorkspace)", release: "1.0",
            run: Probes.runningApps),
        Probe(
            id: "camera", title: "Camera in use (CoreMediaIO DeviceIsRunningSomewhere)", release: "1.0",
            run: Probes.camera),
        Probe(
            id: "microphone", title: "Microphone in use (Core Audio input devices)", release: "1.0",
            run: Probes.microphone),
        Probe(
            id: "audioOutput", title: "Audio output playing (default output device)", release: "1.0",
            run: Probes.audioOutput),
        Probe(
            id: "cpu", title: "CPU load: system-wide and per-process (proc_pidinfo)", release: "1.0", run: Probes.cpu),
        Probe(
            id: "network", title: "Network throughput (getifaddrs byte counters)", release: "1.0", run: Probes.network),
        Probe(id: "displays", title: "Displays and connect/disconnect", release: "1.0", run: Probes.displays),
        Probe(id: "usb", title: "USB devices and attach/detach (IOKit matching)", release: "1.0", run: Probes.usb),
        Probe(
            id: "bluetooth", title: "Connected Bluetooth devices (IOBluetooth)", release: "1.0", run: Probes.bluetooth),
        Probe(id: "wifi", title: "Wi-Fi network name (CoreWLAN)", release: "1.0", run: Probes.wifi),
        Probe(id: "calendar", title: "In-progress calendar events (EventKit)", release: "1.0", run: Probes.calendar),
        Probe(
            id: "preventSystemSleep", title: "Create and release PreventSystemSleep assertion", release: "1.0",
            run: Probes.preventSystemSleep),
        Probe(id: "assertions", title: "Other apps' power assertions", release: "1.2", run: Probes.assertions),
        Probe(
            id: "sleepHistory", title: "Sleep/wake history (sysctl, pmset -g log)", release: "1.2",
            run: Probes.sleepHistory),
        Probe(
            id: "managedPrefs", title: "Managed preferences (objectIsForced)", release: "1.3", run: Probes.managedPrefs),
    ]
}

private func outcome(_ value: String, _ result: ProbeResult) -> ProbeOutcome {
    ProbeOutcome(value: value, result: result)
}

@MainActor
private func log(_ id: String, _ text: String) {
    ProbeModel.shared.event(id, text)
}

@MainActor
enum Probes {
    // Listeners stay registered for the life of the app so user actions show up as events.
    private static var hotKeyRef: EventHotKeyRef?
    private static var deviceMonitor: SystemDeviceStateMonitor?
    private static var lifecycleMonitor: SystemSessionLifecycleMonitor?
    private static var observers: [String: any NSObjectProtocol] = [:]
    private static var usbPort: IONotificationPortRef?
    private static var locationManager: CLLocationManager?
    private static let eventStore = EKEventStore()
    static let agentPlist = "com.underscoretec.uawake.SandboxProbe.agent.plist"

    // MARK: 0.1

    static func hotkey(_ interactive: Bool) async -> ProbeOutcome {
        if hotKeyRef != nil { return outcome("Registered; press ⌃⌥⌘U in any app, presses appear as events", .works) }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                MainActor.assumeIsolated { log("hotkey", "Hotkey pressed") }
                return noErr
            }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_U), UInt32(cmdKey | optionKey | controlKey), EventHotKeyID(signature: 0x7561_776B, id: 1),
            GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
        let ok = installStatus == noErr && status == noErr
        return outcome(
            "InstallEventHandler=\(installStatus) RegisterEventHotKey=\(status); press ⌃⌥⌘U to confirm delivery",
            ok ? .works : .blocked)
    }

    static func deviceState(_ interactive: Bool) async -> ProbeOutcome {
        let monitor = deviceMonitor ?? SystemDeviceStateMonitor()
        if deviceMonitor == nil {
            deviceMonitor = monitor
            Task { for await state in monitor.updates().dropFirst() { log("deviceState", describe(state)) } }
        }
        let state = monitor.current
        return outcome(describe(state), state.powerSource == .unknown ? .limited : .works)
    }

    private static func describe(_ state: DeviceState) -> String {
        let level = state.batteryLevel.map { "\($0)%" } ?? "no battery"
        return
            "battery \(level), source \(state.powerSource), lowPower \(state.isLowPowerModeEnabled), thermal \(state.thermalState.rawValue)"
    }

    static func lifecycle(_ interactive: Bool) async -> ProbeOutcome {
        if lifecycleMonitor == nil {
            let monitor = SystemSessionLifecycleMonitor()
            lifecycleMonitor = monitor
            Task { for await event in monitor.events() { log("lifecycle", "\(event)") } }
        }
        return outcome("Listening to NSWorkspace session and sleep/wake notifications; they appear as events", .works)
    }

    static func loginItem(_ interactive: Bool) async -> ProbeOutcome {
        let service = SMAppService.mainApp
        do {
            try service.register()
        } catch {
            return outcome("register() failed: \(error)", .blocked)
        }
        let status = service.status
        let unregister: String
        do {
            try await service.unregister()
            unregister = "unregistered again"
        } catch {
            unregister = "unregister failed: \(error)"
        }
        let result: ProbeResult =
            status == .enabled ? .works : status == .requiresApproval ? .worksWithPermission : .limited
        return outcome("register() → \(describe(status)); \(unregister)", result)
    }

    static func launchAgent(_ interactive: Bool) async -> ProbeOutcome {
        let service = SMAppService.agent(plistName: agentPlist)
        do {
            try service.register()
        } catch {
            return outcome("register() failed: \(error)", .blocked)
        }
        try? await Task.sleep(for: .seconds(2))
        let pids = pids(named: "SandboxProbeAgent")
        let result: ProbeResult =
            !pids.isEmpty ? .works : service.status == .requiresApproval ? .worksWithPermission : .limited
        return outcome(
            "status \(describe(service.status)); agent pids via proc_listallpids \(pids) (check with pgrep outside the sandbox); --cleanup unregisters",
            result)
    }

    static func cleanup() async {
        try? await SMAppService.agent(plistName: agentPlist).unregister()
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    // MARK: 1.0

    static func runningApps(_ interactive: Bool) async -> ProbeOutcome {
        let workspace = NSWorkspace.shared
        if observers["runningApps"] == nil {
            observers["runningApps"] = workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let name = app?.localizedName ?? "?"
                MainActor.assumeIsolated { log("runningApps", "Activated \(name)") }
            }
        }
        let apps = workspace.runningApplications
        let regular = apps.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName).sorted()
        let front = workspace.frontmostApplication?.localizedName ?? "none"
        return outcome(
            "\(apps.count) running, \(regular.count) regular (\(regular.prefix(6).joined(separator: ", "))); frontmost \(front)",
            apps.count > 1 ? .works : .limited)
    }

    static func camera(_ interactive: Bool) async -> ProbeOutcome {
        let devices = cameraDevices()
        guard !devices.isEmpty else { return outcome("No CoreMediaIO devices visible", .blocked) }
        return outcome(devices.map { "\($0.name): \($0.running ? "IN USE" : "idle")" }.joined(separator: "; "), .works)
    }

    static func microphone(_ interactive: Bool) async -> ProbeOutcome {
        let inputs = audioDevices().filter { hasStreams($0, scope: kAudioObjectPropertyScopeInput) }
        guard !inputs.isEmpty else { return outcome("No Core Audio input devices visible", .blocked) }
        let text = inputs.map { "\(audioName($0)): \(audioRunning($0) ? "IN USE" : "idle")" }
        return outcome(text.joined(separator: "; "), .works)
    }

    static func audioOutput(_ interactive: Bool) async -> ProbeOutcome {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else {
            return outcome("Default output device unreadable (\(status))", .blocked)
        }
        return outcome("\(audioName(device)): \(audioRunning(device) ? "RUNNING (audio active)" : "idle")", .works)
    }

    static func cpu(_ interactive: Bool) async -> ProbeOutcome {
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?
            .processIdentifier
        guard let first = cpuTicks() else { return outcome("host_statistics failed", .blocked) }
        let own = processCPU(getpid())
        let other = finder.map(processCPU) ?? "Finder not running"
        try? await Task.sleep(for: .seconds(1))
        guard let second = cpuTicks() else { return outcome("host_statistics failed", .blocked) }
        let load = Double(second.busy - first.busy) / Double(max(1, second.total - first.total)) * 100
        let pidCount = proc_listallpids(nil, 0)
        let otherWorks = other.hasPrefix("ok")
        return outcome(
            "system \(String(format: "%.1f", load))%; proc_pidinfo own: \(own), Finder: \(other); proc_listallpids: \(pidCount)",
            otherWorks ? .works : .limited)
    }

    static func network(_ interactive: Bool) async -> ProbeOutcome {
        guard let first = interfaceBytes() else { return outcome("getifaddrs failed", .blocked) }
        try? await Task.sleep(for: .seconds(2))
        guard let second = interfaceBytes() else { return outcome("getifaddrs failed", .blocked) }
        let rate = Double(second.bytes &- first.bytes) / 2
        return outcome(
            "\(String(format: "%.0f", rate)) B/s over \(second.interfaces.joined(separator: ", ")) (32-bit counters)",
            second.bytes > 0 ? .works : .limited)
    }

    static func displays(_ interactive: Bool) async -> ProbeOutcome {
        if observers["displays"] == nil {
            observers["displays"] = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { log("displays", "Screens changed: \(screenNames())") }
            }
        }
        return outcome(screenNames(), .works)
    }

    static func usb(_ interactive: Bool) async -> ProbeOutcome {
        if usbPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) {
            usbPort = port
            CFRunLoopAddSource(
                CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
            let callback: IOServiceMatchingCallback = { refcon, iterator in
                let names = Probes.drainNames(iterator)
                let verb = Int(bitPattern: refcon) == 1 ? "Attached" : "Detached"
                MainActor.assumeIsolated { log("usb", "\(verb): \(names.joined(separator: ", "))") }
            }
            for (type, tag) in [(kIOFirstMatchNotification, 1), (kIOTerminatedNotification, 2)] {
                var iterator: io_iterator_t = 0
                let status = IOServiceAddMatchingNotification(
                    port, type, IOServiceMatching("IOUSBHostDevice"), callback,
                    UnsafeMutableRawPointer(bitPattern: tag),
                    &iterator)
                if status != KERN_SUCCESS { log("usb", "IOServiceAddMatchingNotification(\(type)) failed: \(status)") }
                _ = drainNames(iterator)  // Arms the notification.
            }
        }
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
        guard status == KERN_SUCCESS else { return outcome("IOServiceGetMatchingServices failed: \(status)", .blocked) }
        defer { IOObjectRelease(iterator) }
        let names = drainNames(iterator)
        return outcome(
            "\(names.count) USB devices: \(names.joined(separator: ", "))", names.isEmpty ? .limited : .works)
    }

    static func bluetooth(_ interactive: Bool) async -> ProbeOutcome {
        let before = CBManager.authorization
        if before == .notDetermined && !interactive {
            return outcome("Bluetooth permission not determined; press Run to request", .notRun)
        }
        let paired = IOBluetoothDevice.pairedDevices()?.compactMap { $0 as? IOBluetoothDevice } ?? []
        let connected = paired.filter { $0.isConnected() }.map { $0.name ?? "unnamed" }
        let after = CBManager.authorization
        let result: ProbeResult =
            after == .allowedAlways ? (paired.isEmpty ? .limited : .worksWithPermission) : .blocked
        return outcome(
            "authorization \(after.rawValue); \(paired.count) paired, connected: \(connected.joined(separator: ", "))",
            result)
    }

    static func wifi(_ interactive: Bool) async -> ProbeOutcome {
        let manager = locationManager ?? CLLocationManager()
        locationManager = manager
        if interactive && manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            try? await Task.sleep(for: .seconds(1))
        }
        let status = manager.authorizationStatus
        let authorized = status == .authorizedAlways
        let interface = CWWiFiClient.shared().interface()
        let ssid = interface?.ssid()
        let value =
            "interface \(interface?.interfaceName ?? "none"), power \(interface?.powerOn() ?? false), SSID \(ssid ?? "nil"), location \(status.rawValue)"
        let result: ProbeResult =
            ssid == nil ? (authorized ? .limited : .blocked) : (authorized ? .worksWithPermission : .works)
        return outcome(value, result)
    }

    static func calendar(_ interactive: Bool) async -> ProbeOutcome {
        if interactive && EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await eventStore.requestFullAccessToEvents()
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            return outcome(
                "authorization \(status.rawValue) (3 = full access)", status == .notDetermined ? .notRun : .blocked)
        }
        let now = Date()
        let events = eventStore.events(
            matching: eventStore.predicateForEvents(withStart: now, end: now.addingTimeInterval(60), calendars: nil))
        let titles = events.compactMap(\.title).prefix(3).joined(separator: ", ")
        return outcome(
            "\(eventStore.calendars(for: .event).count) calendars; \(events.count) in progress: \(titles)",
            .worksWithPermission)
    }

    /// Creates a PreventSystemSleep assertion, checks powerd lists it for this pid and in the
    /// system-wide status, then releases it and checks it is gone.
    static func preventSystemSleep(_ interactive: Bool) async -> ProbeOutcome {
        let type = "PreventSystemSleep"  // kIOPMAssertPreventSystemSleep is a C macro Swift can't import
        func ownTypes() -> [String] {
            var byProcess: Unmanaged<CFDictionary>?
            _ = IOPMCopyAssertionsByProcess(&byProcess)
            let processes = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:]
            return (processes[NSNumber(value: getpid())] ?? []).compactMap { $0["AssertType"] as? String }
        }
        func systemLevel() -> Int {
            var summary: Unmanaged<CFDictionary>?
            _ = IOPMCopyAssertionsStatus(&summary)
            return (summary?.takeRetainedValue() as? [String: Int])?[type] ?? -1
        }
        var id = IOPMAssertionID(0)
        let create = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "uawake probe (on power)" as CFString, &id)
        guard create == kIOReturnSuccess else { return outcome("Create=\(create)", .blocked) }
        let listed = ownTypes().contains(type)
        let level = systemLevel()
        let release = IOPMAssertionRelease(id)
        let gone = !ownTypes().contains(type)
        let result: ProbeResult = listed && release == kIOReturnSuccess && gone ? .works : .limited
        return outcome(
            "Create=\(create) listed=\(listed) systemLevel=\(level) Release=\(release) goneAfter=\(gone)", result)
    }

    // MARK: 1.2

    static func assertions(_ interactive: Bool) async -> ProbeOutcome {
        var byProcess: Unmanaged<CFDictionary>?
        let byProcessStatus = IOPMCopyAssertionsByProcess(&byProcess)
        let processes = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:]
        var summary: Unmanaged<CFDictionary>?
        let summaryStatus = IOPMCopyAssertionsStatus(&summary)
        let levels = summary?.takeRetainedValue() as? [String: Int] ?? [:]
        let others = processes.filter { $0.key.int32Value != getpid() }
        let samples = others.flatMap { pid, list in
            list.map { "\(pid):\($0["AssertType"] as? String ?? "?") \"\($0["AssertName"] as? String ?? "?")\"" }
        }
        let active = levels.filter { $0.value != 0 }.keys.sorted()
        let result: ProbeResult =
            byProcessStatus == kIOReturnSuccess && !others.isEmpty
            ? .works : summaryStatus == kIOReturnSuccess ? .limited : .blocked
        return outcome(
            "ByProcess=\(byProcessStatus) (\(others.count) other pids: \(samples.prefix(3).joined(separator: "; "))); Status=\(summaryStatus) active types: \(active.joined(separator: ", "))",
            result)
    }

    static func sleepHistory(_ interactive: Bool) async -> ProbeOutcome {
        let sleepTime = sysctlTime("kern.sleeptime")
        let wakeTime = sysctlTime("kern.waketime")
        let pmset = await runProcess("/usr/bin/pmset", ["-g", "log"])
        let lines = pmset.output.split(separator: "\n")
        let sleeps = lines.filter { $0.contains(" Sleep  ") }.count
        let wakes = lines.filter { $0.contains(" Wake  ") || $0.contains(" DarkWake  ") }.count
        let firstDate = lines.first { $0.hasPrefix("20") }.map { String($0.prefix(19)) } ?? "none"
        let pmsetText =
            pmset.status == 0
            ? "pmset -g log: \(lines.count) lines, \(sleeps) sleeps, \(wakes) wakes, since \(firstDate); head: \(pmset.output.prefix(200))"
            : "pmset -g log exit \(pmset.status): \(pmset.error.prefix(160))"
        let result: ProbeResult =
            pmset.status == 0 && sleeps > 0 ? .works : (sleepTime != nil || wakeTime != nil) ? .limited : .blocked
        return outcome(
            "kern.sleeptime \(sleepTime?.formatted() ?? "unavailable"), kern.waketime \(wakeTime?.formatted() ?? "unavailable"); \(pmsetText)",
            result)
    }

    // MARK: 1.3

    static func managedPrefs(_ interactive: Bool) async -> ProbeOutcome {
        let key = "ProbeManagedKey"
        let forced = UserDefaults.standard.objectIsForced(forKey: key)
        let value = UserDefaults.standard.object(forKey: key).map { "\($0)" } ?? "nil"
        return outcome("objectIsForced(\(key))=\(forced), value=\(value)", forced ? .works : .notRun)
    }
}

// MARK: - Helpers

extension Probes {
    private static func screenNames() -> String {
        NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return screen.localizedName + (CGDisplayIsBuiltin(id) != 0 ? " (built-in)" : "")
        }.joined(separator: ", ")
    }

    nonisolated fileprivate static func drainNames(_ iterator: io_iterator_t) -> [String] {
        var names: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let name =
                IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            names.append(name ?? "unnamed")
            IOObjectRelease(service)
        }
        return names
    }

    private static func cameraDevices() -> [(name: String, running: Bool)] {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = cmioAddress(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids.map { id in
            var running: UInt32 = 0
            var runningAddress = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectGetPropertyData(id, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
            var name: Unmanaged<CFString>?
            var nameAddress = cmioAddress(kCMIOObjectPropertyName)
            CMIOObjectGetPropertyData(
                id, &nameAddress, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &name)
            return ((name?.takeRetainedValue() as String?) ?? "camera \(id)", running != 0)
        }
    }

    private static func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func audioAddress(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func audioDevices() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = audioAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = audioAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func audioRunning(_ device: AudioObjectID) -> Bool {
        var address = audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func audioName(_ device: AudioObjectID) -> String {
        var address = audioAddress(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else {
            return "device \(device)"
        }
        return name.takeRetainedValue() as String
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks  // user, system, idle, nice
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        return (busy, busy + UInt64(ticks.2))
    }

    private static func processCPU(_ pid: pid_t) -> String {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        return read == size
            ? "ok (\((info.pti_total_user + info.pti_total_system) / 1_000_000) ms)" : "failed (errno \(errno))"
    }

    private static func interfaceBytes() -> (bytes: UInt64, interfaces: [String])? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var total: UInt64 = 0
        var names: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = entry.ifa_data,
                name != "lo0"
            else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            let bytes = UInt64(counters.ifi_ibytes) + UInt64(counters.ifi_obytes)
            if bytes > 0 { names.append(name) }
            total += bytes
        }
        return (total, names)
    }

    private static func pids(named name: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(found, 0))).filter { pid in
            var buffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buffer, 256) > 0 else { return false }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == name
        }
    }

    private static func sysctlTime(_ name: String) -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec))
    }

    nonisolated private static func runProcess(
        _ path: String, _ arguments: [String]
    ) async -> (status: Int32, output: String, error: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                return (-1, "", "\(error)")
            }
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus, String(decoding: outputData, as: UTF8.self),
                String(decoding: errorData, as: UTF8.self)
            )
        }.value
    }
}
