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
dashboard reminder. Setup also offers to turn on notifications, asks for your
name and email, and lets you pick an accent color and app icon.

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
change the global shortcuts. Voqora includes 28 Kokoro voices in eight
languages, grouped by language in the voice picker:

| Language | Voices |
| --- | --- |
| English (US) | Bella, Sarah, Heart, Nicole, Aoede, Kore, Adam, Michael, Fenrir, Puck |
| English (UK) | Emma, Isabella, George, Lewis, Fable |
| Spanish | Dora, Alex |
| French | Siwis |
| Italian | Sara, Nicola |
| Portuguese (Brazil) | Dora, Alex |
| Hindi | Aanya, Diya, Arjun, Kabir |
| Mandarin (beta) | Xiaoxiao, Yunyang |

Choose the play button next to the picker to hear a short sample of a voice.
Pick a voice in the language of your text; British voices use British English
pronunciation. Turn on **Auto-detect Language** to switch to a voice in the
text's language when it differs from your voice's language.

There is no universally right voice or speed. Voqora starts with Bella. Adjust
the voice and speed until you can follow a paragraph without wanting to rewind it.

## Turn a document into an audiobook

1. Open **Library** in the sidebar.
2. Add the PDF, TXT, DOCX, or Markdown file you want to finish, or drop it on
   the window. You can drop several files at once.
3. Review the page count, word count, and expected length, then choose
   **Create Audiobook**.
4. When the book is ready, choose **Listen Now**. Later, use **Continue
   Listening** in the sidebar to pick up where you left off.

### Listening to a book

- The transcript follows along and highlights the sentence being read. Scroll
  freely; it returns to the current line after a few seconds, or choose
  **Current Line**.
- Click any sentence to play from it, or open **Sections** to jump to a
  heading. Sections come from the headings in Word and Markdown files and from
  the PDF's outline; a document without them is split into Parts.
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
can choose optional AI cleanup with a provider you connect: OpenAI, Anthropic,
xAI, Groq, Cerebras, Google Gemini, OpenRouter, Ollama, LM Studio, or a Custom
OpenAI-compatible server.

1. Open **Preferences -> AI Cleanup -> Add Provider**, pick a provider, enter
   its API key (Ollama and LM Studio need none) and model, and choose
   **Connect**. Voqora checks the connection before saving. You can also
   connect a provider during setup.
2. If you connect more than one, choose the one under **Used for audiobooks**.
3. When you add a document, turn on **Clean Up with <provider>** at the bottom
   of the New Audiobook sheet. The provider menu there switches providers for
   that book. The Cleanup Tokens and Cleanup Cost tiles show the estimate;
   local providers are free.

Your API key is stored in your macOS login Keychain. Voqora sends it only to its
own service on your Mac, with each cleanup request, and from there to the
provider you connected. Removing a provider asks you to confirm, deletes its key
from the Keychain, and tells you what happens to audiobooks that use it.

A Custom server needs an `https://` address when you set an API key, unless it
runs on this computer. Without a key, `http://` works only for servers on this
computer or your local network. A Custom server on your own computer or network
is treated as free.

A scanned PDF needs a provider and model that can read images before it can be
narrated; scanned pages inside an otherwise text PDF are read the same way.
That operation sends the relevant document material to the provider you chose,
or keeps it on your Mac with Ollama, LM Studio, or a local Custom server. It is
separate from the core selected-text speech flow and can be skipped.

If a page cannot be cleaned, Voqora narrates its local text instead and marks it
for retry; right-click the book in the Library to retry those pages. If
cleanup stops for a provider problem, such as a rejected key or an unavailable
model, the book shows the reason. Choose **Fix Provider** to correct the
connection, then **Resume** to continue where it stopped. Pages already cleaned
stay as they are. To continue without AI, choose **Finish Without AI**; the
remaining pages are narrated from local text.

## Stats

Open **Stats** in the sidebar to see your listening time, voices, streaks, and
library totals over the last 7 days, 30 days, 12 months, or all time. Stats are
kept in a file on your Mac and are never sent anywhere. Choose **Reset Stats**
on the page to clear them; **Erase All Local Data** clears them too.

## Run Voqora from the menu bar

Turn on **Preferences -> General -> Hide from Dock & App Switcher** to keep
Voqora in the menu bar only. The menu bar icon stays on while the Dock icon is
hidden.

## The Vault and export

**The Vault** keeps a local history of spoken selections. Search it, star the
passages you want to keep, and play any of them again. Use
`Command + Shift + M` to save the latest clip to your Desktop as a WAV file.

## Updates

Voqora checks for a new release when it launches, at most once every six hours,
and notifies you when one is available. You can also choose **Check for Updates** in About or Preferences.
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
use the optional AI cleanup path with a local provider, or with a cloud
provider only if you are comfortable sending that document material to it with
your own key.

### Where are the logs?

Choose **Preferences -> Data -> Export Debug Logs**. The files are written to
your Desktop so you can attach them to a
[GitHub issue](https://github.com/himudigonda/Voqora/issues).
