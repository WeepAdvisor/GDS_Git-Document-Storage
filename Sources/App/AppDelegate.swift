import AppKit
import os
import SyncCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitDocumentStorage", category: "app")
    private var heartbeatTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--reset-domains") {
            Task {
                await DomainManager.shared.removeAllDomains()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        startHeartbeat()
        CrashReporter.shared.start(process: "app")
        LaunchAtLogin.registerIfRequested()
        AppModel.shared.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        logger.info("Launched")
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { $0.isVisible }
            if !visible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Фаза 6: дождаться опустошения очереди выгрузки (окно «Finishing upload…», таймаут 30 с).
        Task {
        CrashLog.clearMark(process: "app")
            await DomainManager.shared.disconnectAll(reason: "GDS is not running")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func startHeartbeat() {
        let suiteName = (try? SharedPaths())?.appGroupID
        AppLiveness.writeHeartbeat(to: suiteName.flatMap { UserDefaults(suiteName: $0) })
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            AppLiveness.writeHeartbeat(to: suiteName.flatMap { UserDefaults(suiteName: $0) })
        }
    }
}
