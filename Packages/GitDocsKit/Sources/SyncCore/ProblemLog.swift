import Foundation

/// Локальный журнал только сбоев. Хранится 7 дней в контейнере App Group.
public enum ProblemLog {
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    private static let fileName = "problem-log.txt"
    private static let dedupeWindow: TimeInterval = 5 * 60

    public static func record(kind: String, message: String, path: String? = nil, domain: String? = nil, container: URL? = nil) {
        guard let root = container ?? (try? SharedPaths())?.containerURL else { return }
        let url = logURL(in: root)
        let line = format(kind: kind, message: message, path: path, domain: domain, at: Date())
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { url in
            append(line, to: url)
        }
    }

    /// Файл для кнопки в меню. Если за неделю ничего не было — одна строка об этом.
    public static func preparedFileURL(container: URL? = nil) -> URL? {
        guard let root = container ?? (try? SharedPaths())?.containerURL else { return nil }
        let url = logURL(in: root)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { url in
            let kept = currentLines(at: url)
            let crashes = CrashLog.recentText(container: root)
            let crashSection = crashes.isEmpty ? "No crashes in the last 7 days.\n" : crashes
            let problems = kept.isEmpty ? "No problems in the last 7 days.\n" : kept.joined(separator: "\n") + "\n"
            let text = problems + "\n=== Crashes ===\n" + crashSection
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    static func format(kind: String, message: String, path: String?, domain: String?, at: Date) -> String {
        let stamp = iso.string(from: at)
        let where_ = domain ?? "-"
        let file = path ?? "-"
        let text = message.replacingOccurrences(of: "\n", with: " ")
        return "\(stamp)\t\(where_)\t\(kind)\t\(file)\t\(text)"
    }

    private static func append(_ line: String, to url: URL) {
        var lines = currentLines(at: url)
        if let last = lines.last, sameProblem(last, line), recent(last) { return }
        lines.append(line)
        let text = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func currentLines(at url: URL) -> [String] {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let cutoff = Date().addingTimeInterval(-retention)
        return raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { piece in
            let line = String(piece)
            guard let at = timestamp(of: line) else { return nil }
            return at >= cutoff ? line : nil
        }
    }

    private static func timestamp(of line: String) -> Date? {
        let stamp = line.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
        return iso.date(from: stamp)
    }

    private static func sameProblem(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "\t").dropFirst().joined(separator: "\t")
        let right = rhs.split(separator: "\t").dropFirst().joined(separator: "\t")
        return left == right
    }

    private static func recent(_ line: String) -> Bool {
        guard let at = timestamp(of: line) else { return false }
        return Date().timeIntervalSince(at) < dedupeWindow
    }

    private static func logURL(in container: URL) -> URL {
        container.appending(path: "Library/Application Support").appending(path: fileName)
    }

    private static var iso: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
