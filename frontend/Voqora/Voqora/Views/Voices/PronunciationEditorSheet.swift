import SwiftUI

struct PronunciationEditorSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var store: PronunciationStore
    let editing: PronunciationEntry?
    let books: [PronunciationBookOption]
    @State private var draft: PronunciationDraft
    @State private var hasEdited = false
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var matchFocused: Bool

    init(store: PronunciationStore, editing: PronunciationEntry?, initialScope: PronunciationScope, books: [PronunciationBookOption]) {
        self.store = store
        self.editing = editing
        self.books = books
        _draft = State(initialValue: editing.map(PronunciationDraft.init(entry:)) ?? PronunciationDraft(scope: initialScope))
    }

    private var accent: Color {
        vm.accentColor(scheme: colorScheme, contrast: contrast)
    }

    private var visibleMessage: String? {
        errorMessage ?? (hasEdited ? draft.validationMessage : nil)
    }

    private var scopeChoices: [PronunciationBookOption] {
        guard case let .book(id) = draft.scope, !books.contains(where: { $0.id == id }) else { return books }
        return books + [PronunciationBookOption(id: id, title: "This book")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text(editing == nil ? "New Pronunciation" : "Edit Pronunciation")
                .font(vm.font(.sectionHeader))
                .foregroundStyle(accent)
                .accessibilityAddTraits(.isHeader)

            field("When Voqora sees") {
                TextField("SQL", text: $draft.match)
                    .textFieldStyle(.roundedBorder)
                    .font(vm.font(.rowTitle))
                    .focused($matchFocused)
                    .accessibilityLabel("Text to replace")
            }

            field("Say") {
                TextField("sequel", text: $draft.replacement)
                    .textFieldStyle(.roundedBorder)
                    .font(vm.font(.rowTitle))
                    .accessibilityLabel("Replacement")
            }

            Text("Leave Say empty to skip the text. Spell sounds out, like “keer-uh” for Ciara.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Toggle("Whole word only", isOn: $draft.wholeWord)
                Toggle("Match case", isOn: $draft.caseSensitive)
            }
            .toggleStyle(.checkbox)
            .font(vm.font(.rowTitle))

            field("Applies to") {
                Picker("Applies to", selection: $draft.scope) {
                    Text("Everywhere").tag(PronunciationScope.global)
                    if !scopeChoices.isEmpty {
                        Divider()
                        ForEach(scopeChoices) { book in
                            Text(book.title).tag(PronunciationScope.book(book.id))
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            if let visibleMessage {
                Label(visibleMessage, systemImage: "exclamationmark.circle.fill")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(errorMessage == nil ? Palette.warning : Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DesignTokens.Spacing.md) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.voqoraSecondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.voqoraPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid || saving)
            }
        }
        .padding(28)
        .frame(width: 440)
        .voqoraSurface(.floating, in: Rectangle())
        .onChange(of: draft) { _, _ in
            hasEdited = true
            errorMessage = nil
        }
        .onAppear { matchFocused = editing == nil }
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
            content()
        }
    }

    private func save() {
        guard !saving else { return }
        hasEdited = true
        guard draft.isValid else { return }
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                try await store.save(draft, editing: editing?.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
