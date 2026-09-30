# Voqora roadmap

## Shipped in v1.0.0

- Local selected-text speech on Apple silicon.
- Global shortcuts, voice and speed controls, history, and WAV export.
- PDF-to-audiobook creation with resume support.
- Optional cleanup and OCR for difficult PDFs.
- Public source, DMG installer, release notes, and contributor documentation.

## Shipped since v1.0.0

- An audiobook player with a transcript that highlights the sentence being
  read, click-to-play on any sentence, and a Sections tab.
- Scrub previews with the section name, a speed menu in the player, and a sleep
  timer that can stop at the end of a section.
- Selected-text speech shares the same player and transcript.
- The Vault for searching, starring, and replaying spoken selections.
- DOCX, TXT, and Markdown audiobooks alongside PDF, with local cleanup by
  default and Gemini cleanup as an explicit choice.
- Guided DMG downloads for updates, with SHA-256 verification.

## Next public-quality work

1. **Developer ID signing and notarization** - remove the first-launch
   friction from the DMG install path.
2. **Install and first-use diagnostics** - make local-server startup and
   permission recovery easier to understand.
3. **Audiobook reliability polish** - improve recovery, progress clarity, and
   feedback for long documents.
4. **Sharper reading workflows** - continue improving the select-and-listen
   loop before expanding into unrelated product areas.

## Product principle

Voqora should earn complexity. A new feature belongs only if it makes it easier
to get through real text without weakening the simple core action.
