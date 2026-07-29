# Changelog

All notable changes to Voqora are documented here. Voqora starts at v1.0.0:
this is the first public release of the product and its source history.

## [1.0.0] - 2026-07-29

### Final release build

- Reissue v1.0.0 with every install starting from the same predictable
  US-English voice, Bella. This clears a voice left behind by pre-release
  testing once, then preserves any voice the user chooses afterward.
- Corrected the final DMG bundle signature after adding the bundled speech
  service, fonts, licence, and third-party notices.
- Added clear first-launch guidance, including the one-app `xattr` fallback
  for macOS's downloaded-file quarantine warning.

### Release delivery

- Replaced the bespoke in-app DMG downloader with Sparkle 2, which verifies
  signed update archives and uses the native macOS update experience.
- Added a signed appcast generator, GitHub Pages deployment workflow, and
  release preflight checks for version alignment, update configuration, DMG
  readability, code signing, and optional notarization.

### Initial public release

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
