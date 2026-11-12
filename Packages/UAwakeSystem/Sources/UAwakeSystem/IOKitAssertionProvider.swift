import IOKit.pwr_mgt
import UAwakeCore

/// Real power assertions via `IOPMAssertionCreateWithName`.
public struct IOKitAssertionProvider: AssertionProvider {
    public init() {}

    public func acquire(modes: Set<AwakeMode>, reason: String) throws(SessionEngineError) -> AssertionHandle {
        var ids: [UInt32] = []
        for mode in AwakeMode.allCases where modes.contains(mode) {
            do throws(SessionEngineError) {
                ids.append(try create(Self.assertionType(mode), name: "uawake: \(reason)"))
            } catch {
                release(AssertionHandle(ids: ids))
                throw error
            }
        }
        return AssertionHandle(ids: ids)
    }

    public func acquireOnPower(reason: String) throws(SessionEngineError) -> AssertionHandle {
        AssertionHandle(ids: [try create(Self.onPowerType, name: "uawake: \(reason) (on power)")])
    }

    private func create(_ type: String, name: String) throws(SessionEngineError) -> UInt32 {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        guard result == kIOReturnSuccess else { throw .assertionFailed(code: result) }
        return id
    }

    public func release(_ handle: AssertionHandle) {
        for id in handle.ids { IOPMAssertionRelease(id) }
    }

    /// kIOPMAssertPreventSystemSleep, like `caffeinate -s`; not imported into Swift.
    static let onPowerType = "PreventSystemSleep"

    static func assertionType(_ mode: AwakeMode) -> String {
        switch mode {
        case .system: kIOPMAssertionTypePreventUserIdleSystemSleep
        case .display: kIOPMAssertionTypePreventUserIdleDisplaySleep
        case .disk: "PreventDiskIdle"  // kIOPMAssertPreventDiskIdle; not imported into Swift.
        }
    }
}
