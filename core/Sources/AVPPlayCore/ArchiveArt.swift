import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture of a game that has neither a store page nor a Steam entry, made from the game's own files: its icon
/// and a picture of it lie inside the archive of parts built on this Mac (`Recipe.IconSource.archive`). Nothing is
/// shipped with the project. Before the parts are built, a recipe that names the files' `origin` gets the same two
/// files from there (the game's own publisher, checked by their SHA-1), so the game has its picture from the start;
/// without one the overview shows its name on a plain ground until the parts exist.
public enum ArchiveArt {
    /// Where the picture made from the archive is kept, in the game's folder in the library.
    public static func heroURL(store: ContentStore, recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent("parts-hero.png")
    }

    /// The parts archive of the game, whichever builder made it.
    static func archive(recipe: Recipe, store: ContentStore) -> URL? {
        guard recipe.builder != nil else { return nil }
        for local in [GameParts.usesLocalBuilder(recipe), false, true] {
            if let have = GameParts.built(recipe: recipe, store: store, local: local) { return have.url }
        }
        return nil
    }

    /// The landscape picture for the tile, the game's page and the start window: made once from the archive and kept
    /// beside it; made again when the archive is newer. `nil` while there is no archive or it holds no such picture.
    public static func hero(recipe: Recipe, store: ContentStore) -> Data? {
        guard let pictures = recipe.icon?.archive else { return nil }
        let kept = heroURL(store: store, recipe: recipe)
        guard let zip = archive(recipe: recipe, store: store) else {
            // No parts (not built yet, or removed): only a picture made from the files' origin stands in for them.
            guard pictures.origin != nil, FileManager.default.fileExists(atPath: originMarkURL(store: store, recipe: recipe).path)
            else { return nil }
            return try? Data(contentsOf: kept)
        }
        func changed(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        if let have = changed(kept), let source = changed(zip), have >= source, let data = try? Data(contentsOf: kept) { return data }
        guard let icon = read(pictures.icon, from: zip),
              let made = compose(icon: icon, background: pictures.background.flatMap { read($0, from: zip) }) else { return nil }
        try? made.write(to: kept, options: .atomic)
        return made
    }

    /// The largest picture a file holds can be several megabytes; anything beyond this is not a picture of a game.
    static let largestPicture = 24 << 20

    /// Says that `parts-hero.png` was made from the files' origin, not from built parts.
    static func originMarkURL(store: ContentStore, recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent("parts-hero.origin")
    }

    /// The origin as a base address: `https` only, without query or fragment.
    public static func originBase(_ origin: String) -> URL? {
        guard let url = URL(string: origin), url.scheme == "https", url.host?.isEmpty == false,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    /// The SHA-1 an entry is named by: its last path component, 40 lowercase hex digits.
    public static func contentName(_ path: String) -> String? {
        guard let name = path.split(separator: "/").last.map(String.init), name.count == 40,
              name.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return name
    }

    /// Fetches the two files from the origin and makes the picture, once: `true` when a picture was made now.
    /// Nothing happens when the parts are there, the picture already is, or the recipe names no origin. A file
    /// whose SHA-1 is not its name is dropped.
    public static func fetchFromOrigin(recipe: Recipe, store: ContentStore,
                                       fetch: @Sendable (URL) async -> Data? = ArchiveArt.download) async -> Bool {
        guard let pictures = recipe.icon?.archive, let origin = pictures.origin.flatMap(originBase),
              archive(recipe: recipe, store: store) == nil,
              !FileManager.default.fileExists(atPath: originMarkURL(store: store, recipe: recipe).path) else { return false }
        func get(_ path: String) async -> Data? {
            guard let name = contentName(path) else { return nil }
            let url = origin.appendingPathComponent(String(name.prefix(2))).appendingPathComponent(name)
            guard let data = await fetch(url), !data.isEmpty, data.count <= largestPicture,
                  Insecure.SHA1.hash(data: data).map({ String(format: "%02x", $0) }).joined() == name else { return nil }
            return data
        }
        guard let icon = await get(pictures.icon) else { return false }
        let background: Data? = if let b = pictures.background { await get(b) } else { nil }
        guard let made = compose(icon: icon, background: background) else { return false }
        let dir = store.directory(for: recipe)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? made.write(to: heroURL(store: store, recipe: recipe), options: .atomic)) != nil else { return false }
        try? Data((origin.absoluteString + "\n").utf8).write(to: originMarkURL(store: store, recipe: recipe), options: .atomic)
        return true
    }

    /// A plain GET with a short timeout; `nil` for anything but 200.
    @Sendable public static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("AVP Play", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// One entry of the archive: the one whose path is `path` or ends in `/path`.
    static func read(_ path: String, from zip: URL) -> Data? {
        guard Recipe.isArchiveEntry(path),
              let names = try? ApkUnpacker.run(["/usr/bin/unzip", "-Z1", zip.path]).text.split(separator: "\n").map(String.init),
              let entry = names.first(where: { $0 == path || $0.hasSuffix("/" + path) }),
              // The name goes to unzip as one argument: nothing in it may read as a pattern or an option.
              ApkUnpacker.isSafeEntry(entry), !entry.hasPrefix("-"), !entry.contains(where: { "*?[]\\".contains($0) }),
              let data = try? ApkUnpacker.run(["/usr/bin/unzip", "-p", zip.path, entry]).data,
              !data.isEmpty, data.count <= largestPicture else { return nil }
        return data
    }

    /// The largest image in a file (an `.icns` holds several sizes).
    static func largestImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var best: CGImage?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            if image.width > (best?.width ?? 0) { best = image }
        }
        return best
    }

    static let size = (width: 1920, height: 1080)

    /// The icon in the middle of the background picture (which fills the frame, slightly darkened) – or of a plain
    /// dark ground where there is none. PNG, 16:9.
    static func compose(icon: Data, background: Data?) -> Data? {
        guard let front = largestImage(icon), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        ctx.fill(frame)
        if let back = background.flatMap(largestImage) {
            let scale = max(frame.width / CGFloat(back.width), frame.height / CGFloat(back.height))
            let w = CGFloat(back.width) * scale, h = CGFloat(back.height) * scale
            // A picture of blocks stays a picture of blocks when it is enlarged.
            ctx.interpolationQuality = scale > 1.5 ? .none : .high
            ctx.draw(back, in: CGRect(x: (frame.width - w) / 2, y: (frame.height - h) / 2, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
            ctx.fill(frame)
        }
        let scale = min(frame.height * 0.56 / CGFloat(front.height), frame.width * 0.5 / CGFloat(front.width))
        let w = CGFloat(front.width) * scale, h = CGFloat(front.height) * scale
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.draw(front, in: CGRect(x: (frame.width - w) / 2, y: (frame.height - h) / 2, width: w, height: h))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
