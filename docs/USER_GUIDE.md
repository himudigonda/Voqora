# Voqora user guide

## What you need

Voqora v1.0.0 targets Apple-silicon Macs running macOS 14 or newer. Download
the DMG from the [release page](https://github.com/himudigonda/Voqora/releases/tag/v1.0.0),
drag Voqora to Applications, and open it.

The current build is not Apple-notarized. If macOS blocks the first launch,
approve Voqora in **System Settings -> Privacy & Security**, then open it
again.

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

There is no universally right voice or speed. Start with the default voice and
adjust until you can follow a paragraph without wanting to rewind it.

## Turn a PDF into an audiobook

1. Open **Audiobooks**.
2. Add the PDF you want to finish.
3. Review the creation step and start processing.
4. Return to the book when it is ready, then use its progress and playback
   controls to continue where you left off.

Voqora stores audiobook state locally. Close the app and return later without
starting the document from the beginning.

### Optional PDF cleanup

Most text PDFs can be handled locally. If a document is poorly extracted or
scanned, you can choose optional cleanup with a Gemini API key you provide.
That operation sends the relevant document material to Gemini. It is separate
from the core selected-text speech flow and can be skipped.

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

### A PDF needs cleaner text

Try the local flow first. If the document is scanned or extraction is poor,
use the optional Gemini-cleanup path only if you are comfortable sending that
document material to Gemini with your own key.

### Where are the logs?

Voqora can export its frontend and backend logs from the app. The files are
written to your Desktop so you can attach them to a GitHub issue.
