# Releasing Voqora

This is the release checklist for the public Voqora line. A release is not just
a successful archive: the version, source, DMG, installer, notes, and GitHub
release must all describe the same product.

## 1. Release model

`main` is the only public branch. Keep unreleased work isolated from `main` and
do not publish it until the release is approved.

Voqora uses Sparkle 2 for in-app updates. Every release has two identifiers:

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
- Confirm `README.md`, `PRIVACY.md`, and the changelog agree about the release.
- Ensure the working tree is clean and `gh auth status` succeeds.
- Run `scripts/validate_release.sh X.Y.Z` before any archive. It verifies the
  Xcode marketing/build versions and both backend version declarations, so a
  DMG cannot be assembled from a mixed-version source tree.

## 3. Validate proportionately

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
and notices, and creates `build/Voqora-X.Y.Z.dmg`.

Inspect the actual mounted DMG:

1. The window title, installer text, and app label say Voqora.
2. Both the Voqora app and Applications destination are readable.
3. The app bundle reports the intended bundle identifier and version.
4. The local server starts and selected text can be spoken.

## 5. Create and publish the signed update feed

After the DMG is built, generate the Sparkle appcast while the update signing
key is available in the release Mac's Keychain:

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
- From a separately installed older build, open **Preferences → Check for
  Updates**. It should accept the signed appcast and offer the newer release
  rather than download and run a DMG installer itself.
- Check that the repository default branch and release tag contain only Voqora
  branding.
- Check that the release notes explain what users get, not internal project
  history.

## 8. Distribution signing and notarization

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

For a deliberately free, non-notarized experimental distribution only, the
release owner must make that trade-off explicit:

```bash
ALLOW_UNNOTARIZED_PUBLIC_RELEASE=1 make ship VERSION=X.Y.Z
```

That escape hatch still requires a valid Sparkle archive signature and all
normal release checks. It is not a way to bypass those checks, and it means the
README's macOS **Open Anyway** / scoped `xattr` recovery guidance remains part
of the user journey.
