# Changelog

## [1.1.0] - 2026-08-20

### Selection & shortcuts

- Restored the clipboard-based fallback for "select text in any app."
  Terminal, VS Code, browsers, and most Electron apps never expose selected
  text through Accessibility, so the shortcut silently did nothing in them.
  Your clipboard is saved and restored around the fallback, so it works
  everywhere without touching what you last copied.
- The "read selection" shortcut now points you straight to System Settings
  when it silently can't work because Accessibility isn't granted.

### Notifications

- Fixed system notifications never prompting for permission on current macOS
  versions (an off-by-one version check silently disabled the request).
- Notifications now cover audiobook-ready, speaking-started, and
  update-available, with a way to enable them from Preferences at any time.

### Playback

- Fixed the audiobook playback-speed picker so choosing a speed actually
  changes how fast the book plays, instead of only relabeling itself.

### First run & updates

- Quitting the first-run setup partway through now resumes where you left
  off instead of starting over.
- Added a lightweight check that lets you know when a newer Voqora release
  is available on GitHub, without downloading or installing anything
  automatically.

### Audiobooks — reliability

- Fixed a cluster of race conditions in book processing: cancelling and
  immediately deleting a book could resurrect the deleted row, retrying a
  failed book could re-clean files that were never dirty, and a completion
  summary could be attributed to the wrong session.
- TTS cancellation is now checked between every audio segment instead of
  only between pages, so cancelling actually stops promptly.
- Fixed TTS progress stalling when a page's cleaned text was missing; pages
  that failed TTS or were duplicated are now clearly marked in the
  transcript, along with the page status the backend actually reports.
- The transcript view is reactive again after it stopped picking up state
  changes, and no longer fights you over scroll position while it loads.
- Toast dismiss duration now differs by kind, so error toasts stay up
  longer than routine info/success ones.

### Audiobooks — library & UI

- Library search and its "no results" state are wired up.
- Reconciled inconsistent modal and card/grid sizing across the library.
- Added a distinct error state for when the library itself fails to load.
- Error toasts are no longer truncated to two lines.
- "Start Processing" is now correctly disabled when no Gemini API key is
  configured, instead of failing silently later.
- Swept accessibility labels across the audiobook UI.
- Fixed the processing card's context menu being blocked by an overlapping
  hit-testing gate.

### Performance

- Backend TTS synthesis now paces itself instead of running unthrottled,
  and disables ONNX Runtime's intra-op spinning to cut idle CPU use.
- Voqora now recognizes when it's backgrounded and widens its heartbeat and
  audiobook-library polling intervals accordingly, reducing background
  CPU and battery use.
- Bounded the backend's internal worker and SSE subscriber queues to
  prevent unbounded memory growth during long audiobook sessions.

## [1.0.0] - 2026-07-30

Initial public release of Voqora for Apple-silicon Macs running macOS 14 or
newer.

- Turn selected text into speech with a global shortcut.
- Choose a voice, adjust speed and volume, pause, resume, stop, and export.
- Turn supported documents into resumable audiobooks.
- Keep the primary speech path local to the Mac.
- Offer anonymous product metrics and optional email identity separately.
- Use a clear, manual DMG installation and update flow while the project is
  validating product-market fit without Apple notarization.

[1.1.0]: https://github.com/himudigonda/Voqora/releases/tag/v1.1.0
[1.0.0]: https://github.com/himudigonda/Voqora/releases/tag/v1.0.0
