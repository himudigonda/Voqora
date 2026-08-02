# Changelog

## [1.0.1] - 2026-08-01

- Fixed system notifications never prompting for permission on current macOS
  versions (an off-by-one version check silently disabled the request).
- Notifications now cover audiobook-ready, speaking-started, and
  update-available, with a way to enable them from Preferences at any time.
- Fixed the audiobook playback-speed picker so choosing a speed actually
  changes how fast the book plays, instead of only relabeling itself.
- The "read selection" shortcut now points you straight to System Settings
  when it silently can't work because Accessibility isn't granted.
- Quitting the first-run setup partway through now resumes where you left
  off instead of starting over.
- Added a lightweight check that lets you know when a newer Voqora release
  is available on GitHub, without downloading or installing anything
  automatically.

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

[1.0.1]: https://github.com/himudigonda/Voqora/releases/tag/v1.0.1
[1.0.0]: https://github.com/himudigonda/Voqora/releases/tag/v1.0.0
