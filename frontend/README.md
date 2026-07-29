# Voqora for macOS

This directory contains the native SwiftUI application: the reading experience,
global shortcuts, audio playback, preferences, local history, and audiobook
views.

## Open the project

Open `Voqora/Voqora.xcodeproj` in Xcode, or build the full app from the
repository root:

```bash
make backend
make app
make run
```

The full app needs the backend zip produced by `make backend`. The release
pipeline places that bundle, fonts, license, and notices inside the app before
creating the DMG.

## Test deliberately

Swift tests require Xcode to launch a macOS test host. Use the explicit serial
command when the change warrants it:

```bash
make test-swift
```

For normal backend or documentation work, use `make verify` instead. It does
not launch a Mac app host.

## Key areas

| Path | Responsibility |
| --- | --- |
| `Voqora/Views/` | Reading, audiobook, onboarding, and Preferences UI. |
| `Voqora/Services/` | Local-server lifecycle, streaming audio, history, telemetry, and system integration. |
| `Voqora/Utilities/Shortcuts.swift` | Default global shortcuts and their registrations. |
| `VoqoraTests/` | Native unit and service behavior. |

Read the repository [architecture guide](../docs/architecture.md) before
changing the local-server boundary or a public data-handling claim.
