# Voqora privacy summary

Voqora synthesizes speech through a service bundled with the macOS app. Text
sent to that local service stays on your Mac.

Some features can make external requests:

| Feature | When it communicates externally |
| --- | --- |
| Optional product telemetry | When the telemetry toggle is enabled in Preferences. It sends product-use metadata, not the text selected for speech. |
| Optional PDF cleaning | Only when you provide a Gemini API key and choose the PDF-cleaning flow. The selected document material is sent to Gemini for that operation. |
| Release checks | When you ask the app to check GitHub releases. |

Voqora does not require an account to speak text. Review the relevant source
before using an optional integration with material that should not leave your
Mac. If you need help with data deletion or have a privacy question, open a
GitHub issue in this repository.
