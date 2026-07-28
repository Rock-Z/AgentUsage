import Combine
import Foundation
import ServiceManagement

protocol LaunchAtLoginManaging {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

struct MainAppLaunchAtLoginService: LaunchAtLoginManaging {
    private let service = SMAppService.mainApp

    var isEnabled: Bool {
        service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}

final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private let service: any LaunchAtLoginManaging

    init(service: any LaunchAtLoginManaging = MainAppLaunchAtLoginService()) {
        self.service = service
        refresh()
    }

    func refresh() {
        isEnabled = service.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            try service.setEnabled(enabled)
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
