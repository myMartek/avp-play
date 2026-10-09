import Foundation

/// Rosetta 2, Apples Übersetzer für Intel-Programme. Valve liefert SteamCMD als reines Intel-Programm aus (erst
/// nach seiner ersten Selbstaktualisierung hat es auch eine Fassung für Apple-Chips); auf einem Mac, auf dem noch
/// nie ein Intel-Programm lief, fehlt Rosetta, und das Werkzeug startet nicht („Bad CPU type in executable“).
public enum Rosetta {
    /// Ob Intel-Programme auf diesem Mac laufen. Ein Intel-Mac braucht dafür nichts.
    public static var isInstalled: Bool {
        #if arch(x86_64)
        return true
        #else
        // Zum Ausprobieren der Lage „Mac ohne Rosetta“ – nur zusammen mit einem eigenen Datenordner.
        let env = ProcessInfo.processInfo.environment
        if env["AVPPLAY_NO_ROSETTA"] == "1", env["AVPPLAY_HOME"] != nil { return false }
        return FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta")
        #endif
    }

    /// Ob eine Programmdatei eine Fassung für Apple-Chips enthält. `nil`, wenn sie sich nicht lesen lässt oder
    /// kein Mach-O-Programm ist.
    public static func hasArm64Slice(_ file: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.count >= 8 else { return nil }
        return hasArm64Slice(header: data)
    }

    static func hasArm64Slice(header data: Data) -> Bool? {
        let bytes = [UInt8](data)
        func be(_ at: Int) -> UInt32? {
            at + 4 <= bytes.count ? bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } : nil
        }
        func le(_ at: Int) -> UInt32? {
            at + 4 <= bytes.count ? bytes[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } : nil
        }
        let arm64: UInt32 = 0x0100_000C
        guard let magic = be(0) else { return nil }
        switch magic {
        case 0xCAFE_BABE:                               // mehrere Fassungen in einer Datei
            guard let count = be(4), count > 0, count < 32 else { return nil }
            for i in 0..<Int(count) {
                guard let cpu = be(8 + i * 20) else { return nil }
                if cpu == arm64 { return true }
            }
            return false
        case 0xCFFA_EDFE:                               // eine Fassung, 64 Bit (auf der Platte: CF FA ED FE)
            return le(4).map { $0 == arm64 }
        default:
            return nil
        }
    }

    /// Lässt macOS Rosetta installieren. Das ist Apples eigener Weg dafür; er braucht kein Administratorkennwort.
    /// Wer ihn auslöst, stimmt damit Apples Lizenz für Rosetta zu – das steht am Knopf.
    public static func install() -> (ok: Bool, detail: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        p.arguments = ["--install-rosetta", "--agree-to-license"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (false, "softwareupdate") }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let last = text.split(separator: "\n").last.map(String.init) ?? ""
        return (p.terminationStatus == 0 && isInstalled, String(last.prefix(200)))
    }
}
