import Foundation

/// Файлы, которые никогда не уходят в репозиторий (docs/03 §6). Проверяется по имени каждого компонента пути.
public struct IgnoreRules: Sendable {
    public static let `default` = IgnoreRules()

    private let exactNames: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".fseventsd", ".apdisk",
        "Icon\r", ".git",
    ]
    private let prefixes: [String] = ["._", "~$", ".~lock.", ".#"]
    private let suffixes: [String] = [".tmp", ".crdownload", ".part", ".download"]
    private let containsPatterns: [String] = [".sb-"]

    public init() {}

    /// `true`, если элемент с таким именем (не путём!) не должен выгружаться.
    public func isIgnoredName(_ name: String) -> Bool {
        if exactNames.contains(name) { return true }
        if prefixes.contains(where: { name.hasPrefix($0) }) { return true }
        if suffixes.contains(where: { name.lowercased().hasSuffix($0) }) { return true }
        if containsPatterns.contains(where: { name.contains($0) }) { return true }
        return false
    }

    /// `true`, если хотя бы один компонент пути игнорируется.
    public func isIgnoredPath(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains { isIgnoredName(String($0)) }
    }
}
