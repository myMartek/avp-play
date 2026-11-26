import AppKit
import AVPPlayCore
import LocalAuthentication
import SwiftUI

// Die schwebende Hilfe neben Xcode, dem App Store und Device Hub. Übernommen aus Glovebox
// (github.com/glovebox-vr/glovebox, installer/App/Glovebox/XcodeGuide.swift, MIT-Lizenz, © 2026 the Glovebox
// contributors) und an AVP Play angepasst: zweisprachige Texte, die Prüfungen des Assistenten statt der von Glovebox.

/// Die Schritte, die in einem anderen Programm passieren: Xcode im App Store holen, Xcodes erster Start, die Anmeldung
/// in Xcode, das Koppeln in Device Hub und das Schlüsselbund-Fenster von macOS beim ersten Bau. Keines davon lässt sich
/// von außen bedienen. AVP Play öffnet darum das Programm (und stellt Xcodes Einstellungen auf „Apple Accounts“) und
/// lässt daneben eine Blase schweben, die das eine Nächste zeigt: große Tasten zum Drücken oder einen Pfeil auf genau
/// den Knopf, mit einem Ring darum. Die Fenster verfolgt sie nur über ihre Lage, wofür es keine Erlaubnis braucht; ist
/// der Schritt erledigt, verschwindet sie und AVP Play kommt wieder nach vorn.
@MainActor
final class SetupGuide: ObservableObject {
    enum Job: Equatable {
        /// In Xcode mit einem Apple-Account anmelden.
        case signIn
        /// Xcode das Konto noch einmal zeigen: ein Team laden, das es noch nicht gespeichert hat (angemeldet, kein Team:
        /// „Download Manual Profiles“ lässt Xcode bei Apple nachfragen), oder eine neue Mitgliedschaft sehen.
        case refresh
        /// Das Headset koppeln: Device Hub ab Xcode 27, davor Xcodes Fenster „Devices“.
        case pair
        /// Xcode im App Store holen (oder aktualisieren).
        case appStore
        /// Xcodes erster Start: Lizenz, Mac-Passwort für die Bestandteile, die ersten Seiten.
        case setup
        /// Das Schlüsselbund-Fenster von macOS vor dem ersten Signieren: Mac-Passwort, dann „Immer erlauben“.
        case keychain
    }

    enum Sheet: Equatable { case welcome, signIn, password }

    enum Stage: Int, Comparable {
        case welcome, open, click, team, device, confirm, finish, done
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var job: Job = .signIn
    @Published private(set) var stage: Stage = .open
    /// Xcode 27 und neuer haben Device Hub und sagen „Sign In…“; Xcode 26 sagt „Add Apple Account…“.
    @Published private(set) var xcodeMajor = 27
    @Published private(set) var arrow: HorizontalEdge?
    @Published private(set) var arrowY: CGFloat = GuideBubbleShape.defaultArrowY
    @Published private(set) var arrowUpX: CGFloat?
    @Published private(set) var updating = false
    @Published private(set) var sheet: Sheet?
    @Published private(set) var showsPicture = false
    @Published private(set) var installPage = false
    @Published private(set) var pairCode = false
    @Published private(set) var touchID = false
    @Published private(set) var loadingTeam = false

    weak var assistant: SetupAssistant?
    private var panel: NSPanel?
    private var ring: NSWindow?
    private var ringTarget: CGRect?
    private var loop: Task<Void, Never>?
    private var clicks: Any?
    private var keyMonitor: Any?
    private var placedFor: String?
    private var plusClicked: Date?
    private var pairingSeen: Date?
    private var revealed = false
    private var startedAt = Date()
    private var storeClicks = 0
    private var storeFrame: CGRect?
    private var clickedInStore = false
    private var sheetFrame: CGRect?
    private var passwordSeen = false
    private var promptClosed: Date?
    private var promptUp = false
    private var touchIDAtPrompt = false
    private var profilesClicked = false
    private var settingsSeen: Date?
    /// Das Schlüsselbund-Fenster war schon da: Geht es weg, ist die Frage beantwortet.
    private var keychainSeen = false
    /// Xcodes Fenster beim Start der Hilfe (Lage und Größe), um ein danach geöffnetes zu erkennen.
    private var windowsAtStart: Set<String> = []

    static func key(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))" }

    func start(_ job: Job) {
        stop()
        self.job = job
        xcodeMajor = assistant?.xcodeMajor ?? 27
        updating = assistant?.xcodeTooOld == true
        loadingTeam = job == .refresh && assistant?.appleAccount == .teamNotLoaded
        #if DEBUG
        if testLoadingTeam { loadingTeam = true }
        #endif
        stage = .open
        isRunning = true
        assistant?.objectWillChange.send()
        if [.signIn, .refresh].contains(job) { Self.openSettingsOnAccounts() }
        windowsAtStart = Set(Self.windows(of: "com.apple.dt.Xcode").map { Self.key($0.frame) })
        openTarget()
        showPanel(reveal: false)
        startedAt = Date()
        clicks = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let at = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.clicked(at) }
        }
        // Die Tasten gelten nur in Xcode. In AVP Play gedrückt, holen sie Xcode nach vorn, und die Blase zeigt sie weiter.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isGuideKey(event) else { return false }
                self.focusTarget()
                return true
            }
            return handed ? nil : event
        }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.follow()
                self.fitPanel()
                self.revealWhenPlaced()
                if tick % 10 == 0 || self.job == .keychain, self.finished { return self.complete() }
                tick += 1
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if let c = clicks { NSEvent.removeMonitor(c) }
        clicks = nil
        if let k = keyMonitor { NSEvent.removeMonitor(k) }
        keyMonitor = nil
        panel?.orderOut(nil)
        ring?.orderOut(nil)
        panel = nil
        ring = nil
        ringTarget = nil
        placedFor = nil
        plusClicked = nil
        pairingSeen = nil
        revealed = false
        arrow = nil
        arrowUpX = nil
        sheet = nil
        showsPicture = false
        installPage = false
        pairCode = false
        storeClicks = 0
        storeFrame = nil
        clickedInStore = false
        sheetFrame = nil
        passwordSeen = false
        promptClosed = nil
        promptUp = false
        profilesClicked = false
        settingsSeen = nil
        keychainSeen = false
        if isRunning {
            isRunning = false
            assistant?.objectWillChange.send()
        }
    }

    /// „Noch einmal zeigen“: Xcode oder Device Hub wieder vorn, die Blase daneben.
    func bringForward() {
        guard isRunning else { return }
        focusTarget()
        if revealed { panel?.orderFrontRegardless() }
    }

    private func focusTarget() {
        if job == .keychain { return }
        if job == .appStore {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: Self.appStoreID)
        } else if job != .pair || xcodeMajor < 27 {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.apple.dt.Xcode")
        }
        openTarget()
    }

    /// ⌘, (oder ⇧⌘2 für das Fenster „Devices“ in Xcode 26), solange die Blase diese Tasten zeigt.
    private func isGuideKey(_ e: NSEvent) -> Bool {
        guard stage == .open else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch job {
        case .signIn, .refresh: return mods == .command && e.charactersIgnoringModifiers == ","
        case .pair: return xcodeMajor < 27 && mods == [.command, .shift] && e.keyCode == 19
        case .appStore, .setup, .keychain: return false
        }
    }

    private func openTarget() {
        switch job {
        case .keychain: return
        case .appStore: NSWorkspace.shared.open(URL(string: SetupMac.appStoreXcode)!)
        case .pair where xcodeMajor >= 27:
            if let hub = Self.deviceHubURL {
                NSWorkspace.shared.openApplication(at: hub, configuration: NSWorkspace.OpenConfiguration())
            } else {
                SetupMac.openXcode()
            }
        default: SetupMac.openXcode()
        }
    }

    #if DEBUG
    /// Zum Ausprobieren auf einem Mac, auf dem alles schon eingerichtet ist (`AVPPLAY_GUIDE_TEST=<Aufgabe>[,team]`):
    /// Die Hilfe meldet nie „erledigt“.
    var testHold = false
    var testLoadingTeam = false
    #endif

    /// Die Prüfungen des Assistenten, alle paar Sekunden, sagen, wann der Schritt erledigt ist.
    private var finished: Bool {
        #if DEBUG
        if testHold { return false }
        #endif
        guard let a = assistant else { return false }
        switch job {
        case .signIn: return a.appleAccount != .none && a.appleAccount != .checking
        case .refresh:
            if loadingTeam { return a.appleAccount == .teams }
            return a.chosenTeamPaid
        case .pair: return a.headsetPaired
        case .appStore: return a.xcodeArriving || (a.xcode != .missing && a.xcode != .checking && !a.xcodeTooOld)
        case .setup: return a.xcodeLaunched && !Self.windows(of: "com.apple.dt.Xcode").contains(where: Self.isFirstLaunch)
        case .keychain: return keychainSeen && Self.keychainPrompt == nil
        }
    }

    private var targetApps: Set<String> {
        switch job {
        case .appStore: return [Self.appStoreID]
        case .pair: return ["com.apple.dt.Xcode", "com.apple.dt.Devices", "Device Hub"]
        case .keychain: return []
        default: return ["com.apple.dt.Xcode"]
        }
    }

    private func complete() {
        withAnimation(.spring(duration: 0.4, bounce: 0.4)) { stage = .done }
        hideRing()
        resizePanel()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self else { return }
            let apps = self.targetApps
            self.stop()
            if !apps.isEmpty { SetupMac.comeBack(from: apps) }
            self.assistant?.recheck()
        }
    }

    // MARK: Den Fenstern folgen

    private func follow() {
        switch job {
        case .pair: return followPairing()
        case .appStore: return followAppStore()
        case .setup: return followSetup()
        case .keychain: return followKeychain()
        case .signIn, .refresh: break
        }
        let windows = Self.windows(of: "com.apple.dt.Xcode")
        // Xcodes erste Seiten schweben über seinen anderen Fenstern, bis sie durch sind.
        if let welcome = windows.first(where: { $0.layer == 8 && $0.frame.height > 400 }) {
            set(.welcome, beside: welcome.frame)
            return
        }
        // Die Maße der Knöpfe gelten für Xcodes Einstellungen in 710 × 452 Punkten (Xcode 26 und 27.0). Xcode 27.2 öffnet
        // sie größer (942 × 590 gesehen), und der Nutzer kann sie ziehen: Dann gilt ein Fenster passender Größe, das erst
        // nach dem Start der Hilfe aufging, als Einstellungen, und die Blase zeigt ein Bild des Knopfs statt eines Rings.
        let measured = windows.first(where: { $0.layer == 0 && Self.isSettings($0.frame) })
        let grown = measured == nil ? windows.first(where: {
            $0.layer == 0 && !windowsAtStart.contains(Self.key($0.frame))
                && (600...1500).contains($0.frame.width) && (400...1100).contains($0.frame.height)
        }) : nil
        if let grown {
            settingsSeen = Date()
            picture(true)
            set(.finish, beside: grown.frame)
            return
        }
        picture(false)
        guard let settings = measured else {
            // Auf der Seite des Kontos oder Teams fehlt das Fenster kurz, während Xcode es umbaut: alles bleibt, wo es ist.
            if job == .refresh, loadingTeam, stage >= .team, stage < .done, let seen = settingsSeen,
               Date().timeIntervalSince(seen) < 2 { return }
            set(stage == .welcome ? .open : min(stage, .open), beside: windows.first(where: { $0.layer == 0 })?.frame)
            return
        }
        settingsSeen = Date()
        // Ein Blatt über den Einstellungen ist Apples Anmeldung (480 × 600 Punkte in Xcode 27.0).
        let sheet = windows.first { $0.layer == 0 && $0.frame != settings.frame && settings.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.minY + 2)) }
        if let sheet, job == .signIn {
            if (440...520).contains(sheet.frame.width), (540...660).contains(sheet.frame.height) {
                set(.finish, pointAt: Self.accountField(in: sheet.frame), from: .trailing, beside: sheet.frame, ring: false)
            } else {
                set(.finish, beside: sheet.frame)
            }
        } else if job == .refresh, loadingTeam {
            // Das Konto, dann (Xcode 27) sein Team, dann dort „Download Manual Profiles“: Xcode fragt dann Apple nach dem Team.
            if stage == .finish, let button = Self.downloadProfilesButton(in: settings.frame, xcodeMajor: xcodeMajor) {
                set(.finish, pointAt: button, from: .trailing, beside: settings.frame, ring: !profilesClicked)
            } else if stage == .finish {
                set(.finish, beside: settings.frame)
            } else if stage == .team, let team = Self.teamRow(in: settings.frame, xcodeMajor: xcodeMajor) {
                set(.team, pointAt: team, from: .trailing, beside: settings.frame)
            } else {
                set(.click, pointAt: Self.accountRow(in: settings.frame, xcodeMajor: xcodeMajor), from: .trailing, beside: settings.frame)
            }
        } else if stage == .finish || job == .refresh {
            set(job == .refresh ? .click : .finish, beside: settings.frame)
        } else {
            set(.click, pointAt: Self.signInButton(in: settings.frame, xcodeMajor: xcodeMajor), from: .trailing, beside: settings.frame)
        }
    }

    private func followPairing() {
        guard xcodeMajor >= 27 else {
            let windows = Self.windows(of: "com.apple.dt.Xcode").filter { $0.layer == 0 }
            let devices = windows.first { $0.frame.width >= 900 && $0.frame.height >= 500 }
            set(devices == nil ? .open : max(stage, .click), beside: (devices ?? windows.first)?.frame)
            return
        }
        let all = Self.deviceHubWindows
        let hub = all.filter { $0.layer == 0 }.max { $0.frame.width < $1.frame.width }
        // Hat der Mac das Headset gewählt, fragt Device Hub in einem eigenen Fenster nach dem Code aus dem Headset.
        if let code = all.first(where: { $0.layer == 0 && Self.isCodeWindow($0.frame) })?.frame {
            pairingSeen = Date()
            if !pairCode { withAnimation(.spring(duration: 0.35)) { pairCode = true } }
            if let boxes = Self.codeBoxes(in: code) {
                set(.finish, pointAt: boxes, from: .trailing, beside: code)
            } else {
                set(.finish, beside: code)
            }
            return
        }
        if pairCode { withAnimation(.spring(duration: 0.35)) { pairCode = false } }
        // „Pair Nearby Device“ öffnet ein kleines eigenes Fenster (300 × 433 in Xcode 27.0): dort „Vision Pro“ wählen.
        let pairing = all.first { $0.layer == 0 && $0.frame.width < 520 && $0.frame.height > 300 && $0.frame != hub?.frame }
        if pairing != nil { pairingSeen = Date() }
        if stage >= .device {
            if let pairing {
                if stage == .device {
                    set(.device, pointAt: Self.visionProTile(in: pairing.frame), from: .trailing, beside: pairing.frame)
                } else {
                    set(.finish, beside: pairing.frame)
                }
                return
            }
            if Date().timeIntervalSince(pairingSeen ?? startedAt) < (stage == .finish ? 10 : 3) {
                set(stage, beside: hub?.frame)
                return
            }
        }
        guard let hub else {
            set(.open, beside: nil)
            return
        }
        // Das + liegt am linken Rand von Device Hub; sein Menü ist ein eigenes Fenster, „Pair Nearby Device“ zuletzt.
        if let menu = all.first(where: { $0.layer >= 100 && $0.frame.minY >= hub.frame.minY }) {
            let item = CGRect(x: menu.frame.minX + 6, y: menu.frame.maxY - 30, width: menu.frame.width - 12, height: 24)
            set(.click, pointAt: item, from: .leading, beside: hub.frame)
        } else if stage == .click, let at = plusClicked, Date().timeIntervalSince(at) < 4 {
            return
        } else {
            plusClicked = nil
            set(.open, pointAt: Self.plusButton(in: hub.frame), from: .leading, beside: hub.frame)
        }
    }

    /// Xcodes Seite im App Store: „Laden“ (bzw. „Aktualisieren“), dann „Installieren“ an derselben Stelle, dann Apples
    /// Blatt für Anmeldung oder Passwort. Wo der Knopf nicht vermessen ist, zeigt die Blase ein Bild von ihm.
    private func followAppStore() {
        let all = Self.windows(of: Self.appStoreID).filter { $0.layer == 0 }
        guard let main = all.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            set(.open, beside: nil)
            return
        }
        storeFrame = main.frame
        if let over = all.first(where: { $0.frame != main.frame && main.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.minY + 2)) }) {
            let kind: Sheet = sheetFrame == over.frame ? sheet ?? .signIn
                : !clickedInStore ? .welcome : over.frame.height >= 400 ? .signIn : .password
            sheetFrame = over.frame
            if sheet != kind {
                withAnimation(.spring(duration: 0.35)) { sheet = kind }
                placedFor = nil
            }
            picture(false)
            if kind != .welcome {
                set(.finish, beside: over.frame)
            } else if let button = Self.storeContinueButton(in: over.frame) {
                set(.open, pointAt: button, from: .trailing, beside: over.frame)
            } else {
                set(.open, beside: over.frame)
            }
            return
        }
        sheetFrame = nil
        if sheet != nil {
            withAnimation(.spring(duration: 0.35)) { sheet = nil }
            placedFor = nil
        }
        let s: Stage = storeClicks == 0 ? .click : storeClicks == 1 && !updating ? .confirm : .finish
        picture(s != .finish)
        set(s, beside: main.frame)
    }

    static func hasTouchID() -> Bool {
        let c = LAContext()
        return c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && c.biometryType == .touchID
    }

    /// Xcodes erster Start: Lizenz („Agree“), dann fragt macOS nach dem Mac-Passwort für Xcodes Bestandteile, dann
    /// Xcodes erste Seiten („Continue“), bis Xcode läuft.
    private func followSetup() {
        if let prompt = Self.keychainPrompt {
            if !promptUp { touchIDAtPrompt = Self.hasTouchID() }
            promptUp = true
            if touchID != touchIDAtPrompt { touchID = touchIDAtPrompt }
            passwordSeen = true
            promptClosed = nil
            set(.confirm, beside: prompt.frame)
            return
        }
        promptUp = false
        if passwordSeen, promptClosed == nil {
            promptClosed = Date()
            assistant?.recheck()
        }
        let windows = Self.windows(of: "com.apple.dt.Xcode")
        guard let front = windows.first(where: Self.isFirstLaunch) ?? windows.first(where: { $0.layer == 0 }) ?? windows.first else {
            set(.open, beside: nil)
            return
        }
        let licenseLeft = assistant?.xcode == .license
        let partsLeft = assistant?.xcode == .components
        let checkedSince = promptClosed.map { (assistant?.lastCheck ?? .distantPast) > $0 } ?? false
        if licenseLeft, !passwordSeen || checkedSince {
            if let agree = Self.agreeButton(in: front.frame) {
                picture(false)
                set(.click, pointAt: agree, from: .trailing, beside: front.frame)
            } else {
                picture(true)
                set(.click, beside: front.frame)
            }
        } else if Self.isFirstLaunch(front) {
            let install = (licenseLeft || partsLeft) && !passwordSeen
            if installPage != install {
                installPage = install
                placedFor = nil
            }
            set(.welcome, pointAt: Self.continueButton(in: front.frame), from: .trailing, beside: front.frame)
        } else {
            set(.finish, beside: front.frame)
        }
    }

    /// Das Schlüsselbund-Fenster: die Blase gleich darunter, ihr Pfeil nach oben auf „Immer erlauben“.
    private func followKeychain() {
        guard let prompt = Self.keychainPrompt else { return }
        keychainSeen = true
        guard stage != .done else { return }
        go(.click)
        hideRing()
        if let button = Self.alwaysAllowButton(in: prompt.frame) {
            picture(false)
            let key = "up \(button) \(prompt.frame)"
            if placedFor != key {
                placedFor = key
                if !pointUp(at: Self.appKit(button), under: Self.appKit(prompt.frame)) { place(beside: Self.appKit(prompt.frame)) }
            }
        } else {
            picture(true)
            set(.click, beside: prompt.frame)
        }
    }

    private func picture(_ on: Bool) {
        guard showsPicture != on else { return }
        showsPicture = on
        placedFor = nil
        resizePanel()
    }

    /// Ein Klick in den Ring bringt die Hilfe weiter.
    private func clicked(_ at: NSPoint) {
        // Vor dem ersten Klick ins Fenster ist ein Blatt das „Neu im App Store“ des App Store, nicht Apples Anmeldung.
        if job == .appStore, let store = storeFrame, Self.appKit(store).contains(at) { clickedInStore = true }
        guard let target = ringTarget, Self.appKit(target).insetBy(dx: -4, dy: -4).contains(at) else {
            if job == .pair, stage == .click, xcodeMajor < 27, panel?.frame.contains(at) == false { go(.finish) }
            return
        }
        if job == .appStore, sheet == .welcome {
            hideRing()
        } else if job == .appStore {
            storeClicked()
        } else if job == .setup {
            hideRing()
        } else if job == .refresh, loadingTeam, stage == .finish {
            profilesClicked = true
            hideRing()
        } else if job == .refresh, loadingTeam, stage == .click, xcodeMajor >= 27 {
            go(.team)
            hideRing()
        } else if job == .pair, stage == .open {
            plusClicked = Date()
            go(.click)
        } else if job == .pair, stage == .click, xcodeMajor >= 27 {
            pairingSeen = Date()
            go(.device)
            hideRing()
        } else {
            go(.finish)
            hideRing()
        }
    }

    private func storeClicked() {
        storeClicks += 1
        hideRing()
        if updating {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let self, self.isRunning, self.job == .appStore { self.complete() }
            }
        }
    }

    private func go(_ s: Stage) {
        guard s != stage, stage != .done else { return }
        if stage == .welcome, s == .open, NSApp.isActive { focusTarget() }
        withAnimation(.spring(duration: 0.35)) { stage = s }
        resizePanel()
    }

    private func set(_ s: Stage, beside window: CGRect?) {
        guard stage != .done else { return }
        go(s)
        hideRing()
        guard let window else { return }
        let key = "beside \(window) \(s)"
        if placedFor != key {
            placedFor = key
            place(beside: Self.appKit(window))
        }
    }

    private func set(_ s: Stage, pointAt button: CGRect, from side: HorizontalEdge, beside window: CGRect, ring: Bool = true) {
        guard stage != .done else { return }
        go(s)
        if ring {
            ringTarget = button
            showRing(Self.appKit(button))
        } else {
            hideRing()
        }
        let key = "point \(button) \(side) \(s)"
        if placedFor != key {
            placedFor = key
            if !point(at: Self.appKit(button), from: side) { place(beside: Self.appKit(window)) }
        }
    }

    // MARK: Fenster

    struct OtherWindow {
        var frame: CGRect
        var layer: Int
    }

    /// Die sichtbaren Fenster eines anderen Programms, von vorn nach hinten. Lage und Größe brauchen keine Erlaubnis.
    static func windows(of bundleID: String) -> [OtherWindow] {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        return pids.isEmpty ? [] : windows(where: { pid, _ in pids.contains(pid) })
    }

    static var deviceHubWindows: [OtherWindow] {
        let path = deviceHubURL?.resolvingSymlinksInPath().path
        let pids = Set(NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.dt.Devices" || $0.localizedName == "Device Hub"
                || (path != nil && $0.bundleURL?.resolvingSymlinksInPath().path == path)
        }.map(\.processIdentifier))
        return windows(where: { pid, owner in pids.contains(pid) || owner == "Device Hub" })
    }

    /// macOS' Fenster, das nach dem Passwort fragt (Schlüsselbund, Xcodes Bestandteile).
    static var keychainPrompt: OtherWindow? {
        windows(where: { _, owner in owner == "SecurityAgent" }).first
    }

    private static func windows(where owned: (pid_t, String?) -> Bool) -> [OtherWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, owned(pid, w[kCGWindowOwnerName as String] as? String),
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b as CFDictionary),
                  frame.width > 120, frame.height > 80 else { return nil }
            return OtherWindow(frame: frame, layer: w[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    static let appStoreID = "com.apple.AppStore"

    // Die Maße stammen aus Glovebox (vermessen an Xcode 26 und 27.0, macOS 26 und 27).

    static func isFirstLaunch(_ w: OtherWindow) -> Bool { w.layer == 8 && w.frame.height > 400 }

    static func continueButton(in w: CGRect) -> CGRect {
        CGRect(x: w.maxX - 19 - 94, y: w.maxY - 19 - 38, width: 94, height: 38).insetBy(dx: -4, dy: -4)
    }

    static func agreeButton(in w: CGRect) -> CGRect? {
        let b: (width: CGFloat, height: CGFloat, inset: CGFloat)
        if abs(w.width - 480) <= 12, abs(w.height - 632) <= 12 {
            b = (91, 36, 20)
        } else if abs(w.width - 503) <= 12, abs(w.height - 432) <= 12 {
            b = (84, 26, 19)
        } else {
            return nil
        }
        return CGRect(x: w.maxX - b.inset - b.width, y: w.maxY - b.inset - b.height, width: b.width, height: b.height).insetBy(dx: -4, dy: -4)
    }

    static func isSettings(_ r: CGRect) -> Bool { (680...760).contains(r.width) && (420...500).contains(r.height) }

    static func signInButton(in w: CGRect, xcodeMajor: Int) -> CGRect {
        let size = xcodeMajor >= 27 ? CGSize(width: 76, height: 24) : CGSize(width: 151, height: 24)
        let top: CGFloat = xcodeMajor >= 27 ? 158 : 124
        return CGRect(x: w.maxX - 20 - size.width, y: w.minY + top, width: size.width, height: size.height).insetBy(dx: -7, dy: -7)
    }

    static func accountRow(in w: CGRect, xcodeMajor: Int) -> CGRect {
        let r = xcodeMajor >= 27 ? CGRect(x: 200, y: 72, width: 490, height: 52) : CGRect(x: 208, y: 52, width: 482, height: 52)
        return r.offsetBy(dx: w.minX, dy: w.minY).insetBy(dx: -4, dy: -4)
    }

    static func teamRow(in w: CGRect, xcodeMajor: Int) -> CGRect? {
        guard xcodeMajor >= 27 else { return nil }
        return CGRect(x: w.minX + 200, y: w.minY + 229, width: 490, height: 52).insetBy(dx: -4, dy: -4)
    }

    static func downloadProfilesButton(in w: CGRect, xcodeMajor: Int) -> CGRect? {
        guard xcodeMajor >= 27 else { return nil }
        return CGRect(x: w.minX + 325, y: w.minY + 362, width: 181, height: 25).insetBy(dx: -7, dy: -7)
    }

    static func plusButton(in w: CGRect) -> CGRect { CGRect(x: w.minX + 114, y: w.minY + 8, width: 38, height: 38) }

    static func visionProTile(in w: CGRect) -> CGRect { CGRect(x: w.minX + 200, y: w.minY + 138, width: 86, height: 72) }

    static func isCodeWindow(_ w: CGRect) -> Bool { w.width >= 400 && w.width <= 560 && w.height >= 260 && w.height <= 360 }

    static func codeBoxes(in w: CGRect) -> CGRect? {
        guard abs(w.width - 470) <= 16, abs(w.height - 313) <= 16 else { return nil }
        return CGRect(x: w.midX - 151, y: w.minY + 163, width: 302, height: 46)
    }

    static func alwaysAllowButton(in w: CGRect) -> CGRect? {
        guard abs(w.width - 434) <= 12, (160...300).contains(w.height) else { return nil }
        return CGRect(x: w.minX + 94, y: w.maxY - 21 - 22, width: 103, height: 22).insetBy(dx: -4, dy: -4)
    }

    static func accountField(in w: CGRect) -> CGRect { CGRect(x: w.minX + 68, y: w.minY + 272, width: 344, height: 36) }

    static func storeContinueButton(in sheet: CGRect) -> CGRect? {
        guard abs(sheet.width - 480) <= 12, abs(sheet.height - 565) <= 12 else { return nil }
        return CGRect(x: sheet.maxX - 15 - 77, y: sheet.maxY - 15 - 27, width: 77, height: 27).insetBy(dx: -4, dy: -4)
    }

    /// Koordinaten des Fensterservers (oben links am Hauptbildschirm) in die von AppKit (unten links).
    static func appKit(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static var deviceHubURL: URL? {
        guard let xcode = SetupMac.xcodeURL else { return nil }
        let hub = xcode.appendingPathComponent("Contents/Applications/DeviceHub.app")
        return FileManager.default.fileExists(atPath: hub.path) ? hub : nil
    }

    /// Xcode merkt sich die zuletzt gezeigte Seite der Einstellungen; auf „Apple Accounts“ gestellt, öffnet ⌘, genau dort.
    static func openSettingsOnAccounts() {
        UserDefaults(suiteName: "com.apple.dt.Xcode")?.set("IDEKit.IDESettingsPane.Accounts", forKey: "IDELastViewedSettingsPane")
    }

    // MARK: Blase und Ring

    private func showPanel(reveal: Bool = true) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = FirstClickHostingView(rootView: GuideBubble().environmentObject(self))
        panel = p
        resizePanel()
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - p.frame.width - 16, y: screen.maxY - 16))
        }
        revealed = reveal
        if reveal { p.orderFrontRegardless() }
    }

    private func revealWhenPlaced() {
        guard !revealed, let p = panel, placedFor != nil || Date().timeIntervalSince(startedAt) > 15 else { return }
        revealed = true
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 1 }
        if NSApp.isActive { focusTarget() }
    }

    private func resizePanel() {
        guard let p = panel, let v = p.contentView else { return }
        v.layoutSubtreeIfNeeded()
        let size = v.fittingSize
        let top = p.frame.maxY
        p.setFrame(NSRect(x: p.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true, animate: p.isVisible)
    }

    private func fitPanel() {
        guard let p = panel, let v = p.contentView else { return }
        let size = v.fittingSize
        guard abs(size.height - p.frame.height) > 1 || abs(size.width - p.frame.width) > 1 else { return }
        resizePanel()
        placedFor = nil
    }

    private func place(beside w: NSRect) {
        guard let p = panel else { return }
        arrow = nil
        arrowUpX = nil
        let screen = NSScreen.screens.first { $0.frame.intersects(w) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? w
        let size = p.frame.size
        let m = GuideBubbleShape.margin
        var x = w.maxX + 8 - m
        if x + size.width - m > screen.maxX { x = w.minX - 8 - size.width + m }
        if x + m < screen.minX { x = screen.maxX - size.width }
        let top = min(w.maxY + m, screen.maxY)
        p.setFrame(NSRect(x: x, y: max(screen.minY, top - size.height), width: size.width, height: size.height), display: true, animate: true)
    }

    private func point(at b: NSRect, from side: HorizontalEdge) -> Bool {
        guard let p = panel else { return false }
        let screen = NSScreen.screens.first { $0.frame.intersects(b) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? b
        let size = p.frame.size
        let m = GuideBubbleShape.margin
        let gap: CGFloat = 6
        func x(_ s: HorizontalEdge) -> CGFloat { s == .leading ? b.minX - gap - size.width + m : b.maxX + gap - m }
        var s = side
        if x(s) + m < screen.minX || x(s) + size.width - m > screen.maxX { s = s == .leading ? .trailing : .leading }
        guard x(s) + m >= screen.minX, x(s) + size.width - m <= screen.maxX else { return false }
        var top = b.midY + m + GuideBubbleShape.defaultArrowY
        top = min(top, screen.maxY + m)
        top = max(top, screen.minY + size.height - m)
        arrowY = top - m - b.midY
        arrow = s == .leading ? .trailing : .leading
        arrowUpX = nil
        p.setFrame(NSRect(x: x(s), y: top - size.height, width: size.width, height: size.height), display: true, animate: true)
        return true
    }

    private func pointUp(at b: NSRect, under w: NSRect) -> Bool {
        guard let p = panel else { return false }
        let screen = NSScreen.screens.first { $0.frame.intersects(w) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? w
        let size = p.frame.size
        let m = GuideBubbleShape.margin
        let top = w.minY - 9 + m
        guard top - size.height >= screen.minY else { return false }
        let x = min(max(w.minX - m, screen.minX - m), screen.maxX - size.width + m)
        arrow = nil
        arrowUpX = b.midX - (x + m)
        p.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true, animate: true)
        return true
    }

    private func showRing(_ rect: NSRect) {
        let frame = rect.insetBy(dx: -PulseRing.room, dy: -PulseRing.room)
        if ring == nil {
            let r = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            r.isOpaque = false
            r.backgroundColor = .clear
            r.hasShadow = false
            r.ignoresMouseEvents = true
            r.level = .popUpMenu
            r.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            r.isReleasedWhenClosed = false
            r.contentView = NSHostingView(rootView: PulseRing())
            ring = r
        }
        if ring?.frame != frame { ring?.setFrame(frame, display: true) }
        if ring?.isVisible == false { ring?.orderFrontRegardless() }
    }

    private func hideRing() {
        ring?.orderOut(nil)
        ringTarget = nil
    }

    #if DEBUG
    /// Nur die Blase, in einem Zustand, für Bilder (`--snapshot`).
    func showForSnapshot(_ job: Job, stage: Stage, xcodeMajor: Int = 27) -> NSWindow? {
        self.job = job
        self.stage = stage
        self.xcodeMajor = xcodeMajor
        if job == .keychain { arrowUpX = 94 + 51 }
        showPanel()
        return panel
    }

    func hideSnapshot() { stop(); panel?.orderOut(nil); panel = nil }
    #endif
}

/// Nimmt den ersten Klick an, obwohl das Fenster der Blase nie das aktive wird: Tasten gehen weiter an Xcode.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum GuideStyle {
    /// Ein warmes Orange, auf hellen wie dunklen Fenstern gut zu sehen.
    static let accent = Color(red: 1, green: 0.624, blue: 0.18)
}

extension View {
    /// Glas wie in visionOS (ab macOS 26), sonst ein dunkles Material.
    @ViewBuilder func guideGlass<S: Shape>(_ shape: S, tint: Double = 0.3) -> some View {
        if #available(macOS 26.0, *) {
            background(shape.fill(Color.black.opacity(tint))).glassEffect(.regular, in: shape)
        } else {
            background { ZStack { shape.fill(.ultraThinMaterial); shape.fill(Color.black.opacity(tint)) } }
                .overlay(shape.stroke(Color.white.opacity(0.16), lineWidth: 1))
        }
    }
}

// MARK: Ansichten

private struct GuideBubble: View {
    @EnvironmentObject var guide: SetupGuide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop = false
    @State private var nudge = false

    var body: some View {
        let shape = GuideBubbleShape(arrow: guide.arrow, arrowY: guide.arrowY, upX: guide.arrowUpX, topRoom: topRoom)
        VStack(alignment: .leading, spacing: 12) {
            header
            if guide.stage == .done {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white, GuideStyle.accent)
                    Text(doneText).font(.system(size: 22, weight: .bold))
                }
                .padding(.vertical, 6)
                .transition(.scale.combined(with: .opacity))
            } else {
                instruction
                    .id("\(guide.job)-\(guide.stage)")
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .frame(width: width, alignment: .leading)
        .padding(.top, topRoom)
        .padding(.horizontal, GuideBubbleShape.arrowLength)
        .guideGlass(shape, tint: 0.3)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .scaleEffect(pop ? 1.08 : 1, anchor: anchor)
        .offset(x: nudgeOffset, y: nudge && guide.arrowUpX != nil ? -5 : 0)
        .padding(GuideBubbleShape.margin)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, L10n.locale)
        .task(id: wantsAttention) { await bounce() }
        .onChange(of: pointing) { _, on in
            nudge = false
            guard on, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { nudge = true }
        }
    }

    private var pointing: Bool { guide.arrow != nil || guide.arrowUpX != nil }
    private var topRoom: CGFloat { guide.job == .keychain ? 18 : 0 }
    private var width: CGFloat { guide.job == .pair && guide.stage == .finish ? 310 : guide.job == .keychain ? 290 : 260 }

    private var nudgeOffset: CGFloat {
        guard nudge, let a = guide.arrow else { return 0 }
        return a == .leading ? -7 : 7
    }

    private var anchor: UnitPoint {
        if guide.arrowUpX != nil { return .top }
        switch guide.arrow {
        case .leading?: return .leading
        case .trailing?: return .trailing
        case nil: return .center
        }
    }

    private var wantsAttention: Bool { !keys.isEmpty && guide.stage != .done }

    private func bounce() async {
        pop = false
        guard wantsAttention, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.spring(duration: 0.22, bounce: 0.5)) { pop = true }
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.spring(duration: 0.5, bounce: 0.6)) { pop = false }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(0..<(count > 1 ? count : 0), id: \.self) { i in
                Capsule()
                    .fill(i < index ? GuideStyle.accent : i == index ? Color.white : Color.white.opacity(0.25))
                    .frame(width: i == index ? 18 : 6, height: 6)
            }
            Spacer()
            Button { guide.stop() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help(L("Close the help", "Hilfe schließen"))
        }
        .animation(.spring(duration: 0.35), value: index)
    }

    @ViewBuilder private var instruction: some View {
        VStack(alignment: .leading, spacing: 12) {
            headlineText
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .fixedSize(horizontal: false, vertical: true)
            if !keys.isEmpty { PressKeys(keys: keys) }
            if guide.showsPicture, guide.job == .appStore {
                AppStoreButtonMock(title: storeButtonTitle)
            }
            if guide.job == .refresh, guide.loadingTeam, guide.stage == .finish, guide.arrow == nil {
                XcodeButtonMock(title: "Download Manual Profiles")
            }
            if guide.job == .signIn, guide.stage == .finish, guide.showsPicture {
                XcodeButtonMock(title: x27 ? "Sign In…" : "Add Apple Account…")
            }
            if guide.showsPicture, guide.job == .keychain {
                KeychainPromptArt()
                    .scaleEffect(0.8, anchor: .topLeading)
                    .frame(width: 248, height: 96, alignment: .topLeading)
            }
            if guide.job == .pair, guide.stage == .finish, guide.xcodeMajor >= 27, !guide.pairCode {
                GuideStep(number: 1, text: L("On your Vision Pro, open Settings › General › Remote Devices",
                                             "Auf der Vision Pro: Einstellungen › Allgemein › Entfernte Geräte öffnen")) {
                    RemoteDevicesMock(macName: SetupMac.computerName)
                        .scaleEffect(0.75, anchor: .topLeading)
                        .frame(width: 210, height: 135, alignment: .topLeading)
                }
                GuideStep(number: 2, text: L("On this Mac, pick it and click Next", "An diesem Mac auswählen und „Next“ klicken")) { EmptyView() }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let menu {
                HStack(spacing: 6) {
                    Image(systemName: "menubar.rectangle")
                    Text(L("Or click \(menu) in the menu bar.", "Oder in der Menüleiste auf \(menu) klicken."))
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var x27: Bool { guide.xcodeMajor >= 27 }

    private var stages: [SetupGuide.Stage] {
        switch guide.job {
        case .signIn: return [.open, .click, .finish]
        case .refresh: return guide.loadingTeam ? (x27 ? [.open, .click, .team, .finish] : [.open, .click, .finish]) : [.open, .click]
        case .pair: return x27 ? [.open, .click, .device, .finish] : [.open, .click, .finish]
        case .appStore: return guide.updating ? [.click, .finish] : [.click, .confirm, .finish]
        case .setup: return [.click, .confirm, .welcome]
        case .keychain: return [.click]
        }
    }

    private var count: Int { stages.count }

    private var index: Int {
        if guide.stage == .done { return count }
        if guide.job == .setup {
            switch guide.stage {
            case .click, .open: return 0
            case .welcome where !guide.installPage: return 2
            default: return 1
            }
        }
        return stages.firstIndex(of: guide.stage) ?? 0
    }

    private var keys: [String] {
        switch (guide.job, guide.stage) {
        case (.signIn, .open), (.refresh, .open): return ["⌘", ","]
        case (.pair, .open) where !x27: return ["⇧", "⌘", "2"]
        default: return []
        }
    }

    /// Wie der App Store seinen Knopf in der eingestellten Sprache des Macs nennt, wissen wir nicht sicher: beide Namen.
    private var storeButtonTitle: String { guide.updating ? L("Update", "Aktualisieren") : L("Get", "Laden") }

    private var headline: String {
        switch (guide.job, guide.stage) {
        case (.appStore, .open): return guide.sheet == .welcome ? L("Click Continue", "Auf „Fortfahren“ klicken") : L("Opening the App Store", "App Store wird geöffnet")
        case (.appStore, .click):
            if guide.updating { return L("Click Update", "Auf „Aktualisieren“ klicken") }
            return L("Click Get, then Install", "Auf „Laden“, dann „Installieren“ klicken")
        case (.appStore, .confirm): return L("Click Install", "Auf „Installieren“ klicken")
        case (.appStore, .finish):
            switch guide.sheet {
            case .signIn?: return L("Sign in with your Apple Account", "Mit deinem Apple-Account anmelden")
            case .password?: return L("Type your Apple Account password", "Passwort deines Apple-Accounts eingeben")
            case .welcome?, nil: return guide.updating ? L("Xcode is updating", "Xcode wird aktualisiert") : L("Xcode is downloading", "Xcode wird geladen")
            }
        case (.setup, .open): return L("Opening Xcode", "Xcode wird geöffnet")
        case (.setup, .click): return L("Click Agree", "Auf „Agree“ klicken")
        case (.setup, .confirm): return guide.touchID ? L("Use Touch ID", "Touch ID benutzen") : L("Type your Mac's password", "Passwort deines Macs eingeben")
        case (.setup, .finish): return L("Xcode is installing", "Xcode installiert")
        case (.setup, .welcome): return guide.installPage ? L("Click Install", "Auf „Install“ klicken") : L("Click Continue", "Auf „Continue“ klicken")
        case (_, .welcome): return L("Click Continue in Xcode", "In Xcode auf „Continue“ klicken")
        case (.signIn, .open), (.refresh, .open): return L("Press these keys", "Diese Tasten drücken")
        case (.signIn, .click): return x27 ? L("Click Sign In…", "Auf „Sign In…“ klicken") : L("Click Add Apple Account…", "Auf „Add Apple Account…“ klicken")
        case (.signIn, .finish) where guide.showsPicture:
            return x27 ? L("Click Apple Accounts, then Sign In…", "Links auf „Apple Accounts“, dann auf „Sign In…“ klicken")
                : L("Click Accounts, then Add Apple Account…", "Auf „Accounts“, dann „Add Apple Account…“ klicken")
        case (.refresh, .finish) where guide.showsPicture && guide.loadingTeam:
            return L("Click your account, your team, then Download Manual Profiles", "Auf dein Konto, dein Team, dann „Download Manual Profiles“ klicken")
        case (.signIn, .finish): return L("Sign in with your Apple Account", "Mit deinem Apple-Account anmelden")
        case (.refresh, .click) where guide.loadingTeam: return L("Click your Apple Account", "Auf deinen Apple-Account klicken")
        case (.refresh, .team): return L("Click your team", "Auf dein Team klicken")
        case (.refresh, .finish) where guide.loadingTeam: return L("Click Download Manual Profiles", "Auf „Download Manual Profiles“ klicken")
        case (.refresh, _): return L("Click your account", "Auf dein Konto klicken")
        case (.pair, .open): return x27 ? L("Click +", "Auf + klicken") : L("Press these keys", "Diese Tasten drücken")
        case (.pair, .click): return x27 ? L("Click Pair Nearby Device", "Auf „Pair Nearby Device“ klicken") : L("Click your Vision Pro, then Pair", "Deine Vision Pro wählen, dann „Pair“")
        case (.pair, .device): return L("Click Vision Pro", "Auf „Vision Pro“ klicken")
        case (.pair, .finish): return x27 && !guide.pairCode ? L("Find your Vision Pro", "Deine Vision Pro finden") : L("Type the code your Vision Pro shows", "Den Code aus der Vision Pro eingeben")
        default: return ""
        }
    }

    private var headlineText: Text {
        if guide.job == .keychain {
            let allow = L("Always Allow", "Immer erlauben")
            return Text(L("Type your Mac password, then click ", "Mac-Passwort eingeben, dann auf ")) + Text(allow).foregroundColor(GuideStyle.accent)
                + Text(L("", " klicken"))
        }
        return Text(headline)
    }

    private var detail: String? {
        switch (guide.job, guide.stage) {
        case (.signIn, .open), (.refresh, .open): return L("Opens Xcode Settings.", "Öffnet Xcodes Einstellungen.")
        case (.signIn, .finish) where guide.showsPicture:
            return L("In Xcode's Settings. Then sign in with the Apple Account from your iPhone.", "In Xcodes Einstellungen. Dann mit dem Apple-Account von deinem iPhone anmelden.")
        case (.signIn, .finish): return L("The same Apple Account as on your iPhone. A free one works.", "Derselbe Apple-Account wie auf deinem iPhone. Ein kostenloser reicht.")
        case (.refresh, .click) where guide.loadingTeam: return L("Xcode opens your account's page.", "Xcode öffnet die Seite deines Kontos.")
        case (.refresh, .team): return L("Under Teams. Xcode opens its page.", "Unter „Teams“. Xcode öffnet seine Seite.")
        case (.refresh, .finish) where guide.loadingTeam:
            return x27 ? L("Xcode then loads your team, and AVP Play carries on by itself.", "Xcode lädt dann dein Team, und AVP Play macht von selbst weiter.")
                : L("It's on your account's page. Xcode then loads your team, and AVP Play carries on by itself.",
                    "Er ist auf der Seite deines Kontos. Xcode lädt dann dein Team, und AVP Play macht von selbst weiter.")
        case (.refresh, _): return L("Xcode checks your membership again.", "Xcode prüft deine Mitgliedschaft neu.")
        case (.pair, .open): return x27 ? nil : L("First, on your Vision Pro, open Settings › General › Remote Devices.", "Zuerst auf der Vision Pro: Einstellungen › Allgemein › Entfernte Geräte öffnen.")
        case (.pair, .finish) where guide.pairCode || !x27: return L("It's on your Vision Pro. Type it here, on this Mac.", "Er steht in der Vision Pro. Hier am Mac eingeben.")
        case (.appStore, .click): return L("Under Xcode's name, near the top.", "Unter Xcodes Namen, oben.")
        case (.appStore, .confirm): return L("Same place as Get.", "An derselben Stelle wie „Laden“.")
        case (.appStore, .finish):
            switch guide.sheet {
            case .signIn?: return L("Same as on your iPhone.", "Wie auf deinem iPhone.")
            case .password?: return L("It confirms the download. Touch ID works too.", "Das bestätigt den Download. Touch ID geht auch.")
            case .welcome?, nil: return L("This takes a while. AVP Play notices when it is done.", "Das dauert eine Weile. AVP Play merkt, wenn es fertig ist.")
            }
        case (.setup, .click): return guide.showsPicture ? L("Xcode's license, at the bottom right.", "Xcodes Lizenz, unten rechts.") : L("Xcode's license.", "Xcodes Lizenz.")
        case (.setup, .confirm):
            return guide.touchID ? L("Or click Use Password and type your Mac's password. Xcode needs it to finish installing.",
                                     "Oder „Passwort verwenden“ und das Mac-Passwort eingeben. Xcode braucht es, um fertig zu installieren.")
                : L("The one you unlock this Mac with. Xcode needs it to finish installing.", "Das, mit dem du diesen Mac entsperrst. Xcode braucht es, um fertig zu installieren.")
        case (.setup, .finish): return L("If it shows Install, click it.", "Zeigt es „Install“, darauf klicken.")
        case (.keychain, _): return L("Don't press Enter. AVP Play never sees your password.", "Nicht Enter drücken. AVP Play sieht dein Passwort nie.")
        default: return nil
        }
    }

    private var menu: String? {
        switch (guide.job, guide.stage) {
        case (.signIn, .open), (.refresh, .open): return "Xcode › Settings…"
        case (.pair, .open) where !x27: return "Window › Devices and Simulators"
        default: return nil
        }
    }

    private var doneText: String {
        switch guide.job {
        case .signIn: return L("Signed in", "Angemeldet")
        case .refresh: return guide.loadingTeam ? L("Team found", "Team gefunden") : L("Checked", "Geprüft")
        case .pair: return L("Paired", "Gekoppelt")
        case .appStore: return guide.updating ? L("Updating", "Wird aktualisiert") : L("Downloading", "Wird geladen")
        case .setup: return L("Xcode is ready", "Xcode ist bereit")
        case .keychain: return L("Allowed", "Erlaubt")
        }
    }
}

private struct XcodeButtonMock: View {
    var title: String
    @State private var on = false

    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(Color(white: 0.1))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white).shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).inset(by: -4).stroke(GuideStyle.accent, lineWidth: 2.5).opacity(on ? 1 : 0.45))
            .padding(6)
            .environment(\.colorScheme, .light)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true } }
    }
}

private struct AppStoreButtonMock: View {
    var title: String
    @State private var on = false

    var body: some View {
        HStack(spacing: 12) {
            XcodeIcon(size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("Xcode").font(.system(size: 15, weight: .bold))
                Text(L("Developer Tools", "Entwickler-Tools")).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(red: 0, green: 0.48, blue: 1)))
                    .overlay(Capsule().inset(by: -4).stroke(GuideStyle.accent, lineWidth: 2.5).opacity(on ? 1 : 0.45))
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(white: 0.1))
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
        .environment(\.colorScheme, .light)
        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true } }
    }
}

/// Große Tasten, die sich selbst drücken, wie Finger auf der Tastatur.
private struct PressKeys: View {
    var keys: [String]
    @State private var pressed = 0
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                let down = i < pressed
                Text(key)
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.15))
                    .frame(width: 64, height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(down ? Color(red: 1, green: 0.93, blue: 0.84) : Color.white)
                            .shadow(color: .black.opacity(0.45), radius: 0, y: down ? 1 : 4)
                    )
                    .shadow(color: GuideStyle.accent.opacity(glow ? 0.9 : 0), radius: 10)
                    .offset(y: down ? 3 : 0)
            }
        }
        .padding(.bottom, 4)
        .accessibilityLabel(keys.joined(separator: " "))
        .task(id: keys) {
            if reduceMotion {
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.6)) { glow.toggle() }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                for i in 1...keys.count {
                    withAnimation(.easeOut(duration: 0.12)) { pressed = i }
                    try? await Task.sleep(nanoseconds: 160_000_000)
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation(.spring(duration: 0.3, bounce: 0.4)) { pressed = 0 }
            }
        }
    }
}

private struct GuideStep<Art: View>: View {
    var number: Int
    var text: String
    @ViewBuilder var art: Art

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(Color(white: 0.08))
                .frame(width: 24, height: 24)
                .background(Circle().fill(GuideStyle.accent))
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                art
            }
        }
    }
}

/// Ein abgerundetes Rechteck mit einem Pfeil an einer Seite (oder oben).
struct GuideBubbleShape: Shape {
    static let margin: CGFloat = 18
    static let arrowLength: CGFloat = 12
    static let defaultArrowY: CGFloat = 34
    var arrow: HorizontalEdge?
    var arrowY: CGFloat
    var upX: CGFloat?
    var topRoom: CGFloat = 0
    var radius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var body = rect.insetBy(dx: Self.arrowLength, dy: 0)
        body.origin.y += topRoom
        body.size.height -= topRoom
        var p = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
        let half: CGFloat = 11
        if let upX {
            let half: CGFloat = 15
            let x = min(max(rect.minX + upX, body.minX + radius + half), body.maxX - radius - half)
            let mid = (body.minY + rect.minY) / 2
            p.move(to: CGPoint(x: x - half, y: body.minY + 1))
            p.addQuadCurve(to: CGPoint(x: x, y: rect.minY), control: CGPoint(x: x - 3, y: mid))
            p.addQuadCurve(to: CGPoint(x: x + half, y: body.minY + 1), control: CGPoint(x: x + 3, y: mid))
            p.closeSubpath()
            return p
        }
        guard let arrow else { return p }
        let y = min(max(rect.minY + arrowY, body.minY + radius + half), body.maxY - radius - half)
        let base = arrow == .leading ? body.minX + 1 : body.maxX - 1
        let tip = arrow == .leading ? rect.minX : rect.maxX
        p.move(to: CGPoint(x: base, y: y - half))
        p.addQuadCurve(to: CGPoint(x: tip, y: y), control: CGPoint(x: (base + tip) / 2, y: y - 3))
        p.addQuadCurve(to: CGPoint(x: base, y: y + half), control: CGPoint(x: (base + tip) / 2, y: y + 3))
        p.closeSubpath()
        return p
    }
}

/// Der Ring um den Knopf: ein heller Rand, der atmet, und ein Schein, der immer wieder davon ausgeht.
private struct PulseRing: View {
    static let room: CGFloat = 16
    @State private var on = false
    @State private var ripple = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GuideStyle.accent, lineWidth: 3)
                .scaleEffect(ripple ? 1.25 : 1)
                .opacity(ripple ? 0 : 0.8)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(GuideStyle.accent, lineWidth: 4)
                .shadow(color: GuideStyle.accent.opacity(0.9), radius: on ? 10 : 3)
                .opacity(on ? 1 : 0.7)
        }
        .padding(Self.room - 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { ripple = true }
        }
    }
}
