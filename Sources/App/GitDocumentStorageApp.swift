import AppKit
import SwiftUI
import SyncCore

@main
struct GitDocumentStorageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("GDS", systemImage: "folder.badge.gearshape") {
            MenuBarContent()
        }
        Window("Over GitHub Limit", id: "over-limit") {
            OverLimitView()
        }
        .defaultSize(width: 720, height: 480)
        Settings {
            SettingsView()
        }
    }
}

struct MenuBarContent: View {
    @Bindable private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("GDS").font(.headline)
        Text("Git Document Storage").font(.caption).foregroundStyle(.secondary)
        Text(model.status).font(.caption)
        TimelineView(.periodic(from: .now, by: 0.4)) { _ in
            let meters = SyncActivity.current()
            SyncMeterRow(title: "From GitHub", meter: meters.download)
            SyncMeterRow(title: "To GitHub", meter: meters.upload)
        }
        Button("Sync Now") { Task { await model.syncAll() } }
        Button("Show Logs") { model.showProblemLog() }
        Button("Over Limit…") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            openWindow(id: "over-limit")
        }
        if !model.repos.isEmpty {
            Divider()
            ForEach(model.repos) { repo in
                Menu(repo.displayName) {
                    Button("Open") { Task { await model.open(repo) } }
                    Button("Sync Now") { Task { await model.sync(repo) } }
                }
            }
        }
        Divider()
        Button("Open Demo Folder") { Task { await DomainManager.shared.openDemoInFinder() } }
        SettingsLink {
            Text("Settings…")
        }
        .simultaneousGesture(TapGesture().onEnded {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        })
        .keyboardShortcut(",")
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private struct SyncMeterRow: View {
    let title: String
    let meter: SyncMeter

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(meter.percent)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            SyncBar(fraction: meter.fraction)
            Text(meter.caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minWidth: 240)
    }
}

private struct SyncBar: View {
    let fraction: Double
    /// Фиксированная ширина. `GeometryReader` в `MenuBarExtra` зацикливает layout и роняет главный поток в stack overflow.
    private let width: CGFloat = 216

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule()
                .fill(Color.accentColor)
                .frame(width: width * clamped)
        }
        .frame(width: width, height: 6)
    }
}

struct SettingsView: View {
    @Bindable private var model = AppModel.shared
    @State private var tab = 0
    @State private var launchAtLogin = false
    @State private var launchNeedsApproval = false
    @State private var launchError: String?

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                FoldersTab().tabItem { Text("Folders") }.tag(0)
                AccountsTab().tabItem { Text("Accounts") }.tag(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Start at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                        } catch {
                            launchError = error.localizedDescription
                        }
                        refreshLaunchState()
                    }
                ))
                if launchNeedsApproval {
                    Text("macOS is waiting for approval in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
                Text("GDS — Git Document Storage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 640, height: 460)
        .onAppear {
            model.reload()
            refreshLaunchState()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    private func refreshLaunchState() {
        launchAtLogin = LaunchAtLogin.isOn
        launchNeedsApproval = LaunchAtLogin.needsApproval
    }
}

private struct FoldersTab: View {
    @Bindable private var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.appGroupAvailable {
                Text("Finder folders need a signed build so the App Group container exists. `make run` after `Config/Local.xcconfig` has your Team ID.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            List(model.repos) { repo in
                HStack {
                    VStack(alignment: .leading) {
                        Text(repo.displayName).font(.headline)
                        Text("\(repo.fullName) · \(repo.branch) · \(repo.mode == .readWrite ? "read & write" : "read only")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { Task { await model.open(repo) } }
                    Button("Remove") { Task { await model.removeFolder(repo) } }
                }
            }
            .frame(minHeight: 140)
            Divider()
            TextField("owner/repo or GitHub URL", text: $model.repoDraft)
            HStack {
                Picker("Account", selection: $model.selectedAccountID) {
                    Text("None").tag(nil as String?)
                    ForEach(model.accounts) { account in
                        Text(account.login).tag(Optional(account.id))
                    }
                }
                Picker("Conflicts", selection: $model.conflictPolicy) {
                    Text("Last writer wins").tag(ConflictPolicy.lastWriterWins)
                    Text("Keep both").tag(ConflictPolicy.keepBoth)
                }
            }
            TextField("Folder name in Finder", text: $model.folderName)
            if let report = model.capability {
                Text(reportLine(report)).font(.callout)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button(model.checking ? "Checking…" : "Check access") { Task { await model.checkAccess() } }
                    .disabled(model.checking)
                Button("Add folder") { Task { await model.addFolder() } }
                    .disabled(model.capability?.mode == .unavailable || model.capability == nil)
            }
        }
        .padding()
    }

    private func reportLine(_ report: CapabilityReport) -> String {
        switch report.mode {
        case .readWrite:
            let extra = report.isEmptyRepository ? " Empty repository." : ""
            let warnings = report.warnings.map(\.rawValue).joined(separator: ", ")
            return "Live sync (read & write).\(extra)" + (warnings.isEmpty ? "" : " Warnings: \(warnings).")
        case .readOnly:
            return "Read only: \(report.reasons.map(\.rawValue).joined(separator: ", "))."
        case .unavailable:
            return "No access with this account."
        }
    }
}

private struct AccountsTab: View {
    @Bindable private var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(model.accounts) { account in
                HStack {
                    Text(account.login)
                    Text(account.tokenKind == .oauthDeviceFlow ? "GitHub sign-in" : "Token")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign out") { Task { await model.signOut(account) } }
                }
            }
            .frame(minHeight: 120)
            TextField("GitHub OAuth Client ID", text: $model.oauthClientID)
                .onSubmit { model.saveClientID() }
            HStack {
                Button("Save Client ID") { model.saveClientID() }
                Button("Sign in with GitHub") { Task { await model.startDeviceFlow() } }
                    .disabled(model.resolvedClientID.isEmpty)
            }
            if let code = model.deviceCode {
                Text("Code \(code) copied. Confirm it in the browser.")
                    .font(.title3)
            }
            SecureField("Or paste a personal access token", text: $model.tokenDraft)
            Button("Use this token") { Task { await model.saveToken() } }
                .disabled(model.tokenDraft.isEmpty)
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Text("The token needs access to repository contents. Fine-grained: Contents Read and write. Classic: repo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
