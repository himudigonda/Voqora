# Testing Voqora without overloading your Mac

The backend suite is fast and headless. Swift tests are different: Xcode starts
a macOS test-host app. Running several Xcode test commands at once can create
multiple app hosts and consume a lot of CPU. Voqora makes that cost explicit.

## Choose the smallest useful check

| Change | Command | What it does |
| --- | --- | --- |
| Python or API change | `make test` | Fast backend tests only. No Mac app host. |
| Formatting or static checks | `make lint` | Ruff, Black, and SwiftLint when installed. |
| Routine pre-commit check | `make verify` | Lint plus fast backend tests. No Mac app host. |
| Swift UI or service change | `make test-swift` | One serial macOS test host. |
| Deliberate full local proof | `make test-ci` | Backend tests, then one serial macOS test host. |

## Why the Swift target is explicit

`make test-swift` uses a repository lock and refuses to start if another
Voqora Xcode test process is already active. It also disables parallel testing.
This does not make macOS tests free, but it prevents the accidental overlap
that causes a swarm of test-host processes.

If a Swift test run becomes unhealthy, stop the one explicit command you
started before trying again. Do not repeatedly start new `xcodebuild test`
commands; that multiplies the pressure instead of diagnosing the run.

## What CI runs

GitHub Actions separates the work:

- Ubuntu: dependency install, Ruff, Black, backend tests, and coverage floor.
- macOS: one serial `xcodebuild test` job with code signing disabled.

That separation keeps the expensive Mac-host test work off a contributor’s
normal edit-save-verify loop while still testing it before merge.

## Current validation baseline

The public-v1 `main` baseline is 184 backend tests and 73 Swift tests. After
the current local-only merge from `main`, the private v1.1 `develop` branch
passes 389 backend tests and 177 Swift tests in its own serial host. Re-run its
exact fast backend and serial Swift commands after every later merge from
`main` instead of treating a previous green result as current evidence.

Run only the smallest relevant command while iterating, then run the guarded
Swift target once and the full release-candidate matrix at the release gate.
Documentation, packaging, or automation edits that change user-facing
distribution behavior still need their specific artifact or script verification,
even when they do not need the macOS test host. Do not use repeated parallel
runs as a substitute for diagnosis.
