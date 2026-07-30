# Changelog

All notable changes to Voqora are documented here. Voqora starts at v1.0.0:
this is the first public release of the product and its source history.

## [Unreleased] - v1.1.0 candidate

This section describes private, unreleased work. It is not a public release
note and must receive a release date only after the full release checklist has
passed.

### First-run default

- Start every install and upgrade from Bella, the US-English voice, with
  automatic language switching off. The user can opt into automatic
  matching-language speech during onboarding or later in Preferences.

### Reliability and release gates

- Reworked Stop into one cancellation-aware product action. The global
  shortcut, menu-bar item, and in-window controls now cancel an active speech
  request before stopping audio, so late streamed data cannot restart playback
  after someone pressed Stop.
- Preserved audiobook behaviour when the shared player is controlled outside
  the Audiobooks view. Pause/resume and Stop now retain the book's normal
  resume-position and listening-event bookkeeping instead of treating it as a
  disposable selected-text clip.
- A delayed audiobook-file request can no longer revive playback after Stop,
  deletion, or a switch to another book. Voqora invalidates the older request
  before teardown and does not surface its late error as a fresh user action.
- The local speech stream now uses an explicit open-ended WAV envelope that
  AVFoundation accepts. This keeps playback streaming while avoiding an
  apparently successful response that audio parsers treat as an empty file.
- Unified the document contract across the Library importer, global drag and
  drop, MIME handling, and metrics. Voqora accepts PDF, TXT, DOCX, and
  Markdown, stages documents safely before processing, and gives a readable
  message for an unsupported or unreadable drop instead of ignoring it.

### Multilingual listening

- Added 28 curated Kokoro voices across eight supported locales: English (US),
  English (UK), Spanish, French, Italian, Brazilian Portuguese, Hindi, and
  Mandarin.
- Added a grouped, flag-labelled voice picker and bundled voice previews.
- Added on-device automatic language detection through Apple's
  `NLLanguageRecognizer`. It preserves a user's English US/UK choice and only
  switches when a supported non-English language is detected with confidence.
- Marked Mandarin as beta. Japanese is intentionally excluded because the
  bundled phonemization path does not produce dependable narration for normal
  kanji text.

### First-use and reading experience

- Added a voice, language, speed, and auto-detect step to onboarding.
- Made Accessibility loss visible and recoverable after reinstall or a revoked
  system permission.
- Added a real loading state while the first audio buffer is still being
  generated, rather than presenting an apparently frozen playback state.
- Preserved the no-account product model: optional email attribution remains
  optional and does not unlock or gate any reading feature.
- Carry forward the v1 reliability baseline: first-run onboarding remains
  visible above backend startup, playback does not claim to be speaking before
  a real audio buffer arrives, and Stop cancels an in-flight stream before it
  can resume audio.

### Distribution and update experience

- Refined the local installer artwork to use Voqora's dark visual language,
  literal drag-to-Applications instructions, and dedicated high-contrast
  label zones for Finder's app and Applications labels.
- Hardened the release boundary: `make ship` now requires a Developer ID
  signature, a stapled notarization ticket, and a passing Gatekeeper check by
  default. A free non-notarized build is still possible only through an
  explicit release-owner override, so it cannot be uploaded by accident.
- Made update feedback legible in Preferences. Manual checks now show whether
  Voqora is preparing, checking, up to date, has an update ready, or could not
  reach the feed, without replacing Sparkle's native update dialog.
- No new public release is included in this section. Installer, Gatekeeper,
  Sparkle, website/metrics, and full manual-flow evidence remain release gates
  until they are verified against one immutable candidate artifact.

### Audiobooks

- Extended document intake to PDF, DOCX, Markdown, and plain-text files.
- Detect native PDF bookmarks, DOCX heading styles, and Markdown level-one/two
  headings before falling back to an optional cleanup service.
- Persist real per-segment speech timing and render a flowing transcript that
  can follow actual audio rather than a page-duration estimate.
- Added safer upload handling, retry/reconnect recovery, cancellation of
  sibling cleanup work, adaptive layouts, clearer processing states, and live
  audiobook speed updates.
- Reject incomplete audio files instead of serving them as ready playback.

### Consent and resilience

- Require explicit user consent on the local API before sending document
  material to Gemini for cleanup or OCR.
- Prevent duplicate audiobook starts while a book is already processing.
- Harden atomic file writes, blank-page routing, cover rendering, backend
  lifecycle handling, and in-progress resume recovery.

### Engineering

- Added deterministic backend and Swift tests for the new language catalog,
  language detection, document extraction, transcript timing, layout rules,
  retries, cancellation, and partial-output boundaries.
- Kept the public v1.0.0 branch and release untouched while this candidate is
  developed locally.
- Reuse the public document-intake contract in every entry point: PDF, TXT,
  DOCX, and Markdown files are staged into unique local directories before
  asynchronous processing, so same-named Finder files cannot collide.
- Keep the local speech engine lifecycle process-owned and test-safe: no
  global process termination, no duplicate heartbeat loops, and no background
  clipboard polling or reading.

## [1.0.0] - 2026-07-28

### Highlights

- Introduced Voqora for Apple-silicon Macs running macOS 14 or newer.
- Made the core action intentionally small: select text, press
  `Command + Shift + .`, and listen.
- Added a second long-form workflow: turn a PDF into a resumable audiobook.

### Reading and playback

- Speak selected text from the app you are already using.
- Paste text into Voqora for a focused reading surface.
- Stream generated audio progressively so playback can begin before all of a
  longer selection has finished rendering.
- Control playback globally with four remappable defaults:
  `Command + Shift + .` to speak, `Command + Shift + /` to pause or resume,
  `Command + Shift + ,` to stop, and `Command + Shift + M` to export.
- Choose a voice and reading speed, then adjust volume from the native Mac UI.
- Keep a local history of spoken text and export the most recent clip as WAV.

### PDF audiobooks

- Add PDFs to an audiobook library rather than treating a long document as one
  disposable speech request.
- Keep creation progress, chapter information, transcript support, playback
  position, and resume state with the book.
- Continue listening after closing and reopening the app.
- Use local extraction and cleanup by default.
- Optionally provide a Gemini API key for document cleanup or OCR when a PDF
  needs it. This is an explicit opt-in path, not a requirement for the core
  speech experience.

### Local engine and packaging

- Bundle a FastAPI speech service with the native app.
- Run Kokoro ONNX inference and the core speech path locally on Apple silicon.
- Start the bundled service from the app and communicate through local
  loopback HTTP.
- Package the app, local server, fonts, license, and third-party notices into
  a drag-and-drop DMG.
- Ship a new application identity: `com.himudigonda.Voqora`.

### Product controls

- Keep the core app usable without an account.
- Provide an optional product-telemetry toggle in Preferences.
- Document the local speech path, optional PDF-cleanup path, and release
  checks in `PRIVACY.md`.

### Engineering and delivery

- Publish a fresh Voqora repository, a v1.0.0 GitHub release, and an
  Apple-silicon DMG.
- Add a release guide, contributor guide, user guide, architecture guide, and
  testing guide to the public repository.
- Split routine validation from macOS UI-host tests: `make test` runs the fast
  backend suite, while `make test-swift` is explicit, serial, and guarded
  against overlapping Xcode runs.
- Run backend linting and tests in GitHub Actions, with a separate serial
  macOS Swift test job.

### Known limitations

- Voqora v1.0.0 targets Apple-silicon Macs and macOS 14+ only.
- The v1.0.0 DMG is ad-hoc signed and not Apple-notarized. macOS can require
  manual approval on first launch.
- Optional PDF cleanup depends on a Gemini API key supplied by the user.

[1.0.0]: https://github.com/himudigonda/Voqora/releases/tag/v1.0.0
