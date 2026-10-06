# Voqora user guide

Voqora is in early release. If something is confusing or broken, please
[open an issue](https://github.com/himudigonda/Voqora/issues); feedback and pull
requests are welcome.

## What you need

Voqora targets Apple-silicon Macs running macOS 14 or newer. Download
the DMG from the [release page](https://github.com/himudigonda/Voqora/releases/latest),
drag Voqora to Applications, and open it.

The current build is not Apple-notarized. If macOS blocks the first launch,
open **System Settings -> Privacy & Security**, choose **Open Anyway** for
Voqora, then open it again. If macOS does not show that option or repeats the
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
dashboard reminder. Setup also asks for your name and email and lets you pick an
accent color and app icon.

## Speak selected text

1. Select text in the app you are already reading in: a browser, PDF reader,
   IDE, Notes, or another native Mac app.
2. Press `Command + Shift + .`.
3. Voqora reads the selection with your current voice and speed. Now Playing
   shows the text and highlights the sentence being read. Click any sentence
   to hear it from its first word.

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

1. Open **Library** in the sidebar.
2. Add the PDF, TXT, DOCX, or Markdown file you want to finish, or drop it on
   the window.
3. Review the page count, word count, and expected length, then choose
   **Create Audiobook**.
4. When the book is ready, choose **Listen Now**. Later, use **Continue
   Listening** in the sidebar to pick up where you left off.

### Listening to a book

- The transcript follows along and highlights the sentence being read. Scroll
  freely; it returns to the current line after a few seconds, or choose
  **Current Line**.
- Click any sentence to play from it, or open **Sections** to jump to a
  heading.
- Hover over the progress bar to preview a time and its section, then click or
  drag to go there.
- Use the speed button to change the playback speed, and the moon button to
  set a sleep timer. **End of Section** follows your position, so it still
  stops in the right place if you pause, skip, or change speed.
- When you leave the player, a mini player stays at the bottom of the window.
- Export the finished audiobook as a WAV file with the export button.

Voqora stores the source document, extracted text, generated audio, transcript,
and audiobook state locally until you delete that book. Close the app and return later without
starting the document from the beginning.

### Optional document cleanup

Most text-based documents can be handled locally. If extraction is poor, you
can choose optional cleanup with a Gemini API key you provide:

1. Add your key under **Preferences -> Audiobooks -> Gemini API Key** and
   choose **Verify**.
2. When you add a document, turn on **Clean Up with Gemini** at the bottom of
   the New Audiobook sheet. The Gemini Tokens and Gemini Cost tiles then show
   the estimate.

A scanned PDF needs Gemini OCR before it can be narrated. That operation sends
the relevant document material to Gemini. It is separate from the core
selected-text speech flow and can be skipped. If a page cannot be cleaned, Voqora
narrates its local text instead and marks it for retry; right-click the book in
the Library to retry those pages.

## The Vault and export

**The Vault** keeps a local history of spoken selections. Search it, star the
passages you want to keep, and play any of them again. Use
`Command + Shift + M` to save the latest clip to your Desktop as a WAV file.

## Updates

Voqora checks for a new release when it launches and notifies you when one is
available. You can also choose **Check for Updates** in About or Preferences.
Choose **Download Latest Version** to download the verified DMG and open it in
Finder, then drag the new version to Applications. Voqora never replaces itself
automatically.

## Troubleshooting

### Voqora is still initializing

The native app starts a bundled local speech service on first launch. Give it a
moment, then reopen Voqora if it remains unavailable. If you are building from
source, `make run` builds the bundled server before the app.

### The shortcut does nothing

Check that Voqora has the macOS permission it requests to read selected text
from other apps. Then confirm the shortcut has not been claimed by another
utility in Preferences.

### A document needs cleaner text

Try the local flow first. If the document is scanned or extraction is poor,
use the optional Gemini-cleanup path only if you are comfortable sending that
document material to Gemini with your own key.

### Where are the logs?

Choose **Preferences -> Data -> Export Debug Logs**. The files are written to
your Desktop so you can attach them to a
[GitHub issue](https://github.com/himudigonda/Voqora/issues).
