import AppKit
import SwiftUI

// Liquid Glass on macOS 26 and later, with the closest older material on macOS 14 and 15.
//
// Following Apple's guidance, glass is only for controls that float above content (the path bar, the
// photo-size slider). Content panels use the standard grouped fill instead, and nothing glass sits on
// top of something that's already glass (the sidebar, sheets).

extension View {
    /// A panel in the content layer: Apple's standard subtle grouped fill with a hairline edge.
    func contentCard(cornerRadius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.quinary, in: shape)
            .overlay(shape.strokeBorder(.quaternary, lineWidth: 0.5))
    }

    /// A glass capsule for small controls floating above content (path bar, size slider).
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.bar, in: Capsule())
        }
    }

    /// The main action in a window or sheet.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// A secondary action that should still stand out from plain text buttons.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Shows the Cablehop logo and name in the window's title area, like a title rather than a button.
    func logoInTitleBar() -> some View {
        self
            .toolbar {
                if #available(macOS 26.0, *) {
                    // Without this, macOS 26 puts every toolbar item in a round glass button.
                    ToolbarItem(placement: .navigation) { TitleLockup() }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) { TitleLockup() }
                }
            }
            .modifier(HideWindowTitle())
    }
}

private struct HideWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// Logo with the app name beside it, for the window's title area.
struct TitleLockup: View {
    var body: some View {
        HStack(spacing: 8) {
            AppLogo(size: 24)
            Text("Cablehop")
                .font(.title3.weight(.semibold))
                .fixedSize()
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .help("Cablehop \(AppInfo.version)")
    }
}

/// The app icon, as used on GitHub and in the Dock.
struct AppLogo: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("Cablehop")
    }
}
