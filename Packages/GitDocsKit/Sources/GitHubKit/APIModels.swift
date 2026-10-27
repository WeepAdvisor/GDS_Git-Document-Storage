import Foundation

public struct GHRepository: Decodable, Sendable, Equatable {
    public struct Permissions: Decodable, Sendable, Equatable {
        public var admin: Bool?
        public var push: Bool?
        public var pull: Bool?
    }

    public var name: String
    public var fullName: String
    public var defaultBranch: String?
    public var archived: Bool?
    public var disabled: Bool?
    /// Размер репозитория в килобайтах, как отдаёт GitHub.
    public var size: Int?
    public var permissions: Permissions?
}

public struct GHBranch: Decodable, Sendable, Equatable {
    public struct Commit: Decodable, Sendable, Equatable {
        public var sha: String
    }
    public var name: String
    public var protected: Bool
    public var commit: Commit
}

public struct GHBranchProtection: Decodable, Sendable, Equatable {
    public struct Reviews: Decodable, Sendable, Equatable {
        public var requiredApprovingReviewCount: Int?
    }
    public struct StatusChecks: Decodable, Sendable, Equatable {
        public var contexts: [String]?
        public var checks: [Check]?
        public struct Check: Decodable, Sendable, Equatable { public var context: String? }
    }
    public struct Admins: Decodable, Sendable, Equatable {
        public var enabled: Bool?
    }
    public var requiredPullRequestReviews: Reviews?
    public var requiredStatusChecks: StatusChecks?
    public var enforceAdmins: Admins?
}

public struct GHRef: Decodable, Sendable, Equatable {
    public struct Object: Decodable, Sendable, Equatable {
        public var sha: String
        public var type: String
    }
    public var object: Object
}

public struct GHCommitObject: Decodable, Sendable, Equatable {
    public struct Tree: Decodable, Sendable, Equatable { public var sha: String }
    public struct Person: Decodable, Sendable, Equatable { public var date: Date? }
    public var sha: String
    public var message: String?
    public var tree: Tree
    public var committer: Person?
}

public struct GHTree: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public var path: String
        public var mode: String
        public var type: String
        public var sha: String
        public var size: Int?
    }
    public var sha: String
    public var truncated: Bool?
    public var tree: [Entry]
}

public struct GHCompare: Decodable, Sendable, Equatable {
    public struct File: Decodable, Sendable, Equatable {
        public var filename: String
        public var status: String
        public var sha: String?
        public var previousFilename: String?
    }
    public struct Commit: Decodable, Sendable, Equatable {
        public struct Git: Decodable, Sendable, Equatable {
            public var message: String
            public var committer: GHCommitObject.Person?
        }
        public struct Author: Decodable, Sendable, Equatable { public var login: String? }
        public var sha: String
        public var commit: Git
        public var author: Author?
    }
    public var files: [File]?
    public var commits: [Commit]?
}

public struct GHUser: Decodable, Sendable, Equatable {
    public var login: String
    public var name: String?
    public var avatarUrl: URL?
}

public struct GHContents: Decodable, Sendable, Equatable {
    public var content: String?
    public var encoding: String?
}

public struct GHCreatedObject: Decodable, Sendable, Equatable {
    public var sha: String
}

public struct GHContentsWriteResult: Decodable, Sendable, Equatable {
    public struct Content: Decodable, Sendable, Equatable { public var sha: String? }
    public struct Commit: Decodable, Sendable, Equatable {
        public var sha: String
        public var commit: Inner?
        public struct Inner: Decodable, Sendable, Equatable {
            public var committer: GHCommitObject.Person?
        }
    }
    public var content: Content?
    public var commit: Commit
}
