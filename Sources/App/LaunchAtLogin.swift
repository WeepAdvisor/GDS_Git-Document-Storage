import Foundation
import ServiceManagement

/// Регистрация самого приложения в объектах входа через `SMAppService`.
@MainActor
enum LaunchAtLogin {
    private static let requestedKey = "launchAtLoginRequested"

    static var isOn: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Первый запуск включает автозагрузку. Выключенный свитчер не включается обратно.
    static func registerIfRequested() {
        if UserDefaults.standard.object(forKey: requestedKey) == nil {
            UserDefaults.standard.set(true, forKey: requestedKey)
        }
        guard UserDefaults.standard.bool(forKey: requestedKey) else { return }
        guard SMAppService.mainApp.status == .notRegistered else { return }
        try? SMAppService.mainApp.register()
    }

    static func setEnabled(_ enabled: Bool) throws {
        UserDefaults.standard.set(enabled, forKey: requestedKey)
        let status = SMAppService.mainApp.status
        if enabled {
            if status == .notRegistered || status == .notFound {
                try SMAppService.mainApp.register()
            }
        } else if status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
