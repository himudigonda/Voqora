import AppKit
import SwiftUI

enum ReadingModeWindow {
    static let id = "reading"
    static let title = "Reading Mode"
}

struct ReadingModeView: View {
    @EnvironmentObject private var vm: DashboardViewModel
    @EnvironmentObject private var bookVM: AudiobookViewModel
    @ObservedObject private var preferences = ReadingPreferences.shared
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dismissWindow) private var dismissWindow

    private var source: ReadingSource {
        ReadingSource.resolve(
            audiobookTranscript: bookVM.nowPlaying == nil ? nil : bookVM.transcriptState,
            hasSpokenText: vm.spokenText != nil
        )
    }

    private var isPlayable: Bool {
        source == .audiobook || source == .speech
    }

    var body: some View {
        let palette = ReadingThemeResolver.palette(theme: preferences.theme, tint: preferences.tint, increaseContrast: contrast == .increased)
        ZStack {
            Color(palette.background)
                .ignoresSafeArea()
            content(palette: palette)
        }
        .overlay(alignment: .bottom) {
            ReadingControlBar(preferences: preferences, isPlayable: isPlayable, onClose: close)
                .padding(.bottom, DesignTokens.Spacing.xl)
        }
        .background(ReadingWindowAppearance(isDark: palette.isDark))
        .frame(minWidth: 560, minHeight: 420)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard isPlayable else { return .ignored }
            vm.togglePlayback()
            return .handled
        }
        .onExitCommand(perform: close)
        .onAppear {
            loadTranscriptIfNeeded()
            VoqoraLog.info("ReadingMode", "Reading Mode opened", ["source": "\(source)"])
        }
    }

    @ViewBuilder
    private func content(palette: ReadingPalette) -> some View {
        switch source {
        case .audiobook:
            ReadingTranscriptView(follower: bookVM.follower, preferences: preferences, palette: palette) { line in
                bookVM.play(fromLine: line)
            }
        case .speech:
            ReadingTranscriptView(follower: vm.speechFollower, preferences: preferences, palette: palette) { line in
                vm.playSpokenText(from: line)
            }
        case .loading:
            ReadingPlaceholder(palette: palette, title: "Loading Transcript…", message: nil, showsProgress: true)
        case .unavailable:
            ReadingPlaceholder(
                palette: palette,
                title: "Transcript Unavailable",
                message: "This audiobook's text could not be loaded. Try again in a moment.",
                showsProgress: false,
                actionTitle: "Try Again",
                action: retryTranscript
            )
        case .empty:
            ReadingPlaceholder(
                palette: palette,
                title: "Nothing to Read",
                message: "Speak a selection or play an audiobook, and its text appears here.",
                showsProgress: false
            )
        }
    }

    private func loadTranscriptIfNeeded() {
        guard let book = bookVM.nowPlaying, bookVM.transcriptState == .idle else { return }
        bookVM.loadTranscript(for: book.bookID)
    }

    private func retryTranscript() {
        guard let book = bookVM.nowPlaying else { return }
        bookVM.loadTranscript(for: book.bookID)
    }

    private func close() {
        dismissWindow(id: ReadingModeWindow.id)
    }
}

private struct ReadingPlaceholder: View {
    @EnvironmentObject private var vm: DashboardViewModel
    let palette: ReadingPalette
    let title: String
    let message: String?
    let showsProgress: Bool
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Color(palette.text).opacity(0.6))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(vm.appFont(size: 20, weight: .semibold))
                .foregroundStyle(Color(palette.text))
            if let message {
                Text(message)
                    .font(vm.appFont(size: 14))
                    .foregroundStyle(Color(palette.text).opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.voqoraSecondary)
            }
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
