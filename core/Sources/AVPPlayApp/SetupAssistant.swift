import AppKit
import AVPPlayCore
import SwiftUI
import SystemConfiguration

// Der Einrichtungsassistent: beim ersten Start Schritt für Schritt durch Xcode, den Apple-Account, die Vision Pro und
// die Konten – nach dem Vorbild von Glovebox (github.com/glovebox-vr/glovebox, MIT-Lizenz). Jeder Schritt hat eine echte
// Prüfung, die alle paar Sekunden läuft, solange der Assistent offen ist; was in einem anderen Programm passiert,
// zeigt die schwebende Hilfe (`SetupGuide`) direkt dort. Ist ein Schritt erledigt, geht es von selbst weiter.

/// Was auf dem Mac selbst nachgesehen und gestartet wird.
enum SetupMac {
    static let appStoreXcode = "macappstore://apps.apple.com/app/xcode/id497799835"

    /// Das Xcode, mit dem AVP Play baut: das gewählte (`xcode-select`), sonst das neueste in „Programme“.
    static var xcodeURL: URL? {
        if let dev = DeveloperTools.directory(), let r = dev.range(of: ".app/") {
            return URL(fileURLWithPath: String(dev[..<r.lowerBound]) + ".app")
        }
        return DeveloperTools.unchosenXcode(chosen: DeveloperTools.directory()).map {
            URL(fileURLWithPath: $0.developer).deletingLastPathComponent().deletingLastPathComponent()
        }
    }

    static var xcodeIcon: NSImage? { xcodeURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    static func openXcode() {
        guard let url = xcodeURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Der Name des Macs, wie ihn die Vision Pro unter „Entfernte Geräte“ zeigt.
    /// Aus den Systemeinstellungen gelesen, nicht über `Host`: Das fragt im lokalen Netz nach, und macOS will dafür
    /// eine Erlaubnis.
    static var computerName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? L("this Mac", "dieser Mac") }

    /// Xcodes erster Start bietet rund 30 GB Plattformen an; gebraucht wird nur visionOS. Xcode 26 überspringt die
    /// Auswahl, Xcode 27 zeigt sie mit nur visionOS angehakt. Was der Nutzer schon gewählt hat, bleibt.
    static func trimXcodeFirstLaunch() {
        guard let xcode = UserDefaults(suiteName: "com.apple.dt.Xcode") else { return }
        if xcode.object(forKey: "IDEFirstLaunchSuppressPlatformChooser") == nil {
            xcode.set(true, forKey: "IDEFirstLaunchSuppressPlatformChooser")
        }
        for (platform, on) in ["iphoneos": false, "watchos": false, "appletvos": false, "xros": true]
        where xcode.object(forKey: "IDEPlatformsFirstLaunchSelected-\(platform)") == nil {
            xcode.set(on, forKey: "IDEPlatformsFirstLaunchSelected-\(platform)")
        }
    }

    /// Etwas in einem anderen Programm ist erledigt: AVP Play kommt nach vorn, wenn der Nutzer noch dort (oder hier)
    /// ist, sonst hüpft sein Symbol im Dock – nie nimmt es einem anderen Programm den Bildschirm weg.
    static func comeBack(from apps: Set<String>) {
        func inFront() -> Bool {
            let front = NSWorkspace.shared.frontmostApplication
            return apps.contains(front?.bundleIdentifier ?? "") || apps.contains(front?.localizedName ?? "")
        }
        guard NSApp.isActive || inFront() else {
            NSApp.requestUserAttention(.informationalRequest)
            return
        }
        Task { @MainActor in
            for _ in 0..<2 {
                NSApp.activate()
                NSApp.windows.first { AppDelegate.isMain($0) }?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !NSApp.isActive {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                if !NSApp.isActive {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !NSApp.isActive, inFront() else { return }
            }
        }
    }

    /// Führt ein Werkzeug aus und gibt Ausgangswert und Ausgabe zurück.
    static func run(_ tool: String, _ args: [String], developerDir: String?) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let developerDir { env["DEVELOPER_DIR"] = developerDir }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Ist Xcode mit einem Apple-Account angemeldet? Xcode leert beim Abmelden seine Kontoliste, lässt die Teams aber
    /// stehen; ein Eintrag ohne Namen ist kein Konto (wie in Glovebox, `XcodeInfo`).
    static func xcodeHasAccount() -> Bool {
        let (status, exported) = run("/usr/bin/defaults", ["export", "com.apple.dt.Xcode", "-"], developerDir: nil)
        guard status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(exported.utf8), format: nil) as? [String: Any],
              let lists = plist["DVTDeveloperAccountManagerAppleIDLists"] as? [String: Any] else { return false }
        return lists.values.contains { ($0 as? [Any])?.contains(where: isAccount) ?? false }
    }

    static func isAccount(_ entry: Any) -> Bool {
        switch entry {
        case let s as String: return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let d as [String: Any]: return d.values.contains(where: isAccount)
        case let a as [Any]: return a.contains(where: isAccount)
        case is NSNumber, is Date: return false
        default: return true
        }
    }
}

enum Format {
    static func megabytes(_ bytes: Int64) -> String { "\(max(0, bytes) / 1_000_000) MB" }

    static func timeLeft(_ seconds: Double?) -> String? {
        guard let s = seconds, s.isFinite, s > 0 else { return nil }
        if s < 90 { return L("about \(Int(s.rounded())) s left", "noch etwa \(Int(s.rounded())) s") }
        return L("about \(Int((s / 60).rounded())) min left", "noch etwa \(Int((s / 60).rounded())) min")
    }
}

@MainActor
final class SetupAssistant: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, xcode, account, headset, accounts, finish
        var id: Int { rawValue }
    }

    enum StepState: Equatable { case done, working, attention, waiting, todo }

    /// Wo Xcode steht, in der Reihenfolge, in der es durch muss.
    enum XcodeState: Equatable { case checking, missing, tooOld, notChosen, license, components, visionOS, ready }

    enum AppleAccount: Equatable { case checking, none, teamNotLoaded, teams }

    @Published var isPresented = false
    @Published var step: Step = .welcome
    @Published private(set) var xcode: XcodeState = .checking
    @Published private(set) var xcodeVersion: String?
    @Published private(set) var xcodeMajor = 27
    /// Ein Xcode, das schon da ist und nur gewählt werden muss.
    @Published private(set) var otherXcode: DeveloperTools.OtherXcode?
    /// Der App Store legt Xcode schon in „Programme“, während er noch lädt.
    @Published private(set) var xcodeArriving = false
    @Published private(set) var appleAccount: AppleAccount = .checking
    @Published private(set) var teams: [AppleTeam] = []
    /// Alle Vision Pros, die `devicectl` kennt, auch nicht gekoppelte.
    @Published private(set) var headsets: [Device] = []
    @Published private(set) var lastCheck = Date.distantPast
    @Published private(set) var platformDownload: (fraction: Double, secondsLeft: Double?)?
    @Published private(set) var platformProblem: String?
    @Published private(set) var choosingXcode = false
    @Published var chooseProblem: String?

    let guide = SetupGuide()
    weak var model: AppModel?
    private var monitor: Task<Void, Never>?
    private var checking = false
    private var advanceTask: Task<Void, Never>?
    private var arrivedDone = false
    private var triedPlatform = false
    /// Durchlaufene Lizenz und erste Starts je Entwicklerordner: einmal durch, bleiben sie es.
    private var launched: Set<String> = []
    private var keychainWatch: Task<Void, Never>?

    init() { guide.assistant = self }

    var xcodeTooOld: Bool { xcode == .tooOld }
    /// Xcode ist über Lizenz und ersten Start hinaus: Werkzeuge wie `devicectl` laufen.
    var xcodeLaunched: Bool { xcode == .visionOS || xcode == .ready }
    var headsetPaired: Bool { headsets.contains { $0.paired } }
    var chosenTeamPaid: Bool { guard let id = model?.teamId else { return false }; return teams.contains { $0.id == id && !$0.free } }

    // MARK: Öffnen und Schließen

    /// Beim Start: Fehlt etwas Grundlegendes, öffnet sich der Assistent von selbst.
    func offerAtStart() {
        guard let model, Snapshot.directory == nil, !AppDelegate.launchedAtLogin else { return }
        let headsetKnown = UserDefaults.standard.bool(forKey: Self.headsetSeenKey) || model.device != nil || !model.devices.isEmpty
        guard model.xcodeProblem != nil || !model.teamValid || !headsetKnown else { return }
        open()
    }

    static let headsetSeenKey = "setupHeadsetSeen"

    func open(at start: Step? = nil) {
        isPresented = true
        startMonitor()
        Task {
            await check()
            go(start ?? firstOpenStep() ?? .finish)
        }
    }

    func close() {
        guide.stop()
        isPresented = false
        monitor?.cancel()
        monitor = nil
        model?.refresh()
    }

    // MARK: Schritte

    func state(of s: Step) -> StepState {
        switch s {
        case .welcome: return step == .welcome ? .todo : .done
        case .xcode:
            switch xcode {
            case .ready: return .done
            case .checking: return .working
            case .missing: return xcodeArriving || (guide.isRunning && guide.job == .appStore) ? .working : .attention
            case .visionOS: return platformProblem == nil ? .working : .attention
            case .license, .components: return guide.isRunning && guide.job == .setup ? .working : .attention
            case .tooOld, .notChosen: return choosingXcode ? .working : .attention
            }
        case .account:
            guard xcodeLaunched else { return .waiting }
            switch appleAccount {
            case .checking: return .working
            case .none, .teamNotLoaded: return guide.isRunning ? .working : .attention
            case .teams: return model?.teamValid == true && teams.contains(where: { $0.id == model?.teamId }) ? .done : .attention
            }
        case .headset:
            guard xcodeLaunched else { return .waiting }
            if readyHeadset != nil { return .done }
            if guide.isRunning, guide.job == .pair { return .working }
            return .attention
        case .accounts:
            return model?.account == .signedIn || model?.steamSignedIn == true ? .done : .todo
        case .finish:
            return [.xcode, .account, .headset].allSatisfy { state(of: $0) == .done } ? .done : .todo
        }
    }

    /// Ein gekoppeltes, erreichbares Headset mit Entwicklermodus.
    var readyHeadset: Device? { headsets.first { $0.paired && $0.reachable && $0.developerMode } }

    func firstOpenStep() -> Step? {
        [Step.xcode, .account, .headset].first { state(of: $0) != .done }
    }

    func go(_ s: Step) {
        advanceTask?.cancel()
        advanceTask = nil
        arrivedDone = state(of: s) == .done
        withAnimation(.easeInOut(duration: 0.25)) { step = s }
    }

    func continueOn() {
        let all = Step.allCases
        let i = all.firstIndex(of: step) ?? 0
        // Die Konten sind freiwillig: „Weiter“ führt immer dorthin, auch wenn noch nichts angemeldet ist.
        let next = all[(i + 1)...].first { $0 == .accounts || $0 == .finish || state(of: $0) != .done } ?? .finish
        go(next)
    }

    /// Ein Schritt, der gerade auf dem Schirm erledigt wurde, geht nach einem Moment zum nächsten offenen über.
    private func stateChanged() {
        guard isPresented, [.xcode, .account, .headset].contains(step) else { return }
        let done = state(of: step) == .done
        if !done { arrivedDone = false }
        guard done, !arrivedDone, advanceTask == nil else { return }
        let from = step
        advanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.advanceTask = nil
            guard self.step == from, self.state(of: from) == .done else { return }
            self.go(self.firstOpenStep() ?? .accounts)
        }
    }

    // MARK: Prüfen

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                let through = self.firstOpenStep() == nil
                try? await Task.sleep(nanoseconds: through ? 10_000_000_000 : 2_500_000_000)
            }
        }
    }

    func recheck() { Task { await check() } }

    private struct Findings: Sendable {
        var xcode: XcodeState = .missing
        var version: String?
        var major = 27
        var other: DeveloperTools.OtherXcode?
        var arriving = false
        var developerDir: String?
        var account: AppleAccount = .checking
        var teams: [AppleTeam] = []
        var headsets: [Device] = []
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let started = Date()
        let launchedBefore = launched
        var f = await Task.detached(priority: .userInitiated) { Self.findings(launched: launchedBefore) }.value
        #if DEBUG
        // Für Bilder der Seiten, die dieser Mac nicht zeigt: `AVPPLAY_ASSISTANT_FAKE=missing,none,unpaired` usw.
        if let fake = ProcessInfo.processInfo.environment["AVPPLAY_ASSISTANT_FAKE"]?.split(separator: ",").map(String.init) {
            for item in fake {
                switch item {
                case "missing": f.xcode = .missing; f.arriving = false
                case "arriving": f.xcode = .missing; f.arriving = true
                case "license": f.xcode = .license
                case "visionOS": f.xcode = .visionOS
                case "tooOld": f.xcode = .tooOld; f.version = "26.5"
                case "notChosen": f.xcode = .notChosen; f.other = DeveloperTools.unchosenXcode(chosen: nil)
                case "none": f.account = .none; f.teams = []
                case "teamNotLoaded": f.account = .teamNotLoaded; f.teams = []
                case "free": f.teams = [AppleTeam(id: "ABCDE12345", name: "Jane Appleseed (Personal Team)", free: true)]
                case "unpaired": f.headsets = []
                case "devmode": f.headsets = [Device(udid: "x", name: "Apple Vision Pro", osVersion: "27.2", reachable: true, paired: true, developerMode: false)]
                default: break
                }
            }
            triedPlatform = true
        }
        #endif
        if let dev = f.developerDir, f.xcode == .visionOS || f.xcode == .ready { launched.insert(dev) }
        let before = (xcode, appleAccount, headsetPaired, readyHeadset?.udid)
        withAnimation(.spring(duration: 0.35)) {
            xcode = f.xcode
            xcodeVersion = f.version
            xcodeMajor = f.major
            otherXcode = f.other
            xcodeArriving = f.arriving
            appleAccount = f.account
            teams = f.teams
            headsets = f.headsets
        }
        lastCheck = started
        if !f.headsets.filter(\.paired).isEmpty { UserDefaults.standard.set(true, forKey: Self.headsetSeenKey) }
        if f.xcode == .license || f.xcode == .components, ProcessInfo.processInfo.environment["AVPPLAY_ASSISTANT_FAKE"] == nil {
            SetupMac.trimXcodeFirstLaunch()
        }
        // Genau ein bezahltes Team: das ist es. Ein einziges kostenloses ebenso – der Assistent sagt, was das heißt.
        if let model, !model.teamValid || !f.teams.contains(where: { $0.id == model.teamId }) {
            let paid = f.teams.filter { !$0.free }
            if paid.count == 1 { model.teamId = paid[0].id } else if paid.isEmpty, f.teams.count == 1 { model.teamId = f.teams[0].id }
        }
        if f.xcode == .visionOS, !triedPlatform { downloadVisionOS() }
        let after = (xcode, appleAccount, headsetPaired, readyHeadset?.udid)
        if before != after { model?.refresh() }
        stateChanged()
    }

    nonisolated private static func findings(launched: Set<String>) -> Findings {
        var f = Findings()
        let minimum = DeveloperTools.minimumXcodeMajor
        let chosen = DeveloperTools.directory()
        guard let dev = chosen, dev.contains(".app/") else {
            if let other = DeveloperTools.unchosenXcode(chosen: chosen) {
                f.xcode = .notChosen
                f.other = other
                f.version = other.version
            } else {
                f.xcode = .missing
                // Der App Store legt Xcode an, bevor seine Werkzeuge da sind.
                f.arriving = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
                    .contains { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            }
            return f
        }
        f.developerDir = dev
        let app = String(dev[..<dev.range(of: ".app/")!.lowerBound]) + ".app"
        let version = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
        f.version = version
        f.major = version.flatMap { Int($0.split(separator: ".").first ?? "") } ?? 27
        if f.major < minimum {
            if let newer = DeveloperTools.newerXcodes(chosen: dev).first {
                f.xcode = .notChosen
                f.other = newer
            } else {
                f.xcode = .tooOld
            }
            return f
        }
        // Ein neues Xcode baut nichts, bevor seine Lizenz angenommen und sein erster Start durch ist. Vorher läuft
        // nichts über `xcrun`: Das könnte macOS' Frage nach den Entwicklerwerkzeugen auslösen.
        if !launched.contains(dev) {
            let xcodebuild = dev + "/usr/bin/xcodebuild"
            if SetupMac.run(xcodebuild, ["-license", "check"], developerDir: dev).0 != 0 { f.xcode = .license; return f }
            if SetupMac.run(xcodebuild, ["-checkFirstLaunchStatus"], developerDir: dev).0 != 0 { f.xcode = .components; return f }
        }
        let sdks = SetupMac.run(dev + "/usr/bin/xcodebuild", ["-showsdks"], developerDir: dev).1
        f.xcode = sdks.contains("xros") ? .ready : .visionOS
        let teams = AppleTeams.known()
        f.teams = teams
        f.account = !teams.isEmpty ? .teams : SetupMac.xcodeHasAccount() ? .teamNotLoaded : .none
        f.headsets = (try? DeviceControl().devices()) ?? []
        return f
    }

    // MARK: Was der Assistent selbst tut

    /// visionOS zu Xcode hinzufügen (`xcodebuild -downloadPlatform visionOS`), mit Fortschritt.
    func downloadVisionOS() {
        guard platformDownload == nil, let dev = DeveloperTools.directory() else { return }
        triedPlatform = true
        platformProblem = nil
        platformDownload = (0, nil)
        let started = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: dev + "/usr/bin/xcodebuild")
            p.arguments = ["-downloadPlatform", "visionOS"]
            var env = ProcessInfo.processInfo.environment
            env["DEVELOPER_DIR"] = dev
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            var last = ""
            if (try? p.run()) != nil {
                var buffer = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    // xcodebuild zeichnet seinen Fortschritt mit \r neu: an beidem trennen.
                    while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let line = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...i)
                        guard !line.isEmpty else { continue }
                        last = line
                        if let r = line.range(of: #"(\d{1,3}(\.\d+)?)%"#, options: .regularExpression), let v = Double(line[r].dropLast()) {
                            let fraction = min(1, v / 100)
                            let elapsed = Date().timeIntervalSince(started)
                            let left = fraction > 0.03 && elapsed > 5 ? elapsed * (1 - fraction) / fraction : nil
                            Task { @MainActor [weak self] in self?.platformDownload = (fraction, left) }
                        }
                    }
                }
                p.waitUntilExit()
            }
            let status = p.isRunning ? -1 : p.terminationStatus
            let tail = last
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.platformDownload = nil
                if status != 0 {
                    self.platformProblem = L("The download stopped (\(tail.isEmpty ? "status \(status)" : tail)).", "Der Download brach ab (\(tail.isEmpty ? "Status \(status)" : tail)).")
                }
                self.recheck()
            }
        }
    }

    /// Ein vorhandenes Xcode wählen: macOS fragt dafür selbst nach dem Mac-Passwort (im eigenen Fenster, AVP Play
    /// sieht es nicht). Geht das nicht, bleibt der Befehl zum Kopieren.
    func chooseOtherXcode() {
        guard let other = otherXcode, !choosingXcode else { return }
        let path = other.developer
        guard !path.contains("'"), !path.contains("\""), !path.contains("\\") else {
            chooseProblem = L("Run the command below in Terminal.", "Den Befehl unten im Terminal ausführen.")
            return
        }
        choosingXcode = true
        chooseProblem = nil
        Task.detached { [weak self] in
            let script = "do shell script \"/usr/bin/xcode-select -s '\(path)'\" with administrator privileges"
            let (status, out) = SetupMac.run("/usr/bin/osascript", ["-e", script], developerDir: nil)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.choosingXcode = false
                // -128: abgebrochen; dann nichts sagen.
                if status != 0, !out.contains("-128") {
                    self.chooseProblem = L("macOS did not change it: \(out.trimmingCharacters(in: .whitespacesAndNewlines))",
                                           "macOS hat es nicht umgestellt: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                self.recheck()
            }
        }
    }

    func getXcode() { guide.start(.appStore) }

    func openXcodeForSetup() {
        SetupMac.trimXcodeFirstLaunch()
        guide.start(.setup)
    }

    // MARK: Schlüsselbund beim ersten Bau

    /// Während ein Auftrag läuft: Fragt macOS nach dem Signierschlüssel, zeigt die Hilfe auf „Immer erlauben“.
    func startKeychainWatch() {
        guard keychainWatch == nil, Snapshot.directory == nil else { return }
        keychainWatch = Task { [weak self] in
            var handled = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                guard self.model?.runningJob != nil else { handled = false; continue }
                let prompt = SetupGuide.keychainPrompt != nil
                if !prompt { handled = false; continue }
                guard !handled, !self.guide.isRunning else { continue }
                handled = true
                self.guide.start(.keychain)
            }
        }
    }
}

// MARK: Ansichten

struct SetupAssistantView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var assistant: SetupAssistant

    var body: some View {
        VStack(spacing: 0) {
            StepBar()
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)
            Divider()
            ScrollView {
                page
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                    .id(assistant.step)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            Divider()
            HStack {
                Button(assistant.step == .finish ? L("Close", "Schließen") : L("Set Up Later", "Später einrichten")) { assistant.close() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if assistant.step != .welcome, assistant.step != .xcode {
                    Button(L("Back", "Zurück")) {
                        if let prev = SetupAssistant.Step(rawValue: assistant.step.rawValue - 1) { assistant.go(prev) }
                    }
                }
                primaryButton
            }
            .padding(16)
        }
        .frame(width: 780, height: 600)
        .environmentObject(assistant.guide)
    }

    @ViewBuilder private var page: some View {
        switch assistant.step {
        case .welcome: WelcomePage()
        case .xcode: XcodePage()
        case .account: AccountPage()
        case .headset: HeadsetPage()
        case .accounts: AccountsPage()
        case .finish: FinishPage()
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch assistant.step {
        case .welcome:
            Button(L("Get Started", "Los geht’s")) { assistant.go(assistant.firstOpenStep() ?? .accounts) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        case .finish:
            Button(L("Show the Games", "Zu den Spielen")) {
                model.section = .games
                assistant.close()
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        case .accounts:
            Button(L("Continue", "Weiter")) { assistant.continueOn() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        default:
            // Weiter geht es auch, solange ein Schritt noch läuft (Xcode lädt): Der Assistent kommt dorthin zurück.
            Button(assistant.state(of: assistant.step) == .done ? L("Continue", "Weiter") : L("Skip for Now", "Erst einmal überspringen")) { assistant.continueOn() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .tint(assistant.state(of: assistant.step) == .done ? .accentColor : .gray)
        }
    }
}

/// Die Schritte oben: Symbol, Name und wie weit er ist; ein Klick springt hin.
private struct StepBar: View {
    @EnvironmentObject var assistant: SetupAssistant

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SetupAssistant.Step.allCases) { s in
                if s != .welcome {
                    Button { assistant.go(s) } label: {
                        HStack(spacing: 6) {
                            StatusMark(state: assistant.state(of: s), symbol: symbol(s))
                            Text(title(s)).font(.callout.weight(assistant.step == s ? .semibold : .regular)).lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(assistant.step == s ? Color.accentColor.opacity(0.18) : Color.clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    if s != .finish {
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    func title(_ s: SetupAssistant.Step) -> String {
        switch s {
        case .welcome: return L("Welcome", "Willkommen")
        case .xcode: return "Xcode"
        case .account: return L("Apple Account", "Apple-Account")
        case .headset: return "Vision Pro"
        case .accounts: return L("Game Accounts", "Spielekonten")
        case .finish: return L("Done", "Fertig")
        }
    }

    func symbol(_ s: SetupAssistant.Step) -> String {
        switch s {
        case .welcome: return "hand.wave"
        case .xcode: return "hammer"
        case .account: return "person.crop.circle"
        case .headset: return "visionpro"
        case .accounts: return "gamecontroller"
        case .finish: return "flag.checkered"
        }
    }
}

private struct StatusMark: View {
    var state: SetupAssistant.StepState
    var symbol: String

    var body: some View {
        Group {
            switch state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .working: ProgressView().controlSize(.small)
            case .attention: Image(systemName: symbol).foregroundStyle(.orange)
            case .todo, .waiting: Image(systemName: symbol).foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .animation(.spring(duration: 0.35), value: state)
    }
}

/// Eine Seite: große Überschrift, ein Satz, darunter was zu tun ist.
private struct Page<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 26, weight: .bold))
                if let subtitle {
                    Text(subtitle).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
    }
}

/// Eine Zeile mit Häkchen: was erledigt ist oder gerade passiert.
private struct DoneLine: View {
    var text: String
    var working = false

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            if working { ProgressView().controlSize(.small) } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
        .font(.title3)
    }
}

/// Während die Hilfe neben einem anderen Programm läuft.
private struct GuideRunningNote: View {
    @EnvironmentObject var guide: SetupGuide

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Follow the steps next to \(app)", "Folge den Schritten neben \(app)")).font(.headline)
                    Text(L("AVP Play comes back here when you're done.", "AVP Play kommt hierher zurück, wenn du fertig bist.")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Show It Again", "Noch einmal zeigen")) { guide.bringForward() }
                Button(L("Stop", "Beenden")) { guide.stop() }
            }
            .padding(6)
        }
    }

    private var app: String {
        switch guide.job {
        case .appStore: return L("the App Store", "dem App Store")
        case .pair where guide.xcodeMajor >= 27: return "Device Hub"
        default: return "Xcode"
        }
    }
}

private struct WelcomePage: View {
    var body: some View {
        Page(title: L("Welcome to AVP Play", "Willkommen bei AVP Play"),
             subtitle: L("Before the first game goes onto your Vision Pro, this Mac needs a few things. AVP Play walks you through them one by one and shows you exactly where to click.",
                         "Bevor das erste Spiel auf deine Vision Pro kommt, braucht dieser Mac ein paar Dinge. AVP Play führt dich Schritt für Schritt hindurch und zeigt dir genau, wo du klicken musst.")) {
            VStack(alignment: .leading, spacing: 14) {
                item("hammer", L("Xcode", "Xcode"), L("Apple's free developer app. AVP Play uses it to build the games for the Vision Pro.", "Apples kostenloses Entwicklerprogramm. Damit baut AVP Play die Spiele für die Vision Pro."))
                item("person.crop.circle", L("Your Apple Account in Xcode", "Dein Apple-Account in Xcode"), L("The games are signed with it. A free account works; a paid one lasts longer.", "Damit werden die Spiele signiert. Ein kostenloser Account reicht; ein bezahlter hält länger."))
                item("visionpro", L("Your Vision Pro", "Deine Vision Pro"), L("Paired with this Mac once, with Developer Mode on.", "Einmal mit diesem Mac gekoppelt, mit eingeschaltetem Entwicklermodus."))
                item("gamecontroller", L("Your game accounts", "Deine Spielekonten"), L("Meta or Steam, only for the games you bought there.", "Meta oder Steam, nur für die Spiele, die du dort gekauft hast."))
            }
            Text(L("It takes about 30 minutes, most of it Xcode downloading. You can leave and come back at any time: AVP Play remembers where you are.",
                   "Das dauert etwa 30 Minuten, das meiste davon lädt Xcode. Du kannst jederzeit aufhören und später weitermachen: AVP Play merkt sich, wo du bist."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func item(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).frame(width: 32).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct XcodePage: View {
    @EnvironmentObject var assistant: SetupAssistant
    @EnvironmentObject var guide: SetupGuide

    var body: some View {
        switch assistant.xcode {
        case .checking:
            Page(title: L("Looking for Xcode", "Xcode wird gesucht")) { ProgressView() }
        case .missing:
            if guide.isRunning, guide.job == .appStore {
                Page(title: L("Get Xcode", "Xcode laden")) { GuideRunningNote() }
            } else if assistant.xcodeArriving {
                Page(title: L("Xcode is downloading", "Xcode wird geladen"),
                     subtitle: L("The App Store is loading it (about 10 GB). You can continue with the other steps meanwhile; AVP Play notices when it is there.",
                                 "Der App Store lädt es (etwa 10 GB). Du kannst solange mit den anderen Schritten weitermachen; AVP Play merkt, wenn es da ist.")) {
                    HStack(spacing: 14) {
                        XcodeIcon(size: 56)
                        ProgressView().controlSize(.small)
                        Button(L("Open App Store", "App Store öffnen")) { assistant.getXcode() }.buttonStyle(.link)
                    }
                }
            } else {
                Page(title: L("Get Xcode", "Xcode laden"),
                     subtitle: L("It's free in the App Store. AVP Play opens Xcode's page and shows you where to click.",
                                 "Es ist kostenlos im App Store. AVP Play öffnet die Seite von Xcode und zeigt dir, wo du klicken musst.")) {
                    HStack(spacing: 16) {
                        XcodeIcon(size: 64)
                        Button(L("Open Xcode in the App Store", "Xcode im App Store öffnen")) { assistant.getXcode() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
            }
        case .tooOld:
            Page(title: L("Update Xcode", "Xcode aktualisieren"),
                 subtitle: L("AVP Play needs Xcode \(DeveloperTools.minimumXcodeMajor) or newer; this Mac has Xcode \(assistant.xcodeVersion ?? "?").",
                             "AVP Play braucht Xcode \(DeveloperTools.minimumXcodeMajor) oder neuer; auf diesem Mac ist Xcode \(assistant.xcodeVersion ?? "?").")) {
                if guide.isRunning, guide.job == .appStore { GuideRunningNote() } else {
                    HStack(spacing: 16) {
                        XcodeIcon(size: 64)
                        Button(L("Update in the App Store", "Im App Store aktualisieren")) { assistant.getXcode() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
            }
        case .notChosen:
            if let other = assistant.otherXcode {
                Page(title: L("Choose Xcode", "Xcode auswählen"),
                     subtitle: L("\(other.name) \(other.version) is on this Mac, but macOS uses something else for developer tools. One click changes that; macOS asks for your Mac password.",
                                 "\(other.name) \(other.version) liegt auf diesem Mac, aber macOS benutzt als Entwicklerwerkzeuge etwas anderes. Ein Klick stellt das um; macOS fragt dafür nach deinem Mac-Passwort.")) {
                    HStack(spacing: 12) {
                        XcodeIcon(size: 56)
                        Button(L("Use \(other.name)", "\(other.name) verwenden")) { assistant.chooseOtherXcode() }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(assistant.choosingXcode)
                        if assistant.choosingXcode { ProgressView().controlSize(.small) }
                    }
                    if let p = assistant.chooseProblem { Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    DisclosureGroup(L("Or in Terminal", "Oder im Terminal")) {
                        HStack {
                            Text(other.selectCommand).font(.callout.monospaced()).textSelection(.enabled)
                            Button(L("Copy", "Kopieren")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(other.selectCommand, forType: .string)
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        case .license, .components:
            Page(title: L("Finish setting up Xcode", "Xcode fertig einrichten"),
                 subtitle: L("Xcode needs a few clicks on its first start: its license, your Mac password, then Continue. AVP Play shows you where.",
                             "Xcode braucht beim ersten Start ein paar Klicks: seine Lizenz, dein Mac-Passwort, dann „Continue“. AVP Play zeigt dir, wo.")) {
                if guide.isRunning, guide.job == .setup { GuideRunningNote() } else {
                    HStack(spacing: 16) {
                        XcodeIcon(size: 64)
                        Button(L("Open Xcode", "Xcode öffnen")) { assistant.openXcodeForSetup() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                Text(L("AVP Play has preselected only visionOS in Xcode's list of platforms, so Xcode downloads only what the games need.",
                       "AVP Play hat in Xcodes Liste der Plattformen nur visionOS vorgewählt – so lädt Xcode nur, was die Spiele brauchen."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .visionOS:
            Page(title: L("Adding visionOS to Xcode", "visionOS wird zu Xcode hinzugefügt"),
                 subtitle: L("AVP Play does this by itself. You can continue meanwhile.", "Das macht AVP Play selbst. Du kannst solange weitermachen.")) {
                if let p = assistant.platformProblem {
                    HStack {
                        Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Spacer()
                        Button(L("Try Again", "Noch einmal")) { assistant.downloadVisionOS() }
                    }
                } else if let d = assistant.platformDownload {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: d.fraction)
                        Text(Format.timeLeft(d.secondsLeft).map { "\(Int(d.fraction * 100)) % · \($0)" } ?? "\(Int(d.fraction * 100)) %")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 480)
                } else {
                    ProgressView()
                }
            }
        case .ready:
            Page(title: L("Xcode is ready", "Xcode ist bereit")) {
                HStack(spacing: 14) {
                    XcodeIcon(size: 56)
                    DoneLine(text: L("Xcode \(assistant.xcodeVersion ?? "") with visionOS", "Xcode \(assistant.xcodeVersion ?? "") mit visionOS"))
                }
            }
        }
    }
}

private struct AccountPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var assistant: SetupAssistant
    @EnvironmentObject var guide: SetupGuide

    var body: some View {
        if !assistant.xcodeLaunched {
            Page(title: L("Sign in to Xcode", "In Xcode anmelden"), subtitle: L("Xcode comes first.", "Erst kommt Xcode.")) {
                Button(L("Go to Xcode", "Zu Xcode")) { assistant.go(.xcode) }
            }
        } else if guide.isRunning, [.signIn, .refresh].contains(guide.job) {
            Page(title: L("Sign in to Xcode", "In Xcode anmelden")) { GuideRunningNote() }
        } else {
            switch assistant.appleAccount {
            case .checking:
                Page(title: L("Checking your Apple Account", "Apple-Account wird geprüft")) { ProgressView() }
            case .none:
                Page(title: L("Sign in to Xcode", "In Xcode anmelden"),
                     subtitle: L("With the Apple Account you use on your iPhone. AVP Play opens Xcode's settings and shows you each click.",
                                 "Mit dem Apple-Account, den du auch auf dem iPhone benutzt. AVP Play öffnet Xcodes Einstellungen und zeigt dir jeden Klick.")) {
                    Button(L("Sign In", "Anmelden")) { guide.start(.signIn) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Text(L("A free Apple Account works. Games then have to be installed again every 7 days, and a few games need a paid Apple Developer membership.",
                           "Ein kostenloser Apple-Account reicht. Die Spiele müssen dann alle 7 Tage neu installiert werden, und einige wenige Spiele brauchen eine bezahlte Apple-Developer-Mitgliedschaft."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .teamNotLoaded:
                Page(title: L("Load your team in Xcode", "Dein Team in Xcode laden"),
                     subtitle: L("You're signed in. Xcode just hasn't loaded your team yet; two clicks in its settings do it.",
                                 "Du bist angemeldet. Xcode hat dein Team nur noch nicht geladen; zwei Klicks in seinen Einstellungen erledigen das.")) {
                    Button(L("Show Me", "Zeig es mir")) { guide.start(.refresh) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            case .teams:
                teamsPage
            }
        }
    }

    @ViewBuilder private var teamsPage: some View {
        let chosen = assistant.teams.first { $0.id == model.teamId }
        Page(title: chosen == nil ? L("Which team should AVP Play use?", "Welches Team soll AVP Play benutzen?") : L("You're signed in", "Du bist angemeldet"),
             subtitle: chosen?.name) {
            if assistant.teams.count > 1 || chosen == nil {
                Picker(L("Team", "Team"), selection: Binding(get: { model.teamId }, set: { model.teamId = $0; model.refresh() })) {
                    ForEach(assistant.teams, id: \.id) { t in
                        Text("\(t.name)\(t.free ? L(" (free)", " (kostenlos)") : "")").tag(t.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
            if let chosen {
                if chosen.free {
                    Label(L("Free account: games have to be reinstalled every 7 days", "Kostenloser Account: Spiele alle 7 Tage neu installieren"), systemImage: "clock.arrow.circlepath")
                        .font(.title3)
                    FreeAccountLimits()
                    HStack {
                        Button(L("Join the Apple Developer Program …", "Apple Developer Program beitreten …")) {
                            NSWorkspace.shared.open(URL(string: "https://developer.apple.com/programs/enroll/")!)
                        }
                        Button(L("I Joined – Check Again", "Beigetreten – neu prüfen")) { guide.start(.refresh) }
                    }
                    .controlSize(.small)
                } else {
                    DoneLine(text: L("Apple Developer Program", "Apple Developer Program"))
                }
            }
        }
    }
}

private struct HeadsetPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var assistant: SetupAssistant
    @EnvironmentObject var guide: SetupGuide

    var body: some View {
        if !assistant.xcodeLaunched {
            Page(title: L("Pair your Vision Pro", "Vision Pro koppeln"), subtitle: L("Xcode comes first.", "Erst kommt Xcode.")) {
                Button(L("Go to Xcode", "Zu Xcode")) { assistant.go(.xcode) }
            }
        } else if let ready = assistant.readyHeadset {
            Page(title: L("\(ready.name) is ready", "\(ready.name) ist bereit")) {
                DoneLine(text: L("Paired, with Developer Mode on.", "Gekoppelt, Entwicklermodus an."))
                Text(L("From now on the headset only has to be on, unlocked and on the same Wi-Fi as this Mac. With a cable on the Developer Strap, copying is much faster.",
                       "Ab jetzt muss das Headset nur an, entsperrt und im selben WLAN wie dieser Mac sein. Mit Kabel am Developer Strap geht das Kopieren deutlich schneller."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else if let paired = assistant.headsets.first(where: { $0.paired }) {
            if !paired.developerMode {
                Page(title: L("Turn on Developer Mode", "Entwicklermodus einschalten"), subtitle: L("On your Vision Pro. AVP Play continues as soon as it's on.", "Auf deiner Vision Pro. AVP Play macht weiter, sobald er an ist.")) {
                    DeveloperModeGuide()
                    DoneLine(text: L("Waiting for your Vision Pro …", "Warte auf deine Vision Pro …"), working: true)
                }
            } else {
                Page(title: L("Put on your Vision Pro", "Vision Pro aufsetzen"),
                     subtitle: L("\(paired.name) is paired but not reachable right now. Turn it on, unlock it and connect it to the same Wi-Fi as this Mac.",
                                 "\(paired.name) ist gekoppelt, aber gerade nicht erreichbar. Einschalten, entsperren und ins selbe WLAN wie dieser Mac.")) {
                    DoneLine(text: L("Waiting for your Vision Pro …", "Warte auf deine Vision Pro …"), working: true)
                }
            }
        } else if guide.isRunning, guide.job == .pair {
            Page(title: L("Pair your Vision Pro", "Vision Pro koppeln")) { GuideRunningNote() }
        } else {
            Page(title: L("Pair your Vision Pro", "Vision Pro koppeln"),
                 subtitle: L("Once, over Wi-Fi. Put the headset on, make sure it's on the same Wi-Fi as this Mac, then click Pair: AVP Play opens \(assistant.xcodeMajor >= 27 ? "Device Hub" : "Xcode") and shows you each click.",
                             "Einmal, über das WLAN. Headset aufsetzen, im selben WLAN wie dieser Mac, dann „Koppeln“: AVP Play öffnet \(assistant.xcodeMajor >= 27 ? "Device Hub" : "Xcode") und zeigt dir jeden Klick.")) {
                PairingStoryboard(deviceHub: assistant.xcodeMajor >= 27)
                Button(L("Pair", "Koppeln")) { guide.start(.pair) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
}

private struct AccountsPage: View {
    var body: some View {
        Page(title: L("Your game accounts", "Deine Spielekonten"),
             subtitle: L("Only for the games you bought there – you can skip this and do it later under Setup.",
                         "Nur für die Spiele, die du dort gekauft hast – du kannst das überspringen und später unter „Einrichtung“ nachholen.")) {
            MetaAccountCard()
            SteamCard()
        }
    }
}

private struct FinishPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var assistant: SetupAssistant

    var body: some View {
        let open = [SetupAssistant.Step.xcode, .account, .headset].filter { assistant.state(of: $0) != .done }
        Page(title: open.isEmpty ? L("All set", "Alles bereit") : L("Almost there", "Fast geschafft"),
             subtitle: open.isEmpty ? L("Pick a game and click Install. The first build can ask for your Mac password once – AVP Play shows you where.",
                                        "Such dir ein Spiel aus und klick auf „Installieren“. Der erste Bau kann einmal nach deinem Mac-Passwort fragen – AVP Play zeigt dir, wo.")
                 : L("A few things are still open. You can come back here any time from Setup.",
                     "Ein paar Dinge sind noch offen. Du kannst jederzeit über „Einrichtung“ hierher zurück.")) {
            VStack(alignment: .leading, spacing: 10) {
                row(.xcode, L("Xcode", "Xcode"))
                row(.account, L("Apple Account", "Apple-Account"))
                row(.headset, "Vision Pro")
                HStack {
                    Image(systemName: model.toolchainText == nil ? "circle.dashed" : "checkmark.circle.fill")
                        .foregroundStyle(model.toolchainText == nil ? Color.secondary : Color.green)
                    Text(L("Toolchain", "Toolchain"))
                    Text(model.toolchainText ?? L("installs itself", "installiert sich selbst")).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.title3)
            }
        }
    }

    private func row(_ s: SetupAssistant.Step, _ title: String) -> some View {
        let done = assistant.state(of: s) == .done
        return Button { assistant.go(s) } label: {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(done ? Color.green : Color.orange)
                Text(title)
                if !done { Text(L("open – click to continue", "offen – klicken zum Weitermachen")).foregroundStyle(.secondary) }
            }
            .font(.title3)
        }
        .buttonStyle(.plain)
    }
}
