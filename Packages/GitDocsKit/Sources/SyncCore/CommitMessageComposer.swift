import Foundation

public enum CommitMessageComposer {
    public static func compose(changes: [CommitChange], createdPaths: Set<String> = []) -> (headline: String, body: String?) {
        var added: [String] = []
        var deleted: [String] = []
        var renamed: [String] = []
        for change in changes {
            switch change {
            case .addition(let path, _, _, _), .copy(let path, _, _):
                added.append(path)
            case .deletion(let path):
                deleted.append(path)
            case .move(let from, let to, _, _):
                renamed.append("\(Self.name(from)) → \(Self.name(to))")
            }
        }
        let headline: String
        if renamed.count == 1, added.isEmpty, deleted.isEmpty {
            headline = "Rename \(renamed[0])"
        } else if added.count == 1, deleted.isEmpty, renamed.isEmpty {
            let path = added[0]
            headline = createdPaths.contains(path) ? "Add \(name(path))" : "Update \(name(path))"
        } else if deleted.count == 1, added.isEmpty, renamed.isEmpty {
            headline = "Delete \(name(deleted[0]))"
        } else if added.count > 1, deleted.isEmpty, renamed.isEmpty {
            headline = "Add \(added.count) files"
        } else {
            var parts: [String] = []
            if !added.isEmpty { parts.append("update \(added.count)") }
            if !deleted.isEmpty { parts.append("delete \(deleted.count)") }
            if !renamed.isEmpty { parts.append("rename \(renamed.count)") }
            headline = parts.joined(separator: ", ").capitalized
        }
        let lines = (added + deleted + renamed).prefix(50)
        return (headline, lines.isEmpty ? nil : lines.joined(separator: "\n"))
    }

    private static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
