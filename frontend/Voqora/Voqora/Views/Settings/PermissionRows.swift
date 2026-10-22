import SwiftUI

struct PermissionRowPresentation: Equatable {
    enum Action: Equatable {
        case request
        case openSettings
    }

    let chipText: String
    let chipKind: StatusChipKind
    let chipImage: String
    let action: Action?
    let actionTitle: String?

    var isPrimaryAction: Bool {
        action == .request && chipKind == .neutral
    }

    init(kind: PermissionKind, state: PermissionState) {
        switch state {
        case .granted:
            chipText = "Allowed"
            chipKind = .success
            chipImage = "checkmark.circle.fill"
            action = nil
            actionTitle = nil
        case .denied:
            chipText = kind.isRequired ? "Needs access" : "Off"
            chipKind = kind.isRequired ? .danger : .warning
            chipImage = "xmark.circle.fill"
            action = kind == .accessibility ? .request : .openSettings
            actionTitle = "Open System Settings"
        case .notDetermined:
            chipText = "Not asked yet"
            chipKind = .neutral
            chipImage = "questionmark.circle"
            action = .request
            actionTitle = "Allow"
        case .unknown:
            chipText = "Checking…"
            chipKind = .neutral
            chipImage = "ellipsis.circle"
            action = nil
            actionTitle = nil
        }
    }
}

extension PermissionKind {
    var systemImage: String {
        switch self {
        case .accessibility: "hand.raised"
        case .notifications: "bell"
        case .microphone: "mic"
        case .speechRecognition: "waveform"
        case .screenRecording: "display"
        }
    }
}

struct PermissionRow: View {
    let kind: PermissionKind

    @EnvironmentObject var permissions: PermissionsService

    private var presentation: PermissionRowPresentation {
        PermissionRowPresentation(kind: kind, state: permissions.state(for: kind))
    }

    var body: some View {
        SettingsRowShell(title: kind.title, detail: kind.purpose, systemImage: kind.systemImage) {
            HStack(spacing: 10) {
                StatusChip(text: presentation.chipText, kind: presentation.chipKind, systemImage: presentation.chipImage)
                if let action = presentation.action, let title = presentation.actionTitle {
                    if presentation.isPrimaryAction {
                        Button(title) { perform(action) }
                            .buttonStyle(.voqoraFilled)
                    } else {
                        Button(title) { perform(action) }
                            .buttonStyle(.voqoraTonal)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func perform(_ action: PermissionRowPresentation.Action) {
        switch action {
        case .request:
            Task { await permissions.request(kind) }
        case .openSettings:
            permissions.openSettings(for: kind)
        }
    }
}
