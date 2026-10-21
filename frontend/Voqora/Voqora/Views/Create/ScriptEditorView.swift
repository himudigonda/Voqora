import SwiftUI

struct ScriptEditorView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var studio: StudioViewModel
    @ObservedObject var editor: PodcastScriptEditor
    @Environment(\.voqoraTheme) private var theme
    @FocusState private var focusedTurn: PodcastTurn.ID?

    private var isRendered: Bool {
        if case .rendered = editor.renderState {
            return true
        }
        return false
    }

    var body: some View {
        let issues = editor.issues
        PageScaffold(
            title: "Edit Script",
            subtitle: "\(summary) · \(editor.hasUnsavedChanges ? "Editing…" : "Saved on this Mac")",
            accessory: { actions }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                if let notice = editor.notice {
                    StudioBanner(message: notice, tint: theme.onSurfaceVariant, systemImage: "info.circle.fill") {
                        editor.notice = nil
                    }
                }
                ScriptRenderStatus(editor: editor, issues: issues)
                titleField
                SpeakerStrip(editor: editor, issues: issues)
                turnsSection(issues: issues)
            }
        }
        .backButton("Scripts") {
            studio.closeEditor()
            vm.selectedTab = TabKey.createScripts
        }
        .onDisappear {
            if editor.hasUnsavedChanges {
                editor.save()
            }
        }
    }

    private var summary: String {
        let minutes = max(1, Int((editor.script.estimatedAudioSeconds / 60).rounded()))
        let speakers = editor.script.speakers.count
        return "\(speakers) \(speakers == 1 ? "speaker" : "speakers") · about \(minutes) min of audio"
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.item) {
            Button {
                editor.save()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.voqoraTonal)
            .keyboardShortcut("s", modifiers: .command)
            .help("Save this script on your Mac (Command-S)")
            if isRendered {
                Button("Show in Library") { vm.showLibrary() }
                    .buttonStyle(.voqoraTonal)
            }
            Button {
                Task { await editor.render() }
            } label: {
                if editor.renderState == .rendering {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting…")
                    }
                } else {
                    Text(isRendered ? "Render Again" : "Render Podcast")
                }
            }
            .buttonStyle(.voqoraFilled)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!editor.canRender)
            .help("Narrate this script and add it to your Library (Command-R)")
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title")
                .voqoraFont(.label)
                .foregroundStyle(theme.onSurfaceVariant)
            TextField("Title", text: $editor.script.title)
                .textFieldStyle(.plain)
                .voqoraFont(.headline)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 20)
                .frame(height: 56)
                .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
                .accessibilityLabel("Script title")
        }
    }

    private func turnsSection(issues: [PodcastScriptIssue]) -> some View {
        let positions = Dictionary(uniqueKeysWithValues: editor.script.turns.enumerated().map { ($1.id, $0) })
        let issuesByTurn = PodcastScriptValidator.issuesByTurn(issues)
        return VStack(alignment: .leading, spacing: Theme.Space.item) {
            Text("Script · \(editor.script.turns.count) of \(PodcastLimits.turns.upperBound) turns")
                .voqoraFont(.titleSmall)
                .foregroundStyle(theme.primary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            LazyVStack(alignment: .leading, spacing: Theme.Space.item) {
                ForEach(editor.script.turns) { turn in
                    let index = positions[turn.id] ?? 0
                    ScriptTurnCard(
                        turn: turnBinding(turn),
                        index: index,
                        speakers: editor.script.speakers,
                        issues: issuesByTurn[index] ?? [],
                        isFirst: index == 0,
                        isLast: index == editor.script.turns.count - 1,
                        canInsert: editor.canAddTurn,
                        focusedTurn: $focusedTurn,
                        actions: turnActions
                    )
                }
            }
            Button {
                focusedTurn = editor.insertTurn(after: editor.script.turns.last?.id)
            } label: {
                Label("Add Turn", systemImage: "plus")
            }
            .buttonStyle(.voqoraTonal)
            .disabled(!editor.canAddTurn)
        }
    }

    private var turnActions: ScriptTurnCard.Actions {
        ScriptTurnCard.Actions(
            insertBelow: { id in focusedTurn = editor.insertTurn(after: id) },
            delete: { id in
                if focusedTurn == id {
                    focusedTurn = nil
                }
                editor.deleteTurn(id)
            },
            move: { id, offset in editor.moveTurn(id, by: offset) },
            setChapter: { id, title in editor.setChapter(title, forTurn: id) }
        )
    }

    private func turnBinding(_ turn: PodcastTurn) -> Binding<PodcastTurn> {
        Binding(
            get: { editor.script.turns.first { $0.id == turn.id } ?? turn },
            set: { updated in
                if let index = editor.script.turns.firstIndex(where: { $0.id == turn.id }) {
                    editor.script.turns[index] = updated
                }
            }
        )
    }
}

struct ScriptRenderStatus: View {
    @ObservedObject var editor: PodcastScriptEditor
    let issues: [PodcastScriptIssue]

    @Environment(\.voqoraTheme) private var theme
    @State private var showsIssues = false

    var body: some View {
        HStack(spacing: Theme.Space.item) {
            icon
            content
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.item + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        switch editor.renderState {
        case .rendering:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger)
        case .rendered:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
        case .idle:
            Image(systemName: issues.isEmpty ? "waveform" : "exclamationmark.circle.fill")
                .foregroundStyle(issues.isEmpty ? theme.primary : theme.warning)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch editor.renderState {
        case let .failed(message):
            Text(message)
                .voqoraFont(.body)
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        case let .rendered(receipt):
            Text("\u{201C}\(receipt.title)\u{201D} is rendering in your Library.")
                .voqoraFont(.body)
                .foregroundStyle(theme.onSurface)
        case .rendering:
            Text("Starting the render…")
                .voqoraFont(.body)
                .foregroundStyle(theme.onSurface)
        case .idle:
            if issues.isEmpty {
                Text("Ready to render. Voqora narrates on your Mac, no AI needed.")
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
            } else {
                Button {
                    showsIssues.toggle()
                } label: {
                    Text("\(issues.count) \(issues.count == 1 ? "thing" : "things") to fix before rendering")
                        .voqoraFont(.body)
                        .foregroundStyle(theme.warning)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsIssues, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(issues, id: \.self) { issue in
                                Text(issue.message)
                                    .voqoraFont(.bodySmall)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(Theme.Space.item + 4)
                    }
                    .frame(width: 320)
                    .frame(maxHeight: 320)
                }
            }
        }
    }
}

struct SpeakerStrip: View {
    @ObservedObject var editor: PodcastScriptEditor
    let issues: [PodcastScriptIssue]

    @Environment(\.voqoraTheme) private var theme
    @ObservedObject private var blendStore = VoiceBlendStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            Text("Speakers")
                .voqoraFont(.titleSmall)
                .foregroundStyle(theme.primary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            FlowLayout {
                ForEach(editor.script.speakers) { speaker in
                    SpeakerChip(editor: editor, speaker: speaker)
                }
                AssistChip(title: "Add Speaker", systemImage: "person.badge.plus") {
                    editor.addSpeaker(voice: suggestedVoice())
                }
                .disabled(!editor.canAddSpeaker)
            }
            ForEach(Array(editor.script.speakers.enumerated()), id: \.element.id) { index, _ in
                ForEach(issues.filter { $0.speakerIndex == index }, id: \.self) { issue in
                    StudioIssueLabel(message: issue.message)
                }
            }
            Text("Up to \(PodcastLimits.speakers.upperBound) speakers. Tap one to change the name or voice.")
                .voqoraFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
        }
    }

    private func suggestedVoice() -> String {
        let blends = blendStore.blends.map { PodcastVoiceBlend(id: $0.id, name: $0.name, lang: $0.lang) }
        return StudioVoiceCatalog.suggestedVoice(excluding: editor.script.speakers.map(\.voice), blends: blends)
    }
}

private struct SpeakerChip: View {
    @ObservedObject var editor: PodcastScriptEditor
    let speaker: PodcastSpeaker

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @ObservedObject private var blendStore = VoiceBlendStore.shared
    @State private var isEditing = false

    private var voiceName: String {
        VoicePickerCatalog.descriptor(forVoice: speaker.voice, blends: blendStore.blends).name
    }

    private var displayName: String {
        speaker.name.isEmpty ? "Unnamed" : speaker.name
    }

    var body: some View {
        Button {
            isEditing = true
        } label: {
            HStack(spacing: 10) {
                StudioVoiceAvatar(name: displayName, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayName)
                        .voqoraFont(.label)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(voiceName)
                        .voqoraFont(.labelSmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(minHeight: 40)
            .background(theme.surfaceContainer, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(displayName), voice \(voiceName)")
        .accessibilityHint("Edit speaker")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            editor(for: speaker.id)
                .environmentObject(vm)
                .environment(\.voqoraTheme, theme)
        }
    }

    private func editor(for id: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            StudioCapsuleField(prompt: "Speaker name", text: nameBinding(id), label: "Speaker name")
            VoicePickerCard(title: "Voice", voiceID: voiceBinding(id), scope: .podcast(nil))
            HStack {
                Text(turnCountLabel(for: id))
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer()
                if editor.canRemoveSpeaker {
                    Button("Remove Speaker") {
                        isEditing = false
                        editor.removeSpeaker(id: id)
                    }
                    .buttonStyle(.voqoraText)
                    .help("Their turns move to the first speaker.")
                }
            }
        }
        .padding(Theme.Space.card)
        .frame(width: 400)
        .background(theme.surfaceContainerHigh)
    }

    private func turnCountLabel(for speakerID: String) -> String {
        let count = editor.script.turns.count { $0.speakerID == speakerID }
        return "\(count) \(count == 1 ? "turn" : "turns")"
    }

    private func nameBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { editor.script.speaker(withID: id)?.name ?? "" },
            set: { name in
                if let index = editor.script.speakers.firstIndex(where: { $0.id == id }) {
                    editor.script.speakers[index].name = name
                }
            }
        )
    }

    private func voiceBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { editor.script.speaker(withID: id)?.voice ?? "" },
            set: { voice in
                if let index = editor.script.speakers.firstIndex(where: { $0.id == id }) {
                    editor.script.speakers[index].voice = voice
                }
            }
        )
    }
}

struct ScriptTurnCard: View {
    struct Actions {
        let insertBelow: (PodcastTurn.ID) -> Void
        let delete: (PodcastTurn.ID) -> Void
        let move: (PodcastTurn.ID, Int) -> Void
        let setChapter: (PodcastTurn.ID, String?) -> Void
    }

    @Binding var turn: PodcastTurn
    let index: Int
    let speakers: [PodcastSpeaker]
    let issues: [PodcastScriptIssue]
    let isFirst: Bool
    let isLast: Bool
    let canInsert: Bool
    var focusedTurn: FocusState<PodcastTurn.ID?>.Binding
    let actions: Actions

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    private var length: Int {
        PodcastLimits.length(of: turn.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var speakerName: String {
        speakers.first { $0.id == turn.speakerID }?.name ?? "No speaker"
    }

    private var pauseLabel: String {
        "\(turn.pauseAfterSeconds.formatted(.number.precision(.fractionLength(1)))) s"
    }

    var body: some View {
        VoqoraCard {
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                header
                if let section = turn.section {
                    StudioCapsuleField(
                        prompt: "Chapter title",
                        text: Binding(get: { section }, set: { turn.section = $0 }),
                        label: "Chapter title starting at turn \(index + 1)"
                    )
                }
                TextEditor(text: $turn.text)
                    .voqoraFont(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 84)
                    .background(theme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
                    .focused(focusedTurn, equals: turn.id)
                    .overlay(alignment: .topLeading) {
                        if turn.text.isEmpty {
                            Text("What does \(speakerName) say?")
                                .voqoraFont(.body)
                                .foregroundStyle(theme.onSurfaceMuted)
                                .padding(.horizontal, 15)
                                .padding(.top, 10)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Turn \(index + 1) text")
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(issues, id: \.self) { issue in
                            StudioIssueLabel(message: issue.message)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("\(length) / \(PodcastLimits.turnCharacters)")
                        .voqoraFont(.labelSmall)
                        .monospacedDigit()
                        .foregroundStyle(length > PodcastLimits.turnCharacters ? theme.danger : theme.onSurfaceMuted)
                        .accessibilityLabel("\(length) of \(PodcastLimits.turnCharacters) characters")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn \(index + 1), \(speakerName)")
        .accessibilityAction(named: "Move Up") { actions.move(turn.id, -1) }
        .accessibilityAction(named: "Move Down") { actions.move(turn.id, 1) }
        .contextMenu { menuItems }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.item) {
            Text("\(index + 1)")
                .voqoraFont(.label)
                .monospacedDigit()
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 28, height: 28)
                .background(theme.primaryContainer, in: Circle())
                .accessibilityHidden(true)
            speakerMenu
            Spacer(minLength: 0)
            FilterChip(title: "Chapter", isSelected: turn.section != nil) {
                actions.setChapter(turn.id, turn.section == nil ? "" : nil)
            }
            pauseStepper
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.voqoraIcon)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Turn options")
            .accessibilityLabel("Options for turn \(index + 1)")
        }
    }

    private var speakerMenu: some View {
        Menu {
            ForEach(speakers) { speaker in
                Button {
                    turn.speakerID = speaker.id
                } label: {
                    if speaker.id == turn.speakerID {
                        Label(speaker.name.isEmpty ? "Unnamed speaker" : speaker.name, systemImage: "checkmark")
                    } else {
                        Text(speaker.name.isEmpty ? "Unnamed speaker" : speaker.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(speakers.contains { $0.id == turn.speakerID } ? (speakerName.isEmpty ? "Unnamed speaker" : speakerName) : "Choose a speaker")
                    .voqoraFont(.label)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(theme.onPrimaryContainer)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(theme.primaryContainer.opacity(0.65), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Speaker for turn \(index + 1)")
    }

    private var pauseStepper: some View {
        HStack(spacing: 4) {
            Button {
                turn.pauseAfterSeconds = max(PodcastLimits.pauseSeconds.lowerBound, (turn.pauseAfterSeconds - 0.1).rounded(toPlaces: 1))
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.voqoraIcon)
            .disabled(turn.pauseAfterSeconds <= PodcastLimits.pauseSeconds.lowerBound)
            .accessibilityLabel("Shorter pause after turn \(index + 1)")
            Text("Pause \(pauseLabel)")
                .voqoraFont(.labelSmall)
                .monospacedDigit()
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(minWidth: 70)
            Button {
                turn.pauseAfterSeconds = min(PodcastLimits.pauseSeconds.upperBound, (turn.pauseAfterSeconds + 0.1).rounded(toPlaces: 1))
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.voqoraIcon)
            .disabled(turn.pauseAfterSeconds >= PodcastLimits.pauseSeconds.upperBound)
            .accessibilityLabel("Longer pause after turn \(index + 1)")
        }
        .help("Silence after this turn")
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(pauseLabel)")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Insert Turn Below") { actions.insertBelow(turn.id) }
            .disabled(!canInsert)
        if turn.section == nil {
            Button("Start Chapter Here") { actions.setChapter(turn.id, "") }
        } else {
            Button("Remove Chapter") { actions.setChapter(turn.id, nil) }
        }
        Divider()
        Button("Move Up") { actions.move(turn.id, -1) }
            .disabled(isFirst)
        Button("Move Down") { actions.move(turn.id, 1) }
            .disabled(isLast)
        Divider()
        Button("Delete Turn", role: .destructive) { actions.delete(turn.id) }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
