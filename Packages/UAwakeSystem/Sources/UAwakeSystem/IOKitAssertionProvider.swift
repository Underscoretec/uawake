import IOKit.pwr_mgt
import UAwakeCore

/// Real power assertions via `IOPMAssertionCreateWithName`.
public struct IOKitAssertionProvider: AssertionProvider {
    public init() {}

    public func acquire(modes: Set<AwakeMode>, reason: String) throws(SessionEngineError) -> AssertionHandle {
        var ids: [UInt32] = []
        for mode in AwakeMode.allCases where modes.contains(mode) {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                Self.assertionType(mode) as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "uawake: \(reason)" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                release(AssertionHandle(ids: ids))
                throw .assertionFailed(code: result)
            }
            ids.append(id)
        }
        return AssertionHandle(ids: ids)
    }

    public func release(_ handle: AssertionHandle) {
        for id in handle.ids { IOPMAssertionRelease(id) }
    }

    static func assertionType(_ mode: AwakeMode) -> String {
        switch mode {
        case .system: kIOPMAssertionTypePreventUserIdleSystemSleep
        case .display: kIOPMAssertionTypePreventUserIdleDisplaySleep
        case .disk: "PreventDiskIdle"  // kIOPMAssertPreventDiskIdle; not imported into Swift.
        }
    }
}
