# Voqora user guide

## What you need

Voqora targets Apple-silicon Macs running macOS 14 or newer. Download
the DMG from the [release page](https://github.com/himudigonda/Voqora/releases/latest),
drag Voqora to Applications, and open it.

The current build is not Apple-notarized. If macOS blocks the first launch,
open **System Settings -> Privacy & Security**, choose **Open Anyway** for
Voqora, then open it again. The DMG also includes an
**OPTIONAL-OPEN-VOQORA.command** fallback that only targets the installed
`/Applications/Voqora.app`. If macOS does not show that option or repeats the
warning, and you downloaded Voqora from the official release page, run this
once in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Voqora.app
open /Applications/Voqora.app
```

This clears the downloaded-file quarantine marker only from the installed
Voqora app. Do not run it on software from an untrusted source.

On first launch, Voqora opens a short setup flow before the speech engine is
ready. It explains the shortcut and takes you to the macOS Accessibility
setting. Accessibility is required for speaking selected text from other apps,
but you can continue into Voqora without it and enable it later from the
dashboard reminder. Notifications and an optional email are clearly optional.

## Speak selected text

1. Select text in the app you are already reading in: a browser, PDF reader,
   IDE, Notes, or another native Mac app.
2. Press `Command + Shift + .`.
3. Voqora reads the selection with your current voice and speed.

| Action | Default shortcut |
| --- | --- |
| Speak selection | `Command + Shift + .` |
| Play / pause | `Command + Shift + /` |
| Stop | `Command + Shift + ,` |
| Export the latest clip | `Command + Shift + M` |

Change any shortcut in Preferences. If a selection does not arrive on the
first try, click back into the source app, select the text again, and retry.

## Choose a voice and speed

Open Preferences to choose a voice, set the reading speed, adjust volume, and
change the global shortcuts. Voqora includes eight Kokoro voice options:

| Voice | Voice |
| --- | --- |
| `af_bella` | `af_sarah` |
| `am_adam` | `am_michael` |
| `bf_emma` | `bf_isabella` |
| `bm_george` | `bm_lewis` |

There is no universally right voice or speed. Voqora starts with Bella. Adjust
the voice and speed until you can follow a paragraph without wanting to rewind it.

## Turn a document into an audiobook

1. Open **Audiobooks**.
2. Add the PDF, TXT, DOCX, or Markdown file you want to finish.
3. Review the creation step and start processing.
4. Return to the book when it is ready, then use its progress and playback
   controls to continue where you left off.

Voqora stores audiobook state locally. Close the app and return later without
starting the document from the beginning.

### Optional document cleanup

Most text-based documents can be handled locally. If extraction is poor, you
can choose optional cleanup with a Gemini API key you provide. A scanned PDF
needs Gemini OCR before it can be narrated. That operation sends the relevant
document material to Gemini. It is separate from the core selected-text speech
flow and can be skipped.

## History and export

Voqora keeps a local history of spoken selections. Use it to revisit a useful
passage, then use `Command + Shift + M` to save the latest clip as a WAV file.

## Troubleshooting

### Voqora is still initializing

The native app starts a bundled local speech service on first launch. Give it a
moment, then reopen Voqora if it remains unavailable. If you are building from
source, run `make backend` before `make run` so the bundled server zip exists.

### The shortcut does nothing

Check that Voqora has the macOS permission it requests to read selected text
from other apps. Then confirm the shortcut has not been claimed by another
utility in Preferences.

### A document needs cleaner text

Try the local flow first. If the document is scanned or extraction is poor,
use the optional Gemini-cleanup path only if you are comfortable sending that
document material to Gemini with your own key.

### Where are the logs?

Voqora can export its frontend and backend logs from the app. The files are
written to your Desktop so you can attach them to a GitHub issue.
