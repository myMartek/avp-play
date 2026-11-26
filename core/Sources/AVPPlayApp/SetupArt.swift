import AppKit
import AVPPlayCore
import SwiftUI

// Kleine Zeichnungen von dem, was der Nutzer dort sieht, wo AVP Play nicht hinkommt: die Einstellungen der Vision Pro,
// macOS' Schlüsselbund-Fenster. Nach Glovebox (github.com/glovebox-vr/glovebox, installer/App/Glovebox/Illustrations.swift,
// MIT-Lizenz, © 2026 the Glovebox contributors), zweisprachig.

/// Schritte, die woanders passieren, nebeneinander: je eine Zeichnung und eine Zeile Text.
struct Storyboard: View {
    struct Card: Identifiable {
        var id: Int
        var art: AnyView
        var text: String
        var detail: String? = nil
        /// Die eigene Größe der Zeichnung.
        var size = CGSize(width: 200, height: 120)
    }

    var cards: [Card]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(cards) { c in
                VStack(spacing: 10) {
                    Shrunk(natural: c.size) { c.art }
                        .frame(height: 128)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
                        .overlay(alignment: .topLeading) {
                            Text("\(c.id)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.accentColor))
                                .padding(8)
                        }
                    VStack(spacing: 3) {
                        Text(c.text).font(.callout.weight(.semibold))
                        if let d = c.detail { Text(d).font(.caption).opacity(0.7) }
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Eine Zeichnung in ihrer eigenen Größe (`natural`), verkleinert auf den Platz, den sie bekommt.
private struct Shrunk<Content: View>: View {
    var natural: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { g in
            let scale = min(1, (g.size.width - 24) / natural.width, (g.size.height - 20) / natural.height)
            content
                .frame(width: natural.width, height: natural.height)
                .scaleEffect(max(0.1, scale))
                .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// Koppeln, als Bildergeschichte neben dem Knopf, der die Hilfe startet.
struct PairingStoryboard: View {
    var deviceHub: Bool

    var body: some View {
        if deviceHub {
            Storyboard(cards: [
                .init(id: 1, art: AnyView(VisionSettingsMock(path: [VisionText.general, VisionText.remoteDevices])), 
                      text: L("On your Vision Pro, open Settings › General › Remote Devices.", "Auf der Vision Pro: Einstellungen › Allgemein › Entfernte Geräte öffnen."),
                      size: VisionSettingsMock.size),
                .init(id: 2, art: AnyView(Image(systemName: "plus.circle.fill").font(.system(size: 44)).foregroundStyle(.secondary)),
                      text: L("In Device Hub on this Mac: +, Pair Nearby Device, Vision Pro.", "Am Mac in Device Hub: +, „Pair Nearby Device“, „Vision Pro“.")),
                .init(id: 3, art: AnyView(CodeDigits(filled: ["4", "8", "1"], count: 6)),
                      text: L("Type the code your Vision Pro shows.", "Den Code aus der Vision Pro eingeben.")),
            ])
        } else {
            Storyboard(cards: [
                .init(id: 1, art: AnyView(VisionSettingsMock(path: [VisionText.general, VisionText.remoteDevices])), 
                      text: L("On your Vision Pro, open Settings › General › Remote Devices.", "Auf der Vision Pro: Einstellungen › Allgemein › Entfernte Geräte öffnen."),
                      size: VisionSettingsMock.size),
                .init(id: 2, art: AnyView(Text("⇧⌘2").font(.system(size: 30, weight: .medium, design: .rounded))),
                      text: L("In Xcode, press ⇧⌘2, click your Vision Pro, then Pair.", "In Xcode ⇧⌘2 drücken, die Vision Pro wählen, dann „Pair“.")),
                .init(id: 3, art: AnyView(CodeDigits(filled: ["4", "8", "1"], count: 6)),
                      text: L("Type the code your Vision Pro shows.", "Den Code aus der Vision Pro eingeben.")),
            ])
        }
    }
}

/// Entwicklermodus: der Schalter, der Neustart, dann „Einschalten“.
struct DeveloperModeGuide: View {
    var body: some View {
        Storyboard(cards: [
            .init(id: 1, art: AnyView(VisionSettingsMock(path: [VisionText.privacy, VisionText.developerMode], toggle: true)),
                  text: L("Turn on Developer Mode", "Entwicklermodus einschalten"),
                  detail: L("Settings › Privacy & Security", "Einstellungen › Datenschutz & Sicherheit"), size: VisionSettingsMock.size),
            .init(id: 2, art: AnyView(Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 44)).foregroundStyle(.secondary)),
                  text: L("Tap Restart", "„Neustart“ tippen")),
            .init(id: 3, art: AnyView(TurnOnAlertMock()),
                  text: L("Tap Turn On", "„Einschalten“ tippen"), detail: L("When it's back on", "Wenn sie wieder an ist"),
                  size: CGSize(width: 190, height: 110)),
        ])
    }
}

/// Die Wörter, wie die Einstellungen der Vision Pro sie in der eingestellten Sprache zeigen.
enum VisionText {
    static var settings: String { L("Settings", "Einstellungen") }
    static var general: String { L("General", "Allgemein") }
    static var apps: String { L("Apps", "Apps") }
    static var privacy: String { L("Privacy & Security", "Datenschutz & Sicherheit") }
    static var developerMode: String { L("Developer Mode", "Entwicklermodus") }
    static var remoteDevices: String { L("Remote Devices", "Entfernte Geräte") }
}

/// Die Fenster der Vision Pro sind Glas über dem Raum: Die Zeichnungen nehmen immer ihr dunkles Glas.
struct VisionGlass: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .foregroundStyle(.white)
            .background(shape.fill(Color(white: 0.28).opacity(0.92)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.16)))
            .environment(\.colorScheme, .dark)
    }
}

/// Die Einstellungen der Vision Pro, an der Stelle geöffnet, an die es geht: erst leuchtet die Zeile links, dann die
/// rechts, und ein Schalter geht an, wenn es einen gibt.
struct VisionSettingsMock: View {
    static let size = CGSize(width: 388, height: 200)
    var path: [String]
    var toggle = false
    @State private var step = 0

    private struct Item {
        var title: String
        var symbol: String
        var color: Color
    }

    private var sidebar: [Item] {
        [Item(title: VisionText.general, symbol: "gearshape.fill", color: .gray),
         Item(title: VisionText.apps, symbol: "square.grid.2x2.fill", color: .indigo),
         Item(title: VisionText.privacy, symbol: "hand.raised.fill", color: .blue),
         Item(title: "Bluetooth", symbol: "wave.3.right", color: .blue)]
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(VisionText.settings).font(.system(size: 15, weight: .bold)).padding(.bottom, 6)
                ForEach(sidebar.indices, id: \.self) { i in sidebarRow(sidebar[i]) }
                Spacer(minLength: 0)
            }
            .frame(width: 150)
            .padding(14)
            VStack(alignment: .leading, spacing: 8) {
                Text(path.first ?? "").font(.system(size: 15, weight: .bold)).opacity(step >= 1 ? 1 : 0.3)
                ForEach(rows, id: \.self) { detailRow($0).opacity(step >= 1 ? 1 : 0.3) }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 210)
        }
        .frame(height: 200)
        .modifier(VisionGlass(radius: 26))
        .task { await loop() }
    }

    private func sidebarRow(_ item: Item) -> some View {
        let lit = item.title == path.first && step >= 1
        return HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(item.color))
            Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(lit ? 0.22 : 0)))
    }

    private func detailRow(_ name: String) -> some View {
        let target = name == path.last
        let lit = target && step >= 2
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack {
            Text(name).font(.system(size: 11, weight: .medium))
            Spacer()
            if target && toggle {
                ZStack(alignment: step >= 3 ? .trailing : .leading) {
                    Capsule().fill(step >= 3 ? Color.green : Color.white.opacity(0.2))
                    Circle().fill(.white).padding(2)
                }
                .frame(width: 30, height: 18)
            } else {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).opacity(0.4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(shape.fill(Color.white.opacity(lit ? 0.2 : 0.07)))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(lit ? 0.9 : 0), lineWidth: 1.5))
    }

    private var rows: [String] {
        guard let last = path.last else { return [] }
        if last == VisionText.developerMode {
            return [L("Location Services", "Ortungsdienste"), last, L("Analytics & Improvements", "Analyse & Verbesserungen")]
        }
        if last == VisionText.remoteDevices { return [L("About", "Info"), L("Software Update", "Softwareupdate"), last] }
        return [L("About", "Info"), last, L("Storage", "Speicher")]
    }

    private func loop() async {
        while !Task.isCancelled {
            for s in 0...3 {
                withAnimation(.easeInOut(duration: 0.35)) { step = s }
                try? await Task.sleep(nanoseconds: s == 3 ? 2_200_000_000 : 900_000_000)
            }
        }
    }
}

/// „Entfernte Geräte“ auf dem Headset: Es ist jetzt auffindbar; gewählt wird am Mac.
struct RemoteDevicesMock: View {
    var macName: String
    @State private var lit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(VisionText.remoteDevices).font(.system(size: 15, weight: .bold))
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12))
                Text(L("This Apple Vision Pro is now discoverable", "Diese Apple Vision Pro ist jetzt auffindbar"))
                    .font(.system(size: 11, weight: .medium)).lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(lit ? 0.22 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(lit ? 0.9 : 0), lineWidth: 1.5))
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 280, height: 180)
        .modifier(VisionGlass(radius: 26))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { lit = true } }
    }
}

/// Die Kästchen für den Code beim Koppeln.
struct CodeDigits: View {
    var filled: [String]
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Text(i < filled.count ? filled[i] : "")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .frame(width: 30, height: 38)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(i == filled.count ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: i == filled.count ? 2 : 1))
            }
        }
    }
}

/// Die Frage nach dem Neustart des Entwicklermodus.
private struct TurnOnAlertMock: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 6) {
            Text(L("Turn on Developer Mode?", "Entwicklermodus einschalten?")).font(.system(size: 12, weight: .bold))
            Text(L("Turning on Developer Mode lowers the security of your device.", "Der Entwicklermodus verringert die Sicherheit deines Geräts."))
                .font(.system(size: 8)).opacity(0.7).multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Text(L("Cancel", "Abbrechen")).font(.system(size: 10, weight: .medium))
                    .frame(width: 70, height: 22).background(Capsule().fill(Color.white.opacity(0.15)))
                Text(L("Turn On", "Einschalten")).font(.system(size: 10, weight: .semibold))
                    .frame(width: 70, height: 22).background(Capsule().fill(Color.white.opacity(pulse ? 0.45 : 0.28)))
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 190)
        .modifier(VisionGlass(radius: 22))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }
}

/// macOS' eigenes Fenster vor dem Signieren: das Mac-Passwort, „Immer erlauben“ umkreist. Im hellen oder dunklen
/// Aussehen des Macs, dem das echte folgt.
struct KeychainPromptArt: View {
    @State private var pulse = false

    var body: some View {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.99, green: 0.82, blue: 0.38), Color(red: 0.85, green: 0.57, blue: 0.12)],
                                                    startPoint: .top, endPoint: .bottom))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    bar(200, 6, 0.55)
                    bar(118, 6, 0.55)
                    bar(160, 4, 0.28).padding(.top, 2)
                }
                .padding(.top, 3)
            }
            HStack(spacing: 6) {
                Text(L("Password:", "Passwort:")).font(.system(size: 9))
                Text("••••••••")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color(nsColor: .controlAccentColor).opacity(0.75), lineWidth: 1.5))
            }
            .padding(.leading, 46)
            HStack(spacing: 6) {
                Text("?")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(.quaternary))
                button(L("Always Allow", "Immer erlauben"))
                    .overlay(Capsule().strokeBorder(GuideStyle.accent, lineWidth: 2).padding(-4).opacity(pulse ? 1 : 0.55))
                Spacer(minLength: 12)
                button(L("Deny", "Ablehnen"))
                button(L("Allow", "Erlauben"))
            }
        }
        .padding(14)
        .frame(width: 310)
        .foregroundStyle(.primary)
        .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .environment(\.colorScheme, dark ? .dark : .light)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
        .accessibilityElement()
        .accessibilityLabel(L("The macOS window: your Mac password, then Always Allow", "Das Fenster von macOS: Mac-Passwort, dann „Immer erlauben“"))
    }

    private func bar(_ width: CGFloat, _ height: CGFloat, _ opacity: Double) -> some View {
        Capsule().fill(Color.primary.opacity(opacity)).frame(width: width, height: height)
    }

    private func button(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 9)
            .frame(minWidth: 46, minHeight: 17)
            .background(Capsule().fill(.quaternary))
    }
}

/// Xcodes Symbol: das installierte, sonst ein Platzhalter.
struct XcodeIcon: View {
    var size: CGFloat

    var body: some View {
        Group {
            if let icon = SetupMac.xcodeIcon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(Color.blue.gradient)
                    .overlay { Image(systemName: "hammer.fill").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white) }
            }
        }
        .frame(width: size, height: size)
    }
}
