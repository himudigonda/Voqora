# Privacy Policy

Last updated: 2026-10-21. Applies to Voqora 2.0.0 and later.

Voqora is a free Mac app by Himansh Mudigonda ("I", "me"), the controller of
the data described here. Speech is generated on your Mac. I collect as little
as I can, and everything below that leaves your Mac is optional.

## What leaves your Mac, and only if you choose it

| What | When | Where it goes | Why |
| --- | --- | --- | --- |
| Name and email | Only if you enter them in setup or Settings -> Privacy & Data. Both fields can be left blank. | himudigonda.me | To contact you about Voqora. |
| Usage analytics | Only if you turn on **Share Usage Analytics** in setup or Settings -> Privacy & Data. Off by default. | himudigonda.me | To see which features are used and fix problems. |
| Feedback | Only when you send a note with **Send Feedback…**. | himudigonda.me | To read and reply to your feedback. |
| Update check | Automatically, at most every six hours, and when you ask. | api.github.com | To tell you a newer version exists. Sends no personal data beyond what any web request reveals, such as your IP address. |
| Installer download | Only when you choose **Download Latest Version**. | github.com | To fetch the official DMG. |
| Parakeet dictation model | Only when you choose **Download** or **Repair** for the Parakeet engine in dictation settings. | huggingface.co | To fetch the speech model (about 470 MB). After that, dictation with Parakeet runs entirely on your Mac. |
| Bark and Bark Clean dictation models | Only when you choose **Download** or **Repair** for Bark or Bark Clean in dictation settings or onboarding. | huggingface.co | To fetch the speech model (about 440 MB for Bark, 450 MB for Bark Clean), pinned to one revision and checked against a SHA-256 for every file. After that, dictation with Bark runs entirely on your Mac. |
| Optional speech engines | Only when you choose **Download** for Supertonic or Ming in Settings -> Engines. | huggingface.co for the model files; for Ming also github.com for its code and the Python package index (pypi.org and files.pythonhosted.org) for its dependencies | To install the engine. After that, speech with that engine runs entirely on your Mac. |
| Dictation transcripts and AI tool text | Only when you connect your own AI provider and use AI tidy for dictation, or an AI tool (summarize, translate, ask, quiz, flashcards, podcast scripts). Ollama and LM Studio keep this text on your Mac. | The provider you connected | To do the task you asked for, under that provider's terms. |
| Page text and scanned-page images | Only for audiobooks where you connect your own AI provider and switch on AI cleanup. Ollama and LM Studio keep this text on your Mac; a Custom server receives it at the address you enter. | The provider you connected (OpenAI, Anthropic, xAI, Groq, Cerebras, Google Gemini, or OpenRouter) | To clean up the document, under that provider's terms. |

An email you share is stored against the same anonymous install ID used for
opt-in analytics. Feedback is sent with that ID while analytics is on, and with
a one-time random ID while analytics is off.

Analytics, when on, are tied to a random anonymous ID and cover app launches,
the voice, speed, and length of generated audio, audiobook uploads (page count
and file type), listening time, exports, and installer events. They never
include your text, your documents, your file names, or your audio.

### What analytics collect

When on, analytics carry counts and durations: how many times you read text
aloud and from where (selection, clipboard, screen, shortcut, Inbox, History,
AI, apps and agents, voice previews, or in-app), how long audio took to start
and render, dictation word counts, audio length, language code and whether
Tidy ran, AI tool names with provider and response time, audiobook and podcast
counts, chapter counts, and lengths, import and export kinds, and a daily
total of listening, speech, dictation, and AI use. Engine names are limited to
a fixed list, and apps or agents that send speech are reduced to a fixed list
of common names or "other".

They never include your text, file names, titles, links, email, the names of
apps you dictate into, the raw names of apps or agents that send speech to
Voqora, regional locale, model names, or the names of voices you recorded or
blended. Everything is sent over HTTPS and only while the setting is on.

Legal basis (GDPR and similar laws): your consent for analytics and for name
and email. You can withdraw consent at any time by turning analytics off or by
removing your email in Settings -> Privacy & Data.

## What stays on your Mac

Your documents, generated audio, listening history, audiobook progress, and
preferences are stored locally in
`~/Library/Application Support/com.himudigonda.Voqora`. Your AI provider API keys are
stored in your macOS login Keychain, one per provider. Voqora sends a key only
to its own service on your Mac, with each cleanup request, and from there to
the provider you connected. Keys are not included in analytics. Speech is generated on your Mac, by the Kokoro
model that ships inside the app or by an optional engine you downloaded, so no
text you have Voqora read aloud is sent anywhere.

Dictation turns speech into text on your Mac, using Apple's on-device speech
recognition or an optional local model (Parakeet, Bark or Bark Clean). Your audio is not stored or sent.
Transcripts are kept in your dictation history, together with the original
wording when AI tidy changed it, until you delete them. While you dictate,
the text so far is saved to a recovery file that is removed once the
transcript reaches your history. Debug builds, and release builds with
**Save debug traces** on, write dictation timing logs next to them.

The Stats page (listening time, voices, streaks, and library totals) is
computed from a file on your Mac. It is never sent anywhere, you can reset it
from the page, and Erase All Local Data clears it. It is separate from the
usage analytics above.

Voqora asks for macOS Accessibility permission to read the text you select in
other apps, and Automation permission to lower Music or Spotify volume while
it speaks (optional). It reads selected text only when you press the shortcut
and does not store or send anything else about other apps.

## Retention and deletion

- Local data stays until you delete it. **Settings -> Privacy & Data -> Data -> Erase
  All Local Data** removes books, audio, history, settings, identifiers, and your
  provider keys.
- Name, email, and analytics held on my server are kept while Voqora is
  maintained or until you ask me to delete them. Erasing local data does not
  contact the server, so to have your server-side record deleted, ask me
  (below) and include the email you used. I will respond within 30 days.
- The same route works to access or correct anything I hold about you.

## Sharing

I do not sell your data or share it for advertising. Data on my server is
processed only by me and by the hosting provider that runs the site, under
its standard terms. The only other recipients are the services named in the
table above.

## Children

Voqora is not directed at children under 13, and I do not knowingly collect
their data.

## Changes

If this policy changes in a way that affects you, I will update the date above
and note it in the release notes.

## Contact

Open an issue at <https://github.com/himudigonda/Voqora/issues> or reach me
through [himudigonda.me](https://himudigonda.me). For anything private, use
the contact route in [SECURITY.md](SECURITY.md).
