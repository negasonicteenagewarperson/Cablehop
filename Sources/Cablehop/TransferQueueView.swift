import SwiftUI

/// The toolbar's transfers button, Safari style: an icon with a thin progress bar beneath it while
/// copies run. The icon turns green and gently pulses so it's obvious something is transferring.
/// It always keeps the same size, so the toolbar never rebuilds it mid-transfer (which used to
/// close the popover the moment it opened).
struct TransfersToolbarButton: View {
    @Environment(TransferManager.self) private var transfers

    var body: some View {
        let progress = transfers.overallProgress
        Button { TransfersPopover.shared.toggle() } label: {
            TransferIndicator(progress: progress)
                .background(PopoverAnchor())
        }
        .help(helpText(progress))
        .accessibilityLabel("Transfers")
        .accessibilityValue(helpText(progress))
    }

    private func helpText(_ progress: Double?) -> String {
        let active = transfers.activeCount
        guard active > 0, let progress else { return "Transfers: show progress and history (⌥⌘T)" }
        return "Transfers: \(active) in progress, \(Int(progress * 100))% done (⌥⌘T)"
    }
}

/// Icon plus a capsule progress bar, in a fixed-size frame.
struct TransferIndicator: View {
    let progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: progress == nil ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(progress == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.green))
                .symbolEffect(.pulse, options: .repeating, isActive: progress != nil && !reduceMotion)
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.green.gradient)
                            .frame(width: max(3, geo.size.width * (progress ?? 0)))
                            .animation(.easeOut(duration: 0.25), value: progress)
                    }
                }
                .frame(width: 22, height: 3)
                .opacity(progress == nil ? 0 : 1)
        }
        .frame(width: 28, height: 24)
        .contentShape(Rectangle())
    }
}

/// The transfers list as a native popover hanging off the toolbar button.
@MainActor
final class TransfersPopover: NSObject, NSPopoverDelegate {
    static let shared = TransfersPopover()

    weak var anchor: NSView?
    var transfers: TransferManager?
    /// True when it opened itself for a new transfer, so it may also close itself when all are done.
    private(set) var openedAutomatically = false
    private var popover: NSPopover?
    private var closedAt = Date.distantPast

    var isShown: Bool { popover?.isShown == true }

    func toggle() {
        if isShown { popover?.performClose(nil) } else { show(automatically: false) }
    }

    func show(automatically: Bool) {
        guard !isShown, let transfers else { return }
        // A click on the button while the popover is open first closes it (it's transient); don't let
        // that same click's button action open it straight back up.
        if !automatically && Date().timeIntervalSince(closedAt) < 0.3 { return }
        let popover = self.popover ?? makePopover(transfers)
        self.popover = popover
        if let anchor, let window = anchor.window, window.isVisible {
            openedAutomatically = automatically
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if !automatically, let content = NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow })?.contentView {
            // The button is hidden in the toolbar's overflow menu: hang it from the window's top-right corner.
            openedAutomatically = false
            let corner = NSRect(x: content.bounds.maxX - 40, y: content.isFlipped ? 0 : content.bounds.maxY - 1, width: 1, height: 1)
            popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        }
    }

    func closeIfOpenedAutomatically() {
        if isShown && openedAutomatically { popover?.performClose(nil) }
    }

    private func makePopover(_ transfers: TransferManager) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 460)
        popover.contentViewController = NSHostingController(
            rootView: TransferQueueView().environment(transfers).frame(width: 380, height: 460))
        return popover
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        openedAutomatically = false
    }
}

/// Gives the popover a real AppKit view inside the toolbar button to hang from.
private struct PopoverAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        TransfersPopover.shared.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if TransfersPopover.shared.anchor !== view { TransfersPopover.shared.anchor = view }
    }
}

struct TransferQueueView: View {
    @Environment(TransferManager.self) private var transfers

    private var active: [Transfer] { transfers.items.filter { $0.state.isActive }.reversed() }
    private var finished: [Transfer] { transfers.items.filter { !$0.state.isActive }.reversed() }
    /// History from earlier sessions (this session's finished items are shown live above).
    private var earlier: [TransferRecord] {
        let current = Set(transfers.items.map(\.id))
        return transfers.history.filter { !current.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transfers").font(.headline)
                if !active.isEmpty {
                    Text("\(active.count) in progress").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if active.count > 1 {
                    Button("Cancel All") { transfers.cancelAll() }.buttonStyle(.link)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if active.isEmpty && finished.isEmpty && earlier.isEmpty {
                ContentUnavailableView("No transfers yet", systemImage: "arrow.up.arrow.down",
                                       description: Text("Files you copy to or from your phone show up here."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    if !active.isEmpty {
                        Section("In Progress") { ForEach(active) { TransferRow(transfer: $0) } }
                    }
                    if !finished.isEmpty {
                        Section("Recent") { ForEach(finished) { TransferRow(transfer: $0) } }
                    }
                    if !earlier.isEmpty {
                        Section("Earlier") { ForEach(earlier) { HistoryRow(record: $0) } }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            HStack {
                Button {
                    NSWorkspace.shared.open(Prefs.downloadFolder)
                } label: { Label("Downloads Folder", systemImage: "folder") }
                    .buttonStyle(.borderless)
                    .help("Open the folder downloads are saved to")
                Spacer()
                Button("Clear History") { transfers.clearHistory() }
                    .buttonStyle(.borderless)
                    .disabled(finished.isEmpty && earlier.isEmpty)
                    .help("Remove finished transfers from this list")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

/// A transfer from a previous session.
struct HistoryRow: View {
    let record: TransferRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.kind == .upload ? "arrow.up.circle.fill" : record.kind == .download ? "arrow.down.circle.fill" : "app.badge.checkmark.fill")
                .font(.title3)
                .foregroundStyle(record.succeeded ? Color.secondary : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).lineLimit(1).truncationMode(.middle)
                Text(record.date.formatted(.relative(presentation: .named)) + " · " + record.detail)
                    .font(.caption).foregroundStyle(record.succeeded ? Color.secondary : Color.red).lineLimit(1)
            }
            Spacer(minLength: 0)
            if record.kind == .download, record.succeeded, FileManager.default.fileExists(atPath: record.destination) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.destination)])
                } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
            }
        }
        .padding(.vertical, 2)
    }
}

struct TransferRow: View {
    let transfer: Transfer
    @Environment(TransferManager.self) private var transfers

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                if transfer.state == .running {
                    if transfer.direction == .install {
                        ProgressView().progressViewStyle(.linear)
                    } else {
                        ProgressView(value: transfer.progress)
                    }
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            actionButton
        }
        .padding(.vertical, 4)
    }

    private static let timeLeft: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = [.hour, .minute, .second]
        return f
    }()

    private var isFailed: Bool { if case .failed = transfer.state { return true }; return false }

    private var iconColor: Color {
        switch transfer.state {
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var icon: String {
        switch transfer.direction {
        case .push: return "arrow.up.circle.fill"
        case .pull: return "arrow.down.circle.fill"
        case .install: return "app.badge.checkmark.fill"
        }
    }

    private var statusText: String {
        let place: String
        switch transfer.direction {
        case .push: place = "to \(transfer.destination)"
        case .pull: place = "to \((transfer.destination as NSString).deletingLastPathComponent.abbreviatedPath)"
        case .install: place = "Installing app"
        }
        switch transfer.state {
        case .queued: return "Waiting… \(place)"
        case .running:
            if transfer.direction == .install { return "Installing…" }
            var parts = ["\(Int(transfer.progress * 100))%"]
            if let speed = transfer.bytesPerSecond {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
            }
            if let left = transfer.secondsRemaining, left.isFinite {
                parts.append(Self.timeLeft.string(from: max(left, 1)).map { "\($0) left" } ?? "")
            } else {
                parts.append(place)
            }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        case .done: return transfer.detail.isEmpty ? "Done" : transfer.detail
        case .cancelled: return "Cancelled"
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch transfer.state {
        case .queued where !transfer.isExternal, .running where !transfer.isExternal:
            Button { transfers.cancel(transfer) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
        case .done where transfer.direction == .pull:
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: transfer.destination)])
            } label: { Image(systemName: "magnifyingglass.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
        case .failed where !transfer.isExternal, .cancelled where !transfer.isExternal:
            Button { transfers.retry(transfer) } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Retry")
        default:
            EmptyView()
        }
    }
}

private extension String {
    var abbreviatedPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
