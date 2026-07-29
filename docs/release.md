# Releasing Voqora

This is the release checklist for the public Voqora line. A release is not just
a successful archive: the version, source, DMG, installer, notes, and GitHub
release must all describe the same product.

## 1. Prepare the version

Before building:

- Update the top section of `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD`.
- Update the product version in the Xcode project and backend package metadata.
- Confirm `README.md`, `PRIVACY.md`, and the changelog agree about the release.
- Ensure the working tree is clean and `gh auth status` succeeds.

## 2. Validate proportionately

```bash
make verify
make test-swift    # explicit: launches one serial macOS test host
```

Use the full Swift command once for a release candidate, not repeatedly during
ordinary documentation or packaging edits.

## 3. Build and inspect the DMG

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

## 4. Publish

```bash
make ship VERSION=X.Y.Z
```

The ship script refuses a dirty tree and an existing tag. It pushes `main`,
creates `vX.Y.Z`, attaches the DMG, and publishes GitHub release notes from the
matching changelog section.

## 5. Verify the public result

- Open the GitHub release page in a logged-out browser session.
- Download the DMG and confirm its SHA-256 matches the build receipt.
- Check that the repository default branch and release tag contain only Voqora
  branding.
- Check that the release notes explain what users get, not internal project
  history.

## 6. Signing and notarization

v1.0.0 is ad-hoc signed. Before a frictionless mass-market release, add a
Developer ID Application certificate and notarization credentials to the
release environment, then verify the downloaded DMG on a clean Mac.
