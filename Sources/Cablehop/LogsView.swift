import AppKit
import SwiftUI

/// The Logs window: everything Cablehop has logged on this Mac, newest at the bottom.
struct LogsView: View {
    @State private var text = ""
    @State private var search = ""
    @State private var problemsOnly = false
    @State private var confirmClear = false

    private var shown: String {
        guard problemsOnly || !search.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            (!problemsOnly || line.contains("[WARN]") || line.contains("[ERROR]"))
                && (search.isEmpty || line.localizedCaseInsensitiveContains(search))
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            LogTextView(text: shown)
            Divider()
            HStack {
                Image(systemName: "lock")
                Text("Stored only on this Mac, in ~/Library/Logs/Cablehop. Nothing is sent anywhere.")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 640, minHeight: 380)
        .navigationTitle("Logs")
        .searchable(text: $search, placement: .toolbar, prompt: "Search logs")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $problemsOnly) { Label("Warnings and Errors Only", systemImage: "exclamationmark.triangle") }
                    .help("Show only warnings and errors")
                Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Load the latest log lines (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(LogStore.shared.exportText(), forType: .string)
                } label: { Label("Copy All", systemImage: "doc.on.doc") }
                    .help("Copy the complete logs, with app and Mac details, to the clipboard")
                Button { LogStore.saveWithPanel() } label: { Label("Save Logs…", systemImage: "square.and.arrow.down") }
                    .help("Save the complete logs as a text file to attach to a bug report (⌘S)")
                    .keyboardShortcut("s", modifiers: .command)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([LogStore.shared.currentFile])
                } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Show the log files in Finder")
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear Logs…", systemImage: "trash") }
                    .help("Delete all log files")
            }
        }
        .confirmationDialog("Delete all logs?", isPresented: $confirmClear) {
            Button("Delete Logs", role: .destructive) {
                LogStore.shared.clear()
                reload()
            }
        } message: {
            Text("If you're about to report a problem, save the logs first.")
        }
        .task { reload() }
    }

    private func reload() {
        Task.detached(priority: .userInitiated) {
            let contents = LogStore.shared.contents()
            await MainActor.run { text = contents.isEmpty ? "No log entries yet." : contents }
        }
    }
}

/// A read-only, selectable, monospaced text view that copes with megabytes of text and starts at the end.
private struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scrollToEndOfDocument(nil)
    }
}
