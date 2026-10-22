import AppKit
import SwiftUI

struct OnboardingPrivacyStep: View {
    @Binding var identityDraft: IdentityDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            OnboardingCallout(systemImage: "lock.fill", text: OnboardingCopy.privacyLocalNote)
            SettingsSection(title: "Usage analytics", footer: OnboardingCopy.analyticsFooter) {
                AnalyticsSettingRow()
            }
            IdentityFormSection(draft: $identityDraft, requiresSave: false)
            Button(OnboardingCopy.privacyPolicyTitle) { NSWorkspace.shared.open(OnboardingCopy.privacyPolicyURL) }
                .buttonStyle(.voqoraText)
        }
    }
}
