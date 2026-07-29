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

The v1.1 candidate's fast backend suite has 384 passing tests and three
intentional skips. This covers multilingual catalog validation, language
detection contracts, document extraction, consent/duplicate-start guards,
retry/reconnect behaviour, transcript timing, and incomplete-audio handling.
Run the guarded Swift target once for a release candidate after the backend
proof is green; do not use repeated parallel runs as a substitute for diagnosis.
