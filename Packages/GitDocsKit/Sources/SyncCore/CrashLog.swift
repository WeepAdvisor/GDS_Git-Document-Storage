import Foundation

/// Крэши: незакрытое действие с прошлого запуска и отчёт MetricKit. Хранится 7 дней.
public enum CrashLog {
    private static let fileName = "crash-log.txt"

    /// Что делали прямо перед возможным вылетом. Если процесс умрёт, это попадёт в лог на следующем запуске.
    public static func mark(_ action: String, process: String, container: URL? = nil) {
        guard let url = actionURL(process: process, container: container) else { return }
        let text = "\(iso.string(from: Date()))\t\(action)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func clearMark(process: String, container: URL? = nil) {
        guard let url = actionURL(process: process, container: container) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Прошлый процесс не снял отметку — значит, он оборвался на этом действии.
    public static func noteUncleanExit(process: String, container: URL? = nil) {
        guard let url = actionURL(process: process, container: container),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        clearMark(process: process, container: container)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        record(process: process, title: "Process ended during \(trimmed)", detail: "No clean shutdown. The system crash report is added here when macOS delivers it.", container: container)
    }

    public static func record(process: String, title: String, detail: String, container: URL? = nil, at: Date = Date()) {
        guard let root = container ?? (try? SharedPaths())?.containerURL else { return }
        let url = logURL(in: root)
        let stamp = iso.string(from: at)
        let block = "--- \(stamp) \(process) ---\n\(title)\n\(detail)\n"
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { url in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let kept = recentBlocks(at: url, now: Date())
            let text = (kept + [block]).joined()
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public static func recentText(container: URL? = nil, now: Date = Date()) -> String {
        guard let root = container ?? (try? SharedPaths())?.containerURL else { return "" }
        return recentBlocks(at: logURL(in: root), now: now).joined()
    }

    static func recentBlocks(at url: URL, now: Date) -> [String] {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let cutoff = now.addingTimeInterval(-ProblemLog.retention)
        var blocks: [String] = []
        var current = ""
        var keep = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("--- ") {
                if keep, !current.isEmpty { blocks.append(current.hasSuffix("\n") ? current : current + "\n") }
                current = text + "\n"
                keep = (timestamp(in: text) ?? .distantPast) >= cutoff
            } else if keep {
                current += text + "\n"
            }
        }
        if keep, !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func timestamp(in header: String) -> Date? {
        let parts = header.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return iso.date(from: String(parts[1]))
    }

    private static func logURL(in container: URL) -> URL {
        container.appending(path: "Library/Application Support").appending(path: fileName)
    }

    private static func actionURL(process: String, container: URL?) -> URL? {
        guard let root = container ?? (try? SharedPaths())?.containerURL else { return nil }
        return root.appending(path: "Library/Application Support").appending(path: "last-action-\(process).txt")
    }

    private static var iso: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
