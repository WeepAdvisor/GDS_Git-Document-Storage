import Foundation

/// Нормализация и валидация путей (docs/02 §5).
public enum PathNormalizer {
    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case containsNUL
        case dotOrDotDot
        case gitDirectory
        case trailingSpaceOrDot
        case tooLong
    }

    /// Максимальная длина компонента (ограничение APFS 255 байт UTF-8).
    public static let maxComponentBytes = 255

    /// Приводит имя компонента к NFC (в git храним NFC).
    public static func normalizeName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// Собирает путь из компонентов, каждый — NFC.
    public static func joinPath(_ components: [String]) -> String {
        components.map(normalizeName).joined(separator: "/")
    }

    /// Проверка одного компонента имени, которое пришло от Finder.
    public static func validateName(_ name: String) -> ValidationError? {
        if name.isEmpty { return .empty }
        if name.contains("\u{0}") { return .containsNUL }
        if name == "." || name == ".." { return .dotOrDotDot }
        if name == ".git" { return .gitDirectory }
        if name.hasSuffix(" ") || (name.hasSuffix(".") && name != ".") { return .trailingSpaceOrDot }
        if name.utf8.count > maxComponentBytes { return .tooLong }
        return nil
    }

    /// Разбивает серверный путь на компоненты (без пустых).
    public static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Родительский путь (`""` для корня).
    public static func parentPath(of path: String) -> String {
        var parts = components(of: path)
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    public static func fileName(of path: String) -> String {
        components(of: path).last ?? ""
    }
}
