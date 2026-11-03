import Foundation

// Der geteilte Bau: hier exportiert (Toolchain, `run.sh export`), dort eingespielt (eine .ipa auspacken, die App
// einspielen; die Spieldateien kommen danach wie immer aus dem eigenen Kauf). docs/friends.md.

extension Toolchain {
    /// Ob diese Toolchain einen Ad-hoc-Export kann (`run.sh export`).
    public var supportsIPAExport: Bool {
        guard let text = try? String(contentsOf: root.appendingPathComponent("visionos/run.sh"), encoding: .utf8) else { return false }
        return text.contains("\"$MODE\" = \"export\"")
    }

    /// Baut das Spiel wie `buildAndInstall`, aber als Ad-hoc-.ipa für die Headsets, die im Team eingetragen sind. Liefert
    /// den Pfad der .ipa. `bundleId` ist die Kennung, unter der alle Freunde das Spiel bekommen.
    public func exportIPA(recipe: Recipe, team: String, bundleId: String, log: URL, extraEnvironment: [String: String] = [:],
                          spatialPersonas: Bool = false, controllerMode: ControllerMode = .standard,
                          surrealSupport: Bool = true, outputDirectory: URL) throws -> URL {
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw RecipeError.invalid(L("team ID '\(team)' (expected: 10 characters)", "Team-ID '\(team)' (erwartet: 10 Zeichen)"))
        }
        let controllerEnvironment = try controllerEnvironment(controllerMode, surrealSupport: surrealSupport)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["KLEPTON_TEAM"] = team
        env["KLEPTON_TARGET"] = recipe.toolchain.target
        env["KL_SKIP_STAGE"] = "1"
        env["KL_SKIP_LAUNCH"] = "1"
        env["KLEPTON_START_SCREEN"] = "1"
        env["KLEPTON_APP_VERSION"] = AppStamp.short(versionName: recipe.versionName)
        let spatialPersonas = spatialPersonas && offersSpatialPersonas(for: recipe)
        env["KLEPTON_APP_BUILD"] = AppStamp.build(versionCode: recipe.versionCode, toolchainVersion: version(), modified: isModified,
                                                  spatialPersonas: spatialPersonas)
        env["KLEPTON_TEST_ON"] = nil
        env[Toolchain.spatialPersonasVariable] = spatialPersonas ? "1" : nil
        env["KLEPTON_BUNDLE_ID"] = bundleId
        env["KL_EXPORT_DIR"] = outputDirectory.path
        env.merge(Toolchain.genericEnvironment(recipe: recipe)) { _, new in new }
        env.merge(extraEnvironment) { _, new in new }
        env.merge(controllerEnvironment) { _, new in new }
        try SigningWarmUp.run(team: team)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = root.appendingPathComponent("visionos/run.sh")
        p.arguments = ["export"]
        p.currentDirectoryURL = root
        p.environment = env
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        p.waitUntilExit()
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        if p.terminationStatus != 0 || !text.contains("ipa: ") {
            if let refusal = AppleMessages.refusal(in: text) { throw ToolchainError.refused(refusal, free: false, log: log) }
            let hint = lines.last { $0.hasPrefix("!!") || $0.contains("error:") || $0.contains("No profiles") || $0.contains("No Account") } ?? ""
            throw ToolchainError.buildFailed(log: log, hint: hint)
        }
        guard let line = lines.last(where: { $0.contains("ipa: ") }), let range = line.range(of: "ipa: ") else {
            throw ToolchainError.buildFailed(log: log, hint: "")
        }
        let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: path, relativeTo: root.appendingPathComponent("visionos")).standardizedFileURL
    }
}

/// Eine .ipa: auspacken, ansehen, einspielen.
public enum IPAPackage {
    public struct Info: Equatable, Sendable {
        public var bundleId: String
        public var version: String
        public var build: String
        public var app: URL
    }

    /// Packt die .ipa in einen frischen Ordner aus und findet die App darin.
    public static func unpack(_ ipa: URL, into directory: URL) throws -> Info {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", ipa.path, directory.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FriendError.refused(Int(p.terminationStatus), L("the package does not open: \(text)", "das Paket geht nicht auf: \(text)"))
        }
        let payload = directory.appendingPathComponent("Payload")
        guard let app = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
              let plist = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")),
              let bundleId = plist["CFBundleIdentifier"] as? String else { throw FriendError.malformed }
        return Info(bundleId: bundleId, version: plist["CFBundleShortVersionString"] as? String ?? "",
                    build: plist["CFBundleVersion"] as? String ?? "", app: app)
    }

    /// Die Kennung, die die App aus dem Profil in ihr trägt: läuft sie auf diesem Headset?
    public static func provisionedDevices(app: URL) -> [String]? {
        let profile = app.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: profile.path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["cms", "-D", "-i", profile.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["ProvisionedDevices"] as? [String]
    }
}
