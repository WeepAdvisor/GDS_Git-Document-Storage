import AppKit
import FileProvider
import os
import SyncCore

/// Управление доменами File Provider (ADR-004, ADR-005). Фаза 3 синхронизирует список доменов с `RepoConfigStore`.
actor DomainManager {
    static let shared = DomainManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitDocumentStorage", category: "app")

    /// Фаза 0: один демонстрационный домен, чтобы увидеть папку в Finder.
    static let demoDomainIdentifier = NSFileProviderDomainIdentifier(rawValue: "demo")

    /// Старые домены запоминают имя провайдера `GitDocumentStorage`. Один раз снимаем и ставим заново, чтобы Finder показал `GDS`.
    func rebindDomainsIfProviderNameChanged() async {
        let key = "providerSidebarName"
        guard UserDefaults.standard.string(forKey: key) != "GDS" else { return }
        if let domains = try? await NSFileProviderManager.domains() {
            for domain in domains {
                try? await NSFileProviderManager.remove(domain)
            }
        }
        UserDefaults.standard.set("GDS", forKey: key)
        logger.info("Rebound file provider domains under GDS")
    }

    func registerDemoDomainIfNeeded() async {
        do {
            let existing = try await NSFileProviderManager.domains()
            if existing.contains(where: { $0.identifier == Self.demoDomainIdentifier }) { return }
            let domain = NSFileProviderDomain(identifier: Self.demoDomainIdentifier, displayName: "Demo")
            try await NSFileProviderManager.add(domain)
            logger.info("Demo domain added")
        } catch {
            logger.error("Failed to add demo domain: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reconnectAll() async {
        guard let domains = try? await NSFileProviderManager.domains() else { return }
        for domain in domains {
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            do { try await manager.reconnect() } catch {
                logger.error("reconnect \(domain.identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func disconnectAll(reason: String) async {
        guard let domains = try? await NSFileProviderManager.domains() else { return }
        for domain in domains {
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            do { try await manager.disconnect(reason: reason, options: [.temporary]) } catch {
                logger.error("disconnect \(domain.identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func removeAllDomains() async {
        do {
            try await NSFileProviderManager.removeAllDomains()
            logger.info("All domains removed")
        } catch {
            logger.error("removeAllDomains: \(error.localizedDescription, privacy: .public)")
        }
    }

    func syncConfiguredDomains() async {
        let repos = (try? RepoConfigStore.resolve().load().repos) ?? []
        let existing = (try? await NSFileProviderManager.domains()) ?? []
        for repo in repos where repo.isEnabled {
            let identifier = NSFileProviderDomainIdentifier(rawValue: repo.id.uuidString)
            if existing.contains(where: { $0.identifier == identifier }) { continue }
            do {
                try await NSFileProviderManager.add(NSFileProviderDomain(identifier: identifier, displayName: repo.displayName))
                logger.info("Domain added \(repo.fullName, privacy: .public)")
            } catch {
                logger.error("add domain: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func removeDomain(id: UUID) async {
        let identifier = NSFileProviderDomainIdentifier(rawValue: id.uuidString)
        guard let domains = try? await NSFileProviderManager.domains(),
              let domain = domains.first(where: { $0.identifier == identifier }) else { return }
        do { try await NSFileProviderManager.remove(domain) } catch {
            logger.error("remove domain: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reveal(domainID: UUID, itemID: String, path: String) async {
        let identifier = NSFileProviderDomainIdentifier(rawValue: domainID.uuidString)
        guard let domains = try? await NSFileProviderManager.domains(),
              let domain = domains.first(where: { $0.identifier == identifier }),
              let manager = NSFileProviderManager(for: domain) else { return }
        let itemURL = try? await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(itemID))
        let rootURL = try? await manager.getUserVisibleURL(for: .rootContainer)
        let url = itemURL ?? rootURL?.appending(path: path)
        guard let url else { return }
        await MainActor.run {
            _ = url.startAccessingSecurityScopedResource()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openInFinder(domainID: String) async {
        let identifier = NSFileProviderDomainIdentifier(rawValue: domainID)
        guard let domains = try? await NSFileProviderManager.domains(),
              let domain = domains.first(where: { $0.identifier == identifier }),
              let manager = NSFileProviderManager(for: domain) else { return }
        do {
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            _ = url.startAccessingSecurityScopedResource()
            NSWorkspace.shared.open(url)
        } catch {
            logger.error("getUserVisibleURL: \(error.localizedDescription, privacy: .public)")
        }
    }

    func requestSync(domainIDs: [UUID]) async {
        let defaults = (try? SharedPaths())?.userDefaults
        for id in domainIDs {
            SharedDefaultsKey.postSyncRequest(id, defaults: defaults)
            await signal(id.uuidString)
        }
    }

    func signal(_ domainID: String) async {
        let identifier = NSFileProviderDomainIdentifier(rawValue: domainID)
        guard let domains = try? await NSFileProviderManager.domains(),
              let domain = domains.first(where: { $0.identifier == identifier }),
              let manager = NSFileProviderManager(for: domain) else { return }
        try? await manager.signalEnumerator(for: .workingSet)
    }

    func openDemoInFinder() async {
        guard let domains = try? await NSFileProviderManager.domains(),
              let domain = domains.first(where: { $0.identifier == Self.demoDomainIdentifier }),
              let manager = NSFileProviderManager(for: domain) else { return }
        do {
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            _ = url.startAccessingSecurityScopedResource()
            NSWorkspace.shared.open(url)
        } catch {
            logger.error("getUserVisibleURL: \(error.localizedDescription, privacy: .public)")
        }
    }
}
