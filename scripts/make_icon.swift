import AppKit

// Renders a 1024×1024 app-icon master PNG: a light rounded "plate" (macOS-style)
// containing a dark navy terminal tile with a ">" prompt and "IOIOI" bits.
// Usage: swift make_icon.swift <output.png>

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .calibratedRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Transparent background.
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// --- Light plate (rounded square) with a soft drop shadow ---
let plateInset: CGFloat = 88
let plateRect = NSRect(x: plateInset, y: plateInset,
                       width: S - 2*plateInset, height: S - 2*plateInset)
let platePath = NSBezierPath(roundedRect: plateRect, xRadius: 190, yRadius: 190)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 46
shadow.shadowOffset = NSSize(width: 0, height: -22)
shadow.set()
rgb(240, 240, 244).setFill()
platePath.fill()
NSGraphicsContext.restoreGraphicsState()

// Plate gradient (bottom slightly darker → subtle depth).
let plateGrad = NSGradient(colors: [rgb(214, 214, 220), rgb(247, 247, 250)])!
plateGrad.draw(in: platePath, angle: 90)

// Thin top highlight along the plate edge.
rgb(255, 255, 255, 0.6).setStroke()
let hl = NSBezierPath(roundedRect: plateRect.insetBy(dx: 3, dy: 3), xRadius: 188, yRadius: 188)
hl.lineWidth = 3
hl.stroke()

// --- Dark navy terminal tile ---
let tileSize: CGFloat = 566
let tileRect = NSRect(x: (S - tileSize)/2, y: (S - tileSize)/2,
                      width: tileSize, height: tileSize)
let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: 104, yRadius: 104)

NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
tileShadow.shadowBlurRadius = 18
tileShadow.shadowOffset = NSSize(width: 0, height: -8)
tileShadow.set()
rgb(31, 42, 68).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

let tileGrad = NSGradient(colors: [rgb(20, 29, 51), rgb(42, 56, 88)])!
tileGrad.draw(in: tilePath, angle: 90)

// Faint inner border.
rgb(255, 255, 255, 0.07).setStroke()
let tb = NSBezierPath(roundedRect: tileRect.insetBy(dx: 2, dy: 2), xRadius: 102, yRadius: 102)
tb.lineWidth = 2
tb.stroke()

// --- Text: ">" prompt (top-left) and "IOIOI" bits (centered, lower) ---
func mono(_ size: CGFloat) -> NSFont {
    NSFont(name: "Menlo-Bold", size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
}

let promptColor = rgb(120, 235, 160)   // soft terminal green for the prompt
let bitsColor = rgb(240, 244, 250)     // near-white bits

let promptAttrs: [NSAttributedString.Key: Any] = [
    .font: mono(168), .foregroundColor: promptColor,
]
let promptRect = NSRect(x: tileRect.minX + 66, y: tileRect.minY,
                        width: 220, height: tileRect.height - 70)
NSString(string: ">").draw(in: promptRect, withAttributes: promptAttrs)

let para = NSMutableParagraphStyle()
para.alignment = .center
let bitsAttrs: [NSAttributedString.Key: Any] = [
    .font: mono(176), .foregroundColor: bitsColor, .paragraphStyle: para,
    .kern: 2.0,
]
let bitsRect = NSRect(x: tileRect.minX, y: tileRect.minY,
                      width: tileRect.width, height: tileRect.height * 0.56)
NSString(string: "IOIOI").draw(in: bitsRect, withAttributes: bitsAttrs)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
