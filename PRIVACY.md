# Voqora privacy summary

Voqora synthesizes speech through a service bundled with the macOS app. Text
sent to that local service stays on your Mac.

Some features can make external requests:

| Feature | When it communicates externally |
| --- | --- |
| Optional product telemetry | When the telemetry toggle is enabled in Preferences. It sends product-use metadata, not the text selected for speech. An optional email can associate anonymous counts with a user; it is never required to use the app. |
| Optional document cleaning | Only when you provide a Gemini API key, explicitly confirm consent, and choose the cleanup/OCR flow. Relevant PDF, DOCX, Markdown, or text-file material is sent to Gemini for that operation. |
| Release checks | When you ask the app to check GitHub releases. |

Voqora does not require an account to speak text. Review the relevant source
before using an optional integration with material that should not leave your
Mac. If you need help with data deletion or have a privacy question, open a
GitHub issue in this repository.
