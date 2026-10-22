#if DEBUG
    import Foundation

    struct DemoRandom: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    enum UsageStatsDemo {
        static let environmentKey = "VOQORA_STATS_DEMO"
        static let dayCount = 120

        enum Variant: String {
            case full = "1"
            case speech
            case empty
        }

        static var variant: Variant? {
            ProcessInfo.processInfo.environment[environmentKey].flatMap(Variant.init(rawValue:))
        }

        static var isRequested: Bool {
            variant != nil
        }

        static let books: [String: StatsBookInfo] = [
            "demo-book-1": StatsBookInfo(title: "Thinking, Fast and Slow", totalSeconds: 72000, progress: 0.34),
            "demo-book-2": StatsBookInfo(title: "The Overstory", totalSeconds: 79200, progress: 0.71),
            "demo-book-3": StatsBookInfo(title: "Project Hail Mary", totalSeconds: 57600, progress: 1),
            "demo-book-4": StatsBookInfo(title: "Designing Data-Intensive Applications", totalSeconds: 64800, progress: 0.22),
            "demo-book-5": StatsBookInfo(title: "A Short History of Nearly Everything", totalSeconds: 50400, progress: 0.58),
        ]

        static func ledger(now: Date, calendar: Calendar, variant: Variant = .full) -> UsageLedger {
            guard variant != .empty else { return UsageLedger() }
            var generator = DemoGenerator(now: now, calendar: calendar, speechOnly: variant == .speech)
            return generator.build()
        }
    }

    private struct ProviderProfile {
        let value: String
        let weight: Double
        let latency: Double
    }

    private struct EngineProfile {
        let id: String
        let realTime: ClosedRange<Double>
        let firstAudioMs: ClosedRange<Double>
        let failureRate: Double
    }

    private struct DemoGenerator {
        let now: Date
        let calendar: Calendar
        let speechOnly: Bool
        var random = DemoRandom(seed: 0xC0FFEE)
        var ledger = UsageLedger()

        private static let voices: [(id: String, weight: Double)] = [
            ("af_heart", 22), ("af_bella", 14), ("bm_george", 10), ("am_michael", 9), ("bf_emma", 7), ("af_nicole", 5),
            ("supertonic:F1", 8), ("supertonic:M1", 6), ("ming:Maya", 4),
        ]
        private static let engines: [String: EngineProfile] = [
            SpeechEngineID.kokoro: EngineProfile(id: SpeechEngineID.kokoro, realTime: 11 ... 16, firstAudioMs: 160 ... 520, failureRate: 0.004),
            SpeechEngineID.supertonic: EngineProfile(id: SpeechEngineID.supertonic, realTime: 6 ... 9, firstAudioMs: 380 ... 1300, failureRate: 0.015),
            SpeechEngineID.ming: EngineProfile(id: SpeechEngineID.ming, realTime: 1.4 ... 3.5, firstAudioMs: 2200 ... 5200, failureRate: 0.07),
        ]
        private static let speeds: [(value: Double, weight: Double)] = [
            (0.9, 3), (1.0, 18), (1.1, 6), (1.25, 22), (1.5, 26), (1.75, 12), (2.0, 8),
        ]
        private static let sources: [(value: SpeechSource, weight: Double)] = [
            (.selection, 38), (.shortcut, 14), (.clipboard, 11), (.relay, 11), (.ai, 8), (.reader, 8), (.screen, 4), (.inbox, 3), (.app, 3),
        ]
        private static let relayClients: [(value: String, weight: Double)] = [
            ("Claude Code", 40), ("Cursor", 22), ("Codex", 16), ("Raycast", 10), ("ChatGPT", 8), ("VS Code", 6),
        ]
        private static let dictationApps: [(value: String, weight: Double)] = [
            ("Slack", 24), ("Mail", 18), ("Notes", 14), ("Safari", 10), ("Xcode", 10), ("Messages", 9), ("Obsidian", 8), ("Notion", 7),
        ]
        private static let languages: [(value: String, weight: Double)] = [("en", 84), ("es", 7), ("hi", 4), ("fr", 3), ("de", 2)]
        private static let outcomes: [(value: String, weight: Double)] = [
            ("pasted", 72), ("copied", 8), ("copied_needs_accessibility", 4), ("copied_app_changed", 6),
        ]
        private static let tools: [(value: String, weight: Double)] = [
            ("summarize", 30), ("ask", 25), ("tidy", 15), ("translate", 12), ("quiz", 8), ("flashcards", 5), ("podcast_script", 5),
        ]
        private static let providers: [ProviderProfile] = [
            ProviderProfile(value: "anthropic", weight: 36, latency: 2200),
            ProviderProfile(value: "openai", weight: 34, latency: 1900),
            ProviderProfile(value: "ollama", weight: 14, latency: 3600),
            ProviderProfile(value: "groq", weight: 9, latency: 700),
            ProviderProfile(value: "google", weight: 7, latency: 1500),
        ]
        private static let importKinds: [(value: String, weight: Double)] = [
            ("pdf", 36), ("epub", 18), ("web", 16), ("docx", 8), ("txt", 6), ("md", 6), ("inbox", 5), ("text", 5),
        ]
        private static let weekdayHours: [(value: Int, weight: Double)] = [
            (7, 2), (8, 7), (9, 12), (10, 12), (11, 9), (12, 4), (13, 7), (14, 9), (15, 8), (16, 7), (17, 5), (19, 3), (20, 5), (21, 6), (22, 3),
        ]
        private static let weekendHours: [(value: Int, weight: Double)] = [
            (9, 3), (10, 8), (11, 9), (12, 5), (14, 5), (15, 7), (16, 7), (19, 4), (20, 7), (21, 8), (22, 6), (23, 2),
        ]

        init(now: Date, calendar: Calendar, speechOnly: Bool) {
            self.now = now
            self.calendar = calendar
            self.speechOnly = speechOnly
        }

        mutating func build() -> UsageLedger {
            let today = calendar.startOfDay(for: now)
            for offset in (0 ..< UsageStatsDemo.dayCount).reversed() {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                generate(day: day, offset: offset)
            }
            ledger.importedHistory = true
            ledger.importedDictation = true
            return ledger
        }

        private mutating func generate(day: Date, offset: Int) {
            let weekday = calendar.component(.weekday, from: day)
            let isWeekend = weekday == 1 || weekday == 7
            let forced = offset < 17
            let active = forced || chance(isWeekend ? 0.6 : 0.9)
            guard active else { return }
            ledger.recordLaunch(at: moment(on: day, weekend: isWeekend), calendar: calendar)
            generateSpeech(day: day, isWeekend: isWeekend, forced: forced)
            generateListening(day: day, offset: offset, isWeekend: isWeekend)
            guard !speechOnly else { return }
            generateDictation(day: day, offset: offset, isWeekend: isWeekend)
            generateAI(day: day, isWeekend: isWeekend)
            generateCreation(day: day)
            if chance(0.08) {
                ledger.recordExport(at: moment(on: day, weekend: isWeekend), calendar: calendar)
            }
        }

        private mutating func generateSpeech(day: Date, isWeekend: Bool, forced: Bool) {
            var count = isWeekend ? Int.random(in: 0 ... 4, using: &random) : Int.random(in: 2 ... 8, using: &random)
            if forced {
                count = max(count, 1)
            }
            for _ in 0 ..< count {
                let voice = pick(Self.voices.map { ($0.id, $0.weight) })
                let engineKey = SpeechEngineID.engine(forVoice: voice)
                guard let profile = Self.engines[engineKey] else { continue }
                let date = moment(on: day, weekend: isWeekend)
                if !speechOnly, chance(profile.failureRate * 4) {
                    ledger.recordSpeechFailure(engine: engineKey, at: date, calendar: calendar)
                }
                let words = lognormalWords(low: 30, high: 700)
                let speed = pick(Self.speeds.map { ($0.value, $0.weight) })
                let audioSeconds = Double(words) / (165 * speed) * 60 * Double.random(in: 0.92 ... 1.08, using: &random)
                let source = pick(Self.sources.map { ($0.value, $0.weight) })
                let run = SpeechRun(
                    engine: engineKey,
                    source: source,
                    firstAudioMs: Double.random(in: profile.firstAudioMs, using: &random),
                    renderSeconds: audioSeconds / Double.random(in: profile.realTime, using: &random)
                )
                let sample = SpeechSample(text: String(repeating: "word ", count: words), voice: voice, speed: speed, audioSeconds: audioSeconds)
                ledger.recordSpeech(sample, run: speechOnly ? nil : run, at: date, calendar: calendar)
                if source == .relay, !speechOnly {
                    ledger.recordRelay(client: pick(Self.relayClients.map { ($0.value, $0.weight) }), at: date, calendar: calendar)
                }
            }
        }

        private mutating func generateListening(day: Date, offset: Int, isWeekend: Bool) {
            guard chance(isWeekend ? 0.7 : 0.5) else { return }
            let primary = (offset / 24) % 5 + 1
            for _ in 0 ..< Int.random(in: 1 ... 2, using: &random) {
                let book = chance(0.75) ? primary : Int.random(in: 1 ... 5, using: &random)
                let seconds = Double.random(in: 600 ... 4800, using: &random)
                let date = moment(on: day, weekend: isWeekend, evening: true)
                ledger.recordListening(bookID: "demo-book-\(book)", seconds: seconds, at: date, calendar: calendar)
            }
        }

        private mutating func generateDictation(day: Date, offset: Int, isWeekend: Bool) {
            guard chance(isWeekend ? 0.55 : 0.88) else { return }
            let count = isWeekend ? Int.random(in: 1 ... 4, using: &random) : Int.random(in: 2 ... 14, using: &random)
            let trend = 112 + Double(UsageStatsDemo.dayCount - offset) * 0.08
            for _ in 0 ..< count {
                let date = moment(on: day, weekend: isWeekend)
                if chance(0.10) {
                    ledger.recordDictationCancelled(at: date, calendar: calendar)
                    continue
                }
                let words = lognormalWords(low: 6, high: 320)
                let wpm = trend + Double.random(in: -12 ... 12, using: &random)
                let session = DictationSession(
                    text: String(repeating: "word ", count: words),
                    seconds: Double(words) / wpm * 60,
                    outcome: pick(Self.outcomes.map { ($0.value, $0.weight) }),
                    language: pick(Self.languages.map { ($0.value, $0.weight) }),
                    app: pick(Self.dictationApps.map { ($0.value, $0.weight) }),
                    tidied: chance(0.32)
                )
                ledger.recordDictation(session, at: date, calendar: calendar)
            }
        }

        private mutating func generateAI(day: Date, isWeekend: Bool) {
            guard chance(isWeekend ? 0.4 : 0.9) else { return }
            let count = isWeekend ? Int.random(in: 1 ... 2, using: &random) : Int.random(in: 1 ... 7, using: &random)
            for _ in 0 ..< count {
                let provider = Self.providers[pickIndex(Self.providers.map(\.weight))]
                let run = AIRun(
                    tool: pick(Self.tools.map { ($0.value, $0.weight) }),
                    provider: provider.value,
                    ok: chance(0.955),
                    latencyMs: provider.latency * Double.random(in: 0.65 ... 1.35, using: &random),
                    wordsIn: Int.random(in: 40 ... 900, using: &random),
                    wordsOut: Int.random(in: 20 ... 300, using: &random)
                )
                ledger.recordAI(run, at: moment(on: day, weekend: isWeekend), calendar: calendar)
            }
        }

        private mutating func generateCreation(day: Date) {
            let date = moment(on: day, weekend: false)
            if chance(0.14) {
                let audio = Double.random(in: 5400 ... 64800, using: &random)
                ledger.recordBookGenerated(
                    chapters: Int.random(in: 6 ... 34, using: &random),
                    audioSeconds: audio,
                    renderSeconds: audio / Double.random(in: 7 ... 14, using: &random),
                    at: date,
                    calendar: calendar
                )
            }
            if chance(0.10) {
                ledger.recordBookFinished(at: date, calendar: calendar)
            }
            if chance(0.08) {
                ledger.recordPodcastScript(at: date, calendar: calendar)
            }
            if chance(0.06) {
                ledger.recordPodcastRender(speakers: Int.random(in: 2 ... 3, using: &random), audioSeconds: Double.random(in: 420 ... 1800, using: &random), at: date, calendar: calendar)
            }
            if chance(0.07) {
                ledger.recordM4BExport(at: date, calendar: calendar)
            }
            if chance(0.30) {
                ledger.recordImport(kind: pick(Self.importKinds.map { ($0.value, $0.weight) }), at: date, calendar: calendar)
                ledger.recordDocumentAdded(pages: Int.random(in: 4 ... 320, using: &random), at: date, calendar: calendar)
            }
        }

        private mutating func chance(_ probability: Double) -> Bool {
            Double.random(in: 0 ..< 1, using: &random) < probability
        }

        private mutating func pickIndex(_ weights: [Double]) -> Int {
            var roll = Double.random(in: 0 ..< weights.reduce(0, +), using: &random)
            for (index, weight) in weights.enumerated() {
                roll -= weight
                if roll < 0 {
                    return index
                }
            }
            return weights.count - 1
        }

        private mutating func pick<T>(_ items: [(T, Double)]) -> T {
            items[pickIndex(items.map(\.1))].0
        }

        private mutating func lognormalWords(low: Double, high: Double) -> Int {
            Int(exp(Double.random(in: log(low) ... log(high), using: &random)))
        }

        private mutating func moment(on day: Date, weekend: Bool, evening: Bool = false) -> Date {
            let table = weekend ? Self.weekendHours : Self.weekdayHours
            let hour = evening ? [7, 8, 12, 17, 18, 21, 22].randomElement(using: &random) ?? 21 : pick(table.map { ($0.value, $0.weight) })
            return calendar.date(bySettingHour: hour, minute: Int.random(in: 0 ... 59, using: &random), second: 0, of: day) ?? day
        }
    }
#endif
