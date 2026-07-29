# Contributing to Voqora

Thanks for improving Voqora. Keep changes small, product-led, and easy to
verify.

## Local setup

You need an Apple-silicon Mac on macOS 14+, Xcode, Python 3.11+, and `uv`.

```bash
git clone https://github.com/himudigonda/Voqora.git
cd Voqora
make setup
make run
```

The first backend build downloads the pinned model assets and verifies their
checksums. Those assets are intentionally ignored by Git.

## Where changes belong

| If you are changing… | Start in… |
| --- | --- |
| Native UI, shortcuts, playback, or Preferences | `frontend/Voqora/Voqora/` |
| Speech API, local engine, or audiobook processing | `backend/app/` |
| Deterministic Python behavior | `backend/tests/` |
| Swift services or view models | `frontend/Voqora/VoqoraTests/` |
| DMG, backend packaging, or shipping | `scripts/` and `docs/release.md` |
| Public claims | `README.md`, `PRIVACY.md`, `CHANGELOG.md`, and relevant docs together |

## Before a pull request

1. Explain the user-visible outcome in the pull request.
2. Add or update the smallest relevant deterministic test.
3. Run `make verify` for normal work.
4. Run `make test-swift` only when your change affects Swift behavior. It
   launches one serial macOS test host by design.
5. Update documentation when install behavior, a shortcut, data handling, or a
   release contract changes.

Do not commit model files, generated backend zips, DMGs, archives, logs, local
credentials, or user documents.

## Product and license boundary

The core user experience must remain understandable as: select text, use a
shortcut, listen. Do not add an account requirement to that flow casually.

Voqora is source-available under PolyForm Noncommercial 1.0.0. Contributions
are accepted under the repository license. Commercial use needs a separate
agreement; see [COMMERCIAL-LICENSE.md](../COMMERCIAL-LICENSE.md).
