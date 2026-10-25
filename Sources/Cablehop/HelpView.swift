import SwiftUI

/// "Report a Problem": first save the logs, then open GitHub Issues to describe the problem and attach them.
struct ReportProblemView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var savedLog: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppLogo(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report a Problem").font(.title2.bold())
                    Text("Two quick steps help get it fixed faster.").foregroundStyle(.secondary)
                }
            }

            step(1, done: savedLog != nil,
                 title: "Save your logs",
                 detail: savedLog.map { "Saved as “\($0.lastPathComponent)”." }
                     ?? "The logs show what Cablehop was doing when things went wrong. They stay on your Mac unless you attach them.") {
                HStack {
                    Button(savedLog == nil ? "Save Logs…" : "Save Again…") {
                        if let url = LogStore.saveWithPanel() { savedLog = url }
                    }
                    .glassButton()
                    if let savedLog {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedLog]) }
                            .buttonStyle(.link)
                    }
                }
            }

            step(2, done: false,
                 title: "Open an issue on GitHub",
                 detail: "Choose “Bug report”, say what happened and what you expected, and drag the saved log file into the issue. You'll need a free GitHub account.") {
                Button("Open GitHub Issues") {
                    Log.info("Opening GitHub Issues (logs saved: \(savedLog != nil))")
                    openURL(AppInfo.newIssueURL)
                    dismiss()
                }
                .prominentGlassButton()
            }

            Label("Logs can include the names of files and folders on your phone. Have a look before you attach them.",
                  systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func step<Actions: View>(_ number: Int, done: Bool, title: String, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold())
                } else {
                    Text("\(number)").font(.caption.bold())
                }
            }
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions().padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }
}
