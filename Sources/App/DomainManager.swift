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
