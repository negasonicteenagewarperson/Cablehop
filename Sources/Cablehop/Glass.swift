import AppKit
import SwiftUI

// Liquid Glass on macOS 26 and later, with the closest older material on macOS 14 and 15.

extension View {
    /// A floating glass panel, for controls that sit above content.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// A glass capsule (path bar, small floating controls).
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

    /// Puts the Cablehop logo in the window's title area in place of the name.
    func logoInTitleBar() -> some View {
        self
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    AppLogo(size: 26)
                        .padding(.horizontal, 2)
                        .help("Cablehop \(AppInfo.version)")
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
