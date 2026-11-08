import Foundation
import Observation
import Sparkle
import UAwakeCore

/// Sparkle, kept off until the build carries a real EdDSA public key and feed.
/// The beta channel follows the `UpdateChannel` setting.
@MainActor
@Observable
final class UpdatesModel: NSObject, SPUUpdaterDelegate {
    private let settings: UAwakeSettings
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    /// The updater started; `false` in development builds without signing keys.
    private(set) var isConfigured = false

    init(settings: UAwakeSettings, bundle: Bundle = .main) {
        self.settings = settings
        super.init()
        guard Self.hasPublicKey(bundle) else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
            isConfigured = true
        } catch {
            AppModel.logger.error("Updater failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    /// A Sparkle EdDSA public key is 32 bytes, base64-encoded.
    static func hasPublicKey(_ bundle: Bundle) -> Bool {
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            let data = Data(base64Encoded: key)
        else { return false }
        return data.count == 32
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { settings.updateChannel == .beta ? ["beta"] : [] }
    }
}
