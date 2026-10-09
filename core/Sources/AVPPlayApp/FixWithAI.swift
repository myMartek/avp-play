import AppKit
import AVPPlayCore
import SwiftUI

/// Was mit einem Spiel nicht stimmt, in den Worten, die jemand am Headset dafür hat. Die Kennungen sind die,
/// die auch der Dienst des Projekts kennt.
enum Symptom: String, CaseIterable, Identifiable {
    case crash = "crash-at-start"
    case black = "black-screen"
    case graphics
    case controls
    case audio
    case performance
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crash: return L("It closes or crashes when it starts", "Es schließt sich oder stürzt beim Start ab")
        case .black: return L("It stays black or never gets past loading", "Es bleibt schwarz oder kommt nie über das Laden hinaus")
        case .graphics: return L("The picture is wrong (distorted, parts missing, one eye, flicker)", "Das Bild stimmt nicht (verzerrt, Teile fehlen, ein Auge, Flackern)")
        case .controls: return L("The controls do not work (controllers or hands not recognised, wrong buttons)", "Die Steuerung geht nicht (Controller oder Hände nicht erkannt, falsche Tasten)")
        case .audio: return L("No sound, or the sound is broken", "Kein Ton, oder der Ton ist kaputt")
        case .performance: return L("It runs badly (stutter, low frame rate)", "Es läuft schlecht (Ruckeln, niedrige Bildrate)")
        case .other: return L("Something else", "Etwas anderes")
        }
    }

    /// Wo in der Toolchain bei diesem Fehlerbild zuerst zu suchen ist – aus dem, was die geprüften Spiele gekostet haben.
    var hint: String {
        switch self {
        case .crash:
            return "Closes or crashes at start: read the end of the game's own log first (see \"The game's log\"). Typical causes so far: a function of Meta's platform SDK the game calls and the runtime does not provide (runtime/xr/kl_ovrplat.c), a missing Android/JNI call (runtime/kl_jni.c, runtime/jni/, and the engine glue in runtime/guest/ – kl_il2cpp.c for Unity, kl_ue4.c for Unreal), a library the loader cannot resolve (runtime/kl_image.c, runtime/kl_dl.c and the target's row in runtime/kl_target_table.h and visionos/targets.py), or game data that is not where the game looks (the `dest` of the files in the recipe)."
        case .black:
            return "Stays black or hangs while loading: the log usually ends at the last thing that worked. Check whether the game waits for an entitlement or platform answer (runtime/xr/kl_ovrplat.c), for a file (compare what it opens with what is in the app's Documents folder), or for a video (the `video` key of the target in visionos/targets.py; Vulkan games)."
        case .graphics:
            return "Picture is wrong: find out whether the game renders with OpenGL ES or Vulkan (log lines starting with [glfb] or [vk]). OpenGL: runtime/gfx/kl_glfb.c. Vulkan: runtime/gfx/kl_vulkan.c. First try turning foveation off (launch with KL_VRR=0, or in the game's Settings) and lowering the resolution (`render_scale` of the target) to see whether the fault follows either. The compositor side is visionos/Sources/KleptonCompositor.swift."
        case .controls:
            return "Controls: which input API the game uses decides where to look – Meta's OVR plugin API (runtime/xr/kl_ovrp.c; log lines starting with [ovrp]) or OpenXR (runtime/xr/kl_openxr.c; [xr]). Controller poses and buttons come from visionos/Sources/KleptonControllers.swift. Check the log for the action sets or input paths the game asks for and which of them are answered."
        case .audio:
            return "Sound: runtime/media/ and visionos/Sources/KleptonAudio.swift. Check in the log which audio API the game opens (AAudio, OpenSL ES, FMOD, Wwise) and whether the stream starts."
        case .performance:
            return "Performance: the cheapest levers are the target's `render_scale` and `foveation` in visionos/targets.py. Check the frame times the log reports before changing code."
        case .other:
            return "Start from the game's own log and work back from the first line that reports a failure."
        }
    }
}

extension AppModel {
    /// Der Auftrag für eine KI: was das Spiel ist, was nicht geht, wo auf diesem Mac alles liegt, wie gebaut und
    /// geprüft wird, was tabu ist und wie ein funktionierender Fix an das Projekt geht. Auf Englisch, weil er für
    /// ein Programm ist; die KI soll dem Nutzer in dessen Sprache antworten.
    func fixPrompt(for game: Game, symptoms: Set<Symptom>, details: String) -> String {
        let recipe = game.recipe
        let target = recipe.toolchain.target
        let toolchainRoot = toolchain?.root.path ?? "<toolchain not installed – install it in AVP Play first>"
        let toolchainName = toolchain.map { "version \($0.version()) (\($0.commit()))" } ?? "unknown"
        let recipesDir = game.draft ? draftsDirectory.path : (paths.recipes?.path ?? "<recipes folder>")
        let storeDir = paths.store.directory(for: recipe).path
        let bundleId = Toolchain.bundleId(target: target, prefix: customBundlePrefix.isEmpty ? nil : customBundlePrefix)
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/avpplay").path
        let cliNote = FileManager.default.isExecutableFile(atPath: cli) ? "" : "  (if this file is missing, use the `avpplay` command-line tool built from the AVP Play repository)"
        let work = "~/avpplay-fix/\(target)"
        let udid = device?.udid ?? "<UDID of the Vision Pro: xcrun devicectl list devices>"
        let chosen = Symptom.allCases.filter(symptoms.contains)
        let symptomList = chosen.isEmpty ? "- (not specified – ask the user what exactly happens)" : chosen.map { "- \($0.rawValue): \($0.title)" }.joined(separator: "\n")
        let extra = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let api = catalogClient.base.appendingPathComponent("api/v1/fixes").absoluteString
        let symptomsJSON = chosen.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        let language = self.language == .de ? "German" : "English"
        // Unter welcher Kennung der Dienst des Projekts das Spiel führt: die Store-Kennung, und bei einem Spiel, das
        // nicht aus dem Meta-Store kommt, der Name seines Rezepts.
        let fixIdentifier = recipe.store.appId ?? recipe.id

        return """
        You are helping me get a VR game to run on my Apple Vision Pro. I installed it with AVP Play, an open-source Mac app that translates Meta Quest games I own with the Klepton toolchain. The game installs but does not work properly. Please find out why and fix it in the toolchain. Talk to me in \(language).

        ## The game
        - Title: \(recipe.title)
        - Android package: \(recipe.package)
        - Build: \(recipe.versionName) (version code \(recipe.versionCode))\(recipe.store.appId.map { "\n- Meta Store app ID: \($0)" } ?? "")
        - Name in the toolchain (the "target"): \(target)
        - App on the headset: \(bundleId)
        - Status in AVP Play: \(["verified by the project", "community verified – more users report that it runs than not", "untested – nobody has confirmed that it runs", "incompatible – more users report that it does not run"][game.trust.rawValue])

        ## What goes wrong
        \(symptomList)\(extra.isEmpty ? "" : "\n\nIn my own words: \(extra)")

        ## Where everything is on this Mac
        - The toolchain, \(toolchainName): \(toolchainRoot)
          Its documentation: BUILDING.md and DEBUG_ENV_VARS.md in that folder. The game's entry in the target table: visionos/targets.py and runtime/kl_target_table.h.
        - The game's files as downloaded (APK and data – read only, never change or copy them elsewhere): \(storeDir)
        - The recipe that lists them: \(recipesDir)/\(recipe.id).json
        - The log of the last build and install: \(storeDir)/.last-build.log
        - AVP Play's command-line tool: \(cli)\(cliNote)

        ## How to work
        1. Do not edit the installed toolchain. Make a working copy without build products and game files, and put it under version control so the change can be shown as a diff:
           mkdir -p \(work) && rsync -a --exclude build --exclude visionos/build --exclude '/\(target)/' --exclude '*.apk' "\(toolchainRoot)/" \(work)/
           cd \(work) && git init -q && git add -A && git commit -qm baseline && git tag baseline
        2. Build and install from the working copy (this replaces the game on the headset; saved games and data stay):
           AVPPLAY_LANG=en "\(cli)" install \(recipe.id) --recipes "\(recipesDir)" --toolchain \(work) --team \(teamValid ? teamId : "<Apple team ID>")
           The command checks ownership with Meta, uses the files already downloaded, builds, signs and installs. It stops if the game is running on the headset – ask me to quit it first.
        3. You cannot see the headset, so work in rounds and end every round the same way. After each install:
           a. Tell me in two or three sentences what you changed in this round and why.
           b. Ask me to put the headset on, start the game and tell you exactly what I see and hear – and ask me plainly: "Does the game work now?"
           c. Then stop and wait for my answer. Do not start the next change, and never claim that something works, before I have answered.
        4. What my answer means:
           - It does not work yet: fetch the game's log (see below), find the next cause, and do another round.
           - It works, but something is still wrong: ask me whether I want to keep going or send what we have so far.
           - It works: go straight to "When I confirm that it works" below and make the offer described there. Do this on your own – do not wait for me to bring it up.

        ## The game's log
        The game writes Documents/klepton-boot.log inside its app on the headset. It can be read once the game is no longer running:
           xcrun devicectl device copy from --device \(udid) --domain-type appDataContainer --domain-identifier \(bundleId) --source Documents/klepton-boot.log --destination /tmp/klepton-boot.log
        DEBUG_ENV_VARS.md lists switches that make the log say more.

        ## Where to look first
        \(chosen.isEmpty ? Symptom.other.hint : chosen.map { "- " + $0.hint }.joined(separator: "\n"))

        ## Rules
        - Change only files in the working copy \(work). Leave the installed toolchain, the downloaded game files and AVP Play's data alone.
        - Never copy, upload or quote game content (the APK, its libraries, assets or data). Reading it to understand a problem is fine.
        - Do not touch my Meta sign-in: do not read the keychain, do not run `avpplay login` or `logout`, and do not make requests to Meta other than what the install command does by itself.
        - Do not remove ownership or purchase checks, and do not make the game report content as purchased that I have not bought.
        - Keep changes small and specific to the problem. If a change only helps this game, tie it to the target name rather than changing behaviour for all games.
        - If you cannot fix it, say so plainly and tell me what you found.

        ## When I confirm that it works
        As soon as I say the game works, offer – without being asked – to send the change to the AVP Play project so that other people get it too. A maintainer reads every submission before anything is done with it. Show me what would be sent (a short summary and the diff) and ask for my go-ahead first. If I say no, leave it at that. If I say yes:
        1. Create the diff of source changes only:
           cd \(work) && git add -N . && git diff --no-color baseline -- . ':(exclude)vendor' ':(exclude)vendor-moltenvk' > /tmp/avpplay-fix.patch
           Check that it contains no game content and no binary files, and that it is under 256 KB.
        2. Send it as JSON (the patch as one string) with an HTTP POST to \(api):
           {"appId": "\(fixIdentifier)", "versionCode": \(recipe.versionCode), "toolchain": "\(toolchain?.commit() ?? "")", "symptoms": [\(symptomsJSON)], "summary": "<what was wrong, what you changed and why, and what I confirmed on the headset>", "patch": "<contents of /tmp/avpplay-fix.patch>", "contact": "<optional: how the maintainer can reach me, only if I want that>"}
           Build the JSON with a tool that escapes the patch correctly (for example jq or python3), not by hand. The answer contains an id; tell me that id.
        The submission contains nothing about me unless I ask you to add a contact. Do not send anything else to that address.
        """
    }
}

/// „Fix with AI“: fragen, was nicht geht, und daraus den Auftrag für eine KI machen, den der Nutzer ihr selbst gibt.
struct FixSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var symptoms: Set<Symptom> = []
    @State private var details = ""
    @State private var copied = false

    var body: some View {
        let prompt = model.fixPrompt(for: game, symptoms: symptoms, details: details)
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Fix \(game.recipe.title) with AI", "\(game.recipe.title) mit KI reparieren")).font(.title2.bold())
            Text(L("Tick what goes wrong. The app then writes a task for an AI coding assistant that works on your Mac (for example Claude Code): where the files are, how to build and test, what is off limits, and how to send a working fix to the project for review. You give it to the assistant yourself – the app sends nothing.",
                   "Kreuze an, was nicht geht. Die App schreibt dann einen Auftrag für einen KI-Programmierassistenten, der auf deinem Mac arbeitet (zum Beispiel Claude Code): wo die Dateien liegen, wie gebaut und getestet wird, was tabu ist, und wie ein funktionierender Fix zur Prüfung an das Projekt geht. Du gibst ihn dem Assistenten selbst – die App sendet nichts."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Symptom.allCases) { symptom in
                    Toggle(symptom.title, isOn: Binding(
                        get: { symptoms.contains(symptom) },
                        set: { on in if on { symptoms.insert(symptom) } else { symptoms.remove(symptom) }; copied = false }))
                }
            }
            TextField(L("What exactly happens? (optional)", "Was passiert genau? (freiwillig)"), text: $details, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            ScrollView {
                Text(prompt)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 220)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if copied { Label(L("Copied – paste it into your AI assistant.", "Kopiert – füge es in deinen KI-Assistenten ein."), systemImage: "checkmark").foregroundStyle(.green) }
                Spacer()
                Button(L("Close", "Schließen")) { dismiss() }
                Button(L("Copy Task", "Auftrag kopieren")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 720)
    }
}
