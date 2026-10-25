import SwiftUI

@main
struct CablehopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var devices: DeviceManager
    @State private var transfers: TransferManager
    @State private var ui = UIState()

    init() {
        // Must run before anything reads settings (the transfer history loads as soon as it's created).
        RenameMigration.run()
        _devices = State(initialValue: DeviceManager())
        _transfers = State(initialValue: TransferManager())
    }

    var body: some Scene {
        // One window, like most Mac utilities; ⌘N is "New Folder" instead of a duplicate window.
        Window("Cablehop", id: "main") {
            ContentView()
                .environment(devices)
                .environment(transfers)
                .environment(ui)
                .frame(minWidth: 920, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 720)
        .commands {
            CablehopCommands(showPairing: { ui.showPairing = true },
                              toggleTransfers: { TransfersPopover.shared.toggle() })
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
@Observable
final class UIState {
    var showPairing = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets the app show a Dock icon and menu bar even when launched as a bare binary.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        DispatchQueue.global(qos: .background).async { Caches.prune() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let transfers = TransferManager.current, transfers.activeCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Transfers are still in progress"
        alert.informativeText = "\(transfers.activeCount) transfer\(transfers.activeCount == 1 ? " is" : "s are") not finished. Quitting will cancel \(transfers.activeCount == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Keep Transferring")
        alert.addButton(withTitle: "Quit Anyway")
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        transfers.cancelAll()
        return .terminateNow
    }
}

struct ContentView: View {
    @Environment(DeviceManager.self) private var dm
    @Environment(TransferManager.self) private var transfers
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        NavigationSplitView {
            SidebarView(showPairing: $ui.showPairing)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            if let device = dm.selectedDevice {
                if device.state == .device {
                    FileBrowserView(device: device, model: dm.browser(for: device.serial))
                        .id(device.serial)
                } else {
                    DeviceStateView(device: device)
                }
            } else {
                WelcomeView(showPairing: $ui.showPairing)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                TransfersToolbarButton()
            }
        }
        .onAppear { TransfersPopover.shared.transfers = transfers }
        .onChange(of: transfers.startedTick) {
            // Pop the transfers list open whenever a copy starts.
            TransfersPopover.shared.show(automatically: true)
        }
        .onChange(of: transfers.activeCount) { _, active in
            guard active == 0, TransfersPopover.shared.openedAutomatically else { return }
            let anyFailed = transfers.items.contains { if case .failed = $0.state { return true }; return false }
            guard !anyFailed else { return }  // leave it open so the error is seen
            Task {
                try? await Task.sleep(for: .seconds(3))
                if transfers.activeCount == 0 { TransfersPopover.shared.closeIfOpenedAutomatically() }
            }
        }
        .sheet(isPresented: $ui.showPairing) {
            WirelessPairingView()
        }
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.downloadFolderKey) private var downloadFolder = Prefs.defaultDownloadFolder
    @AppStorage(Notifier.enabledKey) private var notify = true
    @State private var cacheSize: Int64?

    var body: some View {
        Form {
            Section("Transfers") {
                LabeledContent("Save downloads to") {
                    HStack {
                        Text((downloadFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
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
            Section("Storage") {
                LabeledContent("Thumbnails & previews") {
                    HStack {
                        Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            Caches.clearAll()
                            Task { await ThumbnailLoader.shared.clearMemory() }
                            cacheSize = 0
                        }
                    }
                }
                Text("Copies of photos and files you open or preview are kept on this Mac for a day, then removed automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("adb (for USB debugging)") {
                    Text(ADB.path ?? "Not installed. File transfer still works.").foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .task {
            cacheSize = await Task.detached { Caches.size(of: Caches.root) }.value
        }
    }
}
