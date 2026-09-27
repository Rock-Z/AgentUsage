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
        readyVersion.map { "Update v\($0) Ready - Install" } ?? "Check for Updates"
    }

    var canPerformAction: Bool {
        installUpdate != nil || canCheckForUpdates
    }

    /// `startsUpdater: false` leaves Sparkle idle, for command-line modes and previews.
    init(startsUpdater: Bool = !CommandLine.arguments.contains("--probe-once")) {
        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: startsUpdater,
            updaterDelegate: self,
            userDriverDelegate: nil)

        if startsUpdater {
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
