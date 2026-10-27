import Foundation

public enum Endpoints {
    public static func repository(owner: String, repo: String) -> Endpoint {
        Endpoint(method: .get, path: "/repos/\(owner)/\(repo)")
    }

    public static func branch(owner: String, repo: String, branch: String) -> Endpoint {
        Endpoint(method: .get, path: "/repos/\(owner)/\(repo)/branches/\(branch)")
    }

    public static func branchProtection(owner: String, repo: String, branch: String) -> Endpoint {
        Endpoint(method: .get, path: "/repos/\(owner)/\(repo)/branches/\(branch)/protection")
    }

    public static func ref(owner: String, repo: String, branch: String) -> Endpoint {
        Endpoint(method: .get, path: "/repos/\(owner)/\(repo)/git/ref/heads/\(branch)", usesETag: true)
    }

    public static func commit(owner: String, repo: String, sha: String) -> Endpoint {
        Endpoint(method: .get, path: "/repos/\(owner)/\(repo)/git/commits/\(sha)")
    }

    public static func tree(owner: String, repo: String, sha: String, recursive: Bool) -> Endpoint {
        Endpoint(method: .get, path: "/repos/\(owner)/\(repo)/git/trees/\(sha)",
                 query: recursive ? [URLQueryItem(name: "recursive", value: "1")] : [])
    }

    public static func blob(owner: String, repo: String, sha: String) -> Endpoint {
        Endpoint(method: .get, path: "/repos/\(owner)/\(repo)/git/blobs/\(sha)",
                 accept: "application/vnd.github.raw+json", category: .blobDownload)
    }

    public static func compare(owner: String, repo: String, base: String, head: String) -> Endpoint {
        Endpoint(method: .get, path: "/repos/\(owner)/\(repo)/compare/\(base)...\(head)")
    }

    public static func contents(owner: String, repo: String, path: String) -> Endpoint {
        Endpoint(method: .get, path: "/repos/\(owner)/\(repo)/contents/\(path)")
    }

    public static func user() -> Endpoint {
        Endpoint(method: .get, path: "/user")
    }

    public static func userRepos(page: Int) -> Endpoint {
        Endpoint(method: .get, path: "/user/repos", query: [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "pushed"),
            URLQueryItem(name: "page", value: String(page)),
        ])
    }

    public static func graphQL(body: Data) -> Endpoint {
        Endpoint(method: .post, path: "/graphql", body: body, category: .graphQL)
    }

    public static func createBlob(owner: String, repo: String, json: Data) -> Endpoint {
        Endpoint(method: .post, path: "/repos/\(owner)/\(repo)/git/blobs", body: json, category: .blobUpload)
    }

    /// Тело передаётся файлом, чтобы не держать base64 большого блоба в памяти.
    public static func createBlob(owner: String, repo: String) -> Endpoint {
        Endpoint(method: .post, path: "/repos/\(owner)/\(repo)/git/blobs", category: .blobUpload)
    }

    public static func createTree(owner: String, repo: String, json: Data) -> Endpoint {
        Endpoint(method: .post, path: "/repos/\(owner)/\(repo)/git/trees", body: json, category: .mutation)
    }

    public static func createCommit(owner: String, repo: String, json: Data) -> Endpoint {
        Endpoint(method: .post, path: "/repos/\(owner)/\(repo)/git/commits", body: json, category: .mutation)
    }

    public static func updateRef(owner: String, repo: String, branch: String, json: Data) -> Endpoint {
        Endpoint(method: .patch, path: "/repos/\(owner)/\(repo)/git/refs/heads/\(branch)", body: json, category: .mutation)
    }

    public static func putContents(owner: String, repo: String, path: String, json: Data) -> Endpoint {
        Endpoint(method: .put, path: "/repos/\(owner)/\(repo)/contents/\(path)", body: json, category: .mutation)
    }

    public static func putContents(owner: String, repo: String, path: String) -> Endpoint {
        Endpoint(method: .put, path: "/repos/\(owner)/\(repo)/contents/\(path)", category: .mutation)
    }
}
