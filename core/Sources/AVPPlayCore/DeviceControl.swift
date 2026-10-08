import Foundation

public struct Device: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let osVersion: String
    public let reachable: Bool
    public let paired: Bool
    public let developerMode: Bool
}

public struct RemoteFile: Sendable, Equatable {
    public let relativePath: String
    public let size: Int64
    public let isDirectory: Bool
}

public struct InstalledApp: Sendable, Equatable {
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    public let bundleVersion: String?
    /// Wo das Programmpaket auf dem Gerät liegt (als `file://`-Adresse). Daran ist ein laufender Prozess der App zu erkennen.
    public var url: String? = nil
}

public enum DeviceError: Error, CustomStringConvertible {
    case tool(String)
    case noDevice
    case ambiguous([String])

    public var description: String {
        switch self {
        case .tool(let m): return L("devicectl reported an error: \(m)", "devicectl meldet einen Fehler: \(m)")
        case .noDevice: return L("No paired, reachable Vision Pro found.", "Keine gekoppelte, erreichbare Vision Pro gefunden.")
        case .ambiguous(let names):
            let list = names.joined(separator: ", ")
            return L("Several devices found (\(list)). Please choose one with --device.",
                     "Mehrere Geräte gefunden (\(list)). Bitte mit --device auswählen.")
        }
    }
}

/// Ansteuerung der Vision Pro über Apples `devicectl`. Ausgewertet wird ausschließlich die JSON-Ausgabe.
public struct DeviceControl: Sendable {
    public init() {}

    // MARK: Auswertung (ohne Gerät testbar)

    static func parseDevices(_ data: Data) throws -> [Device] {
        struct Root: Decodable {
            struct Result: Decodable { let devices: [Entry] }
            struct Entry: Decodable {
                struct Hardware: Decodable { let platform: String?; let reality: String?; let udid: String? }
                struct Connection: Decodable { let tunnelState: String?; let pairingState: String? }
                struct Properties: Decodable { let name: String?; let osVersionNumber: String?; let developerModeStatus: String? }
                let hardwareProperties: Hardware?
                let connectionProperties: Connection?
                let deviceProperties: Properties?
            }
            let result: Result
        }
        return try JSONDecoder().decode(Root.self, from: data).result.devices.compactMap { e in
            guard e.hardwareProperties?.platform == "visionOS", e.hardwareProperties?.reality == "physical",
                  let udid = e.hardwareProperties?.udid else { return nil }
            let tunnel = e.connectionProperties?.tunnelState
            return Device(udid: udid, name: e.deviceProperties?.name ?? "Vision Pro",
                          osVersion: e.deviceProperties?.osVersionNumber ?? "?",
                          // Der Zustand wechselt zwischen "connected" und "disconnected" (gekoppelt, gerade ohne Tunnel);
                          // beides ist ansprechbar, "unavailable" nicht.
                          reachable: tunnel == "connected" || tunnel == "disconnected",
                          paired: e.connectionProperties?.pairingState == "paired",
                          developerMode: e.deviceProperties?.developerModeStatus == "enabled")
        }
    }

    static func parseFiles(_ data: Data) throws -> [RemoteFile] {
        struct Root: Decodable {
            struct Result: Decodable { let files: [Entry] }
            struct Entry: Decodable {
                struct Meta: Decodable { let size: Int64? }
                struct Resources: Decodable { let isDirectory: Bool? }
                let relativePath: String?
                let name: String?
                let metadata: Meta?
                let resources: Resources?
            }
            let result: Result
        }
        return try JSONDecoder().decode(Root.self, from: data).result.files.compactMap { e in
            guard let path = e.relativePath ?? e.name else { return nil }
            return RemoteFile(relativePath: path, size: e.metadata?.size ?? 0, isDirectory: e.resources?.isDirectory ?? false)
        }
    }

    static func parseApps(_ data: Data) throws -> [InstalledApp] {
        struct Root: Decodable {
            struct Result: Decodable { let apps: [Entry] }
            struct Entry: Decodable {
                let bundleIdentifier: String?; let name: String?; let version: String?; let bundleVersion: String?; let url: String?
            }
            let result: Result
        }
        return try JSONDecoder().decode(Root.self, from: data).result.apps.compactMap { e in
            guard let id = e.bundleIdentifier else { return nil }
            return InstalledApp(bundleIdentifier: id, name: e.name ?? id, version: e.version, bundleVersion: e.bundleVersion, url: e.url)
        }
    }

    /// Die Programmdateien aller laufenden Prozesse, als `file://`-Adressen.
    static func parseProcesses(_ data: Data) throws -> [String] {
        struct Root: Decodable {
            struct Result: Decodable { let runningProcesses: [Entry] }
            struct Entry: Decodable { let executable: String? }
            let result: Result
        }
        return try JSONDecoder().decode(Root.self, from: data).result.runningProcesses.compactMap(\.executable)
    }

    /// Läuft die App gerade? Ein Prozess gehört zu ihr, wenn seine Programmdatei in ihrem Programmpaket liegt.
    public static func isRunning(_ app: InstalledApp, executables: [String]) -> Bool {
        guard let url = app.url, !url.isEmpty else { return false }
        let prefix = url.hasSuffix("/") ? url : url + "/"
        return executables.contains { $0.hasPrefix(prefix) }
    }

    // MARK: Aufrufe

    public func devices() throws -> [Device] {
        try DeviceControl.parseDevices(try json(["list", "devices"]))
    }

    /// Die eine Vision Pro, mit der gearbeitet wird: die ausdrücklich genannte, sonst die einzige erreichbare.
    public func pick(udid: String?) throws -> Device {
        let all = try devices().filter { $0.paired }
        if let udid {
            guard let d = all.first(where: { $0.udid == udid }) else { throw DeviceError.noDevice }
            return d
        }
        let usable = all.filter(\.reachable)
        guard let first = usable.first else { throw DeviceError.noDevice }
        guard usable.count == 1 else { throw DeviceError.ambiguous(usable.map(\.name)) }
        return first
    }

    public func runningExecutables(device: Device) throws -> [String] {
        try DeviceControl.parseProcesses(try json(["device", "info", "processes", "--device", device.udid]))
    }

    public func apps(device: Device) throws -> [InstalledApp] {
        try DeviceControl.parseApps(try json(["device", "info", "apps", "--device", device.udid]))
    }

    /// Dateien eines Ordners im Datencontainer der App. Existiert der Ordner nicht, ist die Liste leer.
    public func files(device: Device, bundle: String, subdirectory: String, recursive: Bool = false) throws -> [RemoteFile] {
        var args = ["device", "info", "files", "--device", device.udid, "--domain-type", "appDataContainer",
                    "--domain-identifier", bundle, "--subdirectory", subdirectory]
        args.append(recursive ? "--recurse" : "--no-recurse")
        guard let data = try? json(args) else { return [] }
        return try DeviceControl.parseFiles(data)
    }

    public func copy(_ local: URL, to device: Device, bundle: String, destination: String) throws {
        _ = try run(["device", "copy", "to", "--device", device.udid, "--domain-type", "appDataContainer",
                     "--domain-identifier", bundle, "--source", local.path, "--destination", destination])
    }

    private func json(_ args: [String]) throws -> Data {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("qi-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try run(args + ["--json-output", out.path])
        return try Data(contentsOf: out)
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["devicectl"] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw DeviceError.tool(String((errText.isEmpty ? text : errText).suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }
}
