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

The macOS build and test recipes cap Xcode at four build operations by default.
Swift still manages some internal compiler workers, so the cap is not presented
as a thermal guarantee. The important guard is behavioural: routine checks do
not launch the macOS app host at all, and the explicit Swift suite has one host
and refuses to overlap another Xcode run. Use `XCODE_JOBS=6` only when the
machine is intentionally reserved for a faster build.

## Current validation baseline

The private v1.1 integration baseline is 389 backend tests and 185 Swift tests. The Swift
receipt came from one serial host with four Xcode build jobs, after the
first-use, backend-lifecycle, updater, audiobook-layout, and telemetry
regressions were added. Re-run only the smallest relevant command while
iterating; run the full release candidate matrix once at the release gate.
Documentation, packaging, or automation edits that change user-facing
distribution behavior still need their specific artifact or script verification,
even when they do not need the macOS test host.
