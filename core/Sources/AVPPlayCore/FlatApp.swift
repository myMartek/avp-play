import Foundation

/// Erkennt eine gewöhnliche 2D-App der Quest (Spotify, WhatsApp, …): ein Fenster, das Horizon OS als Panel zeigt,
/// kein Spiel, das eigene Bilder für beide Augen rendert. Die Toolchain kann so etwas nicht starten – sie bildet
/// nach, was Spiele brauchen (OpenXR/OVR, Vulkan/GL, Eingabe), nicht Androids App-Rahmen (GitHub-Meldung 20).
///
/// Bewusst vorsichtig: Als 2D-App gilt ein APK nur, wenn sein Manifest lesbar ist und KEIN Zeichen einer VR-App
/// trägt UND keine seiner nativen Bibliotheken nach VR oder einer Spiel-Engine aussieht. Alles Unklare gilt als
/// Spiel – dann geht es weiter wie bisher. Eine einzelne Angabe reicht nicht: Manche echten Spiele (Unreal) haben
/// keine VR-Kategorie im Manifest, wohl aber `focusaware` und OVR-Bibliotheken.
public enum FlatApp {
    public enum Verdict: Equatable, Sendable {
        /// Sicher eine 2D-App.
        case flat
        /// Mindestens ein Zeichen einer VR-App oder eines Spiels.
        case immersive
        /// Ließ sich nicht lesen – gilt als Spiel.
        case unknown
    }

    /// Angaben im Manifest, die nur eine VR-App macht: die Startkategorie der Quest bzw. von OpenXR, der
    /// Focus-Aware-Eintrag, das Kopf-Tracking als Gerätemerkmal, OpenXR-Berechtigungen, Gear VR.
    static let manifestMarkers = [
        "com.oculus.intent.category.VR",
        "org.khronos.openxr",
        "com.oculus.vr.focusaware",
        "android.hardware.vr.headtracking",
        "com.samsung.android.vr.application.mode",
    ]

    /// Teile von Bibliotheksnamen (klein geschrieben), die zu VR-Laufzeiten oder Spiel-Engines gehören:
    /// `libopenxr_loader`, `libOVRPlugin`, `libovrplatformloader`, `libvrapi`, `libOculusXRPlugin`, `libUnityOpenXR`,
    /// `libunity`, `libil2cpp`, `libUE4`, `libUnreal`, `libgodot_android`, Pico (`pxr`), Google VR (`gvr`).
    static let libraryMarkers = ["openxr", "ovr", "vrapi", "oculus", "metaxr", "xrplugin", "vrintegration", "vrlink",
                                 "pxr", "gvr", "unity", "il2cpp", "ue4", "unreal", "godot"]

    /// Das Urteil aus dem Manifest als Text (`nil`: nicht lesbar) und den Eintragsnamen des Archivs.
    public static func verdict(manifest: String?, entries: [String]) -> Verdict {
        guard let manifest, manifest.contains("<manifest") else { return .unknown }
        if manifestMarkers.contains(where: { manifest.contains($0) }) { return .immersive }
        let libraries = entries.filter { $0.hasPrefix("lib/") && $0.hasSuffix(".so") }
            .map { ($0.split(separator: "/").last.map(String.init) ?? "").lowercased() }
        if libraries.contains(where: { name in libraryMarkers.contains { name.contains($0) } }) { return .immersive }
        return .flat
    }

    /// Das Urteil für ein APK im Bestand. Was sich nicht lesen lässt, ist `.unknown`.
    public static func verdict(apk: URL) -> Verdict {
        guard let names = try? ApkUnpacker.run(["/usr/bin/unzip", "-Z1", apk.path]).text,
              let binary = try? ApkUnpacker.run(["/usr/bin/unzip", "-p", apk.path, "AndroidManifest.xml"]).data,
              let text = try? AXML.decode(binary).text else { return .unknown }
        return verdict(manifest: text, entries: names.split(separator: "\n").map(String.init))
    }

    /// Vermerk im Ordner der Fassung, dass sie als 2D-App erkannt wurde – für die Bibliothek, die nicht jedes APK
    /// öffnen soll. Gehört zur Fassung: eine neue hat ihren eigenen Ordner, und mit den Dateien geht auch er.
    static let markName = ".flat-app"

    public static func mark(store: ContentStore, recipe: Recipe) {
        let dir = store.directory(for: recipe)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? Data().write(to: dir.appendingPathComponent(markName))
    }

    public static func isMarked(store: ContentStore, recipe: Recipe) -> Bool {
        FileManager.default.fileExists(atPath: store.directory(for: recipe).appendingPathComponent(markName).path)
    }

    /// Nur ein Versuch (ein Spiel ohne eigenen Eintrag in der Toolchain) wird geprüft: Was das Projekt mit eigenem
    /// Rezept führt, ist ein bekanntes Spiel. Ist das APK eine 2D-App, wird das vermerkt und abgebrochen.
    static func refuse(apk: URL, recipe: Recipe, store: ContentStore) throws {
        guard DraftRecipe.isGeneric(recipe.toolchain.target), verdict(apk: apk) == .flat else { return }
        mark(store: store, recipe: recipe)
        throw InstallError.notAVRGame
    }
}
