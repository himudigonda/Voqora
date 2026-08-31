# Changelog

## [1.1.1] - 2026-08-31

### Selected-text speech

- Fixed the "speak selected text" shortcut reading raw Markdown syntax
  aloud — headings, emphasis, links, lists, and code fences from things
  like READMEs and notes are now stripped to natural speech instead of
  being read as literal symbols.
- The language field on a speak request is no longer silently discarded —
  it was always hardcoded to English phonemization regardless of what was
  actually requested.
- Repeatedly pressing the shortcut with nothing selected in an app that
  can't expose its text (canvas-rendered PDF viewers, games) now names the
  app and says it may not support this, instead of repeating the same
  generic message forever.

### Audiobooks — narration quality

- Fixed the local (no-Gemini, the default) cleanup path narrating raw
  Markdown syntax verbatim — headings, bold/italic markers, links, and table
  pipes were being read aloud as literal symbols instead of natural speech.
  Lists and tables are now converted into real spoken sentences instead of
  disjoint fragments.
- Extended the same Markdown handling to the optional Gemini cleanup prompt,
  which previously had no rules for Markdown source documents at all.
- Fixed DOCX table content being silently dropped during import — table
  cells were never read by the previous paragraph-only extraction.
- Markdown documents processed without Gemini cleanup now get real chapter
  detection from their headings, instead of always collapsing into one
  section covering the whole book.
- A binary file renamed to look like a supported text document is now
  rejected up front instead of narrating replacement-character noise.
- Re-uploading the exact same file is now flagged as a duplicate instead of
  silently creating an independent copy.
- PDFs now open once per book instead of once per page during import — a
  meaningful speedup on longer documents.

### Audiobooks — reliability

- Fixed a race where deleting a book while a pipeline phase was still
  running could resurrect it afterward as an empty ghost entry.
- A transcript that failed to write to disk no longer leaves a book stuck
  in a falsely "done" state with a permanently broken transcript; it's now
  a retryable failure.
- Added a runtime cap on Gemini cleanup spending per book, tracked against
  actual usage (not just the upfront estimate). Once a book crosses the
  cap, remaining pages fall back to local narration instead of the book
  failing outright — you still get a finished audiobook.
- Selected-text speech interrupting audiobook playback no longer leaves a
  sleep timer running in the background — it previously kept counting down
  and could silently stop whatever played next with no explanation.
- Error messages from a failed document upload are now clear and actionable
  instead of occasionally surfacing raw internal detail.
- Deleting an audiobook now asks for confirmation, matching history's
  existing "clear" confirmation.
- Fixed the transcript-skip keyboard shortcut moving 15 seconds while its
  own on-screen button and tooltip both said 30.
- Backend failures are now logged with a full stack trace instead of a
  single truncated line — including audiobook processing failures, which
  previously logged nothing useful for diagnosing what actually broke.

### Audiobooks — accessibility & UX

- Added VoiceOver labels to the playback, transport, and sleep-timer
  controls in the audiobook player, the mini player, and the main
  dashboard's play/pause/skip controls.
- Fixed the transcript's auto-scroll-pause not responding to normal
  trackpad or scroll-wheel scrolling, which is how most people actually
  scroll on a Mac — it only recognized click-and-drag before.
- The transcript now highlights the sentence currently being read instead
  of the entire page.
- History's empty and no-results states are now visible instead of a blank
  screen.

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

[1.1.1]: https://github.com/himudigonda/Voqora/releases/tag/v1.1.1
[1.1.0]: https://github.com/himudigonda/Voqora/releases/tag/v1.1.0
[1.0.0]: https://github.com/himudigonda/Voqora/releases/tag/v1.0.0
