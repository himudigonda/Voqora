import Foundation

struct SetupChecklistItem: Identifiable, Equatable {
    enum Gap: String {
        case accessibility
        case notifications
        case dictationAccess
        case aiProvider
        case analytics
    }

    let gap: Gap
    let title: String
    let detail: String
    let target: String

    var id: String {
        gap.rawValue
    }
}

enum SetupChecklist {
    static let permissionsTarget = TabKey.settings(.permissions)

    static func items(
        permissions: [PermissionKind: PermissionState],
        hasAIProvider: Bool,
        analyticsDecided: Bool,
        dictationEngine: DictationEngineChoice = .apple
    ) -> [SetupChecklistItem] {
        func state(_ kind: PermissionKind) -> PermissionState {
            permissions[kind] ?? .unknown
        }
        var items: [SetupChecklistItem] = []
        if isMissing(state(.accessibility)) {
            items.append(SetupChecklistItem(
                gap: .accessibility,
                title: "Turn on Accessibility",
                detail: "Needed to read selected text and paste dictation into other apps.",
                target: permissionsTarget
            ))
        }
        if state(.notifications) == .notDetermined {
            items.append(SetupChecklistItem(
                gap: .notifications,
                title: "Decide on notifications",
                detail: "Get told when an audiobook is ready.",
                target: permissionsTarget
            ))
        }
        let dictationKinds = DictationPermissionRows.kinds(for: dictationEngine).filter { $0 != .accessibility }
        if dictationKinds.contains(where: { isMissing(state($0)) }) {
            items.append(SetupChecklistItem(
                gap: .dictationAccess,
                title: "Allow dictation access",
                detail: dictationEngine == .apple
                    ? "Dictation needs Microphone and Speech Recognition."
                    : "Dictation needs the Microphone.",
                target: TabKey.settings(.dictation)
            ))
        }
        if !hasAIProvider {
            items.append(SetupChecklistItem(
                gap: .aiProvider,
                title: "Connect an AI provider",
                detail: "Optional. Powers cleanup, summaries, and translation.",
                target: TabKey.settings(.ai)
            ))
        }
        if !analyticsDecided {
            items.append(SetupChecklistItem(
                gap: .analytics,
                title: "Choose on usage analytics",
                detail: "Off until you switch it on.",
                target: TabKey.settings(.privacy)
            ))
        }
        return items
    }

    static func analyticsDecided(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: MetricsService.analyticsEnabledKey) != nil
    }

    private static func isMissing(_ state: PermissionState) -> Bool {
        state == .denied || state == .notDetermined
    }
}
