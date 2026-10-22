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
ready. The steps are Welcome, Privacy (optional), Permissions, Speech Engine,
Voice, Shortcuts, Dictation (optional), Audiobooks (optional), AI Provider
(optional), Appearance, and Finish, which lists anything you still need to do.
Kokoro is the recommended engine for the fastest real-time speech. Accessibility
is required for speaking selected text from other apps, but you can skip it and
enable it later from the dashboard reminder or **Settings -> Permissions**.
Analytics stay off unless you switch them on, and your name and email are
optional. Each choice can be changed later in Settings.

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
| Speak text on screen | `Command + Shift + 8` |
| Speak clipboard | Not set |
| Start or finish dictation | `Command + Shift + 9` |

Change any shortcut in **Settings -> Shortcuts**. If a selection does not arrive on the
first try, click back into the source app, select the text again, and retry.

### Media keys and headphones

The play/pause, next, and previous keys on your keyboard, AirPods and
headphone controls, and the Now Playing control in Control Center all work
with Voqora:

- Play and pause the selection or audiobook that is playing.
- Skip forward or back 15 seconds.
- Next and previous move to the next or previous sentence of a selection, or
  to the next or previous chapter of an audiobook.
- Drag the Control Center progress bar to jump anywhere in the clip.

Now Playing shows the audiobook title, the current chapter, and the cover, or
"Selected text" while a selection is read. Voqora clears it when you stop.
Playback pauses when the headphones you were listening on disconnect, so a
book never starts playing out loud by surprise.

To leave media keys to Music or another app, turn off "Respond to media keys"
in **Settings -> Shortcuts**.

## More ways to start speech

- **Text on screen.** Press `Command + Shift + 8`, then drag over the part of
  the screen you want to hear, such as an image, a video frame, or an app that
  does not allow selecting text. Voqora reads the text in that area, joining
  words split across lines and keeping paragraphs together. Press Escape to
  cancel. The first time, macOS asks you to allow Screen Recording for Voqora.
  Turn it on in **System Settings -> Privacy & Security -> Screen Recording**,
  then reopen Voqora. The capture is deleted as soon as the text is read.
- **Clipboard.** Assign a shortcut to **Speak Clipboard** in **Settings -> Shortcuts** to
  hear whatever text you last copied.
- **Services menu.** Select text in any app, then choose **Speak with Voqora**
  or **Add to Voqora Library** from the app menu under **Services**, or from
  the right-click menu. Add to Voqora Library turns the selection into a text
  audiobook, named after its first line. If the items are missing, turn them
  on in **System Settings -> Keyboard -> Keyboard Shortcuts -> Services**.
- **Shortcuts app.** Voqora adds **Speak Text** (with an optional voice),
  **Speak Clipboard**, **Pause or Resume Speech**, and **Stop Speech** actions
  for your own shortcuts and for Siri.

## Read web pages in Chrome or Edge

The Voqora extension for Chrome and Edge sends text from web pages to Voqora,
which reads it aloud with your current voice. It talks only to Voqora on this
Mac and never sends page text anywhere else.

1. In Voqora, open **Settings -> Integrations** and turn on **Local API**.
   Note the port and copy the API key.
2. In the browser, open `chrome://extensions` (or `edge://extensions`), turn on
   **Developer mode**, choose **Load unpacked**, and pick the
   `extensions/chromium` folder from the Voqora source code.
3. On the options page that opens, enter the port and the key, then choose
   **Test Connection**.

To listen, select text and right-click **Read selection with Voqora**, or press
`Option + Shift + R`. Right-click elsewhere on the page and choose **Read this
page with Voqora** to hear the main article without menus, sidebars, or
footers. The toolbar button has **Read Selection**, **Read Page**, and **Stop**,
and `Option + Shift + S` stops speech. Pages longer than 50,000 characters are
sent in parts and read in order; **Stop** drops the parts still waiting.

If the extension says it can't reach Voqora, make sure Voqora is open, Local
API is on, and the port matches. If it says the key was not accepted, copy the
key again; regenerating it in Voqora replaces the old one. Browsers do not let
extensions read their own pages, such as `chrome://` pages and the Web Store.
See `extensions/chromium/README.md` for more detail.

## Save articles to your Inbox

Open **Inbox** under **Listen** in the sidebar to keep web articles for later. Voqora saves the
readable text of each article on this Mac, without menus, ads, or cookie
banners.

- **Add an article.** Paste a link into the field at the top and press Return.
  When the Inbox is empty, you can also press `Command + V` anywhere on the
  page. Dropping a link from your browser or a `.webloc` file works too.
- **From any app.** Select a link or text that contains one, then choose
  **Save to Voqora Inbox** from the Services menu. Voqora lets you know when
  the article is saved. If the item is missing, turn it on in **System
  Settings -> Keyboard -> Keyboard Shortcuts -> Services**.
- **Listen.** Choose the play button to hear the article with the transcript,
  using your voice and speed. Long articles are read in parts without a break.
  Voqora remembers how far you got, and finished articles leave the Unread
  list.
- **Make an audiobook.** Choose the books button to add the article to Library
  as an audiobook, using your audiobook voice and speed. If it is already
  there, Voqora offers to open it instead. Links to PDFs can only become
  audiobooks.
- **More actions.** Open the original page, copy the text, archive, or delete
  from the row's menu or by right-clicking it.

Each row shows the estimated listening time at your current speed. Switch
between **Unread**, **Archived**, and **All**, or search by title or site. The
Inbox keeps up to 500 articles. When it is full, the oldest archived articles
are removed first. Voqora only opens public websites and tells you when a page
is paywalled, too large, or not readable. **Erase All Local Data** removes the
Inbox too.

## Dictate into any app

1. Click where you want the text to go, in any app.
2. Press `Control + Option + Space` and start speaking. A small panel at the
   top of the screen shows a level meter and the words as Voqora hears them.
   Any Voqora speech pauses while you dictate.
3. Press the shortcut again, or stop talking for two seconds. Voqora pastes
   the transcript where your cursor is and then puts your previous clipboard
   back.

The first time, macOS asks for microphone access, and for Speech Recognition
access when you use the Apple engine (Parakeet, Bark and Bark Clean don't need
it). If you said no, the panel offers **Open System Settings** so you can turn them on.
Pasting uses the same Accessibility access as speaking a selection; without it,
Voqora copies the transcript so you can paste it yourself.

Open **Dictation** in the sidebar to change the shortcut, the language, whether
Voqora pastes or only copies, and how long a pause ends dictation (or turn
auto-stop off). Recognition runs on your Mac. If a language has no on-device
support, Voqora tells you instead of sending audio anywhere; turn on **Allow
Server Recognition** only if you are comfortable with Apple transcribing that
audio. The page also keeps your last 200 transcripts on this Mac, with search,
copy, and delete. **Erase All Local Data** removes them too.

### Pick a recognition engine

The top of **Settings → Dictation** (and the Dictation step of onboarding)
lists four engines. Apple is built in. The other three download once from
Hugging Face and then run fully on your Mac:

| Engine | Best for | Download |
| --- | --- | --- |
| Apple | Many languages, nothing to download | Built in |
| Parakeet | 25 European languages | about 470 MB |
| Bark | English, every word kept, strongest on natural conversation | about 440 MB |
| Bark Clean | English dictation: leaves out "um", "uh", false starts and repeats | about 450 MB |

Dictation starts using the engine you pick once its download finishes; until
then the shortcut tells you the model isn't installed yet. After a download or
an app update, macOS prepares the model for a minute or two. Voqora starts that
as soon as it opens, and if you dictate before it finishes, keep talking: your
words are recorded and appear once the model is ready.

## Choose a voice and speed

Open **Settings** (`Command + ,`, or **Settings…** in the app menu and the menu
bar icon) to choose a voice, set the reading speed, adjust volume, and change
the global shortcuts. Settings has twelve tabs: **General**, **Permissions**, **Appearance**,
**Speech**, **Reading Mode**, **Audiobooks**, **Dictation**, **Engines**,
**Shortcuts**, **AI**, **Integrations**, and **Privacy & Data**. Voice, speed, pause length, and volume are on **Speech**. Voqora includes 28 Kokoro voices in eight
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

### Speech engines

Kokoro is built in. **Settings -> Engines** lists it next to
**Supertonic**, an optional second engine with 10 voices that speak 31
languages (English, Korean, Japanese, Arabic, German, French, Spanish, Hindi,
Russian and more). Supertonic is a one-time download of about 400 MB, free like
everything else in Voqora.

1. Open **Settings -> Engines** and choose **Download** next to
   Supertonic. A progress bar shows the download; you can keep using Voqora.
2. When it finishes, the Supertonic voices (Male 1 to 5, Female 1 to 5) appear
   under **Supertonic** in every voice picker: your speech voice, your audiobook
   voice, and the voice for a new audiobook.
3. Choose **Remove** to delete the download. Anything set to a Supertonic voice
   switches to Bella, and you can download it again later.

Supertonic voices always read in the language of the text. Voice blends and
Podcasts made in Create use Kokoro voices only, and Auto-detect Language leaves a
Supertonic voice alone. The Supertonic model is released under the OpenRAIL-M
license, which carries use restrictions; see the third-party notices.

### Ming: expressive voices

**Ming** is a second optional engine with 117 voices (English and Chinese
speakers) that can also speak Japanese, Korean, German, French and Spanish. It
is a one-time download of about 3.7 GB. Ming renders slower than real time on
most Macs, so it suits audiobooks and exports better than reading aloud as you
go.

Download it from **Settings -> Engines** like Supertonic. Voqora sets
up its own private runtime for it, so it needs an internet connection and free
disk space during the download.

Ming voices accept **delivery** controls:

- **Emotion**: neutral, happy, sad, angry, fearful, disgusted or surprised.
- **Style**: a free sentence of up to 300 characters, such as "a calm bedtime
  storyteller". It is combined with any emotion, pace or pitch you also set.
- **Pace** (slow, normal, fast), **pitch** (low, normal, high) and **dialect**
  (Cantonese or Sichuanese). A dialect takes priority over everything else.
  Without a pace, a speed of 0.85 or lower reads slowly and 1.2 or higher reads
  fast.

Delivery keeps the voice's identity but not the exact way its sample was read,
so emotions and paces come through clearly.

Add sounds to your text with tags such as `[Laughter]`, `[Sigh]`, `[Cough]`,
`[Breathing]`, `[Uhm]`, `[Surprise-ah]`, `[Surprise-oh]`, `[Dissatisfaction-hnn]`,
`[Confirmation-en]` and `[Question-ei]`, `[Question-ah]`, `[Question-en]`,
`[Question-oh]`, `[Question-huh]`. Pronunciation rules never change a tag.

Set delivery defaults in **Settings -> Speech**, or per book on the New
Audiobook page when a Ming voice narrates it.

You can make your own Ming voices from **My Voices -> New Voice**:

- **Describe a voice** ("a warm older woman with a slow, thoughtful voice").
  Voqora renders a short sample and keeps it as the voice.
- **Clone a voice** from a 3 to 30 second recording (WAV, FLAC, AIFF or MP3)
  and the exact words spoken in it.

The first time a built-in voice is used, Voqora renders a short reference clip
for it, so that first sentence takes a little longer. Ming stops itself after
five idle minutes to give the memory back.

## Voices, pronunciations, and pacing

The **Voices** section of the sidebar is the one place to explore and shape
how Voqora sounds.

### Browse Voices

**Browse Voices** lists every built-in voice from every engine, grouped by
language. Use the engine chips (**All**, **Kokoro**, **Supertonic**, or
**Ming**), the language menu and the search field to narrow the list. An engine
you have not downloaded shows an install card instead of its voices. Choose the
play button to hear a sample, then use **Use** to make a voice your speech
voice (**For Speech**) or your audiobook voice (**For Audiobooks**).

### My Voices

**My Voices** holds only the voices you made, in one list. Each one is labeled
**Blend**, **Designed** or **Cloned**. Choose **New Voice**
(`Shift + Command + N`) and pick what you want to make:

- **Blend voices** mixes two to four built-in voices. Name the voice, pick the
  voices, and drag each weight slider. Weights are relative, so the percentage
  next to each slider shows how much of that voice you hear. **Preview** plays
  the mix without saving it; **Save Voice** keeps it.
- **Describe a voice** (Ming) creates a voice from a written description.
- **Clone a voice** (Ming) creates a voice from a 3 to 30 second recording you
  have the right to use, plus the words spoken in it.

If Ming is not installed, the Describe and Clone choices offer to install it
first. Your voices appear at the top of every voice picker under **My Voices**,
including **Settings -> Speech** and the New Audiobook page. Voices in the same
language blend most naturally. You can save up to 50 blends. If you delete a
voice that is in use, Voqora switches to a fallback voice.

### Pronunciations

Teach Voqora how to say names, acronyms, and jargon. Open **Pronunciations**
and choose **Add**. Enter the text Voqora sees and what it should say, for
example "SQL" as "sequel". Leave **Say** empty to skip the text. **Whole word
only** stops "cat" from matching inside "concatenate", and **Match case** keeps
"US" separate from "us".

- **Applies to** chooses whether an entry is used everywhere or only for one
  audiobook. In the player, the **More** menu has **Pronunciations for This
  Book** for entries that only one book needs. A book's entry wins over an
  everyday entry for the same text.
- Type a sentence under **Test** to see what Voqora will say and hear it read.
- Use **Import or Export** to save your list as a JSON file or bring one in.
  Imported entries go to the scope you are viewing, and entries you already
  have are skipped.
- Changes apply to speech and to audiobook pages narrated from then on.
  Pages that are already narrated keep their audio.

### Pause length

**Settings -> Speech -> Pause Length** makes the pauses between sentences
and paragraphs shorter or longer, from 0.5x to 2x. The New Audiobook page has
the same slider for a book, next to its voice, and remembers your last choice.

## Turn a document into an audiobook

1. Open **Library** under **Listen** in the sidebar.
2. Add the PDF, EPUB, DOCX, HTML, TXT, or Markdown file you want to finish,
   or drop it on the window. You can drop several files at once. EPUB books
   bring their own title, author, cover, and chapters; DRM-protected EPUBs
   can't be opened.
3. Review the page count, word count, and expected length, then choose
   **Create Audiobook**.
4. When the book is ready, choose **Listen Now**. Later, use **Continue
   Listening** in the sidebar to pick up where you left off.

Book cards and the player show the author when the document names one, and
the Library search matches titles and authors.

### Add a web article

1. In **Library**, choose **Add from URL** in the toolbar, or press
   `Command + Shift + U`.
2. Paste the link to an article or a PDF. A link without `http://` or
   `https://` is opened with `https://`.
3. Pick the voice and narration speed, then choose **Continue**. Voqora
   fetches the page, keeps the article text and its headings, and shows the
   same estimate and cleanup choices as a file.

Voqora explains why a page can't be added. It doesn't open links to your Mac
or your local network, pages over its size limit, or pages without readable
text. For a page behind a subscription or sign-in, save it from your browser
as a web page and add the HTML file instead. Choose **Edit Link** to try
another address.

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
- Export a finished audiobook from the export button in the player, or
  right-click the book in the Library and choose **Export**. Pick
  **Audiobook (M4B)** for a file with chapters, cover art, and title that
  Apple Books and other audiobook players understand, **Audio (MP3)** for a
  file that plays almost anywhere, or **Audio Only (WAV)** for the raw
  narration. The M4B chapters start exactly where each chapter's narration
  starts. **Subtitles (SRT)** and **Subtitles (WebVTT)** save timed captions of
  the transcript for video editors and web players. While an export runs, the
  export button shows its progress and the same menu offers **Cancel Export**.
  Long books can take a minute to encode as MP3 before the progress moves.
- Set the M4B quality in **Settings -> Audiobooks -> Export Quality**.
  64 kbps keeps narration clear and files small; 128 kbps is the largest.
  **MP3 Quality** sets the MP3 bitrate from 64 to 192 kbps; 96 kbps suits
  spoken word.

Voqora stores the source document, extracted text, generated audio, transcript,
and audiobook state locally until you delete that book. Close the app and return later without
starting the document from the beginning.

### Optional document cleanup

Most text-based documents can be handled locally. If extraction is poor, you
can choose optional AI cleanup with a provider you connect: OpenAI, Anthropic,
xAI, Groq, Cerebras, Google Gemini, OpenRouter, Ollama, LM Studio, or a Custom
OpenAI-compatible server.

1. Open **Settings -> AI** and choose **Add Provider…**, pick a provider, enter
   its API key (Ollama and LM Studio need none) and model, and choose
   **Connect**. Voqora checks the connection before saving. You can also
   connect a provider during setup.
2. If you connect more than one, choose the one under **Used for audiobooks**.
3. When you add a document, turn on **Clean Up with <provider>** at the bottom
   of the New Audiobook page. The provider menu there switches providers for
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

## AI reading tools

With an AI provider connected in **Settings -> AI**, the audiobook player
shows an **Assistant** panel next to **Transcript** and **Sections**. If no
provider is connected, the panel offers to connect one. The tools send the
book's text to the provider used for audiobooks; Ollama, LM Studio, and local
Custom servers keep it on your Mac.

- **Summary**: choose Short, Medium, or Detailed and an output language, then
  choose **Summarize Book**. Long books can take a few minutes.
- **Ask**: type a question about the book and press Return. Answers list the
  passages they come from; select a citation to play the book from that
  sentence.
- **Quiz**: pick a difficulty and how many questions, then answer each one to
  see whether you were right and why. Your score appears at the top.
- **Flashcards**: click a card to flip it, use **Previous** and **Next**
  (Command-Left and Command-Right), and choose **Mark Known** (Command-K) to
  skip cards you already know.

Every result can be copied or spoken aloud with your speech voice, switched to
a voice in the result's language when needed. Speaking stops the audiobook;
press Play to continue where you left off. Switching away from the Assistant
panel or closing the player cancels any request that is still running.

Two global shortcuts work in any app. They have no keys at first, so assign
them in **Settings -> Shortcuts**:

- **Summarize Selection and Speak** reads the selected text, asks your provider
  for a short summary, and speaks it.
- **Translate Selection and Speak** translates the selection and speaks it with
  a voice for that language. Choose the language under **Translate Selection
  Into** in **Settings -> AI**. It starts as the first non-English language
  in your Mac's language list that Voqora has a voice for, or Spanish.

If Voqora is already busy with other AI requests, the provider is rate limiting
your key, or a text is over the size or cost limit for one request, Voqora says
so and nothing is spoken. Selections can be up to 20,000 characters for
translation.

## Make a podcast in Create

Podcasts made in **Create** turn something you want to understand into a
conversation, and let you write scripts for several voices yourself.

1. Open **Create** in the sidebar and choose **New Podcast**
   (`Shift + Command + N`).
2. Pick the source: an item from your Library, or text. Paste text, choose
   **Paste from Clipboard**, or choose **Use Last Spoken Text** to reuse what
   Voqora just read aloud.
3. Choose a style. **Deep Dive** and **Brief** use one or two hosts,
   **Debate** uses two, and **Lecture** uses one. Set the length (2 to 30
   minutes) and the language, then name the hosts and pick their voices. Your
   voice blends are listed too. Use the play button to hear a voice.
4. Choose **Generate Script** (`Command + Return`). Writing the script uses the
   AI provider you connected in **Settings -> AI**, and sends the
   source text to it. Without a provider, Create shows where to add one, or
   you can start a blank script instead.

### Edit the script

- Each turn has a speaker, its text (up to 2,000 characters), and the pause
  after it. Drag turns to reorder them, or use the turn menu to insert a turn
  below, move it, start a chapter there, or delete it.
- The speakers table sets each speaker's name and voice, with a preview for
  each. A script can have up to four speakers and 600 turns. Removing a speaker
  moves their turns to the first speaker.
- Scripts save on your Mac as you edit (`Command + S` saves right away). Find
  them under **Scripts** on the Create page.
- **New Blank Script** (`Shift + Command + B`) starts an empty script you
  write yourself. Rendering it needs no AI provider.

### Render and listen

Choose **Render Podcast** (`Command + R`). Voqora narrates each turn with its
speaker's voice on your Mac, and the podcast appears in the Library with a
**Podcast** badge and the usual progress. The transcript shows who is talking.

To change a podcast later, right-click it in the Library and choose **Edit
Script in Studio**, or choose **Edit Script** under **Rendered Podcasts**.
You edit a copy, and rendering it adds a new podcast while the original stays
in the Library. Right-click any finished audiobook and choose **Make a
Podcast** to start from it.

## Reading Mode

Reading Mode shows the text being read, from a selection or an audiobook, in a
window of its own. It is built for focus, dyslexia, and low vision.

- Open it with the page button next to the transcript in the player, or choose
  **Reading Mode** from the menu bar icon. Use the green window button or the
  full screen button in the control bar to fill the screen. Press Escape to
  close it.
- The sentence being read is highlighted. Turn on **Reading Ruler** to dim
  everything else. When word timing is available, **Word-by-Word Emphasis**
  marks each word as it is spoken; otherwise the whole sentence is highlighted.
  Audiobooks include word timing.
- Click any sentence to play from it. Press Space to pause or resume.
- Use the text size buttons in the control bar, or open the settings button to
  choose a font (System, Rounded, Serif, or Mono), text size from 14 to 48 pt,
  line height, letter spacing, and word spacing.
- Pick a Paper, Sepia, Dark, or High Contrast theme, and add a soft tint if a
  colored page is easier on your eyes.

The same settings live in **Settings -> Speech**, with a live preview, and
are remembered between sessions. Reading Mode follows the macOS Reduce Motion
and Increase Contrast settings.

## Stats

Open **Stats** under **Insights** in the sidebar to see your listening time, voices, streaks, and
library totals over the last 7 days, 30 days, 12 months, or all time. Stats are
kept in a file on your Mac and are never sent anywhere. Choose **Reset Stats**
on the page to clear them; **Erase All Local Data** clears them too.

## Run Voqora from the menu bar

Turn on **Settings -> General -> Hide from Dock & App Switcher** to keep
Voqora in the menu bar only. The menu bar icon stays on while the Dock icon is
hidden.

## History and export

**History**, under **Activity** in the sidebar, keeps a local record of spoken
selections. Search it, star the
passages you want to keep, and play any of them again. Use
`Command + Shift + M` to save the latest clip to your Desktop as a WAV file.

## Integrations

Open **Settings -> Integrations** to connect Voqora to other apps.

### Local API for apps and AI tools

Turn on **Local API** to let apps and AI tools on this Mac use Voqora's voices.
It is off until you turn it on and only accepts connections from this Mac.

- **Port.** Voqora listens on port 51851 by default. Enter any port from 1024
  to 65535 and press Return. If another app already uses the port, the status
  line says so; choose a different one.
- **API key.** Voqora creates a random key the first time you turn the API on
  and keeps it in your Keychain. Use the eye button to show it, **Copy** to
  copy it, and **Regenerate** to replace it. Apps using the old key stop
  working until you give them the new one.
- **Setup snippets.** Copy a ready-made `curl` command for the OpenAI-compatible
  speech endpoint, a `claude mcp add` command for Claude Code, or an
  `mcpServers` entry for other MCP clients. Each one includes your port and key.

When a tool asks Voqora to speak, the text plays through Voqora like a spoken
selection, with your current voice unless the tool names one. A new request
replaces the one playing unless the tool asks to queue it, in which case it
plays after what is already speaking. A stop request stops speech and clears the
queue. The speech endpoint takes up to 4,096 characters per request. If the tool sends its
name, a short note says which app asked.

### Audiobookshelf

Send finished audiobooks to your own Audiobookshelf server.

1. Enter the server address, such as `https://abs.example.com`. Plain `http`
   works only for servers on your own network, and Voqora warns you that the
   connection is not encrypted.
2. In Audiobookshelf, create an API key (under **Settings -> API Keys**), then
   paste it into **API Token** and choose **Save**. The account needs
   permission to upload. Voqora keeps the token in your Keychain.
3. Choose **Test Connection**, then pick the library (and folder, if it has more
   than one) that should receive uploads.

Then open a finished book's **Export** menu and choose **Upload to
Audiobookshelf**. Voqora makes an M4B with chapters and cover art, uploads it,
and shows progress on the export button. Choose **Cancel Upload** from the same
menu to stop. **Disconnect** removes the address and deletes the token.

### Shortcuts and Services

The Integrations tab also lists the Shortcuts actions and the Services menu
items described in [More ways to start speech](#more-ways-to-start-speech).

## Updates

Voqora checks for a new release when it launches, at most once every six hours,
and notifies you when one is available. You can also choose **Check for Updates** in **About Voqora**, **Settings -> General**, or the
menu bar icon menu.
Choose **Download Latest Version** to download the verified DMG and open it in
Finder, then drag the new version to Applications. Voqora never replaces itself
automatically.

## About and feedback

Choose **About Voqora** from the app menu to see the version, check for
updates, and find the developer's links. Choose **Send Feedback…** from the
**Help** menu to send a note from the app. **Settings -> Privacy & Data** holds an
optional name and email, used only to reply to your feedback, and the data tools.
**Run Setup Again** is in **Settings -> General**.

## Troubleshooting

### Voqora is still initializing

The native app starts a bundled local speech service on first launch. Give it a
moment, then reopen Voqora if it remains unavailable. If you are building from
source, `make run` builds the bundled server before the app.

### The shortcut does nothing

Check that Voqora has the macOS permission it requests to read selected text
from other apps. Then confirm the shortcut has not been claimed by another
utility in **Settings -> Shortcuts**.

To see which macOS permissions Voqora has, open **Settings -> Permissions**. It
shows Accessibility, Microphone, Speech Recognition, Screen Recording, and
Notifications, and opens the System Settings page for any that is not granted.

### A document needs cleaner text

Try the local flow first. If the document is scanned or extraction is poor,
use the optional AI cleanup path with a local provider, or with a cloud
provider only if you are comfortable sending that document material to it with
your own key.

### Where are the logs?

Choose **Settings -> Privacy & Data -> Data -> Export Debug Logs**. The files are written to
your Desktop so you can attach them to a
[GitHub issue](https://github.com/himudigonda/Voqora/issues).
