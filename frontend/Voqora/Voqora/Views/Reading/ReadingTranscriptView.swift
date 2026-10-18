import SwiftUI

struct ReadingTranscriptView: View {
    @ObservedObject var follower: TranscriptFollower
    @ObservedObject var preferences: ReadingPreferences
    let palette: ReadingPalette
    let onSelect: (TranscriptLine) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var document: ReadingDocument = .empty
    @State private var isFollowing = true
    @State private var resumeTask: Task<Void, Never>?

    private static let anchor = UnitPoint(x: 0, y: 0.4)

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(document.sentences) { sentence in
                            row(for: sentence)
                                .padding(.top, document.startsBlock(sentence.id) ? blockGap(for: sentence) : 0)
                                .id(sentence.id)
                        }
                    }
                    .padding(.top, geometry.size.height * Self.anchor.y)
                    .padding(.bottom, geometry.size.height * (1 - Self.anchor.y))
                    .frame(maxWidth: preferences.typography.measure, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.xxxl)
                    .frame(maxWidth: .infinity)
                    .background(ScrollInteractionMonitor(onUserScroll: userDidScroll))
                }
                .scrollIndicators(isFollowing ? .hidden : .automatic)
                .onChange(of: follower.revision, initial: true) { _, _ in
                    document = ReadingDocument(transcript: follower.document)
                    scroll(proxy, animated: false)
                    settle(proxy)
                }
                .onChange(of: follower.activeIndex) { old, new in
                    activeSentenceChanged(proxy, from: old, to: new)
                }
                .onChange(of: follower.isScrubbing) { _, scrubbing in
                    if scrubbing {
                        resumeFollowing()
                    }
                }
                .onChange(of: preferences.typography) { _, _ in scroll(proxy, animated: false) }
                .onChange(of: isFollowing) { _, following in
                    if following {
                        scroll(proxy, animated: true)
                    }
                }
            }
        }
        .onDisappear { resumeTask?.cancel() }
    }

    @ViewBuilder
    private func row(for sentence: ReadingSentence) -> some View {
        let isActive = follower.activeIndex == sentence.id
        let style = ReadingRowStyle(
            typography: preferences.typography,
            palette: palette,
            isActive: isActive,
            isDimmed: preferences.showsRuler && !isActive && follower.activeIndex != nil,
            animation: reduceMotion ? nil : .easeInOut(duration: 0.2)
        )
        if isActive, preferences.emphasizesWords, sentence.words != nil {
            ReadingTimedSentenceRow(document: document, sentence: sentence, follower: follower, style: style) {
                select(sentence)
            }
        } else {
            ReadingSentenceRow(sentence: sentence, emphasizedWord: nil, style: style) {
                select(sentence)
            }
        }
    }

    private func blockGap(for sentence: ReadingSentence) -> CGFloat {
        let size = CGFloat(preferences.typography.fontSize)
        return sentence.isHeading ? size * 1.6 : size * 0.8
    }

    private func select(_ sentence: ReadingSentence) {
        guard follower.document.lines.indices.contains(sentence.id) else { return }
        resumeFollowing()
        onSelect(follower.document.lines[sentence.id])
    }

    private func userDidScroll() {
        isFollowing = false
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: TranscriptView.resumeDelay)
            guard !Task.isCancelled else { return }
            isFollowing = true
        }
    }

    private func resumeFollowing() {
        resumeTask?.cancel()
        resumeTask = nil
        isFollowing = true
    }

    private func activeSentenceChanged(_ proxy: ScrollViewProxy, from old: Int?, to new: Int?) {
        if let old, let new, abs(new - old) > 1 {
            resumeFollowing()
        }
        scroll(proxy, animated: true)
    }

    private func settle(_ proxy: ScrollViewProxy) {
        guard isFollowing, let index = follower.activeIndex else { return }
        let anchor = Self.anchor
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: anchor)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard isFollowing, let index = follower.activeIndex else { return }
        if animated, !reduceMotion {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.88)) {
                proxy.scrollTo(index, anchor: Self.anchor)
            }
        } else {
            proxy.scrollTo(index, anchor: Self.anchor)
        }
    }
}

struct ReadingRowStyle {
    let typography: ReadingTypography
    let palette: ReadingPalette
    let isActive: Bool
    let isDimmed: Bool
    let animation: Animation?
}

private struct ReadingTimedSentenceRow: View {
    @EnvironmentObject private var audio: AudioService
    let document: ReadingDocument
    let sentence: ReadingSentence
    let follower: TranscriptFollower
    let style: ReadingRowStyle
    let onSelect: () -> Void

    var body: some View {
        let highlight = ReadingHighlighter.highlight(
            in: document,
            sentenceIndex: sentence.id,
            at: follower.documentTime,
            emphasizesWords: true
        )
        ReadingSentenceRow(sentence: sentence, emphasizedWord: highlight.wordIndex(inSentence: sentence.id), style: style, onSelect: onSelect)
    }
}

struct ReadingSentenceRow: View {
    let sentence: ReadingSentence
    let emphasizedWord: Int?
    let style: ReadingRowStyle
    let onSelect: () -> Void

    private var emphasisRange: Range<String.Index>? {
        guard let emphasizedWord, let words = sentence.words else { return nil }
        let ranges = ReadingWordLocator.ranges(of: words, in: sentence.text)
        return ranges.indices.contains(emphasizedWord) ? ranges[emphasizedWord] : nil
    }

    var body: some View {
        Text(ReadingTextStyler.attributed(sentence.text, typography: style.typography, palette: style.palette, emphasis: emphasisRange))
            .font(style.typography.font(isHeading: sentence.isHeading))
            .lineSpacing(style.typography.lineSpacing)
            .foregroundStyle(Color(style.palette.text))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, CGFloat(style.typography.fontSize) * 0.2)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(style.isActive ? Color(style.palette.focusBand) : Color.clear)
            )
            .opacity(style.isDimmed ? style.palette.dimmedOpacity : 1)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onEnded { value in
                        if hypot(value.translation.width, value.translation.height) < 6 {
                            onSelect()
                        }
                    }
            )
            .padding(.horizontal, -DesignTokens.Spacing.md)
            .animation(style.animation, value: style.isActive)
            .animation(style.animation, value: style.isDimmed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sentence.text)
            .accessibilityHint("Plays from this sentence")
            .accessibilityAddTraits(style.isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onSelect() }
    }
}

enum ReadingTextStyler {
    static func attributed(_ text: String, typography: ReadingTypography, palette: ReadingPalette, emphasis: Range<String.Index>?) -> AttributedString {
        var output = AttributedString(text)
        output[AttributeScopes.SwiftUIAttributes.KerningAttribute.self] = typography.letterKerning
        if typography.wordKerning > 0 {
            let spacing = typography.letterKerning + typography.wordKerning
            for index in text.indices where text[index] == " " {
                if let range = Range<AttributedString.Index>(index ..< text.index(after: index), in: output) {
                    output[range][AttributeScopes.SwiftUIAttributes.KerningAttribute.self] = spacing
                }
            }
        }
        if let emphasis, let range = Range<AttributedString.Index>(emphasis, in: output) {
            output[range][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color(palette.emphasisText)
            output[range][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color(palette.emphasis)
        }
        return output
    }
}
