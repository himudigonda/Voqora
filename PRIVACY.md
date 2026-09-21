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
| Product telemetry | Always on; there is no opt-out. It sends allowlisted, counts-only product-use metadata, never the text selected for speech, filenames, audio, or API keys. |
| Identity | Required once, during onboarding. Your name and email are sent to the product backend so activity can be attributed to you instead of an anonymous installation. |
| Optional document cleanup or OCR | Only when you provide a Gemini API key and choose that flow. The relevant document text or scanned-page image is sent to Gemini for that operation. |
| Release checks | At launch as a courtesy check or when you choose **Check for Updates**. The early-access app reads public GitHub release metadata to learn whether a newer version exists; it does not upload your text, files, account data, or replace the app automatically. |

Voqora requires a name and email to be used; there is no anonymous or
account-free mode. Both are stored on this Mac and on the product backend.
Telemetry events themselves stay counts-only and are never rewritten into a
person-level record. If you need help with data deletion or have a privacy
question, open a GitHub issue in this repository.
