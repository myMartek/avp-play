import AppKit
import AVPPlayCore
import SwiftUI

/// `--render-build <builder log> --render-job <job file> --render-dir <folder> [--render-at <s>,…] [--render-steps]
/// [--render-language en|de] [--render-size <w>x<h>]`: draws a job's page while its game's parts are being built, as
/// pictures, from a builder log with time stamps (`HH:MM:SS <line>`, as `tools/avpplay/build_parts.sh` writes it
/// under its work folder) at the given seconds after the log's first line – `3-auftrag-baut-<s>.png` each – and
/// ends. Only the page itself is drawn: the rest of the app does not start (no device, no account, no catalogue,
/// nothing written but the pictures).
@MainActor
enum BuildSnapshot {
    static func value(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func runIfRequested() {
        guard let logPath = value("--render-build") else { return }
        guard let jobPath = value("--render-job"), let dirPath = value("--render-dir") else {
            FileHandle.standardError.write(Data("--render-build needs --render-job <file> and --render-dir <folder>\n".utf8))
            exit(2)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let model = AppModel()
        // after the model, which applies the language it has stored
        L10n.language = value("--render-language") == "de" ? .de : .en
        BuildProgressView.expandedAtStart = CommandLine.arguments.contains("--render-steps")
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jobFile = URL(fileURLWithPath: jobPath)
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8),
              var job = try? JobStore(directory: jobFile.deletingLastPathComponent()).load(jobFile.deletingPathExtension().lastPathComponent) else {
            FileHandle.standardError.write(Data("cannot read \(logPath) or \(jobPath)\n".utf8))
            exit(1)
        }
        job.state = .running
        job.current = .fetch
        job.completed = job.steps.filter { $0 == .account }
        job.failure = nil
        let size = value("--render-size").map { $0.split(separator: "x").compactMap { Double($0) } } ?? []
        let width = size.count == 2 ? size[0] : 760, height = size.count == 2 ? size[1] : 980
        let moments = (value("--render-at") ?? "60").split(separator: ",").compactMap { Double($0) }
        let lines = timedLines(text)
        guard let first = lines.first?.seconds else { exit(1) }
        for at in moments {
            let now = Date()
            var build = BuildProgress()
            var said = [L("[1/2] Check account and ownership", "[1/2] Konto und Besitz prüfen"),
                        L("[2/2] Download files", "[2/2] Dateien laden"),
                        "    " + L("Building the game's parts on this Mac …", "Die Spielteile werden auf diesem Mac gebaut …")]
            let heard = Heard()
            let narrator = BuildNarrator(report: { heard.add("    " + $0) })
            for line in lines where line.seconds - first <= at {
                let when = now.addingTimeInterval(line.seconds - first - at)
                if line.text.hasPrefix("PARTS ") { build.finish(at: when) } else { build.apply(line.text, at: when) }
                narrator.update(build, at: when)
            }
            said += heard.lines
            model.jobs = [job]
            model.selectedJob = job.id
            model.runningJob = job.id
            model.logs[job.id] = LogTail(lines: said, total: said.count)
            model.copyProgress[job.id] = InstallProgress(step: .fetch, done: 0, total: 0, build: build)
            let page = JobDetail(job: job)
                .environmentObject(model)
                .environment(\.locale, L10n.locale)
                .frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: value("--render-appearance") == "dark" ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: page)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = "3-auftrag-baut-\(Int(at))\(L10n.language == .de ? "-de" : "").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                let e = build.estimate(at: Date())
                let summary = "\(name): \(build.summary(at: Date())) | overall \(String(format: "%.3f", e.overall)) step \(e.step.map { String(format: "%.3f", $0) } ?? "-")\n"
                if let h = try? FileHandle(forWritingTo: dir.appendingPathComponent("baut.txt")) {
                    h.seekToEndOfFile(); h.write(Data(summary.utf8)); try? h.close()
                } else { try? Data(summary.utf8).write(to: dir.appendingPathComponent("baut.txt")) }
            }
            window.orderOut(nil)
        }
        exit(0)
    }

    /// `HH:MM:SS <line>` → seconds of the day and the line; other lines are skipped. A run past midnight goes on
    /// counting.
    static func timedLines(_ text: String) -> [(seconds: Double, text: String)] {
        var out: [(Double, String)] = []
        var day = 0.0, last = -1.0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(raw)
            guard s.count >= 9, s[s.index(s.startIndex, offsetBy: 8)] == " " else { continue }
            let clock = s.prefix(8).split(separator: ":").compactMap { Int($0) }
            guard clock.count == 3 else { continue }
            var t = Double(clock[0] * 3600 + clock[1] * 60 + clock[2]) + day
            if t < last - 3600 { day += 86_400; t += 86_400 }
            last = t
            out.append((t, String(s.dropFirst(9))))
        }
        return out
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        func add(_ s: String) { lock.lock(); said.append(s); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return said }
    }
}
