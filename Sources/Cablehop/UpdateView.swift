import SwiftUI

/// The software update sheet: what's new, then Install / Remind Me Later / Skip This Version.
struct UpdateView: View {
    @Environment(\.openURL) private var openURL
    let updater = Updater.shared

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            AppLogo(size: 64)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            Text("Checking for updates…").font(.headline)
            ProgressView().progressViewStyle(.linear)
            buttons { Button("Cancel") { updater.dismiss() }.keyboardShortcut(.cancelAction) }

        case .upToDate:
            Text("You're up to date!").font(.headline)
            Text("Cablehop \(AppInfo.version) is the newest version available.").foregroundStyle(.secondary)
            buttons { Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction).prominentGlassButton() }

        case .available(let release):
            Text("A new version of Cablehop is available!").font(.headline)
            Text("Cablehop \(release.version?.description ?? release.tagName) is now available. You have \(AppInfo.version).")
                .foregroundStyle(.secondary)
            ReleaseNotes(markdown: release.body ?? "")
            buttons {
                Button("Skip This Version") { updater.skip(release) }
                Spacer()
                Button("Remind Me Later") { updater.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install Update") { updater.install(release) }
                    .keyboardShortcut(.defaultAction)
                    .prominentGlassButton()
            }

        case .downloading(let release, let progress):
            Text("Downloading Cablehop \(release.version?.description ?? "")…").font(.headline)
            ProgressView(value: progress)
            Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
            buttons { Button("Hide") { updater.dismiss() } }

        case .installing(let release):
            Text("Installing Cablehop \(release.version?.description ?? "")…").font(.headline)
            ProgressView().progressViewStyle(.linear)
            Text("Checking the download, then Cablehop will restart.").foregroundStyle(.secondary)

        case .failed(let message):
            Text("Couldn't update Cablehop").font(.headline)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("View Releases on GitHub") { openURL(AppInfo.releasesURL) }
                Spacer()
                Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction).prominentGlassButton()
            }
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { Spacer(minLength: 0); content() }.padding(.top, 4)
    }
}

/// GitHub release notes, shown as simple formatted text.
private struct ReleaseNotes: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.isHeading {
                        Text(line.text).font(.subheadline.bold()).padding(.top, 4)
                    } else {
                        Text(attributed(line.text)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(height: 220)
        .contentCard(cornerRadius: 12)
    }

    private var lines: [(text: String, isHeading: Bool)] {
        markdown.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { return (line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces), true) }
            if line.hasPrefix("- ") { return ("•  " + line.dropFirst(2), false) }
            return (line, false)
        }
    }

    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
