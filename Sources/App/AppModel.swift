import AppKit
import Foundation
import GitHubKit
import Observation
import SyncCore

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var accounts: [Account] = []
    var repos: [RepoConfig] = []
    var oauthClientID: String = ""
    var status: String = "Starting"
    var deviceCode: String?
    var errorMessage: String?

    var tokenDraft = ""
    var repoDraft = ""
    var folderName = ""
    var selectedAccountID: String?
    var conflictPolicy: ConflictPolicy = .lastWriterWins
    var capability: CapabilityReport?
    var checking = false

    private let poller = RemotePoller()
    private var started = false
    private var configuration = AppConfiguration()

    var appGroupAvailable: Bool { (try? SharedPaths()) != nil }

    func start() {
        guard !started else { return }
        started = true
        reload()
        status = repos.isEmpty ? "Add a folder" : "Watching \(repos.count) folder\(repos.count == 1 ? "" : "s")"
        Task {
            await DomainManager.shared.rebindDomainsIfProviderNameChanged()
            await DomainManager.shared.registerDemoDomainIfNeeded()
            await DomainManager.shared.syncConfiguredDomains()
            await DomainManager.shared.reconnectAll()
        }
        Task { await poller.start() }
    }

    func syncAll() async {
        await sync(repos.filter { $0.isEnabled && $0.mode != .unavailable })
    }

    func sync(_ repo: RepoConfig) async {
        await sync([repo])
    }

    func showProblemLog() {
        guard let url = ProblemLog.preparedFileURL() else {
            status = "Problem log is unavailable"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func sync(_ targets: [RepoConfig]) async {
        guard !targets.isEmpty else { return }
        let names = targets.map(\.displayName).joined(separator: ", ")
        CrashLog.mark("Sync Now \(names)", process: "app")
        status = "Syncing…"
        await DomainManager.shared.requestSync(domainIDs: targets.map(\.id))
        CrashLog.clearMark(process: "app")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if status == "Syncing…" {
            status = repos.isEmpty ? "Add a folder" : "Watching \(repos.count) folder\(repos.count == 1 ? "" : "s")"
        }
    }

    func reload() {
        configuration = (try? RepoConfigStore.resolve().load()) ?? AppConfiguration()
        accounts = configuration.accounts
        repos = configuration.repos
        if oauthClientID.isEmpty {
            oauthClientID = configuration.oauthClientID ?? bundledClientID ?? ""
        }
        if selectedAccountID == nil { selectedAccountID = accounts.first?.id }
    }

    func saveToken() async {
        let raw = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        errorMessage = nil
        let client = GitHubClient { raw }
        do {
            let user = try await client.value(Endpoints.user(), as: GHUser.self)
            let account = Account(login: user.login, displayName: user.name, avatarURL: user.avatarUrl, tokenKind: .personalAccessToken)
            try await KeychainTokenStore.fromBundle().setToken(raw, for: account.id)
            upsert(account)
            tokenDraft = ""
            selectedAccountID = account.id
            status = "Signed in as \(user.login)"
        } catch {
            errorMessage = "GitHub rejected that token. \(error.localizedDescription)"
        }
    }

    func startDeviceFlow() async {
        let clientID = resolvedClientID
        guard !clientID.isEmpty else {
            errorMessage = "Set a GitHub OAuth Client ID first. Device Flow must be enabled on that OAuth App."
            return
        }
        errorMessage = nil
        let auth = DeviceFlowAuthenticator(clientID: clientID)
        do {
            let session = try await auth.start()
            deviceCode = session.userCode
            copy(session.userCode)
            NSWorkspace.shared.open(session.verificationURI)
            for try await event in auth.poll(session) {
                if case let .authorized(token, _) = event {
                    deviceCode = nil
                    tokenDraft = token
                    await saveToken()
                    if let id = selectedAccountID, var account = accounts.first(where: { $0.id == id }) {
                        account.tokenKind = .oauthDeviceFlow
                        upsert(account)
                    }
                    return
                }
            }
        } catch {
            deviceCode = nil
            errorMessage = error.localizedDescription
        }
    }

    func signOut(_ account: Account) async {
        try? await KeychainTokenStore.fromBundle().removeToken(for: account.id)
        configuration.accounts.removeAll { $0.id == account.id }
        persist()
        for repo in repos where repo.accountID == account.id {
            await DomainManager.shared.removeDomain(id: repo.id)
        }
        configuration.repos.removeAll { $0.accountID == account.id }
        persist()
        reload()
    }

    func checkAccess() async {
        guard let ownerRepo = Self.parse(repoDraft) else {
            errorMessage = "Use owner/repo or a github.com URL."
            return
        }
        guard let account = accounts.first(where: { $0.id == selectedAccountID }) ?? accounts.first else {
            errorMessage = "Add a GitHub account first."
            return
        }
        checking = true
        defer { checking = false }
        errorMessage = nil
        let client = client(for: account)
        capability = await CapabilityChecker.check(owner: ownerRepo.0, repo: ownerRepo.1, account: account, client: client)
        if folderName.isEmpty { folderName = ownerRepo.1 }
    }

    func addFolder() async {
        guard let ownerRepo = Self.parse(repoDraft) else { return }
        guard let account = accounts.first(where: { $0.id == selectedAccountID }) ?? accounts.first else { return }
        let report = capability ?? CapabilityReport(mode: .readOnly, reasons: [.noAccess], accountID: account.id)
        guard report.mode != .unavailable else {
            errorMessage = "This account cannot open that repository."
            return
        }
        let config = RepoConfig(
            owner: ownerRepo.0, repo: ownerRepo.1, branch: report.defaultBranch ?? "main", accountID: account.id,
            displayName: folderName.isEmpty ? ownerRepo.1 : folderName, mode: report.mode, conflictPolicy: conflictPolicy,
            lastCapabilityReport: report
        )
        configuration.repos.append(config)
        persist()
        reload()
        await DomainManager.shared.syncConfiguredDomains()
        await DomainManager.shared.reconnectAll()
        repoDraft = ""
        folderName = ""
        capability = nil
        status = "Folder \(config.displayName) is in Finder"
    }

    func removeFolder(_ repo: RepoConfig) async {
        await DomainManager.shared.removeDomain(id: repo.id)
        configuration.repos.removeAll { $0.id == repo.id }
        persist()
        reload()
    }

    func open(_ repo: RepoConfig) async {
        await DomainManager.shared.openInFinder(domainID: repo.id.uuidString)
    }

    func saveClientID() {
        let trimmed = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.oauthClientID = trimmed.isEmpty || trimmed == "REPLACE_ME" ? nil : trimmed
        persist()
    }

    var resolvedClientID: String {
        let typed = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, typed != "REPLACE_ME" { return typed }
        return bundledClientID ?? ""
    }

    private var bundledClientID: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "GDSGitHubOAuthClientID") as? String
        guard let value, !value.isEmpty, value != "REPLACE_ME" else { return nil }
        return value
    }

    private func client(for account: Account) -> GitHubClient {
        let store = KeychainTokenStore.fromBundle()
        let accountID = account.id
        return GitHubClient {
            guard let token = try await store.token(for: accountID) else { throw GitHubError.unauthorized }
            return token
        }
    }

    private func upsert(_ account: Account) {
        if let index = configuration.accounts.firstIndex(where: { $0.id == account.id }) {
            configuration.accounts[index] = account
        } else {
            configuration.accounts.append(account)
        }
        persist()
        reload()
    }

    private func persist() {
        try? RepoConfigStore.resolve().save(configuration)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func parse(_ raw: String) -> (String, String)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), url.host?.contains("github.com") == true {
            text = url.path
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if text.hasSuffix(".git") { text.removeLast(4) }
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}
