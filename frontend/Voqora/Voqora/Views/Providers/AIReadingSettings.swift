import SwiftUI

struct AIReadingSettings: View {
    @EnvironmentObject var vm: DashboardViewModel
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Reading tools")
                .font(vm.font(.rowTitle).weight(.semibold))
            HStack {
                Label("Translate Selection Into", systemImage: "character.bubble")
                    .font(vm.font(.rowTitle))
                Spacer()
                Picker("Translate Selection Into", selection: target) {
                    ForEach(AILanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            Text(
                "Summaries, questions, quizzes and flashcards in the audiobook player, and the Summarize Selection and Translate Selection " +
                    "shortcuts, use the provider selected above. Results are spoken with a voice that matches their language."
            )
            .font(vm.font(.rowSubtitle))
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
