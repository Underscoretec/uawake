/// Acquires and releases power assertions. The production conformer wraps
/// `IOPMAssertionCreateWithName` / `IOPMAssertionRelease`; tests use a fake.
///
/// Calls are synchronous and cheap, so the main-actor engine calls them directly.
public protocol AssertionProvider: Sendable {
    /// Creates one assertion per mode, each named `uawake: <reason>`. `reason` is
    /// always English (``SessionReason/englishDescription``), never localized.
    /// All-or-nothing: on failure, anything already created is released.
    func acquire(modes: Set<AwakeMode>, reason: String) throws(SessionEngineError) -> AssertionHandle

    /// Releases every assertion in `handle`. Releasing twice is a no-op.
    func release(_ handle: AssertionHandle)
}

/// Opaque token for the assertions backing one session.
public struct AssertionHandle: Hashable, Sendable {
    /// IOKit assertion ids (`IOPMAssertionID`), one per mode.
    public let ids: [UInt32]

    public init(ids: [UInt32]) {
        self.ids = ids
    }
}
