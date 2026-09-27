import Combine
import Foundation
import ServiceManagement

final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status != .notRegistered {
                try service.unregister()
            }
            refresh()
            if isEnabled != enabled {
                errorMessage = enabled
                    ? "Allow AgentUsage in System Settings > General > Login Items."
                    : "AgentUsage could not be removed from Login Items."
            }
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }
}
