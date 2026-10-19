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
  default and AI cleanup as an explicit choice.
- Guided DMG downloads for updates, with SHA-256 verification.
- AI cleanup through ten providers (OpenAI, Anthropic, xAI, Groq, Cerebras,
  Google Gemini, OpenRouter, Ollama, LM Studio, and Custom servers), with keys
  in the macOS Keychain and local providers that keep text on the Mac.
- 28 voices in eight languages, with voice samples and optional language
  auto-detect.
- A local Stats page, and an option to hide Voqora from the Dock.

## Shipped in v2.0.0

Everything in 2.0.0 is free, with no paid tier.

- Audiobooks from EPUB, HTML, and web links, with the book's author, MP3 and
  M4B (with chapters and cover) export, and SRT and WebVTT subtitles.
- Reading Mode with word-by-word highlighting.
- Voices: a Voice Catalog, My Voices blends, a pronunciation dictionary
  (global and per book), and Pause Length.
- AI reading tools: summaries, questions with citations, quizzes, flashcards,
  and Summarize or Translate Selection and Speak.
- Studio: two-voice podcasts from any text, with an editable script.
- An Inbox for saving articles to listen to later.
- Speak Text on Screen (OCR), Speak Clipboard, macOS Services, Shortcuts app
  actions, media keys, and Now Playing.
- On-device Dictation into any app.
- An optional local API (OpenAI speech API compatible, plus MCP) for other
  apps and AI agents, Audiobookshelf upload, and a Chrome and Edge extension.
- Supertonic as a second, optional speech engine: a one-time download of about
  400 MB under Preferences, Speech Engines, with 10 voices in 31 languages for
  speech and audiobooks.

## Next

1. **More speech engines** - Chatterbox, Qwen3-TTS, and Dia2 as optional
   downloads, and Parakeet for dictation.
2. **Safari extension and an iPhone companion.**

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
