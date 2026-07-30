# Voqora privacy summary

Voqora synthesizes speech through a service bundled with the macOS app. Text
sent to that local service stays on your Mac.

Some features can make external requests:

| Feature | When it communicates externally |
| --- | --- |
| Optional product telemetry | When the telemetry toggle is enabled in Preferences. It sends product-use metadata, not the text selected for speech. |
| Optional document cleanup | Only when you provide a Gemini API key and choose that flow. The selected document material is sent to Gemini for that operation. |
| Release checks | When automatic update checks are enabled or you choose **Check for Updates**. The app checks Voqora's public update feed for a newer release; it does not upload your text, files, or account data. |

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
