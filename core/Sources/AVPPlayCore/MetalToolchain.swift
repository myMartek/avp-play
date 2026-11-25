import Foundation

/// Xcode's Metal Toolchain (`xcrun metal`): since Xcode 26 a download of its own, and one that belongs to one Xcode
/// build, so an Xcode update leaves the new Xcode without it. Klepton games need no Metal compiler while they are
/// built; the games with a toolchain of their own do (Skyrim VR compiles the game's 10,818 shaders, Half-Life and
/// Vice City have `.metal` files in their Xcode projects). Without it Skyrim VR's build stopped with "stage app is
/// missing an input" and no word about Metal (avp-play#149). So: check before such a build, try to download it,
/// and only if that fails ask the player to do it, saying where.
public enum MetalToolchain {
    /// Whether the build of a game with this toolchain needs the Metal compiler.
    public static func needed(by toolchain: Toolchain) -> Bool { needed(kind: toolchain.kind) }

    static func needed(kind: String) -> Bool { kind != Toolchain.kleptonKind }

    /// Whether the Metal compiler runs for visionOS (`xcrun -sdk xros metal --version`): exactly what the builds call.
    public static func installed() -> Bool { installed(run: Toolchain.status) }

    static func installed(run: ([String]) -> Int32) -> Bool {
        run(["/usr/bin/xcrun", "-sdk", "xros", "metal", "--version"]) == 0
    }

    /// The command Apple names for it (`xcodebuild -help`, and the error `xcrun metal` prints without it).
    public static let downloadCommand = "xcodebuild -downloadComponent MetalToolchain"

    /// The state in a line of `xcodebuild -downloadComponent`, in bytes: "Downloading... (27,2 MB of 838,9 MB
    /// downloaded)" (Xcode 27.2; the numbers follow the Mac's region, so a comma may be the decimal point). `nil`
    /// for a line without one ("Beginning asset download...", "Done downloading: …").
    public static func bytes(in line: String) -> (done: Int64, total: Int64)? {
        let unit = #"(bytes?|[kKMGT]B)"#
        guard let regex = try? NSRegularExpression(pattern: #"([\d.,]+)\s*"# + unit + #"\s+of\s+([\d.,]+)\s*"# + unit),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: line).map { String(line[$0]) } }
        guard let doneNumber = group(1).flatMap(number), let doneUnit = group(2).flatMap(factor),
              let totalNumber = group(3).flatMap(number), let totalUnit = group(4).flatMap(factor) else { return nil }
        let done = Int64((doneNumber * doneUnit).rounded()), total = Int64((totalNumber * totalUnit).rounded())
        guard total > 0 else { return nil }
        return (min(done, total), total)
    }

    /// "838,9", "838.9", "1.234,5", "1,234.5" → the number; with one kind of separator it is the decimal point
    /// (the byte counts Apple prints have at most three digits before it).
    static func number(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        if let lastDot = t.lastIndex(of: "."), let lastComma = t.lastIndex(of: ",") {
            let thousands: Character = lastDot > lastComma ? "," : "."
            t.removeAll { $0 == thousands }
        }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }

    static func factor(_ unit: String) -> Double? {
        switch unit.lowercased() {
        case "byte", "bytes": return 1
        case "kb": return 1e3
        case "mb": return 1e6
        case "gb": return 1e9
        case "tb": return 1e12
        default: return nil
        }
    }

    /// The last line of the download's output that says why it failed, for the message to the player.
    public static func reason(in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.last(where: { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("fail") })
            ?? lines.last
        return line.map { String($0.prefix(200)) }
    }

    /// Downloads it with `xcodebuild -downloadComponent MetalToolchain` (no administrator password needed); the
    /// output goes to `log`, each line to `line`. Returns nil when it worked, otherwise the reason. Cancelling the
    /// job ends the download.
    public static func download(log: URL, line: @escaping @Sendable (String) -> Void) async -> String? {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return L("cannot write \(log.path)", "\(log.path) lässt sich nicht schreiben") }
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        p.arguments = ["-downloadComponent", "MetalToolchain"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let collected = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            handle.write(data)
            // Progress lines may end in a carriage return instead of a newline.
            for piece in collected.append(data) { line(piece) }
        }
        let status: Int32? = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Int32?, Never>) in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { p.terminationHandler = nil; c.resume(returning: nil) }
            }
        } onCancel: { if p.isRunning { p.terminate() } }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            handle.write(rest)
            for piece in collected.append(rest) { line(piece) }
        }
        let output = collected.text
        guard let status else { return L("xcodebuild could not be started", "xcodebuild ließ sich nicht starten") }
        if Task.isCancelled { return L("cancelled", "abgebrochen") }
        guard status == 0 else { return reason(in: output) ?? "xcodebuild \(status)" }
        return nil
    }
}

/// Collects the download's output and hands out complete lines (split at newlines and carriage returns; Swift's `isNewline` covers both and the pair).
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all = Data()
    private var pending = ""

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: all, as: UTF8.self) }

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        all.append(data)
        pending += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let cut = pending.firstIndex(where: \.isNewline) {
            let piece = pending[..<cut].trimmingCharacters(in: .whitespaces)
            pending = String(pending[pending.index(after: cut)...])
            if !piece.isEmpty { lines.append(piece) }
        }
        return lines
    }
}
