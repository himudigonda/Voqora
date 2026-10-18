import SwiftUI

struct PodcastScriptEditorView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var studio: StudioViewModel
    @ObservedObject var editor: PodcastScriptEditor
    @FocusState private var focusedTurn: PodcastTurn.ID?

    var body: some View {
        let issues = editor.issues
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, DesignTokens.Spacing.md)
            List {
                Section {
                    speakersTable(issues: issues)
                } header: {
                    PaneSectionHeader(title: "Speakers")
                }
                Section {
                    turnRows(issues: issues)
                    addTurnButton
                } header: {
                    PaneSectionHeader(title: "Script · \(editor.script.turns.count) of \(PodcastLimits.turns.upperBound) turns")
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            PodcastRenderBar(editor: editor, issues: issues)
                .padding(.horizontal, 32)
                .padding(.vertical, DesignTokens.Spacing.md)
        }
        .onDisappear {
            if editor.hasUnsavedChanges {
                editor.save()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack {
                Button {
                    studio.goHome()
                } label: {
                    Label("Studio", systemImage: "chevron.left")
                        .font(vm.font(.rowTitle))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel("Back to Studio")
                Spacer()
                Text(saveStatus)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textTertiary)
                Button("Save") { editor.save() }
                    .buttonStyle(.voqoraSecondary)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save this script on your Mac (Command-S)")
            }
            TextField("Title", text: $editor.script.title)
                .textFieldStyle(.plain)
                .font(vm.font(.pageTitle))
                .foregroundStyle(Palette.textPrimary)
                .accessibilityLabel("Script title")
            Text(summary)
                .font(vm.appFont(size: 14))
                .foregroundStyle(Palette.textSecondary)
            if let notice = editor.notice {
                StudioBanner(message: notice, tint: Palette.textSecondary, systemImage: "info.circle.fill") {
                    editor.notice = nil
                }
            }
        }
    }

    private var saveStatus: String {
        editor.hasUnsavedChanges ? "Editing…" : "Saved on this Mac"
    }

    private var summary: String {
        let minutes = max(1, Int((editor.script.estimatedAudioSeconds / 60).rounded()))
        let speakers = editor.script.speakers.count
        return "\(speakers) \(speakers == 1 ? "speaker" : "speakers") · about \(minutes) min of audio"
    }

    private func speakersTable(issues: [PodcastScriptIssue]) -> some View {
        let groups = StudioVoiceCatalog.groups(blends: studio.blends)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ForEach(Array(editor.script.speakers.enumerated()), id: \.element.id) { index, speaker in
                HStack(spacing: DesignTokens.Spacing.md) {
                    TextField("Name", text: speakerNameBinding(speaker.id))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Speaker \(index + 1) name")
                    StudioVoicePicker(
                        title: "Voice for \(speaker.name)",
                        selection: speakerVoiceBinding(speaker.id),
                        groups: groups,
                        blends: studio.blends
                    )
                    .frame(maxWidth: 240)
                    StudioPreviewButton(previewer: studio.previewer, voice: speaker.voice, speakerName: speaker.name, blends: studio.blends)
                    Text(turnCountLabel(for: speaker.id))
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textTertiary)
                    Spacer(minLength: 0)
                    if editor.canRemoveSpeaker {
                        Button {
                            editor.removeSpeaker(id: speaker.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove speaker. Their turns move to the first speaker.")
                        .accessibilityLabel("Remove \(speaker.name)")
                    }
                }
                ForEach(issues.filter { $0.speakerIndex == index }, id: \.self) { issue in
                    StudioIssueLabel(message: issue.message)
                }
            }
            HStack {
                Button {
                    editor.addSpeaker(voice: StudioVoiceCatalog.suggestedVoice(excluding: editor.script.speakers.map(\.voice), blends: studio.blends))
                } label: {
                    Label("Add Speaker", systemImage: "person.badge.plus")
                }
                .buttonStyle(.voqoraSecondary)
                .disabled(!editor.canAddSpeaker)
                Text("Up to \(PodcastLimits.speakers.upperBound) speakers. Each can use any voice or blend.")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textTertiary)
            }
            StudioPreviewErrorLabel(previewer: studio.previewer)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private func turnRows(issues: [PodcastScriptIssue]) -> some View {
        let positions = Dictionary(uniqueKeysWithValues: editor.script.turns.enumerated().map { ($1.id, $0) })
        let issuesByTurn = PodcastScriptValidator.issuesByTurn(issues)
        ForEach($editor.script.turns) { $turn in
            let index = positions[turn.id] ?? 0
            PodcastTurnRow(
                turn: $turn,
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
        .onMove { source, destination in
            editor.moveTurns(fromOffsets: source, toOffset: destination)
        }
    }

    private var turnActions: PodcastTurnRow.Actions {
        PodcastTurnRow.Actions(
            insertBelow: { id in focusedTurn = editor.insertTurn(after: id) },
            delete: { id in editor.deleteTurn(id) },
            move: { id, offset in editor.moveTurn(id, by: offset) },
            setChapter: { id, title in editor.setChapter(title, forTurn: id) }
        )
    }

    private var addTurnButton: some View {
        Button {
            focusedTurn = editor.insertTurn(after: editor.script.turns.last?.id)
        } label: {
            Label("Add Turn", systemImage: "plus")
        }
        .buttonStyle(.voqoraSecondary)
        .disabled(!editor.canAddTurn)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private func turnCountLabel(for speakerID: String) -> String {
        let count = editor.script.turns.count { $0.speakerID == speakerID }
        return "\(count) \(count == 1 ? "turn" : "turns")"
    }

    private func speakerNameBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { editor.script.speaker(withID: id)?.name ?? "" },
            set: { name in
                if let index = editor.script.speakers.firstIndex(where: { $0.id == id }) {
                    editor.script.speakers[index].name = name
                }
            }
        )
    }

    private func speakerVoiceBinding(_ id: String) -> Binding<String> {
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

struct StudioIssueLabel: View {
    @EnvironmentObject var vm: DashboardViewModel
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(vm.font(.rowSubtitle))
            .foregroundStyle(Palette.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PodcastTurnRow: View {
    struct Actions {
        let insertBelow: (PodcastTurn.ID) -> Void
        let delete: (PodcastTurn.ID) -> Void
        let move: (PodcastTurn.ID, Int) -> Void
        let setChapter: (PodcastTurn.ID, String?) -> Void
    }

    @EnvironmentObject var vm: DashboardViewModel
    @Binding var turn: PodcastTurn
    let index: Int
    let speakers: [PodcastSpeaker]
    let issues: [PodcastScriptIssue]
    let isFirst: Bool
    let isLast: Bool
    let canInsert: Bool
    var focusedTurn: FocusState<PodcastTurn.ID?>.Binding
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Palette.textTertiary)
                    .help("Drag to reorder")
                    .accessibilityHidden(true)
                Text("\(index + 1)")
                    .font(vm.font(.rowSubtitle))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                    .frame(minWidth: 24, alignment: .trailing)
                    .accessibilityHidden(true)
                Picker("Speaker", selection: $turn.speakerID) {
                    if !speakers.contains(where: { $0.id == turn.speakerID }) {
                        Text("Choose a speaker").tag(turn.speakerID)
                    }
                    ForEach(speakers) { speaker in
                        Text(speaker.name.isEmpty ? "Unnamed speaker" : speaker.name).tag(speaker.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .accessibilityLabel("Speaker for turn \(index + 1)")
                Spacer(minLength: 0)
                Stepper(value: $turn.pauseAfterSeconds, in: PodcastLimits.pauseSeconds, step: 0.1) {
                    Text("Pause \(turn.pauseAfterSeconds.formatted(.number.precision(.fractionLength(1)))) s")
                        .font(vm.font(.rowSubtitle))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }
                .help("Silence after this turn")
                .accessibilityLabel("Pause after turn \(index + 1)")
                .accessibilityValue("\(turn.pauseAfterSeconds.formatted(.number.precision(.fractionLength(1)))) seconds")
                menu
            }
            if let section = turn.section {
                TextField("Chapter title", text: Binding(get: { section }, set: { turn.section = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(vm.font(.rowTitle))
                    .accessibilityLabel("Chapter title starting at turn \(index + 1)")
            }
            TextField(placeholder, text: $turn.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(vm.appFont(size: 14))
                .lineLimit(1 ... 12)
                .focused(focusedTurn, equals: turn.id)
                .padding(DesignTokens.Spacing.sm)
                .voqoraSurface(.control, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
                .accessibilityLabel("Turn \(index + 1) text")
            HStack {
                ForEach(issues, id: \.self) { issue in
                    StudioIssueLabel(message: issue.message)
                }
                Spacer(minLength: 0)
                if length > PodcastLimits.turnCharacters - 200 {
                    Text("\(length) / \(PodcastLimits.turnCharacters)")
                        .font(vm.font(.caption))
                        .monospacedDigit()
                        .foregroundStyle(length > PodcastLimits.turnCharacters ? Palette.danger : Palette.textTertiary)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn \(index + 1), \(speakerName)")
        .accessibilityAction(named: "Move Up") { actions.move(turn.id, -1) }
        .accessibilityAction(named: "Move Down") { actions.move(turn.id, 1) }
        .contextMenu { menuItems }
    }

    private var length: Int {
        PodcastLimits.length(of: turn.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var speakerName: String {
        speakers.first { $0.id == turn.speakerID }?.name ?? "No speaker"
    }

    private var placeholder: String {
        "What does \(speakerName) say?"
    }

    private var menu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Turn options")
        .accessibilityLabel("Options for turn \(index + 1)")
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

struct PodcastRenderBar: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject var editor: PodcastScriptEditor
    let issues: [PodcastScriptIssue]
    @State private var showsIssues = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            status
            Spacer(minLength: DesignTokens.Spacing.md)
            if case .rendered = editor.renderState {
                Button("Show in Library") { vm.showLibrary() }
                    .buttonStyle(.voqoraSecondary)
            }
            Button {
                Task { await editor.render() }
            } label: {
                if editor.renderState == .rendering {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Starting…")
                    }
                } else {
                    Text(isRendered ? "Render Again" : "Render Podcast")
                }
            }
            .buttonStyle(.voqoraPrimary)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!editor.canRender)
            .help("Narrate this script and add it to your Library (Command-R)")
        }
    }

    private var isRendered: Bool {
        if case .rendered = editor.renderState {
            return true
        }
        return false
    }

    @ViewBuilder
    private var status: some View {
        switch editor.renderState {
        case let .failed(message):
            StudioIssueLabel(message: message)
        case let .rendered(receipt):
            Label("\u{201C}\(receipt.title)\u{201D} is rendering in your Library.", systemImage: "checkmark.circle.fill")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.success)
        case .idle, .rendering:
            if issues.isEmpty {
                Text("Ready to render. Voqora narrates on your Mac, no AI needed.")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Button {
                    showsIssues.toggle()
                } label: {
                    Label(
                        "\(issues.count) \(issues.count == 1 ? "thing" : "things") to fix before rendering",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.warning)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsIssues, arrowEdge: .top) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                            ForEach(issues, id: \.self) { issue in
                                Text(issue.message)
                                    .font(vm.font(.rowSubtitle))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(DesignTokens.Spacing.lg)
                    }
                    .frame(width: 320)
                    .frame(maxHeight: 320)
                }
            }
        }
    }
}
