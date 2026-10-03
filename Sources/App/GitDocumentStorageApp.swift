import SwiftUI
import SyncCore

@main
struct GitDocumentStorageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("GitDocumentStorage", systemImage: "folder.badge.gearshape") {
            MenuBarContent()
        }
        Settings {
            SettingsView()
        }
    }
}

struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("GitDocumentStorage — Phase 0").font(.headline)
        Divider()
        Button("Open Demo Folder in Finder") {
            Task { await DomainManager.shared.openDemoInFinder() }
        }
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Text("Folders, Accounts and General settings arrive in Phase 6 (see docs/00-PLAN.md).")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 480, height: 200)
    }
}
