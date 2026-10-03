import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Проверка «главное приложение запущено» (ADR-005). Используется расширением перед сетевыми операциями.
/// Два сигнала: процесс с bundle id существует И heartbeat в App Group свежее `maxHeartbeatAge`.
public struct AppLiveness: Sendable {
    public let mainAppBundleID: String
    /// Suite name App Group UserDefaults (`UserDefaults` сам не `Sendable`, поэтому держим имя и открываем по требованию).
    public let defaultsSuiteName: String?
    public let maxHeartbeatAge: TimeInterval

    public init(mainAppBundleID: String, defaultsSuiteName: String?, maxHeartbeatAge: TimeInterval = 30) {
        self.mainAppBundleID = mainAppBundleID
        self.defaultsSuiteName = defaultsSuiteName
        self.maxHeartbeatAge = maxHeartbeatAge
    }

    private var defaults: UserDefaults? { defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } }

    public var isProcessRunning: Bool {
        #if canImport(AppKit)
        return !NSRunningApplication.runningApplications(withBundleIdentifier: mainAppBundleID).isEmpty
        #else
        return true
        #endif
    }

    public var isHeartbeatFresh: Bool {
        guard let defaults, let at = defaults.object(forKey: SharedDefaultsKey.heartbeatAt) as? Date else { return false }
        return Date().timeIntervalSince(at) < maxHeartbeatAge
    }

    /// Процесс жив — достаточно (heartbeat может отставать сразу после запуска).
    public var isAlive: Bool { isProcessRunning || isHeartbeatFresh }

    /// Вызывается приложением каждые 10 с.
    public static func writeHeartbeat(to defaults: UserDefaults?) {
        defaults?.set(Date(), forKey: SharedDefaultsKey.heartbeatAt)
    }
}
