import Foundation
import MetricKit

/// Забирает крэш-отчёт системы на следующем запуске и кладёт его в `CrashLog`.
public final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    nonisolated(unsafe) public static let shared = CrashReporter()
    private var process = "app"
    private var started = false

    public func start(process: String) {
        guard !started else { return }
        started = true
        self.process = process
        CrashLog.noteUncleanExit(process: process)
        if let stack = CrashStack.consumePending(process: process) {
            CrashLog.record(process: process, title: "Crash stack", detail: stack)
        }
        CrashStack.install(process: process)
        NSSetUncaughtExceptionHandler { exception in
            let frames = exception.callStackSymbols.prefix(40).joined(separator: "\n")
            CrashLog.record(
                process: CrashReporter.shared.process,
                title: "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")",
                detail: frames
            )
        }
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {}

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                CrashLog.record(process: process, title: Self.summary(crash), detail: Self.detail(crash))
            }
        }
    }

    private static func summary(_ crash: MXCrashDiagnostic) -> String {
        let type = crash.exceptionType?.intValue ?? -1
        let code = crash.exceptionCode?.intValue ?? -1
        let signal = crash.signal?.intValue ?? -1
        let reason = crash.exceptionReason?.composedMessage ?? crash.terminationReason ?? ""
        return "Crash exceptionType=\(type) exceptionCode=\(code) signal=\(signal) \(reason)"
    }

    private static func detail(_ crash: MXCrashDiagnostic) -> String {
        var parts: [String] = []
        if let info = crash.virtualMemoryRegionInfo, !info.isEmpty {
            parts.append(info)
        }
        let stack = CrashStack.formatMetricKit(crash.callStackTree.jsonRepresentation())
        if !stack.isEmpty { parts.append(stack) }
        return parts.joined(separator: "\n")
    }
}
