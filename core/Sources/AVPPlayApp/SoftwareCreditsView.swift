import AVPPlayCore
import SwiftUI

/// Einstellungen › Verwendete Software: was in den gebauten Spielen steckt, mit Herkunft und Lizenz, und die Mods
/// von Beat Saber aus der Toolchain. Zugeklappt, weil es zum Bedienen nicht gebraucht wird.
struct SoftwareCreditsView: View {
    @EnvironmentObject var model: AppModel

    private struct Item: Identifiable {
        let name, authors, license, url, note: String
        var id: String { name }
    }

    private var toolchainParts: [Item] {
        [Item(name: "Klepton", authors: "Max Thomas and contributors, with this project's changes", license: "MIT",
              url: "https://github.com/myMartek/Klepton",
              note: L("The toolchain that turns a game's Android build into a visionOS app.",
                      "Die Toolchain, die aus der Android-Fassung eines Spiels eine visionOS-App macht.")),
         Item(name: "ANGLE", authors: "The ANGLE authors", license: "BSD-3-Clause",
              url: "https://chromium.googlesource.com/angle/angle", note: L("OpenGL ES on Metal.", "OpenGL ES auf Metal.")),
         Item(name: "MoltenVK", authors: "The Khronos Group", license: "Apache-2.0",
              url: "https://github.com/KhronosGroup/MoltenVK", note: L("Vulkan on Metal.", "Vulkan auf Metal.")),
         Item(name: "Fossilize", authors: "Valve", license: "MIT", url: "https://github.com/ValveSoftware/Fossilize",
              note: L("Prepared shaders for Vulkan games.", "Vorbereitete Shader für Vulkan-Spiele.")),
         Item(name: "Glovebox", authors: "The Glovebox contributors", license: "MIT", url: "https://github.com/glovebox-vr/glovebox",
              note: L("Shader preparation, Steam sign-in and Steam Cloud for Half-Life: Alyx.",
                      "Shader-Vorbereitung, Steam-Anmeldung und Steam Cloud für Half-Life: Alyx.")),
         Item(name: "SMOL-V", authors: "Aras Pranckevičius", license: "Public domain or MIT", url: "https://github.com/aras-p/smol-v",
              note: L("Reads Unity's stored Vulkan shaders.", "Liest Unitys gespeicherte Vulkan-Shader.")),
         Item(name: "xrizer", authors: "Supreeeme and contributors", license: "GPL-3.0", url: "https://github.com/Supreeeme/xrizer",
              note: L("Downloaded for Half-Life: Alyx only.", "Nur für Half-Life: Alyx geladen.")),
         Item(name: "Surreal Touch SDK", authors: "Surreal Interactive", license: L("Surreal Interactive's terms", "Bedingungen von Surreal Interactive"),
              url: "https://github.com/surreal-interactive/SwiftSDKBinary",
              note: L("Downloaded from Surreal Interactive when a game is built with Surreal Touch support.",
                      "Wird bei Surreal Interactive geladen, wenn ein Spiel mit Surreal-Touch-Unterstützung gebaut wird.")),
         Item(name: "Skyrim VR on Apple Vision Pro", authors: "gseddon", license: "MIT",
              url: "https://github.com/gseddon/Skyrim-VR-Vision-Pro",
              note: L("Fetched and built on this Mac for Skyrim VR only; its own notices list what it builds on.",
                      "Wird nur für Skyrim VR geholt und auf diesem Mac gebaut; seine eigenen Hinweise nennen, worauf es aufbaut.")),
         Item(name: "vivecraft-visionos", authors: "rebelancap", license: "MIT",
              url: "https://github.com/rebelancap/vivecraft-visionos",
              note: L("The port of Minecraft: Java Edition to the Vision Pro. Fetched for Minecraft only; it builds the game's parts on this Mac.",
                      "Die Portierung von Minecraft: Java Edition auf die Vision Pro. Wird nur für Minecraft geholt und baut die Spielteile auf diesem Mac.")),
         Item(name: "Vivecraft", authors: "The Vivecraft team", license: "LGPL-3.0",
              url: "https://github.com/Vivecraft/VivecraftMod",
              note: L("The VR mod in Minecraft. The game's app lists every mod and library it holds (Licenses).",
                      "Die VR-Mod in Minecraft. Die App des Spiels nennt jede Mod und Bibliothek, die sie enthält (Licenses).")),
         Item(name: "Oracle GraalVM", authors: "Oracle", license: L("GraalVM Free Terms and Conditions", "GraalVM Free Terms and Conditions"),
              url: "https://www.oracle.com/downloads/licenses/graal-free-license.html",
              note: L("Downloaded from Oracle when Minecraft's parts are built; it translates the game for Apple's chips.",
                      "Wird bei Oracle geladen, wenn die Spielteile von Minecraft gebaut werden; es übersetzt das Spiel für Apples Chips."))]
    }

    var body: some View {
        DisclosureGroup(L("Software used", "Verwendete Software")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("What the games built by AVP Play contain, and where it comes from. Thank you to everyone who made it.",
                       "Was in den Spielen steckt, die AVP Play baut, und woher es kommt. Danke an alle, die es gemacht haben."))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(toolchainParts) { item in
                    row(name: item.name, authors: item.authors, license: item.license, url: item.url, note: item.note)
                }
                if let credits = model.modCredits {
                    Divider()
                    Text(L("Beat Saber mods", "Beat-Saber-Mods")).font(.headline)
                    Text(L("A Beat Saber build with mods carries these mods of the Beat Saber modding community; the game names them too (start window › Settings › Mods).",
                           "Ein Beat-Saber-Bau mit Mods bringt diese Mods aus der Beat-Saber-Modding-Community mit; das Spiel nennt sie ebenfalls (Startfenster › Einstellungen › Mods)."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    row(name: credits.port.name, authors: credits.port.authors, license: credits.port.license, url: credits.port.url, note: "")
                    ForEach(credits.mods) { m in
                        row(name: m.name + (m.version.map { " " + $0 } ?? ""), authors: m.authors, license: m.license,
                            url: m.url, note: m.role ?? "")
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func row(name: String, authors: String, license: String, url: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                if let link = URL(string: url) { Link(L("Project", "Projekt"), destination: link).font(.callout) }
            }
            Text(authors + " · " + (license.isEmpty ? L("no licence stated", "keine Lizenzangabe") : license))
                .font(.callout).foregroundStyle(.secondary)
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
