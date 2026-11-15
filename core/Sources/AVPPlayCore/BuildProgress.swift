import Foundation

/// How far a build of a game's parts on this Mac is (`PartsBuild`), and how long it will still take.
///
/// It is fed the builder's lines as they come (`apply(_:at:)`) and answers for any moment (`estimate(at:)`):
/// - the step that runs, with a plain name (`BuildStepNames`), and which steps are already done;
/// - a bar for the whole build, weighted by how long each step takes on the reference Mac;
/// - a bar for the step, where the builder counts its work (`PROGRESS`), else elapsed against the usual time;
/// - the time left for the whole build.
///
/// The builder knows its steps and says how long each one took on the reference Mac (`PLAN`); this side scales
/// that by how fast this Mac turns out to be. A builder that prints neither line still shows “Step i of n” and the
/// time spent in the step.
public struct BuildProgress: Sendable, Equatable {
    /// One step of the plan: its short name, its reference seconds for this run, whether its result is there
    /// already (it will be skipped), whether its time is mostly a download.
    public struct Planned: Sendable, Equatable {
        public var name: String
        public var seconds: Double
        public var done: Bool
        public var network: Bool
        public init(name: String, seconds: Double, done: Bool = false, network: Bool = false) {
            self.name = name; self.seconds = seconds; self.done = done; self.network = network
        }
    }

    /// What the builder counts within a step.
    public struct Measure: Sendable, Equatable {
        public enum Unit: Sendable, Equatable {
            case files, bytes, entries, libraries, parts, seconds
            /// A word this side does not know: shown as plain numbers.
            case other(String)

            init(_ word: String) {
                switch word {
                case "files": self = .files
                case "bytes": self = .bytes
                case "entries": self = .entries
                case "libraries": self = .libraries
                case "parts": self = .parts
                case "seconds": self = .seconds
                default: self = .other(word)
                }
            }
        }
        public var done: Int64
        public var total: Int64
        public var unit: Unit
        /// With `.parts`: the reference seconds of each part (as many as `total`).
        public var weights: [Double]?
        public init(done: Int64, total: Int64, unit: Unit, weights: [Double]? = nil) {
            self.done = done; self.total = total; self.unit = unit; self.weights = weights
        }
    }

    /// The machine-readable lines of a builder. Every other line is text for the log.
    public enum Line: Sendable, Equatable {
        case stage(PartsBuild.Stage, alreadyDone: Bool)
        case plan([Planned])
        case progress(Measure)
        /// `FAILED <i>/<n> <name>: <sentence>`
        case failed(index: Int?, count: Int?, name: String, reason: String)
        /// `LOG <path>`
        case log(String)
        /// `WAIT <reason>`: the build waits for the user (`screen-locked`: the Mac's screen must be unlocked);
        /// `WAIT end`: it goes on.
        case wait(String?)

        /// `nil` for a line that is none of these (also for a broken one: it is then only text).
        public static func parse(_ raw: String) -> Line? {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard raw.first.map({ !$0.isWhitespace }) ?? false else { return nil }   // " STAGE …" is a quoted line
            if let s = PartsBuild.Stage.parse(line) {
                let suffix = " (already done)"
                if s.name.hasSuffix(suffix) {
                    var plain = s
                    plain.name = String(s.name.dropLast(suffix.count))
                    return .stage(plain, alreadyDone: true)
                }
                return .stage(s, alreadyDone: false)
            }
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let head = words.first else { return nil }
            switch head {
            case "PLAN":
                var plan: [Planned] = []
                for token in words.dropFirst() {
                    let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 2, !parts[0].isEmpty, parts[0].count <= 40, let s = Double(parts[1]), s.isFinite, s >= 0 else { return nil }
                    let flags = parts.count > 2 ? parts[2] : ""
                    plan.append(Planned(name: PartsBuild.clean(parts[0], limit: 40), seconds: min(s, 86_400),
                                        done: flags.contains("d"), network: flags.contains("n")))
                }
                guard (1...99).contains(plan.count) else { return nil }
                return .plan(plan)
            case "PROGRESS":
                guard words.count >= 4, let done = Int64(words[1]), let total = Int64(words[2]), total > 0, done >= 0 else { return nil }
                let unit = Measure.Unit(words[3])
                var weights: [Double]?
                if unit == .parts {
                    guard total <= 99 else { return nil }
                    if words.count > 4 {
                        let w = words[4].split(separator: ",").compactMap { Double($0) }.filter { $0.isFinite && $0 >= 0 }
                        if w.count == Int(total), w.reduce(0, +) > 0 { weights = w }
                    }
                }
                return .progress(Measure(done: min(done, total), total: total, unit: unit, weights: weights))
            case "FAILED":
                let rest = line.dropFirst(7)
                guard let colon = rest.firstIndex(of: ":") else { return .failed(index: nil, count: nil, name: "", reason: PartsBuild.clean(String(rest), limit: 400)) }
                let head = rest[..<colon].split(separator: " ", maxSplits: 1).map(String.init)
                let numbers = head.first?.split(separator: "/").compactMap { Int($0) } ?? []
                let reason = PartsBuild.clean(String(rest[rest.index(after: colon)...]), limit: 400)
                return .failed(index: numbers.count == 2 ? numbers[0] : nil, count: numbers.count == 2 ? numbers[1] : nil,
                               name: head.count > 1 ? PartsBuild.clean(head[1], limit: 40) : "", reason: reason)
            case "LOG":
                let path = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                return .log(path)
            case "WAIT":
                guard words.count == 2, words[1].count <= 40 else { return nil }
                return .wait(words[1] == "end" ? nil : words[1])
            default:
                return nil
            }
        }
    }

    public var plan: [Planned]?
    /// How many steps there are (from the plan or the first `STAGE` line).
    public var count: Int = 0
    /// When the builder started talking.
    public var started: Date?
    /// The step that runs (from 1), its short name, and since when.
    public var current: Int?
    public var currentName = ""
    public var currentStarted: Date?
    /// Steps that ran in this run, and how many seconds each took.
    public var ran: [Int: Double] = [:]
    /// Steps the builder skipped because their result was there.
    public var skipped: Set<Int> = []
    /// What the running step counts, when the builder says.
    public var measure: Measure?
    /// When `measure` last changed, and when the step's first count came (with what it said then).
    public var measureChanged: Date?
    public var measureFirst: (at: Date, done: Int64)? {
        get { firstAt.map { ($0, firstDone) } }
        set { firstAt = newValue?.at; firstDone = newValue?.done ?? 0 }
    }
    private var firstAt: Date?
    private var firstDone: Int64 = 0
    /// For a step counted in parts: when the part that runs began.
    public var partStarted: Date?
    /// The running step's share of the whole build's bar never drops below what it already showed (a first count
    /// can be behind the time-based guess before it, a timed wait can start again with a longer time).
    public var stepFloor = 0.0
    /// The build ended (with its result, or not).
    public var finished: Date?
    public var failure: (index: Int?, reason: String)? {
        get { failureReason.map { (failureIndex, $0) } }
        set { failureIndex = newValue?.index; failureReason = newValue?.reason }
    }
    private var failureIndex: Int?
    private var failureReason: String?
    public var builderLog: String?
    /// What the build waits for (`screen-locked`), and since when; `nil` while it works. The estimate stands still
    /// meanwhile, and the time waited does not count as time of the step.
    public var waiting: String?
    public var waitingSince: Date?

    public init() {}

    public static func == (a: BuildProgress, b: BuildProgress) -> Bool {
        a.plan == b.plan && a.count == b.count && a.started == b.started && a.current == b.current
            && a.currentName == b.currentName && a.currentStarted == b.currentStarted && a.ran == b.ran
            && a.skipped == b.skipped && a.measure == b.measure && a.measureChanged == b.measureChanged
            && a.partStarted == b.partStarted && a.finished == b.finished && a.failureReason == b.failureReason && a.stepFloor == b.stepFloor
            && a.waiting == b.waiting && a.waitingSince == b.waitingSince
    }

    // MARK: Reading the lines

    /// Takes one line of the builder. Returns whether anything a display shows has changed.
    @discardableResult
    public mutating func apply(_ raw: String, at now: Date) -> Bool {
        if started == nil { started = now }
        guard let line = Line.parse(raw) else { return false }
        switch line {
        case .plan(let entries):
            guard plan == nil else { return false }
            plan = entries
            if count == 0 { count = entries.count }
        case .stage(let s, let alreadyDone):
            endCurrent(at: now)
            if count == 0 || plan == nil { count = s.count }
            current = s.index
            currentName = s.name
            currentStarted = now
            measure = nil
            measureChanged = nil
            measureFirst = nil
            partStarted = now
            stepFloor = 0
            if alreadyDone { skipped.insert(s.index) } else { skipped.remove(s.index) }
        case .progress(let m):
            guard current != nil else { return false }
            stepFloor = max(stepFloor, estimate(at: now).stepShown)
            if measure?.unit != m.unit || measure?.total != m.total && m.unit == .parts { measureFirst = nil }
            if measureFirst == nil { measureFirst = (now, m.done) }
            if m.unit == .parts, m.done != measure?.done { partStarted = now }
            if m.unit == .seconds || m != measure { measureChanged = now }
            measure = m
        case .failed(let index, _, _, let reason):
            failure = (index, reason)
            finished = now
        case .log(let path):
            builderLog = path
        case .wait(let reason?):
            if waiting == nil { waitingSince = now }
            waiting = reason
        case .wait(nil):
            endWait(at: now)
        }
        return true
    }

    /// The wait is over: everything the estimate measures from moves on by the time waited, as if it had not been.
    private mutating func endWait(at now: Date) {
        guard let since = waitingSince else { waiting = nil; return }
        let paused = max(0, now.timeIntervalSince(since))
        currentStarted = currentStarted.map { $0.addingTimeInterval(paused) }
        partStarted = partStarted.map { $0.addingTimeInterval(paused) }
        measureChanged = measureChanged.map { $0.addingTimeInterval(paused) }
        if let first = measureFirst { measureFirst = (first.at.addingTimeInterval(paused), first.done) }
        waiting = nil
        waitingSince = nil
    }

    /// The result line ends the last step.
    public mutating func finish(at now: Date) {
        endCurrent(at: now)
        current = nil
        measure = nil
        finished = now
    }

    private mutating func endCurrent(at now: Date) {
        if waiting != nil { endWait(at: now) }
        guard let i = current, let since = currentStarted, !skipped.contains(i) else { return }
        ran[i] = max(0, now.timeIntervalSince(since))
    }

    // MARK: The estimate

    /// What a display shows at one moment.
    public struct Estimate: Sendable, Equatable {
        /// The whole build, 0…1 (steps weighted by their reference time; steps already done count as done).
        public var overall: Double
        /// Seconds left for the whole build; `nil` when the builder named no plan.
        public var remaining: Double?
        /// The running step's bar, 0…1; `nil`: its work is not countable (an indeterminate bar).
        public var step: Double?
        /// Seconds the running step has run, and how long it usually takes on this Mac.
        public var stepElapsed: Double
        /// Seconds since the builder started.
        public var elapsed: Double = 0
        public var stepTypical: Double?
        /// The running step takes clearly longer than usual.
        public var slow: Bool
        /// The running step is past its usual time and does not count its work: `remaining` is then only what the
        /// steps after it need, a lower bound.
        public var open: Bool
        /// How fast this Mac is against the reference: >1 slower. Downloads and the rest separately.
        public var scale: Double
        public var networkScale: Double
        /// The running step's share as the whole build's bar counts it (its bar, or a guess from the time).
        public var stepShown: Double
    }

    /// Reference seconds of the finished steps that weigh in the speed of this Mac, and the weight of the
    /// reference itself: until about two minutes of reference time are measured, this Mac counts as the reference.
    static let priorSeconds = 120.0
    /// Short steps say little about the speed (a second's rounding is a large share of them).
    static let minimumStepForScale = 20.0
    /// This Mac is taken to be at most this much faster or slower than the reference.
    static let scaleBounds = 0.5...3.0
    /// A step counts as slow once it is past its usual time by this share and at least this many seconds.
    static let slowShare = 0.1
    static let slowSeconds = 30.0

    static func isSlow(_ seconds: Double, _ usual: Double) -> Bool {
        seconds > usual * (1 + slowShare) && seconds > usual + slowSeconds
    }

    func entry(_ i: Int) -> Planned? {
        guard let plan, i >= 1, i <= plan.count else { return nil }
        return plan[i - 1]
    }

    /// Will step `i` run in this run? Steps behind the running one: if they ran. Ahead: unless the plan says
    /// their result is there.
    func runs(_ i: Int) -> Bool {
        if skipped.contains(i) { return false }
        if ran[i] != nil { return true }
        if let c = current, i == c { return true }
        if let c = current, i < c { return false }
        return !(entry(i)?.done ?? false)
    }

    /// The speed of this Mac against the reference, from the steps that ran – and, for the steps after it, the
    /// running one too once it is past its reference time.
    func scale(network: Bool, now: Date, withCurrent: Bool = true) -> Double {
        guard let plan else { return 1 }
        var actual = 0.0, reference = 0.0
        for (i, seconds) in ran {
            guard i >= 1, i <= plan.count, plan[i - 1].network == network, plan[i - 1].seconds >= Self.minimumStepForScale else { continue }
            actual += seconds; reference += plan[i - 1].seconds
        }
        if withCurrent, let c = current, !skipped.contains(c), let e = entry(c), e.network == network, e.seconds >= Self.minimumStepForScale,
           let since = currentStarted {
            let elapsed = now.timeIntervalSince(since)
            if elapsed > e.seconds { actual += elapsed; reference += e.seconds }
        }
        let s = (actual + Self.priorSeconds) / (reference + Self.priorSeconds)
        return min(max(s, Self.scaleBounds.lowerBound), Self.scaleBounds.upperBound)
    }

    public func estimate(at realNow: Date) -> Estimate {
        // While the build waits for the user, everything stands still at the moment the wait began.
        let now = waitingSince.map { min($0, realNow) } ?? realNow
        let cpu = scale(network: false, now: now)
        let net = scale(network: true, now: now)
        func typical(_ i: Int) -> Double? { entry(i).map { $0.seconds * ($0.network ? net : cpu) } }
        // What is usual for the running step: from the steps before it, not from how long it runs itself.
        let cpuBefore = scale(network: false, now: now, withCurrent: false)
        let netBefore = scale(network: true, now: now, withCurrent: false)
        func usualTime(_ i: Int) -> Double? { entry(i).map { $0.seconds * ($0.network ? netBefore : cpuBefore) } }
        let elapsed = currentStarted.map { max(0, now.timeIntervalSince($0)) } ?? 0

        // The running step: its bar and its time left.
        var stepShare: Double?
        var stepLeft: Double?
        var slow = false
        var open = false
        if let c = current, finished == nil, !skipped.contains(c) {
            let usual = usualTime(c)
            if let m = measure {
                (stepShare, stepLeft, slow, open) = Self.measured(m, usual: usual, elapsed: elapsed, now: now, progress: self,
                                                                  scale: entry(c)?.network == true ? netBefore : cpuBefore)
            } else if let usual {
                // Past its usual time a step may well end any moment; well past it, nobody knows when.
                slow = Self.isSlow(elapsed, usual)
                open = slow
                stepLeft = slow ? 0 : max(usual - elapsed, min(usual * 0.15, 60))
            }
        }

        // The whole build.
        let n = plan?.count ?? count
        var overall = 0.0
        var shown = 0.0
        var remaining: Double?
        if let plan {
            let total = plan.reduce(0) { $0 + max($1.seconds, 1) }
            var done = 0.0
            var left = 0.0
            for (k, e) in plan.enumerated() {
                let i = k + 1
                let weight = max(e.seconds, 1)
                if finished != nil && failure == nil { done += weight; continue }
                if let c = current {
                    if i < c || skipped.contains(i) { done += weight; continue }
                    if i == c {
                        let share = max(stepShare ?? min(elapsed / max(usualTime(i) ?? weight, 1), 0.9), stepFloor)
                        shown = min(max(share, 0), 1)
                        done += weight * shown
                        left += stepLeft ?? 0
                        continue
                    }
                } else if e.done {
                    done += weight; continue
                }
                if !runs(i) { done += weight; continue }
                left += typical(i) ?? 0
            }
            overall = total > 0 ? min(1, done / total) : 0
            remaining = finished != nil ? 0 : left
        } else if n > 0, let c = current {
            shown = max(stepShare ?? 0, stepFloor)
            overall = (Double(c - 1) + shown) / Double(n)
        }
        if finished != nil, failure == nil { overall = 1 }
        let total = started.map { max(0, (finished ?? realNow).timeIntervalSince($0)) } ?? 0
        return Estimate(overall: overall, remaining: remaining, step: stepShare, stepElapsed: elapsed, elapsed: total,
                        stepTypical: current.flatMap(usualTime), slow: slow, open: open && finished == nil, scale: cpu, networkScale: net,
                        stepShown: shown)
    }

    /// Bar, time left and slowness of a step that counts its work.
    static func measured(_ m: Measure, usual: Double?, elapsed: Double, now: Date, progress p: BuildProgress, scale: Double)
        -> (share: Double?, left: Double?, slow: Bool, open: Bool) {
        let total = Double(max(m.total, 1))
        switch m.unit {
        case .seconds:
            // A timed wait: the builder said how much of it was behind it when it wrote the line.
            let behind = Double(m.done) + max(0, now.timeIntervalSince(p.measureChanged ?? now))
            let share = min(behind / total, 0.97)
            let slow = behind > total + slowSeconds
            return (share, slow ? 0 : max(total - behind, 5), slow, slow)
        case .parts:
            let weights = m.weights ?? Array(repeating: 1, count: Int(total))
            let sum = weights.reduce(0, +)
            // The parts' reference seconds, stretched to this step's usual time on this Mac …
            let unit = (usual ?? sum) / max(sum, 1)
            let k = Int(min(max(m.done, 0), m.total))
            let doneRef = weights.prefix(k).reduce(0, +)
            // … and to how fast the finished parts of this step went.
            var local = 1.0
            let inPart = max(0, now.timeIntervalSince(p.partStarted ?? now))
            if k >= weights.count { return (1, 0, false, false) }
            func pace(_ actual: Double, _ reference: Double) -> Double {
                let r = (actual + priorSeconds) / (reference + priorSeconds)
                return min(max(r, scaleBounds.lowerBound / scale), scaleBounds.upperBound / scale)
            }
            if k > 0, let partStart = p.partStarted, let since = p.currentStarted {
                local = pace(partStart.timeIntervalSince(since), doneRef * unit)
            }
            let part = weights[k] * unit * local
            // A part past its time slows the guess for the parts after it, as it goes on.
            if inPart > part, let since = p.currentStarted {
                local = pace(now.timeIntervalSince(since), (doneRef + weights[k]) * unit)
            }
            let partShare = min(inPart / max(part, 1), 0.95)
            let share = (doneRef + partShare * weights[k]) / max(sum, 1)
            let later = weights.dropFirst(k + 1).reduce(0, +) * unit * local
            // A part well past its time: nobody knows when it ends, the time left is what the later parts need.
            let partSlow = isSlow(inPart, part)
            let left = (partSlow ? 0 : max(part - inPart, min(part * 0.1, 60))) + later
            // Slow: that, or the step as a whole will take clearly longer (its finished parts were slow, and the
            // rest is expected at their pace).
            let slow = partSlow || (usual.map { isSlow(elapsed + left, $0) } ?? false)
            return (share, left, slow, partSlow)
        default:
            let share = Double(m.done) / total
            guard let usual else { return (share, nil, false, false) }
            let byReference = usual * (1 - share)
            var left = byReference
            if let first = p.measureFirst, m.done > first.done {
                let counting = now.timeIntervalSince(first.at)
                if counting >= 10 {
                    let rate = Double(m.done - first.done) / counting
                    let byRate = (Double(m.total) - Double(m.done)) / rate
                    let trust = min(1, share / 0.3)
                    left = trust * byRate + (1 - trust) * byReference
                }
            }
            if share >= 1 { left = 0 }
            // Its own pace says something once a good part is counted (the first files are the large ones), or
            // once the usual time is up.
            let judged = share >= 0.15 || elapsed > usual
            return (share, left, judged && isSlow(elapsed + left, usual), false)
        }
    }
}

// MARK: - Words

/// The plain names of the steps of a game's parts build, by the builder's short names. A short name may stand
/// beside it, small, for a bug report – never as the main text.
public enum BuildStepNames {
    public static func title(_ name: String) -> String? {
        switch name {
        case "tree": return L("Preparing the build folder", "Bauordner vorbereiten")
        case "tools": return L("Downloading the build tools", "Bauwerkzeuge laden")
        case "graalvm": return L("Downloading the Java compiler (GraalVM)", "Java-Übersetzer laden (GraalVM)")
        case "headers": return L("Downloading graphics interface files", "Dateien der Grafikschnittstelle laden")
        case "vivecraft": return L("Building the VR mod Vivecraft", "VR-Mod Vivecraft bauen")
        case "minecraft": return L("Downloading Minecraft from Mojang", "Minecraft von Mojang laden")
        case "openal": return L("Building the sound library", "Tonbibliothek bauen")
        case "lwjgl": return L("Building the game's helper libraries", "Hilfsbibliotheken des Spiels bauen")
        case "klsdl": return L("Building the window and controller library", "Fenster- und Controller-Bibliothek bauen")
        case "ltw": return L("Building the graphics translator", "Grafik-Übersetzer bauen")
        case "voicechat": return L("Building the voice chat parts", "Teile für den Sprachchat bauen")
        case "shims": return L("Building the VR connection", "VR-Anbindung bauen")
        case "classpath": return L("Putting the game's files in order", "Dateien des Spiels ordnen")
        case "world": return L("Creating a test world", "Testwelt anlegen")
        case "bake": return L("Recording which game code is used", "Aufzeichnen, welcher Spielcode gebraucht wird")
        case "launcher": return L("Preparing the game for compiling", "Spiel für das Übersetzen vorbereiten")
        case "image": return L("Compiling Minecraft for the Vision Pro", "Minecraft für die Vision Pro übersetzen")
        case "relink": return L("Finishing the game library", "Spielbibliothek fertigstellen")
        case "payload": return L("Putting the game's parts together", "Spielteile zusammenstellen")
        case "zip": return L("Packing the game's parts", "Spielteile verpacken")
        default: return nil
        }
    }

    /// A sentence more, where the step does something the user may notice or wonder about.
    public static func note(_ name: String) -> String? {
        switch name {
        case "world", "bake":
            return L("Minecraft runs on this Mac for a moment in the background – invisible and without sound. You don't need to do anything; just leave the Mac unlocked.",
                     "Minecraft läuft dafür kurz im Hintergrund auf diesem Mac – unsichtbar und ohne Ton. Du musst nichts tun, lass den Mac nur entsperrt.")
        case "image":
            return L("The longest step. The Mac works hard meanwhile, other programs may feel slower.",
                     "Der längste Schritt. Der Mac arbeitet dabei stark, andere Programme können langsamer wirken.")
        case "vivecraft", "minecraft":
            return L("Mostly downloading: how long it takes depends on the internet connection.",
                     "Vor allem Herunterladen: Wie lange es dauert, hängt von der Internetverbindung ab.")
        default: return nil
        }
    }

    /// “Step 6 of 20: Downloading Minecraft from Mojang” – or “Step 6 of 20” for a step without a plain name.
    public static func headline(index: Int, count: Int, name: String) -> String {
        let step = L("Step \(index) of \(count)", "Schritt \(index) von \(count)")
        return title(name).map { "\(step): \($0)" } ?? step
    }
}

extension BuildProgress {
    /// Seconds as a short time, “4:05” or “1:02:05”.
    public static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A duration in rounded words: “about 35 minutes”. The rounding is coarser the further away it is, so that
    /// the number does not look more precise than it is.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 45 { return L("less than a minute", "weniger als eine Minute") }
        if seconds < 90 { return L("about a minute", "etwa eine Minute") }
        let minutes = seconds / 60
        let step: Double = minutes < 10 ? 1 : minutes < 45 ? 5 : 10
        let m = Int((minutes / step).rounded() * step)
        if m < 60 { return L("about \(m) minutes", "etwa \(m) Minuten") }
        let h = m / 60, rest = m % 60
        let hours = L(h == 1 ? "1 hour" : "\(h) hours", h == 1 ? "1 Stunde" : "\(h) Stunden")
        return rest == 0 ? L("about \(hours)", "etwa \(hours)") : L("about \(hours) \(rest) minutes", "etwa \(hours) \(rest) Minuten")
    }

    /// “about 35 minutes left” for the whole build. While a step takes longer than usual nobody knows how much
    /// longer, so the time is then only a lower bound – what the steps after it need: “at least 8 minutes left”.
    public static func remainingText(_ seconds: Double, atLeast: Bool = false) -> String {
        if atLeast {
            let m = Int(seconds / 60)
            if m < 2 { return L("a little longer than expected", "etwas länger als erwartet") }
            let step = m < 10 ? 1 : m < 45 ? 5 : 10
            let down = m / step * step
            if down < 60 { return L("at least \(down) minutes left", "noch mindestens \(down) Minuten") }
            let h = down / 60, rest = down % 60
            let hours = L(h == 1 ? "1 hour" : "\(h) hours", h == 1 ? "1 Stunde" : "\(h) Stunden")
            return rest == 0 ? L("at least \(hours) left", "noch mindestens \(hours)") : L("at least \(hours) \(rest) minutes left", "noch mindestens \(hours) \(rest) Minuten")
        }
        if seconds < 45 { return L("less than a minute left", "noch weniger als eine Minute") }
        return L("\(duration(seconds)) left", "noch \(duration(seconds))")
    }

    /// What the running step has done, in words: “1,234 of 5,242 files”, “120 of 353 MB”, “part 2 of 8”.
    public static func countText(_ m: Measure) -> String? {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.locale = L10n.locale
        func n(_ v: Int64) -> String { number.string(from: NSNumber(value: v)) ?? "\(v)" }
        switch m.unit {
        case .files: return L("\(n(m.done)) of \(n(m.total)) files", "\(n(m.done)) von \(n(m.total)) Dateien")
        case .bytes: return "\(Installer.megabytes(m.done)) \(L("of", "von")) \(Installer.megabytes(m.total))"
        case .entries: return L("\(n(m.done)) of \(n(m.total)) entries", "\(n(m.done)) von \(n(m.total)) Einträgen")
        case .libraries: return L("\(n(m.done)) of \(n(m.total)) libraries", "\(n(m.done)) von \(n(m.total)) Bibliotheken")
        case .parts:
            let k = min(m.done + 1, m.total)
            return m.done >= m.total ? L("all \(m.total) parts done", "alle \(m.total) Teile fertig") : L("part \(k) of \(m.total)", "Teil \(k) von \(m.total)")
        case .seconds: return nil
        case .other(let word): return "\(n(m.done)) / \(n(m.total)) \(word)"
        }
    }

    /// What the user is asked to do while the build waits, in plain words.
    public var waitText: String? {
        guard let waiting else { return nil }
        if waiting == "screen-locked" {
            return L("Waiting: please unlock this Mac. Minecraft has to run on it for a moment to build the game; then it goes on by itself.",
                     "Warte: Bitte entsperre diesen Mac. Minecraft muss darauf kurz laufen, um das Spiel zu bauen; danach geht es von selbst weiter.")
        }
        return L("Waiting (\(waiting)).", "Warte (\(waiting)).")
    }

    /// The line under the step's bar: what it counted, or how long it runs against how long it usually takes.
    public func stepText(_ e: Estimate) -> String {
        var parts: [String] = []
        if let m = measure, let words = BuildProgress.countText(m) { parts.append(words) }
        if e.slow {
            parts.append(L("\(BuildProgress.clock(e.stepElapsed)) so far – taking longer than usual", "\(BuildProgress.clock(e.stepElapsed)) bisher – dauert länger als sonst"))
            if let usual = e.stepTypical { parts.append(L("usually \(BuildProgress.duration(usual))", "sonst \(BuildProgress.duration(usual))")) }
        } else {
            parts.append(L("\(BuildProgress.clock(e.stepElapsed)) so far", "\(BuildProgress.clock(e.stepElapsed)) bisher"))
            if measure == nil || measure?.unit == .seconds, let usual = e.stepTypical {
                parts.append(L("usually \(BuildProgress.duration(usual))", "meist \(BuildProgress.duration(usual))"))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// The line under the whole build's bar: “Step 6 of 20 · 31 % · about 35 minutes left”.
    public func overallText(_ e: Estimate) -> String {
        var parts: [String] = []
        if let c = current { parts.append(L("Step \(c) of \(max(count, c))", "Schritt \(c) von \(max(count, c))")) }
        parts.append("\(Int((e.overall * 100).rounded(.down))) %")
        if let left = e.remaining, finished == nil { parts.append(BuildProgress.pausable(BuildProgress.remainingText(left, atLeast: e.open), waiting != nil)) }
        return parts.joined(separator: " · ")
    }

    /// A time left that stands still while the build waits says so.
    public static func pausable(_ text: String, _ paused: Bool) -> String {
        paused ? L("\(text) (paused)", "\(text) (pausiert)") : text
    }

    /// The line under the whole build's bar in the job's view (the time left stands beside the bar, the step's
    /// number in the box below it).
    public func overallCaption(_ e: Estimate) -> String {
        let percent = Int((e.overall * 100).rounded(.down))
        return L("\(percent) % of the whole build · running for \(BuildProgress.clock(e.elapsed))",
                 "\(percent) % des ganzen Baus · läuft seit \(BuildProgress.clock(e.elapsed))")
    }

    /// The label of the folded list of steps: “All 20 steps: 13 done, 1 running, 6 to come”.
    public func stepsSummary() -> String {
        let all = steps()
        var done = 0, running = 0, coming = 0
        for s in all {
            switch s.state {
            case .done, .skipped: done += 1
            case .running: running += 1
            case .pending, .willSkip: coming += 1
            }
        }
        return L("All \(all.count) steps: \(done) done, \(running) running, \(coming) to come",
                 "Alle \(all.count) Schritte: \(done) erledigt, \(running) läuft, \(coming) folgen")
    }

    /// How long a step still to come usually takes on this Mac, in words.
    public func usualText(_ i: Int, estimate e: Estimate) -> String {
        guard let step = entry(i) else { return "" }
        return BuildProgress.duration(step.seconds * (step.network ? e.networkScale : e.scale))
    }

    /// The plain name of the running step, with its number.
    public var headline: String? {
        current.map { BuildStepNames.headline(index: $0, count: max(count, $0), name: currentName) }
    }

    /// The plan as a display lists it: each step, and whether it is done, runs, or is still to come.
    public enum StepState: Sendable, Equatable { case done(seconds: Double?), skipped, running, pending, willSkip }
    public func steps() -> [(index: Int, name: String, state: StepState)] {
        let names: [String] = plan?.map(\.name) ?? (count > 0 ? (1...count).map { $0 == current ? currentName : "" } : [])
        return names.enumerated().map { k, name in
            let i = k + 1
            let state: StepState
            if skipped.contains(i) { state = .skipped }
            else if let s = ran[i] { state = .done(seconds: s) }
            else if i == current, finished == nil { state = .running }
            else if let c = current, i < c { state = .done(seconds: nil) }
            else if entry(i)?.done == true { state = .willSkip }
            else { state = .pending }
            return (i, name, state)
        }
    }

    /// One line for a log or a terminal: where the build is and how long it still takes.
    public func summary(at now: Date) -> String {
        let e = estimate(at: now)
        var parts = [headline ?? L("Starting", "Beginnt")]
        if waiting == "screen-locked" { parts.append(L("WAITING for this Mac to be unlocked", "WARTET, bis dieser Mac entsperrt ist")) }
        if let m = measure, let words = BuildProgress.countText(m) { parts.append(words) }
        if let s = e.step, measure?.unit != .seconds { parts.append(L("step \(Int((s * 100).rounded(.down))) %", "Schritt \(Int((s * 100).rounded(.down))) %")) }
        if e.slow { parts.append(L("taking longer than usual", "dauert länger als sonst")) }
        parts.append(L("whole build \(Int((e.overall * 100).rounded(.down))) %", "ganzer Bau \(Int((e.overall * 100).rounded(.down))) %"))
        if let left = e.remaining { parts.append(BuildProgress.pausable(BuildProgress.remainingText(left, atLeast: e.open), waiting != nil)) }
        return parts.joined(separator: " · ")
    }
}

/// Tells a job's log where a build is: the estimate once the plan is known, then each step as it begins, with the
/// time left for the whole build. Steps the builder skips are told together (“steps 1–13 of 20 already done”).
public final class BuildNarrator: @unchecked Sendable {
    private let lock = NSLock()
    private let report: @Sendable (String) -> Void
    private var toldPlan = false
    private var toldStep: Int?
    private var skippedRun: ClosedRange<Int>?
    private var toldEnd = false
    private var toldWait: String?

    public init(report: @escaping @Sendable (String) -> Void) { self.report = report }

    public func update(_ p: BuildProgress, at now: Date = Date()) {
        lock.lock()
        var lines: [String] = []
        if !toldPlan, let plan = p.plan {
            toldPlan = true
            let done = plan.filter(\.done).count
            let e = p.estimate(at: now)
            let left = e.remaining.map { BuildProgress.duration($0) } ?? "?"
            lines.append(done == 0
                ? L("  The build has \(plan.count) steps. Expected time on this Mac: \(left) (refined as it goes).",
                    "  Der Bau hat \(plan.count) Schritte. Erwartete Dauer auf diesem Mac: \(left) (wird unterwegs genauer).")
                : L("  The build has \(plan.count) steps, \(done) of them already done. Expected time on this Mac: \(left) (refined as it goes).",
                    "  Der Bau hat \(plan.count) Schritte, \(done) davon schon erledigt. Erwartete Dauer auf diesem Mac: \(left) (wird unterwegs genauer)."))
        }
        if let c = p.current, c != toldStep {
            toldStep = c
            if p.skipped.contains(c) {
                skippedRun = skippedRun.map { $0.lowerBound...c } ?? c...c
            } else {
                if let line = flushSkipped(count: p.count) { lines.append(line) }
                var line = "  " + BuildStepNames.headline(index: c, count: max(p.count, c), name: p.currentName)
                if BuildStepNames.title(p.currentName) != nil { line += " [\(p.currentName)]" }
                if let left = p.estimate(at: now).remaining { line += " · " + BuildProgress.remainingText(left) }
                lines.append(line)
            }
        }
        if p.waiting != toldWait {
            if p.waiting != nil, let text = p.waitText { lines.append("  " + text) }
            else if toldWait != nil { lines.append(L("  The wait is over; the build goes on.", "  Das Warten ist vorbei; der Bau geht weiter.")) }
            toldWait = p.waiting
        }
        if p.finished != nil, !toldEnd {
            toldEnd = true
            if let line = flushSkipped(count: p.count) { lines.append(line) }
        }
        lock.unlock()
        for line in lines { report(line) }
    }

    private func flushSkipped(count: Int) -> String? {
        guard let run = skippedRun else { return nil }
        skippedRun = nil
        return run.count == 1
            ? L("  step \(run.lowerBound) of \(count) already done", "  Schritt \(run.lowerBound) von \(count) schon erledigt")
            : L("  steps \(run.lowerBound)–\(run.upperBound) of \(count) already done", "  Schritte \(run.lowerBound)–\(run.upperBound) von \(count) schon erledigt")
    }
}
