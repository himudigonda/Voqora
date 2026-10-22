import SwiftUI

struct PronunciationEditorSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PronunciationStore
    let editing: PronunciationEntry?
    let books: [PronunciationBookOption]
    @State private var draft: PronunciationDraft
    @State private var hasEdited = false
    @State private var saving = false
    @State private var errorMessage: String?

    init(store: PronunciationStore, editing: PronunciationEntry?, initialScope: PronunciationScope, books: [PronunciationBookOption]) {
        self.store = store
        self.editing = editing
        self.books = books
        _draft = State(initialValue: editing.map(PronunciationDraft.init(entry:)) ?? PronunciationDraft(scope: initialScope))
    }

    private var visibleMessage: String? {
        errorMessage ?? (hasEdited ? draft.validationMessage : nil)
    }

    private var scopeChoices: [PronunciationBookOption] {
        guard case let .book(id) = draft.scope, !books.contains(where: { $0.id == id }) else { return books }
        return books + [PronunciationBookOption(id: id, title: "This book")]
    }

    private var scopeLabel: String {
        switch draft.scope {
        case .global: "Everywhere"
        case let .book(id): scopeChoices.first { $0.id == id }?.title ?? "This book"
        }
    }

    var body: some View {
        VoqoraSheet(
            title: editing == nil ? "New pronunciation" : "Edit pronunciation",
            supporting: "Leave “Say” empty to skip the text. Spell sounds out, like “keer-uh” for Ciara.",
            primaryTitle: saving ? "Saving…" : "Save",
            isPrimaryEnabled: draft.isValid && !saving,
            onPrimary: save
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                VoiceTextField(title: "When Voqora sees", prompt: "SQL", text: $draft.match)
                VoiceTextField(title: "Say", prompt: "sequel", text: $draft.replacement)
                ListGroup {
                    SettingsSwitchRow(title: "Whole word only", isOn: $draft.wholeWord)
                    SettingsSwitchRow(title: "Match case", isOn: $draft.caseSensitive)
                    SettingsPickerRow(title: "Applies to", valueLabel: scopeLabel) {
                        Button("Everywhere") { draft.scope = .global }
                        if !scopeChoices.isEmpty {
                            Divider()
                            ForEach(scopeChoices) { book in
                                Button(book.title) { draft.scope = .book(book.id) }
                            }
                        }
                    }
                }
                if let visibleMessage {
                    VoicesBanner(message: visibleMessage, isError: errorMessage != nil)
                }
            }
            .padding(.bottom, Theme.Space.unit)
        }
        .onChange(of: draft) { _, _ in
            hasEdited = true
            errorMessage = nil
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
