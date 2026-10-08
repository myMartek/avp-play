import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Das Bild, das die installierte App in ihrem Startfenster zeigt.
public enum StartHero {
    /// Hier kann der Nutzer ein eigenes Bild hinterlegen.
    public static func customURL(store: ContentStore, recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent("hero.png")
    }

    /// Das zwischengespeicherte Titelbild im Querformat von der Store-Seite.
    public static func storeURL(store: ContentStore, recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent("store-hero.img")
    }

    /// Reihenfolge: eigenes Bild, Querformat aus dem Meta-Store, Hintergrund aus der Steam-Bibliothek des
    /// Nutzers, zuletzt das quadratische Titelbild. Gibt es nichts davon, zeigt das Startfenster nur den Namen.
    public static func choose(recipe: Recipe, store: ContentStore) -> (image: Data, origin: String)? {
        func usable(_ url: URL) -> Data? {
            guard let data = try? Data(contentsOf: url), AppIcon.image(data) != nil else { return nil }
            return data
        }
        if let own = usable(customURL(store: store, recipe: recipe)) { return (own, L("custom image", "eigenes Bild")) }
        if let wide = usable(storeURL(store: store, recipe: recipe)) {
            return (wide, L("cover image (landscape) from the Meta Store", "Titelbild (quer) aus dem Meta-Store"))
        }
        if let steam = recipe.icon?.steamAppId, case .layered(let background, _)? = AppIcon.steamLibrary(appId: steam) {
            return (background, L("Steam library", "Steam-Bibliothek"))
        }
        if let square = usable(Toolchain.storeCoverURL(store: store, recipe: recipe)) {
            return (square, L("cover image from the Meta Store", "Titelbild aus dem Meta-Store"))
        }
        return nil
    }

    /// Schreibt das Bild als `…imageset`, als PNG und höchstens 2560 Pixel breit.
    public static func writeImageSet(_ data: Data, to directory: URL) throws {
        guard let source = AppIcon.image(data) else { throw UnpackError.manifest(L("the start image couldn't be read", "Startbild ließ sich nicht lesen")) }
        var image = source
        if source.width > 2560 {
            let scale = 2560.0 / Double(source.width)
            let w = 2560, h = max(1, Int(Double(source.height) * scale))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw UnpackError.manifest(L("the start image couldn't be resized", "Startbild ließ sich nicht verkleinern"))
            }
            ctx.interpolationQuality = .high
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let scaled = ctx.makeImage() { image = scaled }
        }
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = directory.appendingPathComponent("hero.png")
        guard let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw UnpackError.manifest(L("the start image couldn't be written", "Startbild ließ sich nicht schreiben"))
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw UnpackError.manifest(L("the start image couldn't be written", "Startbild ließ sich nicht schreiben")) }
        let contents = """
        {
          "images" : [ { "filename" : "hero.png", "idiom" : "universal" } ],
          "info" : { "author" : "xcode", "version" : 1 }
        }

        """
        try contents.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    }
}
