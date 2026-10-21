import SwiftUI

struct AIReadingSettings: View {
    @AppStorage(AIReadingPreferences.translateTargetKey) private var storedTarget = ""

    private var target: Binding<AILanguage> {
        Binding(
            get: {
                AILanguage(rawValue: storedTarget)
                    ?? AIReadingPreferences.defaultTranslateTarget(preferredLanguages: Locale.preferredLanguages)
            },
            set: { storedTarget = $0.rawValue }
        )
    }

    var body: some View {
        SettingsSection(
            title: "Reading tools",
            footer: "Summaries, questions, quizzes and flashcards in the audiobook player, and the Summarize Selection and Translate Selection " +
                "shortcuts, use the provider selected above. Results are spoken with a voice that matches their language."
        ) {
            SettingsPickerRow(
                title: "Translate Selection Into",
                detail: "The language Translate Selection speaks.",
                systemImage: "character.bubble",
                valueLabel: target.wrappedValue.displayName
            ) {
                Picker("Translate Selection Into", selection: target) {
                    ForEach(AILanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.inline)
            }
        }
    }
}
