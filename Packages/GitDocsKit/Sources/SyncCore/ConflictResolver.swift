import Foundation

public enum LocalOpKind: Sendable, Equatable {
    case create, modify, delete, rename
}

public enum ConflictAction: Sendable, Equatable {
    case takeLocal
    case takeRemote
    case conflictCopy(String)
    case resurrectLocal
    case cancelDelete
    case dropLocal
}

public enum ConflictResolver {
    public static func resolve(local: LocalOpKind, remote: RemoteDiffEntry.Status, policy: ConflictPolicy,
                               path: String, login: String, now: Date = Date(), takenNames: Set<String> = []) -> ConflictAction {
        switch (local, remote) {
        case (.create, .added):
            return policy == .keepBoth ? .conflictCopy(copyName(path: path, login: login, now: now, taken: takenNames)) : .takeLocal
        case (.modify, .modified), (.modify, .changed):
            return policy == .keepBoth ? .conflictCopy(copyName(path: path, login: login, now: now, taken: takenNames)) : .takeLocal
        case (.modify, .removed):
            return .resurrectLocal
        case (.delete, .modified), (.delete, .changed):
            return .cancelDelete
        case (.delete, .removed):
            return .dropLocal
        case (.rename, .modified), (.rename, .changed):
            return .takeRemote
        case (.rename, .removed):
            return .resurrectLocal
        case (.rename, .renamed):
            return .takeRemote
        case (_, .added) where local == .modify:
            return .conflictCopy(copyName(path: path, login: login, now: now, taken: takenNames))
        default:
            return .conflictCopy(copyName(path: path, login: login, now: now, taken: takenNames))
        }
    }

    public static func copyName(path: String, login: String, now: Date, taken: Set<String>) -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? path : ns.deletingPathExtension
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let base = "\(stem) (conflicted copy \(login) \(formatter.string(from: now)))"
        var candidate = ext.isEmpty ? base : "\(base).\(ext)"
        var index = 2
        while taken.contains(candidate) {
            let numbered = "\(base) \(index)"
            candidate = ext.isEmpty ? numbered : "\(numbered).\(ext)"
            index += 1
        }
        return candidate
    }
}
