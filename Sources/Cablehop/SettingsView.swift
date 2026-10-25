import SwiftUI

/// Cablehop › Settings (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            HelpSettings()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.downloadFolderKey) private var downloadFolder = Prefs.defaultDownloadFolder
    @AppStorage(Notifier.enabledKey) private var notify = true

    var body: some View {
        Form {
            Section("Transfers") {
                LabeledContent("Save downloads to") {
                    HStack {
                        Text((downloadFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { downloadFolder = url.path }
                        }
                    }
                }
                Toggle("Notify me when transfers finish in the background", isOn: $notify)
            }
            Section("USB debugging") {
                LabeledContent("adb") {
                    Text(ADB.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not installed. File transfer still works.")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UpdateSettings: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                LabeledContent("Current version") {
                    Text(AppInfo.version).monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Last checked") {
                    Text(updater.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                        .glassButton()
                }
            } footer: {
                Text("Cablehop asks GitHub once a day whether a newer release exists. Updates are checked against their published checksum before they're installed. Nothing about you or your phone is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StorageSettings: View {
    @State private var cacheSize: Int64?
    @State private var logSize: Int64?

    var body: some View {
        Form {
            Section {
                LabeledContent("Thumbnails & previews") {
                    HStack {
                        Text(size(cacheSize)).foregroundStyle(.secondary)
                        Button("Clear") {
                            Caches.clearAll()
                            Task { await ThumbnailLoader.shared.clearMemory() }
                            cacheSize = 0
                        }
                    }
                }
                LabeledContent("Logs") {
                    Text(size(logSize)).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Copies of files you open or preview are removed after a day. Logs are capped at about 10 MB.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            cacheSize = await Task.detached { Caches.size(of: Caches.root) }.value
            logSize = await Task.detached { Caches.size(of: LogStore.shared.directory) }.value
        }
    }

    private func size(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…"
    }
}

private struct HelpSettings: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @State private var showReport = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        Button("View Logs") { openWindow(id: "logs") }
                        Button("Save Logs…") { LogStore.saveWithPanel() }
                    }
                } label: {
                    Text("Logs")
                    Text("A record of what Cablehop did, kept only on this Mac.")
                }
                LabeledContent {
                    Button("Report a Problem…") { showReport = true }.prominentGlassButton()
                } label: {
                    Text("Need help?")
                    Text("Save your logs, then open an issue on GitHub.")
                }
            }
            Section {
                LabeledContent("Project") {
                    Button("Cablehop on GitHub") { openURL(AppInfo.repositoryURL) }.buttonStyle(.link)
                }
                LabeledContent("Version") {
                    Text(AppInfo.version).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showReport) { ReportProblemView() }
    }
}
