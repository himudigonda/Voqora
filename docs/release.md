# Releasing Voqora

This is the release checklist for the public Voqora line. A release is not just
a successful archive: the version, source, DMG, installer, notes, and GitHub
release must all describe the same product.

## 1. Release model

`main` is the only public branch. Keep unreleased work isolated from `main` and
do not publish it until the release is approved.

The current early-access channel uses a verified DMG handoff: the app obtains
official GitHub release metadata, verifies the DMG's published SHA-256, then
opens the DMG in Finder for an explicit drag to Applications. It does not use
Sparkle to replace an unsigned app.

Sparkle is reserved for the later Developer ID-signed and notarized channel.
Every public release still has two identifiers:

- **Marketing version**: what people see, for example `1.0.0`.
- **Build number**: the monotonically increasing bundle identity Sparkle uses.

Every public update needs a semantically newer marketing version and a higher
build number. Do not replace a released asset in place: Sparkle will not treat
an equal-version build as a new update.

## 2. Prepare the version

Before building:

- Update the top section of `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD`.
- Update the product version in the Xcode project, backend package metadata,
  and backend runtime configuration.
- Increment both the public version and `CURRENT_PROJECT_VERSION` for every
  distributable update.
- Run `make backend` after any backend/version change. It creates
  `VoqoraServer.zip` plus its deterministic detached manifest; the manifest
  must verify the exact archive in both the source tree and mounted DMG.
- Confirm `README.md`, `PRIVACY.md`, and the changelog agree about the release.
- Ensure the working tree is clean and `gh auth status` succeeds.
- Run `scripts/validate_release.sh X.Y.Z` before any archive. It verifies the
  Xcode marketing/build versions and both backend version declarations, so a
  DMG cannot be assembled from a mixed-version source tree.

## 3. Validate proportionately

SwiftLint and SwiftFormat are required release-quality tools. Install them on a
release machine with `brew install swiftlint swiftformat`; `make lint` fails
closed when either is unavailable. CI installs both on its clean macOS runner
and runs the same strict lint and format checks before app-host tests. A new
tool release that changes the result is a deliberate gate: update checked-in
configuration or source with a reviewed change, never suppress the failure.

The backend CI job also runs the pinned `pip-audit` scanner against the exact
environment created from `uv sync --frozen`. It must find no known
vulnerabilities. Do not audit a re-resolved requirements export under a
different Python interpreter: that can report an installation failure instead
of assessing the locked runtime that is actually bundled.

```bash
make verify
make test-swift    # explicit: launches one serial macOS test host
```

Use the full Swift command once for a release candidate, not repeatedly during
ordinary documentation or packaging edits.

## 4. Build and inspect the DMG

```bash
make release VERSION=X.Y.Z
```

This builds the local backend bundle, archives the Release app, includes fonts
and notices, and creates `build/Voqora-X.Y.Z.dmg` plus the matching
`build/Voqora-X.Y.Z.dmg.sha256` receipt. The receipt is written after any
notarization stapling, so it names the final immutable DMG bytes.

Inspect the actual mounted DMG:

1. The window title, installer text, and app label say Voqora.
2. Both the Voqora app and Applications destination are readable.
3. The app bundle reports the intended bundle identifier and version.
4. The bundled backend archive and `VoqoraServer.manifest.json` are present.
5. The local server starts and selected text can be spoken. The release gate
   runs `scripts/test_frozen_backend.py` against the mounted archive: it uses
   the inherited loopback FD, verifies token rejection, checks `/health` and
   `/engine`, and requires a minimal `/speak` WAV response.

## 5. Create and publish the signed update feed only for the notarized channel

Do this only after Developer ID signing and notarization are available. After
the DMG is built, generate the Sparkle appcast while the update signing key is
available in the release Mac's Keychain:

```bash
make appcast VERSION=X.Y.Z
git add docs/updates/appcast.xml
git commit -m "release: publish vX.Y.Z update feed"
```

The feed points to the immutable GitHub release asset URL and is deployed to
GitHub Pages by `.github/workflows/pages.yml`. Enable **Settings → Pages →
Source → GitHub Actions** once in the GitHub repository before the first
release. Do not push the new feed by itself: `make ship` uploads the immutable
DMG first, then pushes `main` so Pages can expose an enclosure that already
exists. Confirm `https://himudigonda.github.io/Voqora/appcast.xml` only after
that ordered publish completes.

## 6. Publish

### Manual early-access channel (the 1.2.3 release path)

Do **not** run `make appcast` for an unsigned early-access build. Its explicit
manual channel refuses to ship if the versioned DMG is already named in the
Sparkle feed, uploads both the DMG and its SHA-256 receipt, and adds an
installation note to the release. It still requires a clean `main`, exact
version checks, a unique tag, and a successful mounted-DMG validation.

```bash
ALLOW_UNNOTARIZED_PUBLIC_RELEASE=1 RELEASE_CHANNEL=manual make ship VERSION=X.Y.Z
```

This is a consciously limited public distribution path: the in-app guided
installer verifies the GitHub API SHA-256 before opening the DMG, but the user
must drag Voqora to Applications and may need the standard macOS **Open
Anyway** confirmation. The release page exposes the matching `.sha256` file
for independent manual verification. Never add that release to
`docs/updates/appcast.xml`; doing so would create an automatic-update promise
the unsigned channel is not allowed to make.

### Notarized Sparkle channel

```bash
make ship VERSION=X.Y.Z
```

The ship script refuses a dirty tree, an unsigned or missing update feed, an
existing tag, a version mismatch, or a distribution artifact that is not
Developer ID signed and notarized. It creates `vX.Y.Z` and attaches the DMG
first. Only after the immutable GitHub asset exists does it push `main`, which
lets GitHub Pages expose the matching appcast. This prevents a running app from
seeing an enclosure before the file it names is available. GitHub release notes
come from the matching changelog section.

## 7. Verify the public result

- Open the GitHub release page in a logged-out browser session and confirm the
  exact DMG asset can be downloaded before checking the appcast.
- Download the DMG and confirm its SHA-256 matches the build receipt.
- In the early-access channel, choose **Preferences → Download latest
  installer**. Confirm it opens only a digest-verified DMG in Finder and that
  no app is replaced automatically.
- In the notarized Sparkle channel, separately install an older build and
  verify the signed appcast offers the newer release.
- Check that the repository default branch and release tag contain only Voqora
  branding.
- Check that the release notes explain what users get, not internal project
  history.

## 8. Distribution signing and notarization

### Reviewed third-party test-warning exceptions

The backend test configuration treats warnings as errors. Version 1.2.3 has
only these narrowly scoped dependency exceptions, both owned by the release
maintainer and required to be removed when the named upstream dependency ships
the compatible fix:

- `starlette.exceptions.StarletteDeprecationWarning` during `TestClient`
  import: remove when the locked FastAPI/Starlette/httpx stack supports the
  upstream `httpx2` migration.
- `google.genai.types`' Python-3.17 `_UnionGenericAlias` deprecation: remove
  when the locked `google-genai` release eliminates the deprecated typing
  reference.

No source warning or any other dependency warning may be waived in this list.

### Reviewed third-party packaging-analysis warning

On macOS, the locked PyInstaller dynamic-library scanner can print exactly
`Library user32 required via ctypes not found`. This is its built-in Windows
DLL candidate list, not a Voqora import or a missing macOS library: the source
and frozen archive are checked for that dependency, and the exact frozen
archive is launched through `scripts/test_frozen_backend.py` on every release
candidate. The release maintainer owns this exception; remove this note once
the locked PyInstaller version stops emitting the cross-platform scanner
message. Do not suppress, waive, or generalize any other packaging warning.

Xcode 26 can also invoke `appintentsmetadataprocessor` for a target with
`EXTRACT_APP_INTENTS_METADATA=NO` and print exactly `Metadata extraction
skipped. No AppIntents.framework dependency found.` Voqora has no AppIntents
source or framework dependency; this is an Xcode tooling notice and cannot
affect the bundled app. The release maintainer owns it and must remove this
exception once the selected Xcode stops invoking that no-op extractor. No other
Xcode compiler, asset-catalog, or runtime warning is acceptable.

Sparkle verifies each update archive with the app's public EdDSA key. The
matching private key remains in the release Mac's Keychain and must be backed
up securely before a second release machine is used.

Developer ID signing and notarization are still a separate Apple requirement.
Set `DEVELOPER_ID_APPLICATION` and `NOTARYTOOL_PROFILE` in the release
environment. `create_dmg.sh` uses the Developer ID when present, validates the
app signature, submits the final DMG to notarytool, and staples the ticket.
`make ship` enables that strict preflight by default and additionally verifies
the mounted app's Developer ID team, the stapled ticket, and Gatekeeper
assessment. It does not pretend ad-hoc signing is public-ready.

For a deliberately free, non-notarized early-access distribution only, the
release owner must make that trade-off explicit and select the manual channel:

```bash
ALLOW_UNNOTARIZED_PUBLIC_RELEASE=1 RELEASE_CHANNEL=manual make ship VERSION=X.Y.Z
```

That escape hatch still requires all normal source, artifact, mounted-DMG, and
checksum checks. It intentionally skips and rejects the Sparkle path; it is
not a way to bypass those checks, and it means the README's macOS **Open
Anyway** / scoped `xattr` recovery guidance remains part of the user journey.
