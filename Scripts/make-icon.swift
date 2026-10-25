// Renders the app icon to a 1024px PNG: swift Scripts/make-icon.swift out.png
import AppKit

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size, flipped: false) { rect in
    let inset = rect.insetBy(dx: 100, dy: 100)
    let squircle = NSBezierPath(roundedRect: inset, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.20, green: 0.85, blue: 0.55, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.45, blue: 0.75, alpha: 1))!.draw(in: squircle, angle: -60)

    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }
    return true
}

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
