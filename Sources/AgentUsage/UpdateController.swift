import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    private static let updateDefaultsVersion = 1
    private static let updateDefaultsVersionKey = "updateDefaultsVersion"

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var readyVersion: String?

    private var controller: SPUStandardUpdaterController!
    private var installUpdate: (() -> Void)?

    var actionTitle: String {
        Self.actionTitle(readyVersion: readyVersion)
    }

    var canPerformAction: Bool {
        installUpdate != nil || canCheckForUpdates
    }

    nonisolated static func actionTitle(readyVersion: String?) -> String {
        guard let readyVersion else { return "Check for Updates" }
        return "Update v\(readyVersion) Ready - Install"
    }

    override init() {
        super.init()

        let isCommandMode = CommandLine.arguments.contains("--self-test")
            || CommandLine.arguments.contains("--probe-once")
        controller = SPUStandardUpdaterController(
            startingUpdater: !isCommandMode,
            updaterDelegate: self,
            userDriverDelegate: nil)

        if !isCommandMode {
            applyUpdateDefaultsIfNeeded()
        }

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    private func applyUpdateDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.updateDefaultsVersionKey)
            < Self.updateDefaultsVersion
        else { return }

        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.updateCheckInterval = 3_600
        controller.updater.automaticallyDownloadsUpdates = true
        defaults.set(
            Self.updateDefaultsVersion,
            forKey: Self.updateDefaultsVersionKey)
    }

    func performAction() {
        if let installUpdate {
            installUpdate()
            return
        }
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool
    {
        installUpdate = immediateInstallHandler
        readyVersion = item.displayVersionString
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installUpdate = nil
        readyVersion = nil
    }
}
