// Draws the DMG window background at 1x and 2x:
//   swift Scripts/make-dmg-background.swift <out-dir> <version>
// The window is 660×420 points. App icon sits at (170, 200), Applications at (490, 200).
// A mid-tone green is used so Finder's icon labels (black in Light Mode, white in Dark Mode) stay readable.
import AppKit

let outDir = CommandLine.arguments[1]
let version = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let size = CGSize(width: 660, height: 420)

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size  // points, so the 2x image is treated as Retina
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Flip so y runs top to bottom, matching Finder's icon positions.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)

    NSGradient(colors: [
        NSColor(red: 0.27, green: 0.50, blue: 0.43, alpha: 1),
        NSColor(red: 0.36, green: 0.55, blue: 0.48, alpha: 1),
    ])!.draw(in: NSRect(origin: .zero, size: size), angle: 90)

    func text(_ string: String, at y: CGFloat, size fontSize: CGFloat, weight: NSFont.Weight, alpha: CGFloat, width: CGFloat = 560) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: style,
        ]
        let rect = NSRect(x: (size.width - width) / 2, y: y, width: width, height: 60)
        // Text draws upright in a flipped context only with a flipped graphics context.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    text("Cablehop" + (version.isEmpty ? "" : " \(version)"), at: 30, size: 26, weight: .semibold, alpha: 1)
    text("Drag Cablehop onto Applications to install it", at: 66, size: 14, weight: .regular, alpha: 0.9)

    // Arrow from the app icon to Applications.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 268, y: 196))
    ctx.addLine(to: CGPoint(x: 388, y: 196))
    ctx.move(to: CGPoint(x: 370, y: 180))
    ctx.addLine(to: CGPoint(x: 390, y: 196))
    ctx.addLine(to: CGPoint(x: 370, y: 212))
    ctx.strokePath()

    text("First time only: if macOS says it can't verify Cablehop, open System Settings › Privacy & Security and click “Open Anyway”.",
         at: 338, size: 11.5, weight: .regular, alpha: 0.88, width: 520)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    let data = draw(scale: scale).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
