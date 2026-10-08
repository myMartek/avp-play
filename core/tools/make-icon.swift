// Zeichnet das Programm-Icon der Mac-App und legt es als .iconset ab.
//   swift tools/make-icon.swift <Ordner.iconset>     danach: iconutil -c icns <Ordner.iconset>
//
// Eigene Zeichnung (ein Visier, in das ein Pfeil zeigt) – keine Symbole oder Marken Dritter.
import AppKit
import CoreGraphics

func draw(size: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    // Fläche in der Form eines macOS-Icons, mit weichem Schatten darunter
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(color(0x2A1B8F))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x7C6CFF), color(0x4B36D9), color(0x23146F)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 220, y: 924), end: CGPoint(x: 804, y: 100), options: [])
    // ein heller Schein oben, damit die Fläche nicht stumpf wirkt
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 960), startRadius: 0, endCenter: CGPoint(x: 512, y: 960), endRadius: 520, options: [])
    ctx.restoreGState()

    // Visier: breite Kapsel mit einer Aussparung für die Nase
    let visorRect = CGRect(x: 232, y: 250, width: 560, height: 250)
    var visor = CGPath(roundedRect: visorRect, cornerWidth: 112, cornerHeight: 112, transform: nil)
    visor = visor.subtracting(CGPath(ellipseIn: CGRect(x: 512 - 70, y: 250 - 62, width: 140, height: 124), transform: nil))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.3))
    ctx.addPath(visor)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    // Glas
    var glass = CGPath(roundedRect: visorRect.insetBy(dx: 30, dy: 30), cornerWidth: 84, cornerHeight: 84, transform: nil)
    glass = glass.subtracting(CGPath(ellipseIn: CGRect(x: 512 - 96, y: 250 - 60, width: 192, height: 176), transform: nil))
    ctx.saveGState()
    ctx.addPath(glass)
    ctx.clip()
    let glassGradient = CGGradient(colorsSpace: space, colors: [color(0x2B1D7A), color(0x120A3D)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(glassGradient, start: CGPoint(x: 262, y: 470), end: CGPoint(x: 762, y: 280), options: [])
    ctx.restoreGState()

    // Pfeil nach unten, in das Visier hinein
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(58)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 512, y: 800))
    ctx.addLine(to: CGPoint(x: 512, y: 590))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 420, y: 676))
    ctx.addLine(to: CGPoint(x: 512, y: 584))
    ctx.addLine(to: CGPoint(x: 604, y: 676))
    ctx.strokePath()

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Aufruf: swift make-icon.swift <Ordner.iconset>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(size: points * scale).write(to: out.appendingPathComponent(name))
}
