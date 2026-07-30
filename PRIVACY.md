# Voqora privacy summary

Voqora synthesizes speech through a service bundled with the macOS app. Text
sent to that local service stays on your Mac.

Some features can make external requests:

| Feature | When it communicates externally |
| --- | --- |
| Optional product telemetry | When the telemetry toggle is enabled in Preferences. It sends product-use metadata, not the text selected for speech. Every event is labelled `voqora`; the retired SuperSay legacy app uses a separate `supersay` label. |
| Optional PDF cleaning | Only when you provide a Gemini API key and choose the PDF-cleaning flow. The selected document material is sent to Gemini for that operation. |
| Release checks | When you ask the app to check GitHub releases. |

If SuperSay is found in `/Applications` or `~/Applications`, Voqora can report
that discovery, a completed explicit preference import, and a later observed
legacy-app removal. These are product events only. Voqora never uploads the
legacy app's preferences or contents, and it never removes SuperSay itself.

Telemetry reports anonymous installations, not a deduplicated count of people.
If you voluntarily enter an email in Voqora, it is stored separately from
anonymous events and is the only possible future basis for linking identity.

Voqora does not require an account to speak text. Review the relevant source
before using an optional integration with material that should not leave your
Mac. If you need help with data deletion or have a privacy question, open a
GitHub issue in this repository.
