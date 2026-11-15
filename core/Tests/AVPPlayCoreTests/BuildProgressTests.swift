import XCTest
@testable import AVPPlayCore

/// The progress display of a parts build: the builder's PLAN and PROGRESS lines, and the estimate made from them,
/// fed with what real runs on the reference Mac printed (`BuildFixtures`).
final class BuildProgressTests: XCTestCase {
    override func setUp() { L10n.language = .en }
    override func tearDown() { L10n.language = .en }

    /// A fixture's lines with the moment each was written.
    func lines(_ text: String) -> [(at: Date, line: String)] {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        return text.split(separator: "\n").map { raw in
            let s = String(raw)
            let clock = s.prefix(8).split(separator: ":").compactMap { Int($0) }
            let seconds = Double(clock[0] * 3600 + clock[1] * 60 + clock[2])
            return (base.addingTimeInterval(seconds), String(s.dropFirst(9)))
        }
    }

    /// Plays a fixture into a `BuildProgress`, and calls `look` every `every` seconds of the run's own time
    /// (and right after every line) with the state and the moment.
    @discardableResult
    func replay(_ text: String, every: Double = 10, look: (BuildProgress, Date) -> Void = { _, _ in }) -> BuildProgress {
        var p = BuildProgress()
        let all = lines(text)
        var clock = all.first!.at
        for (at, line) in all {
            while clock.addingTimeInterval(every) < at {
                clock = clock.addingTimeInterval(every)
                look(p, clock)
            }
            if PartsBuild.parseResult(line) != nil { p.finish(at: at) } else { p.apply(line, at: at) }
            clock = at
            look(p, at)
        }
        return p
    }

    func span(_ text: String) -> Double {
        let all = lines(text)
        return all.last!.at.timeIntervalSince(all.first!.at)
    }

    // MARK: The lines

    func testTheLinesParseAndAnythingElseIsText() {
        typealias Line = BuildProgress.Line
        XCTAssertEqual(Line.parse("PLAN tree:2 tools:14:n graalvm:3:d world:62:dn"),
                       .plan([.init(name: "tree", seconds: 2), .init(name: "tools", seconds: 14, network: true),
                              .init(name: "graalvm", seconds: 3, done: true), .init(name: "world", seconds: 62, done: true, network: true)]))
        XCTAssertEqual(Line.parse("PROGRESS 25 5242 files"), .progress(.init(done: 25, total: 5242, unit: .files)))
        XCTAssertEqual(Line.parse("PROGRESS 120000 353673229 bytes"), .progress(.init(done: 120000, total: 353673229, unit: .bytes)))
        XCTAssertEqual(Line.parse("PROGRESS 2 8 parts 11,568,50,28,38,170,40,70"),
                       .progress(.init(done: 2, total: 8, unit: .parts, weights: [11, 568, 50, 28, 38, 170, 40, 70])))
        // weights that do not fit the number of parts are dropped, the parts stay
        XCTAssertEqual(Line.parse("PROGRESS 1 4 parts 1,2"), .progress(.init(done: 1, total: 4, unit: .parts)))
        XCTAssertEqual(Line.parse("PROGRESS 9 142 seconds"), .progress(.init(done: 9, total: 142, unit: .seconds)))
        XCTAssertEqual(Line.parse("PROGRESS 3 7 widgets"), .progress(.init(done: 3, total: 7, unit: .other("widgets"))))
        XCTAssertEqual(Line.parse("PROGRESS 9 7 files"), .progress(.init(done: 7, total: 7, unit: .files)), "never more than all")
        XCTAssertEqual(Line.parse("STAGE 6/20 minecraft"), .stage(.init(index: 6, count: 20, name: "minecraft"), alreadyDone: false))
        XCTAssertEqual(Line.parse("STAGE 2/20 tools (already done)"), .stage(.init(index: 2, count: 20, name: "tools"), alreadyDone: true))
        XCTAssertEqual(Line.parse("FAILED 14/20 world: no output and no download progress for 20 min, so the stage was stopped as hung."),
                       .failed(index: 14, count: 20, name: "world", reason: "no output and no download progress for 20 min, so the stage was stopped as hung."))
        XCTAssertEqual(Line.parse("FAILED 0/20 setup: AVPPLAY_WORK is not set."), .failed(index: 0, count: 20, name: "setup", reason: "AVPPLAY_WORK is not set."))
        XCTAssertEqual(Line.parse("LOG /work/logs/build.log"), .log("/work/logs/build.log"))
        XCTAssertEqual(Line.parse("WAIT screen-locked"), .wait("screen-locked"))
        XCTAssertEqual(Line.parse("WAIT end"), .wait(nil))
        XCTAssertNil(Line.parse("WAIT"))
        XCTAssertNil(Line.parse("WAIT for a long time"))
        XCTAssertNil(Line.parse(" WAIT screen-locked"))
        // what a tool printed and the builder quoted (a leading blank), broken lines, and plain text
        for other in [" STAGE 3/20 graalvm", " PROGRESS 1 2 files", " PLAN a:1", "PROGRESS", "PROGRESS 1 0 files", "PROGRESS x 2 files",
                      "PROGRESS -1 2 files", "PROGRESS 1 200 parts", "PLAN", "PLAN tree", "PLAN tree:x", "PLANET x:1", "PROGRESSIVE 1 2 files",
                      "assets 25/5149", "[2/8] Performing analysis...", ""] {
            XCTAssertNil(Line.parse(other), other)
        }
    }

    /// A builder that prints neither PLAN nor PROGRESS (the first state of the Minecraft builder): “Step i of n”,
    /// the time in the step, no estimate.
    func testABuilderWithoutPlanShowsStepsAndTimeOnly() {
        var p = BuildProgress()
        let t0 = Date()
        p.apply("STAGE 1/3 download", at: t0)
        p.apply("fetching the client", at: t0.addingTimeInterval(5))
        p.apply("STAGE 2/3 native image", at: t0.addingTimeInterval(10))
        let e = p.estimate(at: t0.addingTimeInterval(70))
        XCTAssertNil(e.remaining)
        XCTAssertNil(e.step)
        XCTAssertEqual(e.stepElapsed, 60)
        XCTAssertEqual(e.overall, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(p.headline, "Step 2 of 3", "a short name the app does not know is no headline")
        XCTAssertEqual(p.stepText(e), "1:00 so far")
        XCTAssertEqual(p.overallText(e), "Step 2 of 3 · 33 %")
    }

    // MARK: Real runs

    /// The run from an empty work folder. The estimate is there from the first line, it only shrinks while the
    /// Mac keeps pace, the whole-build bar never goes back, and the guesses get better as the steps finish.
    func testAFreshBuildIsEstimatedFromTheStartAndRefined() throws {
        let actual = span(BuildFixtures.fresh)          // 3110 s
        var first: Double?
        var lastOverall = 0.0
        var samples: [(elapsed: Double, left: Double, truth: Double)] = []
        let start = lines(BuildFixtures.fresh).first!.at
        let p = replay(BuildFixtures.fresh) { p, now in
            let e = p.estimate(at: now)
            if p.plan != nil, first == nil { first = e.remaining }
            XCTAssertGreaterThanOrEqual(e.overall, lastOverall - 1e-9, "the bar of the whole build never goes back")
            lastOverall = e.overall
            if let left = e.remaining, p.finished == nil {
                XCTAssertGreaterThanOrEqual(left, 0)
                let elapsed = now.timeIntervalSince(start)
                samples.append((elapsed, left, actual - elapsed))
            }
            if let s = e.step { XCTAssert((0...1).contains(s)) }
        }
        let atStart = try XCTUnwrap(first)
        // The plan's sum is the reference Mac's median run; this night's run was slower (downloads).
        XCTAssertEqual(atStart, 2452, accuracy: 1)
        XCTAssertEqual(BuildProgress.remainingText(atStart), "about 40 minutes left")
        XCTAssertEqual(p.estimate(at: lines(BuildFixtures.fresh).last!.at).overall, 1)
        // From the image step on (the last 16 minutes) the estimate is within a quarter of what really came,
        // give or take a minute and a half (its last phases were quicker than their reference).
        for s in samples where s.elapsed >= 2150 && s.truth > 60 {
            XCTAssertEqual(s.left, s.truth, accuracy: s.truth * 0.25 + 90, "at \(Int(s.elapsed)) s")
        }
        // At no time is it off by more than half the real rest (plus two minutes).
        for s in samples { XCTAssertEqual(s.left, s.truth, accuracy: s.truth * 0.5 + 120, "at \(Int(s.elapsed)) s") }
        XCTAssertEqual(p.ran.count, 20)
        XCTAssertTrue(p.skipped.isEmpty)
    }

    /// The Minecraft download counts files: its bar follows them, and with the network slower than the reference
    /// the step says so, with a time left from its own pace.
    func testTheMinecraftDownloadCountsFiles() throws {
        var seen: [(Double, Double, Bool)] = []
        replay(BuildFixtures.fresh) { p, now in
            guard p.currentName == "minecraft", let m = p.measure, p.finished == nil else { return }
            let e = p.estimate(at: now)
            XCTAssertEqual(e.step ?? -1, Double(m.done) / Double(m.total), accuracy: 1e-9)
            seen.append((e.step ?? 0, e.stepElapsed, e.slow))
        }
        XCTAssertGreaterThan(seen.count, 50)
        XCTAssertEqual(seen.last?.0 ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(seen.contains { $0.2 }, "882 s against a usual 420 × the network's pace: taking longer than usual")
        var p = BuildProgress()
        for (at, line) in lines(BuildFixtures.fresh) {
            p.apply(line, at: at)
            if line == "PROGRESS 1000 5242 files" || line.hasPrefix("PROGRESS 1") && p.measure?.done ?? 0 >= 1000 { break }
        }
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.locale = L10n.locale
        XCTAssertEqual(BuildProgress.countText(try XCTUnwrap(p.measure)),
                       "\(n.string(from: NSNumber(value: p.measure!.done))!) of \(n.string(from: 5242)!) files")
    }

    /// A rebuild with the downloads kept: its estimate starts far lower, and its image step – 1416 s against the
    /// usual 975 – says that it takes longer than usual instead of counting down below zero or standing still.
    func testARebuildIsShorterAndAnOverrunningStepSaysSo() throws {
        let actual = span(BuildFixtures.rebuild)        // 2102 s
        var atStart: Double?
        var slowTexts: Set<String> = []
        var overallTexts: [String] = []
        replay(BuildFixtures.rebuild, every: 5) { p, now in
            let e = p.estimate(at: now)
            if atStart == nil, p.plan != nil { atStart = e.remaining }
            if let left = e.remaining { XCTAssertGreaterThanOrEqual(left, 0) }
            if p.currentName == "image", p.finished == nil {
                if e.slow { slowTexts.insert(p.stepText(e)) }
                overallTexts.append(p.overallText(e))
            }
        }
        let start = try XCTUnwrap(atStart)
        XCTAssertEqual(start, 1559, accuracy: 1, "the plan's steps that run: much less than a build from nothing")
        XCTAssertEqual(start, actual, accuracy: actual * 0.3)
        XCTAssertFalse(slowTexts.isEmpty, "the step says it takes longer than usual")
        XCTAssertTrue(slowTexts.allSatisfy { $0.contains("taking longer than usual") }, "\(slowTexts)")
        // While its long second phase overran (785 s against 568 × this Mac's pace) the time left was only a lower
        // bound, and said so; after it the phases tell how much longer. Never below zero, never still for long.
        XCTAssertTrue(overallTexts.contains { $0.contains("at least") })
        XCTAssertFalse(overallTexts.contains { $0.contains("-") })
        var longest = 0, run = 1
        for (a, b) in zip(overallTexts, overallTexts.dropFirst()) {
            let same = a.split(separator: "·").last == b.split(separator: "·").last
            run = same ? run + 1 : 1
            longest = max(longest, run)
        }
        XCTAssertLessThan(longest * 5, 330, "the same time left for at most five and a half minutes (\(longest * 5) s)")
    }

    /// The image step's parts: native-image prints “[k/8]” as phase k ends; the bar runs through the phases by their
    /// reference times and stops short of a phase's end until the phase is really over.
    func testTheImageStepRunsThroughItsPhases() {
        var shares: [Double] = []
        var texts: Set<String> = []
        replay(BuildFixtures.verification, every: 15) { p, now in
            guard p.currentName == "image", p.finished == nil, p.current == 17 else { return }
            let e = p.estimate(at: now)
            guard e.stepElapsed > 0 else { return }      // the STAGE line itself: its PROGRESS line follows at once
            shares.append(e.step ?? -1)
            if let m = p.measure { texts.insert(BuildProgress.countText(m) ?? "") }
        }
        XCTAssertFalse(shares.contains(-1), "the image step always has a bar (from its first line on)")
        XCTAssertEqual(shares, shares.sorted(), "and it never goes back")
        XCTAssertTrue(texts.isSuperset(of: ["part 2 of 8", "part 3 of 8", "part 8 of 8"]), "\(texts)")
        // Phase 2 ran 568 s on the reference Mac; ten seconds before its end line the bar is near 0.6, not done.
        var p = BuildProgress()
        for (at, line) in lines(BuildFixtures.verification) {
            if line.hasPrefix("PROGRESS 2 8 parts") {
                let e = p.estimate(at: at.addingTimeInterval(-10))
                XCTAssertEqual(e.step ?? 0, (11 + 568 * 0.95) / 975, accuracy: 0.03)
                break
            }
            p.apply(line, at: at)
        }
    }

    /// The bake waits a fixed time before its full pass; the builder says so, and the bar follows the clock.
    func testTheBakeIsATimedWait() throws {
        var p = BuildProgress()
        var at0: Date?
        for (at, line) in lines(BuildFixtures.verification) {
            p.apply(line, at: at)
            if line.hasPrefix("PROGRESS 0 142 seconds") { at0 = at; break }
        }
        let start = try XCTUnwrap(at0)
        XCTAssertEqual(p.estimate(at: start.addingTimeInterval(71)).step ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(p.estimate(at: start.addingTimeInterval(400)).step ?? 0, 0.97, accuracy: 1e-9, "never shown as done before it is")
        XCTAssertTrue(p.estimate(at: start.addingTimeInterval(400)).slow)
        XCTAssertEqual(p.stepText(p.estimate(at: start.addingTimeInterval(60))), "1:00 so far · usually about 2 minutes")
    }

    /// A resumed build: the steps already done show as done from the plan on – the bar of the whole build starts
    /// where they leave it – and the estimate counts only what still runs.
    func testAResumeShowsTheDoneStepsAsDoneAndCountsOnlyTheRest() throws {
        var p = BuildProgress()
        let all = lines(BuildFixtures.resume)
        p.apply(all[0].line, at: all[0].at)          // the plan
        let before = p.estimate(at: all[0].at)
        XCTAssertEqual(before.remaining ?? 0, 62 + 141 + 17 + 975 + 6 + 31 + 8, accuracy: 0.5)
        let doneShare = (2 + 3 + 3 + 2 + 8 + 9 + 58 + 158 + 12 + 28 + 37 + 2 + 3) / 1565.0
        XCTAssertEqual(before.overall, doneShare, accuracy: 0.001)
        XCTAssertEqual(p.steps().prefix(13).map(\.state), Array(repeating: .willSkip, count: 13))
        for (at, line) in all.dropFirst() { p.apply(line, at: at) }
        let e = p.estimate(at: all.last!.at.addingTimeInterval(30))
        XCTAssertEqual(e.overall, doneShare + 62 * min(30 / 62, 0.9) / 1565, accuracy: 0.002)
        XCTAssertEqual(p.steps().prefix(13).map(\.state), Array(repeating: .skipped, count: 13))
        XCTAssertEqual(p.steps()[13].state, .running)
        XCTAssertEqual(p.headline, "Step 14 of 20: Creating a test world")
        XCTAssertEqual(BuildProgress.remainingText(try XCTUnwrap(e.remaining)), "about 20 minutes left")

        // the job's log hears it once: the done steps together, then the step that runs
        let heard = Heard()
        let narrator = BuildNarrator(report: { heard.add($0) })
        var q = BuildProgress()
        for (at, line) in all { q.apply(line, at: at); narrator.update(q, at: at) }
        XCTAssertEqual(heard.lines, [
            "  The build has 20 steps, 13 of them already done. Expected time on this Mac: about 20 minutes (refined as it goes).",
            "  steps 1–13 of 20 already done",
            "  Step 14 of 20: Creating a test world [world] · about 20 minutes left",
        ])
    }

    /// A stage that hangs (the world stage of a job, 21 minutes against the usual minute) is shown as taking
    /// longer than usual; the builder's FAILED line names the step and its reason.
    func testAHungStepIsSlowAndItsFailureIsNamed() throws {
        var slowAfter: Double?
        let p = replay(BuildFixtures.hung, every: 5) { p, now in
            guard p.currentName == "world", p.failure == nil else { return }
            let e = p.estimate(at: now)
            if e.slow, slowAfter == nil { slowAfter = e.stepElapsed }
            if e.stepElapsed > 120 {
                XCTAssertTrue(e.open)
                XCTAssertTrue(p.overallText(e).contains("at least"), p.overallText(e))
            }
        }
        XCTAssertEqual(try XCTUnwrap(slowAfter), 95, accuracy: 6, "62 s usual (× this Mac's pace) + 30 s")
        XCTAssertEqual(p.failure?.index, 14)
        XCTAssertEqual(p.failure?.reason, "no output and no download progress for 20 min, so the stage was stopped as hung.")
        XCTAssertEqual(p.builderLog, "/work/logs/build-20261115-052923-55649.log")
    }

    /// The world step of the real run that met a locked screen (the run of 2026-11-15 13:45; its world stage
    /// started 13:57:57), as the builder now says it: it waits, the estimate stands still meanwhile, the user is told
    /// what to do, and after the unlock everything goes on as if the wait had not been.
    func testAWaitForAnUnlockedScreenPausesTheEstimate() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var p = BuildProgress()
        p.apply("PLAN tree:2:d tools:3:d graalvm:3:d headers:2:d vivecraft:8:d minecraft:9:d openal:58:d lwjgl:158:d klsdl:12:d ltw:28:d voicechat:37:d shims:2:d classpath:3:d world:62 bake:141 launcher:17 image:975 relink:6 payload:31 zip:8", at: t0)
        for i in 1...13 { p.apply("STAGE \(i)/20 \(p.plan![i - 1].name) (already done)", at: t0) }
        p.apply("STAGE 14/20 world", at: t0)
        p.apply("waiting: the screen of this Mac is locked; Minecraft can only run while it is unlocked.", at: t0.addingTimeInterval(1))
        p.apply("WAIT screen-locked", at: t0.addingTimeInterval(1))
        XCTAssertEqual(p.waiting, "screen-locked")
        let atWait = p.estimate(at: t0.addingTimeInterval(1))
        let later = p.estimate(at: t0.addingTimeInterval(1800))
        XCTAssertEqual(later.remaining, atWait.remaining, "half an hour locked: the time left stands still")
        XCTAssertEqual(later.stepElapsed, 1)
        XCTAssertFalse(later.slow, "waiting is not taking longer than usual")
        XCTAssertEqual(later.elapsed, 1800, "the clock of the whole build goes on")
        XCTAssertTrue(p.overallText(later).hasSuffix("(paused)"), p.overallText(later))
        XCTAssertTrue(p.waitText!.hasPrefix("Waiting: please unlock this Mac."))
        L10n.language = .de
        XCTAssertTrue(p.waitText!.hasPrefix("Warte: Bitte entsperre diesen Mac."))
        L10n.language = .en
        // unlocked after 30 minutes: the step has run one second, not thirty minutes
        p.apply("WAIT end", at: t0.addingTimeInterval(1801))
        XCTAssertNil(p.waiting)
        let after = p.estimate(at: t0.addingTimeInterval(1811))
        XCTAssertEqual(after.stepElapsed, 11, accuracy: 0.001)
        XCTAssertEqual(after.remaining ?? 0, (atWait.remaining ?? 0) - 10, accuracy: 0.5)
        p.apply("STAGE 15/20 bake", at: t0.addingTimeInterval(1860))
        XCTAssertEqual(p.ran[14] ?? 0, 60, accuracy: 0.001, "the step's time without the wait")

        let heard = Heard()
        let narrator = BuildNarrator(report: { heard.add($0) })
        var q = BuildProgress()
        for (offset, line) in [(0.0, "STAGE 14/20 world"), (1, "WAIT screen-locked"), (900, "WAIT end")] {
            q.apply(line, at: t0.addingTimeInterval(offset)); narrator.update(q, at: t0.addingTimeInterval(offset))
        }
        XCTAssertEqual(heard.lines.suffix(2), [
            "  Waiting: please unlock this Mac. Minecraft has to run on it for a moment to build the game; then it goes on by itself.",
            "  The wait is over; the build goes on.",
        ])
    }

    /// A resume with only the last step left: almost all of the bar is done, and the time left is short.
    func testAResumeOfTheLastStep() throws {
        var p = BuildProgress()
        var sawZip = false
        for (at, line) in lines(BuildFixtures.lastStep) {
            if PartsBuild.parseResult(line) != nil { p.finish(at: at); continue }
            p.apply(line, at: at)
            if p.current == 20 && !p.skipped.contains(20) && !sawZip {
                sawZip = true
                let e = p.estimate(at: at)
                XCTAssertGreaterThan(e.overall, 0.99)
                XCTAssertEqual(BuildProgress.remainingText(try XCTUnwrap(e.remaining)), "less than a minute left")
            }
        }
        XCTAssertTrue(sawZip)
        XCTAssertEqual(p.estimate(at: Date()).overall, 1)
        XCTAssertEqual(p.estimate(at: Date()).remaining, 0)
    }

    // MARK: Through a real process

    /// A builder that prints the new lines, quotes a tool's look-alike line, and fails in a step: the job hears the
    /// progress, and the error names the step in plain words, the builder's reason and the log.
    func testABuilderRunPassesItsProgressAndNamesTheFailedStep() throws {
        let dir = URL(fileURLWithPath: "/tmp/avpplay-progress-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let tools = dir.appendingPathComponent("builder/tools/avpplay", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        echo "PLAN tree:2:d minecraft:420:n world:62"
        echo "STAGE 1/3 tree (already done)"
        echo "STAGE 2/3 minecraft"
        echo "PROGRESS 0 5242 files"
        echo " STAGE 9/9 quoted"
        echo " PROGRESS 5000 5242 files"
        echo "PROGRESS 2500 5242 files"
        echo "STAGE 3/3 world"
        echo "PROGRESS what"
        echo "FAILED 3/3 world: the world-creation run ended early."
        echo "LOG $AVPPLAY_WORK/logs/build.log"
        exit 1
        """
        let entry = dir.appendingPathComponent("builder/\(PartsBuilders.entry)")
        try script.write(to: entry, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        let seen = Seen()
        let build = PartsBuild(builder: dir.appendingPathComponent("builder"), work: dir.appendingPathComponent("work"))
        XCTAssertThrowsError(try build.run(out: dir.appendingPathComponent("out.zip"), log: dir.appendingPathComponent("parts.log"),
                                           stage: { seen.stage($0) }, progress: { seen.progress($0) })) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("in step 3 of 3 (“Creating a test world”)"), text)
            XCTAssertTrue(text.contains(": the world-creation run ended early."), text)
            XCTAssertTrue(text.contains("parts.log"), text)
        }
        XCTAssertEqual(seen.stages, ["1/3 tree", "2/3 minecraft", "3/3 world"], "the quoted line is no step")
        let last = try XCTUnwrap(seen.states.last)
        XCTAssertEqual(last.skipped, [1])
        XCTAssertEqual(last.plan?.map(\.name), ["tree", "minecraft", "world"])
        XCTAssertEqual(last.failure?.index, 3)
        XCTAssertTrue(last.builderLog?.hasSuffix("work/logs/build.log") ?? false)
        XCTAssertEqual(seen.states.compactMap { $0.measure?.done }.max(), 2500, "the quoted count is not taken")
        // the full log keeps every line, the quoted ones too
        let log = try String(contentsOf: dir.appendingPathComponent("parts.log"), encoding: .utf8)
        XCTAssertTrue(log.contains(" PROGRESS 5000 5242 files"))
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var s: [String] = []
        private var p: [BuildProgress] = []
        func stage(_ x: PartsBuild.Stage) { lock.lock(); s.append("\(x.index)/\(x.count) \(x.name)"); lock.unlock() }
        func progress(_ x: BuildProgress) { lock.lock(); p.append(x); lock.unlock() }
        var stages: [String] { lock.lock(); defer { lock.unlock() }; return s }
        var states: [BuildProgress] { lock.lock(); defer { lock.unlock() }; return p }
    }

    // MARK: Words

    func testDurationsAreRoundedLikeTheEstimateDeserves() {
        XCTAssertEqual(BuildProgress.remainingText(20), "less than a minute left")
        XCTAssertEqual(BuildProgress.remainingText(80), "about a minute left")
        XCTAssertEqual(BuildProgress.remainingText(7 * 60 + 20), "about 7 minutes left")
        XCTAssertEqual(BuildProgress.remainingText(33 * 60), "about 35 minutes left")
        XCTAssertEqual(BuildProgress.remainingText(52 * 60), "about 50 minutes left")
        XCTAssertEqual(BuildProgress.remainingText(64 * 60), "about 1 hour left")
        XCTAssertEqual(BuildProgress.remainingText(78 * 60), "about 1 hour 20 minutes left")
        XCTAssertEqual(BuildProgress.remainingText(9 * 60 + 50, atLeast: true), "at least 9 minutes left")
        XCTAssertEqual(BuildProgress.remainingText(60, atLeast: true), "a little longer than expected")
        XCTAssertEqual(BuildProgress.clock(65), "1:05")
        XCTAssertEqual(BuildProgress.clock(3725), "1:02:05")
        L10n.language = .de
        XCTAssertEqual(BuildProgress.remainingText(33 * 60), "noch etwa 35 Minuten")
        XCTAssertEqual(BuildProgress.remainingText(78 * 60), "noch etwa 1 Stunde 20 Minuten")
        XCTAssertEqual(BuildProgress.remainingText(20 * 60, atLeast: true), "noch mindestens 20 Minuten")
        XCTAssertEqual(BuildStepNames.headline(index: 6, count: 20, name: "minecraft"), "Schritt 6 von 20: Minecraft von Mojang laden")
        XCTAssertTrue(BuildProgress.countText(.init(done: 1234, total: 5242, unit: .files))!.hasSuffix(" Dateien"))
    }

    /// Every step of the Minecraft builder has a plain name in both languages; the world and bake steps say that
    /// Minecraft runs in the background and nothing is asked of the user.
    func testEveryStepHasAPlainName() throws {
        let plan = try XCTUnwrap(lines(BuildFixtures.fresh).first?.line)
        guard case .plan(let steps)? = BuildProgress.Line.parse(plan) else { return XCTFail(plan) }
        for language in [Language.en, .de] {
            L10n.language = language
            for step in steps {
                let title = try XCTUnwrap(BuildStepNames.title(step.name), step.name)
                XCTAssertNotEqual(title.lowercased(), step.name)
                XCTAssertGreaterThan(title.split(separator: " ").count, 1, title)
            }
            XCTAssertTrue(BuildStepNames.note("world")!.contains(language == .en ? "in the background" : "im Hintergrund"))
            XCTAssertEqual(BuildStepNames.note("bake"), BuildStepNames.note("world"))
        }
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        func add(_ s: String) { lock.lock(); said.append(s); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return said }
    }

    /// Not a check: prints how the estimate went in each real run, for the record (`swift test --filter …Table`).
    func testPrintTable() {
        for (name, text) in [("fresh", BuildFixtures.fresh), ("rebuild", BuildFixtures.rebuild), ("verification", BuildFixtures.verification)] {
            let start = lines(text).first!.at
            let total = span(text)
            var lastStep = 0
            print("== \(name): \(Int(total)) s")
            replay(text) { p, now in
                guard let c = p.current, c != lastStep, !p.skipped.contains(c) else { return }
                lastStep = c
                let e = p.estimate(at: now)
                let elapsed = now.timeIntervalSince(start)
                print(String(format: "  %5.0f s  step %2d %-10@ left %5.0f (true %5.0f)  %@", elapsed, c, p.currentName as NSString,
                             e.remaining ?? -1, total - elapsed, BuildProgress.remainingText(e.remaining ?? 0) as NSString))
            }
        }
    }
}
