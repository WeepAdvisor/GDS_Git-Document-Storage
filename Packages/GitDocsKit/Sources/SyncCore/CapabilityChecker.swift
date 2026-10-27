import Foundation
import GitHubKit

public enum CapabilityChecker {
    public static func check(owner: String, repo: String, account: Account, client: GitHubClient) async -> CapabilityReport {
        do {
            let repository = try await client.value(Endpoints.repository(owner: owner, repo: repo), as: GHRepository.self)
            var warnings: [CapabilityReport.Warning] = []
            var reasons: [CapabilityReport.Reason] = []
            if repository.archived == true {
                return report(.readOnly, reasons: [.archived], account: account, branch: repository.defaultBranch)
            }
            if repository.disabled == true {
                return report(.readOnly, reasons: [.disabled], account: account, branch: repository.defaultBranch)
            }
            if let size = repository.size, size > 2_000_000 { warnings.append(.largeRepo) }
            let branchName = repository.defaultBranch ?? "main"
            let canPush = repository.permissions?.push == true
            if repository.permissions?.push == false {
                reasons.append(.noPush)
            }

            let branchResponse: GitHubClient.Response<GHBranch>
            do {
                branchResponse = try await client.request(Endpoints.branch(owner: owner, repo: repo, branch: branchName))
            } catch let error as GitHubError where error == .notFound || error == .emptyRepository {
                return report(.readWrite, reasons: [.emptyRepo], warnings: warnings, account: account, branch: branchName, empty: true)
            }
            let branch = branchResponse.body
            if branch.protected {
                do {
                    let protection = try await client.value(Endpoints.branchProtection(owner: owner, repo: repo, branch: branchName), as: GHBranchProtection.self)
                    let blocks = protection.requiredPullRequestReviews != nil
                        || protection.requiredStatusChecks != nil
                        || protection.enforceAdmins?.enabled == true
                    if blocks {
                        return report(.readOnly, reasons: [.protectedBranch], warnings: warnings, account: account, branch: branchName)
                    }
                } catch let error as GitHubError {
                    if case .http(let status, _, _) = error, status == 403 { warnings.append(.unknownProtection) }
                    else if case .notFound = error { /* protection endpoint 404 means unprotected */ }
                    else { warnings.append(.unknownProtection) }
                }
            }
            if let attributes = try? await client.value(Endpoints.contents(owner: owner, repo: repo, path: ".gitattributes"), as: GHContents.self),
               let text = decodeContents(attributes), text.contains("filter=lfs") {
                warnings.append(.lfsDetected)
            }
            if let ref = try? await client.value(Endpoints.ref(owner: owner, repo: repo, branch: branchName), as: GHRef.self),
               let commit = try? await client.value(Endpoints.commit(owner: owner, repo: repo, sha: ref.object.sha), as: GHCommitObject.self),
               let tree = try? await client.value(Endpoints.tree(owner: owner, repo: repo, sha: commit.tree.sha, recursive: true), as: GHTree.self) {
                if tree.truncated == true { warnings.append(.hugeTree) }
                if tree.tree.count > 20_000 { warnings.append(.largeTree) }
            }
            if let scopes = branchResponse.headers["x-oauth-scopes"], !scopes.isEmpty, !scopes.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("repo") {
                return report(.readOnly, reasons: [.tokenScope], warnings: warnings, account: account, branch: branchName)
            }
            let mode: AccessMode = canPush ? .readWrite : .readOnly
            return report(mode, reasons: reasons, warnings: warnings, account: account, branch: branchName, remaining: branchResponse.rateLimit.remaining)
        } catch let error as GitHubError {
            switch error {
            case .ssoRequired(let url):
                return report(.unavailable, reasons: [.ssoRequired], account: account, sso: url)
            case .unauthorized, .notFound:
                return report(.unavailable, reasons: [.noAccess], account: account)
            default:
                return report(.unavailable, reasons: [.noAccess], account: account)
            }
        } catch {
            return report(.unavailable, reasons: [.noAccess], account: account)
        }
    }

    public static func best(owner: String, repo: String, accounts: [Account], client: (Account) -> GitHubClient) async -> [CapabilityReport] {
        var reports: [CapabilityReport] = []
        for account in accounts {
            reports.append(await check(owner: owner, repo: repo, account: account, client: client(account)))
        }
        return reports.sorted { rank($0.mode) > rank($1.mode) }
    }

    private static func rank(_ mode: AccessMode) -> Int {
        switch mode {
        case .readWrite: return 2
        case .readOnly: return 1
        case .unavailable: return 0
        }
    }

    private static func decodeContents(_ contents: GHContents) -> String? {
        guard contents.encoding == "base64" || contents.encoding == nil, let raw = contents.content else { return nil }
        let cleaned = raw.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else { return raw }
        return String(data: data, encoding: .utf8)
    }

    private static func report(_ mode: AccessMode, reasons: [CapabilityReport.Reason] = [], warnings: [CapabilityReport.Warning] = [],
                               account: Account, branch: String? = nil, empty: Bool = false, sso: URL? = nil, remaining: Int? = nil) -> CapabilityReport {
        CapabilityReport(mode: mode, reasons: reasons, warnings: warnings, accountID: account.id, defaultBranch: branch,
                         isEmptyRepository: empty, ssoAuthorizationURL: sso, rateLimitRemaining: remaining)
    }
}
