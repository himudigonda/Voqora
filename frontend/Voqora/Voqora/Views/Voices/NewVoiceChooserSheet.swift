import SwiftUI

struct NewVoiceChooserSheet: View {
    @ObservedObject var store: VoiceBlendStore
    @ObservedObject var engines: SpeechEngineStore
    let choose: (NewVoiceSheet) -> Void

    private var mingBadge: String? {
        engines.mingNeedsInstall ? "Needs Ming (\(engines.mingSizeLabel))" : nil
    }

    var body: some View {
        VoqoraSheet(
            title: "New Voice",
            supporting: "How do you want to make it?",
            width: 760
        ) {
            HStack(alignment: .top, spacing: Theme.Space.item) {
                OptionCard(
                    title: "Blend voices",
                    supporting: "Mix two or more built-in voices. Instant and works everywhere.",
                    systemImage: "slider.horizontal.3",
                    badge: store.canCreateMore ? nil : "Limit reached"
                ) {
                    if store.canCreateMore {
                        choose(.blend(nil))
                    }
                }
                OptionCard(
                    title: "Describe a voice",
                    supporting: "Type what it should sound like. Uses Ming.",
                    systemImage: "wand.and.stars",
                    badge: mingBadge
                ) {
                    choose(.describe)
                }
                OptionCard(
                    title: "Clone a voice",
                    supporting: "Use a 3–30 second recording you have rights to. Uses Ming.",
                    systemImage: "waveform.badge.mic",
                    badge: mingBadge
                ) {
                    choose(.clone)
                }
            }
        }
    }
}
