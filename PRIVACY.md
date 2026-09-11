# Voqora privacy summary

Voqora synthesizes speech through a service bundled with the macOS app. Text
sent to that local service stays on your Mac.

## Local audiobook data

When you import a document, Voqora keeps the original source document, extracted
and cleaned page text, generated WAV audio, cover image, transcript, and local
book metadata on this Mac so narration can resume after the app closes. It keeps
those files **until you delete the book**. Deleting a book removes its source and
all of those derived files. The library's Delete All Books control removes every
book and its local book data. Device backups may retain an older copy until the
backup provider's normal retention period expires.

Debug logs are operational metadata, not a document archive: Voqora redacts
selected text, source paths, API-key-like values, IPC credentials, and raw
provider/parser errors before a user exports diagnostics. Review exported logs
before sharing them with support.

Some features can make external requests:

| Feature | When it communicates externally |
| --- | --- |
| Optional product telemetry | When the telemetry toggle is enabled in Preferences. It sends product-use metadata, not the text selected for speech. |
| Optional document cleanup or OCR | Only when you provide a Gemini API key and choose that flow. The relevant document text or scanned-page image is sent to Gemini for that operation. |
| Release checks | At launch as a courtesy check or when you choose **Check for Updates**. The early-access app reads public GitHub release metadata to learn whether a newer version exists; it does not upload your text, files, account data, or replace the app automatically. |

Telemetry reports anonymous installations, not a deduplicated count of people.
If you voluntarily enter an email in Voqora, it is stored separately from
anonymous events and is the only possible future basis for linking identity.
Use **Preferences → Identity → Remove** to delete that optional contact from
the product backend and this Mac. Removing it does not change the separate,
anonymous event history.

Voqora does not require an account to speak text. Review the relevant source
before using an optional integration with material that should not leave your
Mac. If you need help with data deletion or have a privacy question, open a
GitHub issue in this repository.
