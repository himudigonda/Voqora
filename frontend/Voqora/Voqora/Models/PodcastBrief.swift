import Foundation

enum PodcastSourceKind: String, CaseIterable, Identifiable {
    case library
    case text

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .library: "Library Item"
        case .text: "Text"
        }
    }
}

enum PodcastBriefIssue: Hashable {
    case missingBook
    case missingText
    case textTooLong(length: Int)
    case hostCount(PodcastStyle)
    case missingHostName(host: Int)
    case hostNameTooLong(host: Int)
    case duplicateHostNames
    case missingVoice(host: Int)
    case voiceLanguage(host: Int, language: PodcastLanguage)
    case titleTooLong

    var message: String {
        switch self {
        case .missingBook:
            "Choose a Library item to talk about."
        case .missingText:
            "Paste or type the text to talk about."
        case let .textTooLong(length):
            "The text has \(length.formatted()) characters. Keep it to \(PodcastLimits.sourceCharacters.formatted()) or fewer."
        case let .hostCount(style):
            style.allowedHostCounts.count == 1
                ? "\(style.displayName) needs exactly \(style.allowedHostCounts.lowerBound) \(style.allowedHostCounts.lowerBound == 1 ? "host" : "hosts")."
                : "\(style.displayName) needs one or two hosts."
        case let .missingHostName(host):
            "Host \(host + 1) needs a name."
        case let .hostNameTooLong(host):
            "Keep host \(host + 1)'s name to \(PodcastLimits.speakerNameCharacters) characters or fewer."
        case .duplicateHostNames:
            "Give each host a different name."
        case let .missingVoice(host):
            "Choose a voice for host \(host + 1)."
        case let .voiceLanguage(host, language):
            "Host \(host + 1)'s voice doesn't speak \(language.displayName). Choose a \(language.displayName) voice."
        case .titleTooLong:
            "Keep the title to \(PodcastLimits.titleCharacters) characters or fewer."
        }
    }
}

struct PodcastBrief: Equatable {
    var sourceKind: PodcastSourceKind = .text
    var bookID: String?
    var text = ""
    var style: PodcastStyle = .deepDive
    var minutes = PodcastLimits.defaultMinutes
    var language: PodcastLanguage = .englishUS
    var hosts: [PodcastHost]
    var title = ""

    init(language: PodcastLanguage = .englishUS) {
        self.language = language
        let voices = StudioVoiceCatalog.defaultVoices(for: language)
        let names = ["Avery", "Jordan"]
        hosts = zip(names, voices).map { PodcastHost(name: $0, voice: $1) }
    }

    var source: PodcastSource? {
        switch sourceKind {
        case .library:
            return bookID.map(PodcastSource.book)
        case .text:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
    }

    func issues(blends: [PodcastVoiceBlend]) -> [PodcastBriefIssue] {
        var issues = sourceIssues()
        if !style.allowedHostCounts.contains(hosts.count) {
            issues.append(.hostCount(style))
        }
        var seenNames: Set<String> = []
        var hasDuplicate = false
        for (index, host) in hosts.enumerated() {
            let name = PodcastText.singleLine(host.name)
            if name.isEmpty {
                issues.append(.missingHostName(host: index))
            } else if PodcastLimits.length(of: name) > PodcastLimits.speakerNameCharacters {
                issues.append(.hostNameTooLong(host: index))
            } else if !seenNames.insert(name.lowercased()).inserted {
                hasDuplicate = true
            }
            if host.voice.isEmpty {
                issues.append(.missingVoice(host: index))
            } else if !StudioVoiceCatalog.speaks(host.voice, language: language, blends: blends) {
                issues.append(.voiceLanguage(host: index, language: language))
            }
        }
        if hasDuplicate {
            issues.append(.duplicateHostNames)
        }
        if PodcastLimits.length(of: PodcastText.singleLine(title)) > PodcastLimits.titleCharacters {
            issues.append(.titleTooLong)
        }
        return issues
    }

    func request(blends: [PodcastVoiceBlend]) -> PodcastScriptRequest? {
        guard issues(blends: blends).isEmpty, let source else { return nil }
        let normalizedTitle = PodcastText.singleLine(title)
        return PodcastScriptRequest(
            source: source,
            style: style,
            minutes: min(max(minutes, PodcastLimits.minutes.lowerBound), PodcastLimits.minutes.upperBound),
            language: language,
            hosts: hosts.map { PodcastHost(name: PodcastText.singleLine($0.name), voice: $0.voice) },
            title: normalizedTitle.isEmpty ? nil : normalizedTitle
        )
    }

    mutating func applyStyle(_ newStyle: PodcastStyle) {
        style = newStyle
        let allowed = newStyle.allowedHostCounts
        if hosts.count > allowed.upperBound {
            hosts = Array(hosts.prefix(allowed.upperBound))
        } else if hosts.count < allowed.lowerBound {
            addHost()
        }
    }

    mutating func applyLanguage(_ newLanguage: PodcastLanguage, blends: [PodcastVoiceBlend]) {
        language = newLanguage
        let defaults = StudioVoiceCatalog.defaultVoices(for: newLanguage)
        for index in hosts.indices where !StudioVoiceCatalog.speaks(hosts[index].voice, language: newLanguage, blends: blends) {
            hosts[index].voice = defaults.indices.contains(index) ? defaults[index] : defaults.first ?? ""
        }
    }

    var canAddHost: Bool {
        hosts.count < min(style.allowedHostCounts.upperBound, PodcastLimits.hosts.upperBound)
    }

    var canRemoveHost: Bool {
        hosts.count > style.allowedHostCounts.lowerBound
    }

    mutating func addHost() {
        guard hosts.count < PodcastLimits.hosts.upperBound else { return }
        let defaults = StudioVoiceCatalog.defaultVoices(for: language)
        let used = Set(hosts.map(\.voice))
        let voice = defaults.first { !used.contains($0) } ?? defaults.first ?? ""
        let taken = Set(hosts.map { $0.name.lowercased() })
        let name = ["Avery", "Jordan", "Host 2"].first { !taken.contains($0.lowercased()) } ?? "Host \(hosts.count + 1)"
        hosts.append(PodcastHost(name: name, voice: voice))
    }

    mutating func removeHost(at index: Int) {
        guard hosts.indices.contains(index), hosts.count > 1 else { return }
        hosts.remove(at: index)
    }

    private func sourceIssues() -> [PodcastBriefIssue] {
        switch sourceKind {
        case .library:
            return bookID == nil ? [.missingBook] : []
        case .text:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return [.missingText]
            }
            let length = PodcastLimits.length(of: trimmed)
            return length > PodcastLimits.sourceCharacters ? [.textTooLong(length: length)] : []
        }
    }
}
