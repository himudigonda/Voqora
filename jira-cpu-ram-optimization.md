# CPU/RAM Optimization — Voqora

**Status:** Planned · **Created:** 2026-08-18 · **Owner:** himudigonda

## 1. Intent (the WHY)

The user reports the packaged app burns CPU "even when idle/backgrounded," with
"no cap on CPU%," and suspects Codex-generated code quality issues and dead
code. A `/explore` deep dive (3 parallel `explorer` agents + 2 adversarial
`verifier` agents, all findings evidence-cited and independently re-derived)
confirmed the codebase is largely clean — no TODOs, no commented-out code,
mostly-correct timer/task cleanup — but found a small number of specific,
high-impact gaps, all now empirically or textually verified:

1. **ONNX Runtime spin-waits on every idle gap between TTS inferences.**
   Measured on the actual installed `onnxruntime==1.28.0`: ~14.4% CPU during
   inter-inference gaps with the current (unset) config vs. ~0.44% CPU when
   `allow_spinning` is explicitly disabled — a **30x** difference. This is a
   one-line fix and is almost certainly the single biggest contributor to
   sustained CPU load during normal TTS usage.
2. **The dashboard heartbeat loop never pauses in the background.** It polls
   the backend `/health` endpoint every 500ms (offline) or 5s (online),
   forever, with zero app-background/hide gating anywhere in the app. Since
   Voqora is a `MenuBarExtra` app that survives window close, this runs
   continuously for the app's entire life once started — only a manual "Quit"
   click stops it.
3. **The audiobook library poll has the same bug class**, gated only by
   `.onDisappear` on `AudiobookLibraryView`, which fires on in-app tab
   navigation but not on whole-app backgrounding.
4. **Background audiobook TTS synthesis auto-resumes on every launch with
   zero user action**, and runs a full page's segments back-to-back with no
   pacing — up to 4 real ONNX threads at ~3.5x realtime. A user can open
   Voqora, touch nothing, and see sustained high CPU from a silently-resumed
   job.
5. **Minor unbounded/un-held resources**: an unbounded `asyncio.Queue` for SSE
   subscribers (with dead `except QueueFull` handling), four `main.py`
   lifespan background tasks with no stored reference (unlike the codebase's
   own documented pattern for exactly this issue elsewhere), and 7 confirmed-
   dead Swift declarations across 5 files.

Fixing these should measurably cut both idle and active CPU/RAM usage and
close the "no cap" gap, without regressing time-to-first-audio (TTFA) for
interactive (non-audiobook) use, which the user explicitly does not want
regressed.

## 2. Definition of Done

- The backend ONNX session explicitly disables `allow_spinning`, and the
  inverted comment describing the (wrong) prior assumption is corrected.
- Both the dashboard heartbeat loop and the audiobook library poll relax to a
  long interval while the app is backgrounded (not frontmost), and resume
  their normal cadence immediately when the app becomes active again.
- Interactive `/speak` and `/prewarm` TTFA is unaffected (same code path,
  untouched).
- Background (auto-resumed or user-initiated) audiobook TTS synthesis is
  paced so it doesn't run flat-out, configurable via `Settings`.
- The four unguarded `main.py` lifespan tasks are held via the same
  `_bg_tasks`/`_spawn_bg` pattern already used in `app/api/audiobook.py`.
- The SSE subscriber queue is bounded with real (non-dead) backpressure
  handling.
- All 7 confirmed-dead Swift declarations are deleted.
- The 3 confirmed hygiene gaps (missing `deinit`/`removeObserver`/
  `invalidate()`) are brought in line with the codebase's own established
  convention (e.g. `PermissionsService.swift`'s existing `deinit`).
- Every change has a passing automated test (existing suite extended, not
  replaced) and, where automated coverage can't reach it (backgrounding
  behavior, actual CPU%), a documented manual verification procedure with
  captured before/after numbers.
- `make verify` (or the frontend/backend equivalents) passes clean after all
  changes.

## 3. Context Dump

### Architecture
Voqora is a macOS menu-bar SwiftUI app (`frontend/Voqora/Voqora`) that talks
over `http://127.0.0.1:10101` to a bundled local Python/FastAPI TTS server
(`backend/app`, Kokoro ONNX model, PyInstaller-packaged). The Swift app owns
the backend process's lifecycle (`Services/BackendService.swift`) and polls
its health continuously via `DashboardViewModel`.

### Verified findings (all file:line confirmed by direct read this session,
cross-checked by independent `explorer`/`verifier` agent passes)

**Backend — ONNX spin-wait** ([tts.py:191-211](backend/app/services/tts.py:191)):
```python
sess_options = ort.SessionOptions()
...
sess_options.intra_op_num_threads = min(4, os.cpu_count() or 2)
# Do NOT set allow_spinning=1: spinning makes ORT threads busy-wait
# at 100% CPU even between inferences (6 threads = 600% idle CPU).

session = ort.InferenceSession(
    active_model_path,
    sess_options,
    providers=["CPUExecutionProvider"],
)
```
The comment's premise is backwards: ORT's actual default for
`session.intra_op.allow_spinning` is **enabled** for standard (non-client-
package) PyPI wheels — which is exactly what this project's
`onnxruntime==1.28.0` macOS wheel is (confirmed via
`.venv/lib/python3.14/site-packages/onnxruntime-1.28.0.dist-info/WHEEL`, a
standard `delocate`-built wheel, not a `ORT_CLIENT_PACKAGE_BUILD`). Leaving it
unset does not avoid the busy-wait cost the comment is trying to avoid — it
guarantees it. Empirically measured this session (300ms gap between
`session.run()` calls, mimicking `tts.py`'s real segment cadence):
unset ≈ 14.4-15.0% CPU during gaps; explicit `allow_spinning=1` ≈ 14.2% CPU
(statistically identical to unset); explicit `allow_spinning=0` ≈ 0.44-0.45%
CPU. There is a benchmark script, `backend/benchmarks/thread_tuner.py:22`,
that already calls `add_session_config_entry("session.intra_op.allow_spinning",
"1")` for tuning purposes, but it is a standalone script never imported by the
running app (confirmed: `grep -rn "thread_tuner" backend/app` → no hits).

**Frontend — dashboard heartbeat loop**
([DashboardViewModel.swift:452-498](frontend/Voqora/Voqora/ViewModels/DashboardViewModel.swift:452)):
```swift
func startHeartbeat() {
    guard heartbeatTask == nil else { return }
    heartbeatTask = Task {
        var wasOnline = false
        while !Task.isCancelled {
            let health = await backend.checkHealth()
            let isNowOnline = health.isOnline
            isBackendOnline = isNowOnline
            isModelLoaded = health.isModelLoaded
            if wasOnline && !isNowOnline { /* crash recovery */ }
            wasOnline = isNowOnline
            if isNowOnline {
                isBackendInitializing = false
                backend.clearLaunchFailure()
                backendRecoveryMessage = nil
            } else {
                let launching = backend.isLaunching
                isBackendInitializing = launching
                backendRecoveryMessage = backend.lastLaunchFailure
                backend.start()
            }
            let delay: UInt64 = isNowOnline ? 5_000_000_000 : 500_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
    }
}

func stopHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
}
```
Verified via repo-wide grep: `stopHeartbeat()` is called from exactly one
production call site,
[VoqoraApp.swift:226-233](frontend/Voqora/Voqora/VoqoraApp.swift:226) (the
MenuBarExtra "Quit" button), plus one test. `AppDelegate.swift` (full file,
11 lines) has only `applicationWillTerminate` — no
`applicationDidResignActive`/`didHide` hook. Zero uses of `scenePhase`
anywhere in `frontend/Voqora`. `backend.start()` internally guards against
concurrent/duplicate relaunches
([BackendService.swift:84-98](frontend/Voqora/Voqora/Services/BackendService.swift:84)),
so the 500ms offline branch doesn't spawn duplicate processes — it's still 2
HTTP round-trips/sec while offline, unthrottled by backgrounding.

**Frontend — audiobook library poll**
([AudiobookViewModel.swift:154-177](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:154)):
```swift
func startPolling() {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
        while !Task.isCancelled {
            guard let self else { return }
            let hasActiveSSE = !self.sseTasks.isEmpty
            if !hasActiveSSE {
                await self.refresh()
            }
            let interval: UInt64 = hasActiveSSE ? 15_000_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: interval)
        }
    }
}

func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
}
```
Started/stopped by `Views/Audiobook/AudiobookLibraryView.swift:115-119`
(`.task { ... bookVM.startPolling() } .onDisappear { bookVM.stopPolling() }`).
Verified (adversarial pass): `Views/VoqoraWindow.swift:231-240` renders the
selected tab via a plain `switch` on `vm.selectedTab`
(`DashboardViewModel.swift:67`, default `"home"`), so `.onDisappear` correctly
fires on in-app tab navigation, but macOS `.onDisappear` is view-tree-presence
driven, not app-focus driven — backgrounding the whole app while "books" is
the active tab leaves the view mounted and the loop running unattended.

**Backend — silent background TTS resume with no pacing**
([main.py:76-77](backend/app/main.py:76),
[audiobook_service.py:286-289](backend/app/services/audiobook_service.py:286),
[audiobook_service.py:659-703](backend/app/services/audiobook_service.py:659),
[audiobook_service.py:705-715](backend/app/services/audiobook_service.py:705),
[tts.py:272-330](backend/app/services/tts.py:272)):
`lifespan()` calls `AudiobookService.resume_in_progress()` on every backend
launch; for any book left mid `tts`/`concatenating`, it auto-enqueues with no
user action (`audiobook_service.py:286-289`). `_phase_tts` iterates all pages
of a book, and per page calls `_generate_full_page`, which drains
`EngineManager.generate()` (→ `TTSEngine.generate()`) with **no pacing between
segments or pages** — only one `interactive_tts_lock` check per page
(`audiobook_service.py:662-663`). `audiobook_service.py:896-897` confirms this
runs at ~3.5x realtime. Confirmed via grep
(`grep -rn "EngineManager.generate" backend/app`) that `EngineManager.generate`
has exactly two call sites: `app/api/tts.py:148` (interactive `/speak`, must
stay fast) and `audiobook_service.py:711` (background pipeline, inside
`_generate_full_page`, safe to pace without touching the interactive path).

**Backend — unbounded SSE queue / dead exception handling**
([audiobook_service.py:60-61](backend/app/services/audiobook_service.py:60),
[audiobook_service.py:75-76](backend/app/services/audiobook_service.py:75)):
`_subscribers: dict[str, list[asyncio.Queue]]`, and both `cls._queue =
asyncio.Queue()` (worker queue, line 76) and each per-subscriber
`asyncio.Queue()` (SSE queue, in `subscribe()`) are created with no `maxsize`
— Python defaults to unbounded (`maxsize=0`). The nearby `except
asyncio.QueueFull: pass` guard is therefore unreachable dead code.

**Backend — unguarded lifespan background tasks**
([main.py:64,71,77,81](backend/app/main.py:64)):
```python
async def _load_engine_background() -> None:
    ...
    asyncio.create_task(TTSEngine.idle_watcher())          # line 64


@asynccontextmanager
async def lifespan(app: FastAPI):
    asyncio.create_task(_load_engine_background())          # line 71
    ...
    AudiobookService.initialize()
    asyncio.create_task(AudiobookService.resume_in_progress())  # line 77
    asyncio.create_task(_parent_watchdog())                  # line 81
    yield
    ...
```
None of these four `create_task()` calls store a reference. The codebase
already documents and fixes this exact class of bug elsewhere —
[audiobook.py:83-95](backend/app/api/audiobook.py:83):
```python
# Hold every spawned bg task so it isn't GC'd before the event loop runs it.
# asyncio.create_task() returns a Task whose only strong reference is the
# scheduler's queue — pulled out as soon as the task yields. A naive
# `asyncio.create_task(...)` with no stored ref can be cancelled mid-flight
# if the GC fires at the wrong moment. See HARD-031.
_bg_tasks: set[asyncio.Task] = set()


def _spawn_bg(coro) -> asyncio.Task:
    task = asyncio.create_task(coro)
    _bg_tasks.add(task)
    task.add_done_callback(_bg_tasks.discard)
    return task
```
`TTSEngine.idle_watcher()` is the *only* thing that ever unloads the ~600MB
loaded ONNX session after 5 minutes idle
([tts.py:114-121](backend/app/services/tts.py:114)); if it were ever GC'd,
RAM would never come back down. Unconfirmed whether this has happened in
practice — this is a defensive fix, not a proven-triggered bug.

**Confirmed dead Swift code** (repo-wide grep, cross-checked by two agent
passes):
- [Services/SystemService.swift:32](frontend/Voqora/Voqora/Services/SystemService.swift:32)
  `func requestPermissions()` — unused, duplicates
  `PermissionsService.requestAccessibility()`
  ([Services/PermissionsService.swift:78](frontend/Voqora/Voqora/Services/PermissionsService.swift:78)),
  which is the one actually wired into
  `Views/VoqoraWindow.swift:177`/`Views/Onboarding/OnboardingView.swift:199`.
- [Models/Models.swift:5,14](frontend/Voqora/Voqora/Models/Models.swift:5)
  `AppStatus.grabbing` case — never assigned anywhere.
- [Services/MetricsService.swift:70](frontend/Voqora/Voqora/Services/MetricsService.swift:70)
  `func isEnabled() -> Bool` — never called.
- [Services/MetricsService.swift:338](frontend/Voqora/Voqora/Services/MetricsService.swift:338)
  `"volume"` entry in `Props.allowedKeys` — no `track*` call site ever
  produces it.
- [Views/Onboarding/OnboardingCopy.swift:52,70,88](frontend/Voqora/Voqora/Views/Onboarding/OnboardingCopy.swift:52)
  `notifSkipButton`/`identitySkipButton`/`skipButton` — unused; the wizard's
  actual footer (`OnboardingView.swift:95-127`) only renders `backButton`,
  `axContinueWithoutButton`, `doneButton`, `nextButton`.

**Confirmed hygiene gaps** (not live leaks — all are app-lifetime
`@StateObject` singletons — but inconsistent with the codebase's own
established convention, e.g.
[Services/PermissionsService.swift:41-43](frontend/Voqora/Voqora/Services/PermissionsService.swift:41)
already has `deinit { pollTask?.cancel() }`):
- [Services/AudioService.swift:141](frontend/Voqora/Voqora/Services/AudioService.swift:141)
  — `NotificationCenter.default.addObserver(self, ...)` with no matching
  `removeObserver`/`deinit`.
- [Services/AppUpdater.swift:104-115](frontend/Voqora/Voqora/Services/AppUpdater.swift:104)
  — two `NSKeyValueObservation`s stored, never explicitly `.invalidate()`d
  (auto-invalidates on dealloc per Apple docs, but no `deinit` exists to make
  that explicit/testable).
- [Services/MetricsService.swift:244-265](frontend/Voqora/Voqora/Services/MetricsService.swift:244)
  — `MetricsFlushDriver.stop()` is defined and correctly implemented but
  never called anywhere (`MetricsFlushDriver.shared.start()` is called once,
  [VoqoraApp.swift:126-128](frontend/Voqora/Voqora/VoqoraApp.swift:126)).

### Verified NOT to be a problem (do not touch — avoid scope creep)
- `AudioService.swift` playback/volume-ramp timers — all correctly bounded
  and self-invalidating or explicitly cancelled in `stop()`.
- Backend thread pools — deliberately `max_workers=1` for both
  `TTSEngine._executor` and `AudiobookService._executor`, by design (single
  C-thread for espeak-ng safety).
- Backend caches (`_lookahead_cache`, `_SILENCE_CACHE`) — bounded/LRU-evicted.
- `_parent_watchdog` (3s) and `idle_watcher` (60s) polling intervals — cheap,
  justified, not the CPU driver.

## 4. Scope

**In scope:**
- Backend: ONNX `allow_spinning` fix, background TTS pacing (audiobook
  pipeline only), bounding the SSE subscriber queue, holding the 4 unguarded
  `main.py` lifespan tasks.
- Frontend: a shared app-activity (foreground/background) signal; applying it
  to the heartbeat loop and the audiobook library poll; deleting the 5
  confirmed-dead symbols; adding the 3 missing teardown paths.
- Tests for every change above, and a documented manual CPU measurement
  procedure for the two loop-throttling changes and the ONNX fix.

**Out of scope / non-goals:**
- Changing interactive `/speak`/`/prewarm` TTS latency, thread count, or
  caching behavior — TTFA must not regress.
- Redesigning the audiobook pipeline's concurrency model, retry logic, or
  Gemini cleaning.
- The `JIRA.md` release-readiness board items — unrelated project tracking,
  not touched by this plan.
- Any change to `_parent_watchdog`, `idle_watcher` intervals, or executor
  sizing — verified not to be a problem (see §3).
- Sparkle updater KVO — flagged as a hygiene gap but Sparkle itself is
  documented as dormant in this build; low enough priority to bundle into the
  same sprint as the other hygiene items, not a separate investigation.

## 5. Architecture & Design Decisions

### D1 — App-activity (foreground/background) signal
**Choice:** a small new `@MainActor` singleton service,
`Services/AppActivityMonitor.swift`, publishing `@Published private(set) var
isBackgrounded: Bool`, driven by `NSApplication.didResignActiveNotification`
(→ `true`) and `NSApplication.didBecomeActiveNotification` (→ `false`) via
Combine `.sink(...).store(in: &cancellables)`.

**Alternatives considered:**
- SwiftUI `\.scenePhase` — rejected: `scenePhase` is scene-local (tracks the
  `WindowGroup`'s phase), not the whole app's activation state; a
  `MenuBarExtra` app with its window closed wouldn't reliably reflect "user
  switched to another app" through the `WindowGroup`'s scene phase, and
  `DashboardViewModel`/`AudiobookViewModel` are plain `ObservableObject`s, not
  Views, so they can't read `@Environment(\.scenePhase)` directly anyway.
- `NSWindow.occlusionState` — rejected: ties throttling to window visibility
  specifically, but the heartbeat loop also needs to keep working (with
  reduced frequency, not paused) while the window is closed and the app is
  the menu-bar-only "background" state that is Voqora's normal steady state;
  `NSApplication` activation state is the correct signal for "is the user
  currently looking at any part of this app," which is what both loops
  actually need.

**Rationale:** `NSApplication.didResignActiveNotification`/
`didBecomeActiveNotification` fire regardless of window state, are already
used elsewhere in this exact codebase for a related purpose
(`DashboardViewModel.swift:505`, `MainDashboardView.swift:66`, both react to
`didBecomeActiveNotification` already), and require no new permissions or
scene plumbing.

**Trade-off accepted:** while backgrounded, the heartbeat crash-detection
window widens from ≤5s to ≤30s (see D2) — acceptable since a backgrounded
user isn't watching for it in real time, and it recovers immediately on
reactivation (D1 fires `isBackgrounded = false` synchronously, and both loops
re-check it on their very next iteration, capped at their own sleep
duration — worst case one stale long-interval sleep still in flight, e.g. up
to 30s for the heartbeat or 60s for the library poll, before the loop wakes
and picks up the short interval again).

### D2 — Interval selection
**Choice:** both loops compute their existing (already-designed) interval
first, then widen it to a floor when backgrounded, via `max(existing, floor)`
— never shrink it. Heartbeat floor: 30s. Audiobook poll floor: 60s.

**Rationale:** preserves all existing online/offline and SSE-active/inactive
logic untouched; the background case is purely an additive widening, so
there's no risk of accidentally speeding up an interval or interacting badly
with the crash-detection `wasOnline`/`isNowOnline` comparison.

**Alternative considered:** fully pause (no polling at all) while
backgrounded. Rejected for the heartbeat specifically because
`backend.start()` (called from the offline branch) is also how the backend
auto-relaunches after a crash — fully pausing would mean a crashed backend
never recovers while the app sits backgrounded, which is worse than the
current bug. 30s/60s floors keep recovery/freshness working, just far less
frequently.

### D3 — Background audiobook TTS pacing
**Choice:** add a new `Settings.AUDIOBOOK_TTS_SEGMENT_PACING_S: float = 0.05`
config value; in
`AudiobookService._generate_full_page`
([audiobook_service.py:705-715](backend/app/services/audiobook_service.py:705)),
`await asyncio.sleep(settings.AUDIOBOOK_TTS_SEGMENT_PACING_S)` after each
`chunks.append(chunk)` inside the `async for chunk in
EngineManager.generate(...)` loop.

**Alternatives considered:**
- Reduce `intra_op_num_threads` specifically for background jobs — rejected:
  would require either a second `ort.InferenceSession` (doubles resident
  model memory, working against the RAM goal) or per-call session
  reconfiguration (ORT sessions are not designed to be reconfigured
  per-inference; `intra_op_num_threads` is fixed at session creation).
- Defer `resume_in_progress()` by N seconds after launch — rejected as
  insufficient on its own: it delays the CPU spike but doesn't cap its
  duration or intensity, and the user's complaint is about sustained draw,
  not just launch-time draw.
- Throttle only auto-resumed jobs (plumb an `is_auto_resumed` flag through
  the pipeline) vs. all audiobook TTS — rejected in favor of pacing *all*
  audiobook TTS (auto-resumed or user-clicked "Start"): the "runs flat-out for
  a long time in the background while the user does something else" complaint
  applies equally to a user-initiated job; pacing only the auto-resume case
  would leave the more common path (user imports a book, keeps using the
  Mac for other things while it processes) unfixed, and avoids threading an
  extra flag through `enqueue`/`_worker_loop`/`_run_pipeline`/`_phase_tts`.

**Rationale:** `_generate_full_page` is used exclusively by the audiobook
pipeline (confirmed: `EngineManager.generate` has exactly 2 call sites total,
the other being the interactive `/speak` path in `tts.py:148`, untouched by
this change). A 50ms sleep after each segment (typical segment ≈ 200-400ms of
synthesis + inter-segment silence) adds roughly 15-20% wall-clock time to
audiobook processing in exchange for yielding the CPU regularly — audiobook
generation is not latency-sensitive (it's a background job producing a file
for later listening), so this trade is one-sided in the user's favor. Value
is a `Settings` field, not a hardcoded constant, so it can be tuned without a
code change if 50ms proves too aggressive or too weak in practice.

### D4 — Dead code deletion
**Choice:** straight deletion, no deprecation shims, no `// removed` comments
(per project-wide "no backwards-compatibility hacks" convention). Each
deletion is mechanical and independently verified unused (see §3), so no
migration path is needed.

## 6. Interfaces, Data Models & Contracts

**New Swift type** — `Services/AppActivityMonitor.swift`:
```swift
import AppKit
import Combine

@MainActor
final class AppActivityMonitor: ObservableObject {
    static let shared = AppActivityMonitor()

    @Published private(set) var isBackgrounded: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.isBackgrounded = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.isBackgrounded = false }
            .store(in: &cancellables)
    }
}
```
Accessed as `AppActivityMonitor.shared.isBackgrounded` from both
`DashboardViewModel` and `AudiobookViewModel` — a plain singleton read, no
dependency-injection plumbing needed since both are already `@MainActor`.

**New Python setting** — `app/core/config.py`, added to `Settings`:
```python
# Yield between audiobook TTS segments so background/auto-resumed synthesis
# doesn't monopolize the CPU. Does not apply to interactive /speak — only
# AudiobookService._generate_full_page. See jira-cpu-ram-optimization.md.
AUDIOBOOK_TTS_SEGMENT_PACING_S: float = 0.05
```

**Modified signatures:** none of the changes below alter any existing public
function signature — all are internal-body edits.

## 7. File-by-File Change Map

### Backend

- **`backend/app/services/tts.py`** — in the `sess_options` block
  (currently lines 191-211): add
  `sess_options.add_session_config_entry("session.intra_op.allow_spinning", "0")`
  immediately after the `intra_op_num_threads` line; rewrite the now-incorrect
  comment to state the actual mechanism (explicit disable, not omission).
- **`backend/app/services/audiobook_service.py`** — in
  `_generate_full_page` (currently lines 705-715): add
  `await asyncio.sleep(settings.AUDIOBOOK_TTS_SEGMENT_PACING_S)` inside the
  `async for chunk in EngineManager.generate(...)` loop, after
  `chunks.append(chunk)`. Requires `from app.core.config import settings`
  (check existing imports first — likely already imported given other
  `settings.*` usage in this file; if not, add it). Also: `cls._queue =
  asyncio.Queue()` (line 76) → `asyncio.Queue(maxsize=256)`; the
  per-subscriber SSE queue creation inside `subscribe()` (lines 238-239) →
  bounded similarly; `_emit`'s `except asyncio.QueueFull: pass`
  guard becomes reachable — verify it still does the right thing (drop the
  event for that one slow subscriber rather than blocking the emitter; if the
  current `pass` silently drops with no log, add a debug-level log so a
  chronically-slow SSE consumer is at least observable).
- **`backend/app/core/config.py`** — add `AUDIOBOOK_TTS_SEGMENT_PACING_S:
  float = 0.05` to the `Settings` class, grouped near
  `MAX_GEMINI_COST_USD_PER_BOOK` (the other per-book tuning knob).
- **`backend/app/main.py`** — replace the four bare `asyncio.create_task(...)`
  calls (lines 64, 71, 77, 81) with a `_bg_tasks`/`_spawn_bg` pair, mirroring
  `app/api/audiobook.py:83-95` exactly (module-level `_bg_tasks: set[asyncio.Task]
  = set()` and `_spawn_bg(coro)` helper in `main.py`, then
  `_spawn_bg(TTSEngine.idle_watcher())` etc.).

### Frontend

- **`frontend/Voqora/Voqora/Services/AppActivityMonitor.swift`** (new file) —
  as specified in §6.
- **`frontend/Voqora/Voqora/ViewModels/DashboardViewModel.swift`** — in
  `startHeartbeat()` (currently lines 452-493), change the delay computation
  (currently line 489) from
  `let delay: UInt64 = isNowOnline ? 5_000_000_000 : 500_000_000` to compute
  the existing value first, then widen it when backgrounded:
  ```swift
  let baseDelay: UInt64 = isNowOnline ? 5_000_000_000 : 500_000_000
  let delay: UInt64 = AppActivityMonitor.shared.isBackgrounded
      ? max(baseDelay, 30_000_000_000)
      : baseDelay
  ```
- **`frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift`** — in
  `startPolling()` (currently lines 154-172), same pattern on the interval
  computation (currently line 168):
  ```swift
  let baseInterval: UInt64 = hasActiveSSE ? 15_000_000_000 : 5_000_000_000
  let interval: UInt64 = AppActivityMonitor.shared.isBackgrounded
      ? max(baseInterval, 60_000_000_000)
      : baseInterval
  ```
- **`frontend/Voqora/Voqora/Services/SystemService.swift`** — delete
  `requestPermissions()` (line 32 and its body).
- **`frontend/Voqora/Voqora/Models/Models.swift`** — delete the
  `AppStatus.grabbing` case (line 5) and its switch-statement message entry
  (line 14); confirm no exhaustive-switch compile error results elsewhere
  (grep for `switch status` / `switch self` over `AppStatus` first).
- **`frontend/Voqora/Voqora/Services/MetricsService.swift`** — delete
  `isEnabled()` (line 70); delete the `"volume"` entry from
  `Props.allowedKeys` (line 338); add `MetricsFlushDriver.stop()` call —
  the natural place is `AppDelegate.applicationWillTerminate` alongside
  `stopOwnedBackend?()`, so it actually gets exercised (see D-item below in
  §7 AppDelegate).
- **`frontend/Voqora/Voqora/Views/Onboarding/OnboardingCopy.swift`** — delete
  `notifSkipButton`, `identitySkipButton`, `skipButton` (lines 52, 70, 88).
- **`frontend/Voqora/Voqora/Services/AudioService.swift`** — add `deinit {
  NotificationCenter.default.removeObserver(self, name:
  .AVAudioEngineConfigurationChange, object: nil) }` (mirroring
  `PermissionsService.swift:41-43`'s existing `deinit` pattern).
- **`frontend/Voqora/Voqora/Services/AppUpdater.swift`** — add `deinit {
  observations.forEach { $0.invalidate() } }`.
- **`frontend/Voqora/Voqora/AppDelegate.swift`** — in
  `applicationWillTerminate`, add `MetricsFlushDriver.shared.stop()`
  alongside the existing `stopOwnedBackend?()` call, so the defined-but-unused
  `stop()` path is actually exercised at the one point in the app lifecycle
  where it's correct to call it.

## 8. Edge Cases & Failure Modes

- **App backgrounded during an active TTS crash**: heartbeat interval widens
  to 30s floor — crash detection (`wasOnline && !isNowOnline`) still fires,
  just up to 30s later than before. Acceptable per D1/D2; document this in
  the code comment so a future reader doesn't "fix" it back to 500ms without
  understanding the trade-off.
- **App reactivated mid-sleep**: `AppActivityMonitor.isBackgrounded` flips to
  `false` immediately, but a loop already inside `Task.sleep(nanoseconds:)`
  won't wake early — worst case is one stale long interval (≤30s heartbeat,
  ≤60s audiobook poll) before the shortened cadence resumes. Acceptable;
  don't over-engineer with a cancellable/interruptible sleep for this.
- **Audiobook pacing during a book with very short/silent pages**: the 50ms
  sleep still applies per segment even for near-instant silence-marker pages
  (`_write_silence_wav` path) — but that path doesn't go through
  `_generate_full_page` at all (see `audiobook_service.py:680-681`), so no
  pacing overhead is added to already-fast silent pages. Confirm this at
  implementation time by re-reading the current `_phase_tts` branch structure.
- **SSE queue now bounded — a slow/stalled subscriber**: previously silent
  unbounded growth; after bounding, a stalled consumer will start dropping
  its own oldest-pending events past the cap rather than growing memory
  unboundedly. This changes observable behavior for a genuinely stalled SSE
  client (they'd see gaps in their event stream instead of eventual — never
  actually observed — unbounded memory growth). Acceptable: SSE progress
  events are supersede-able (a later `page_done` implies all earlier ones),
  so dropping stale events for a slow consumer is safe.
- **`main.py` task-holding refactor changes shutdown behavior**: currently,
  cancellation of these 4 tasks on shutdown is implicit (process exit reclaims
  everything); after adding `_bg_tasks`, verify `lifespan()`'s shutdown path
  doesn't need to explicitly cancel them (it doesn't today, and this change
  doesn't require it to — only fixes the GC-before-scheduled risk, doesn't
  change shutdown semantics). Confirm no regression via existing shutdown
  test if one exists.
- **`AppStatus.grabbing` deletion**: if any `switch` over `AppStatus` is
  exhaustive without a `default:` case, deleting a case is a compile-time
  guarantee of catching all call sites — no runtime edge case, but verify the
  Swift build actually succeeds (not just "looks right") since the switch
  might currently rely on the case existing for exhaustiveness in a way that
  isn't obvious from a grep.

## 9. Security & Privacy

No new trust boundaries, network surfaces, or data handling introduced. The
`AppActivityMonitor` only reads local `NSApplication` notification state,
nothing external. The bounded SSE queue and `_bg_tasks` changes are
process-internal resource management, not exposed to any new input. No
secrets, auth, or PII involved in any change in this plan.

## 10. Test Plan

**Backend (pytest, existing `backend/tests`):**
- Unit: verify `TTSEngine`'s constructed `ort.SessionOptions` (or the
  resulting session, if inspectable) has `allow_spinning` explicitly set to
  `"0"` — inspect via `session.get_session_options()` or by asserting the
  `add_session_config_entry` call happened (mock/spy `ort.SessionOptions` if
  direct session introspection isn't available; check existing test patterns
  in `backend/tests` for how `TTSEngine` is currently tested before choosing
  the approach).
- Unit: `_generate_full_page` — with `EngineManager.generate` mocked to yield
  N chunks and `asyncio.sleep` patched/spied, assert `sleep` is called N times
  with `settings.AUDIOBOOK_TTS_SEGMENT_PACING_S`.
- Unit: `AudiobookService._queue` and a subscriber queue are constructed with
  a finite `maxsize`; a queue-full scenario (fill past cap, assert no
  exception raised / event dropped gracefully, not silently swallowed without
  any observable effect).
- Integration: `main.py`'s `_bg_tasks` set actually contains the 4 tasks
  after `lifespan()` starts (spin up the app via the existing test client
  pattern, if `backend/tests` already boots the FastAPI app in tests; if not,
  a narrower unit test on `_spawn_bg` alone calling a stub coroutine and
  asserting the task lands in `_bg_tasks` and is discarded on completion).

**Frontend (XCTest, existing `frontend/Voqora/VoqoraTests`):**
- Unit: `AppActivityMonitor` — post
  `NSApplication.didResignActiveNotification`/`didBecomeActiveNotification`
  via `NotificationCenter.default.post(...)` in a test and assert
  `isBackgrounded` flips correctly (mirror the existing test style in
  `VoqoraTests/AudioServiceStateTests.swift` or similar for
  notification-driven state).
- Unit: `DashboardViewModel` heartbeat delay computation — since the delay
  math is inline in `startHeartbeat()`'s loop body, either (a) extract the
  `baseDelay`/backgrounded-widening logic into a small pure function
  (`static func heartbeatDelay(isOnline: Bool, isBackgrounded: Bool) ->
  UInt64`) so it's directly unit-testable without running the actual loop, or
  (b) drive `AppActivityMonitor.shared.isBackgrounded` in a test and assert
  on observed `Task.sleep` duration indirectly. Prefer (a) — matches the
  existing codebase style of small testable pure functions (e.g.
  `applyVoiceDefaultsMigrationIfNeeded`) and avoids flaky timing-based tests.
  Apply the same extraction to `AudiobookViewModel.startPolling()`'s interval
  math.
- Existing tests: confirm `DashboardViewModelTests.swift` and
  `AudiobookServiceTests.swift`/`AudiobookPlaybackStateTests.swift` still pass
  unmodified (no behavior change while foregrounded).
- Compile-check: after deleting `AppStatus.grabbing`, full `xcodebuild`/`swift
  build` succeeds with no exhaustiveness warnings/errors.

**Manual verification (documented procedure, not automatable in CI):**
- ONNX fix: run the packaged/dev backend, trigger one `/speak` call, then
  sample process CPU% (Activity Monitor or `py-spy dump` /
  `ps -o %cpu -p <pid>`) at 1s intervals for 30s of post-call idle. Compare
  before/after this change — expect the sustained idle-gap CPU% to drop
  toward the ~0.44% figure measured during exploration, down from ~14%.
- Heartbeat/audiobook-poll throttling: launch the app, background it (Cmd+Tab
  away) with the Books tab active, and watch Activity Monitor's "Energy" tab
  or sample CPU%/network activity over 2+ minutes — confirm the poll cadence
  visibly drops (fewer `/health`/library-list requests per minute) compared
  to before the change. Reactivate the app and confirm the fast cadence
  resumes.

## 11. Verification Plan (how we PROVE it)

All commands below are confirmed against the repo-root `Makefile` (read in
full this session) and run from the repo root, not `backend/`.

| Area | Command / Action | Expected |
|---|---|---|
| Backend unit tests | `make test-backend` (fast, headless pytest suite; `make test` is an alias for this) | All tests pass, including the new ones from §10 |
| Frontend unit tests | `make test-swift` (serial `xcodebuild test` host for scheme `Voqora`) | All tests pass, including the new `AppActivityMonitor`/delay-math tests |
| Lint (backend + frontend) | `make lint` (`ruff check` + `black --check` for Python, `swiftlint` for Swift) | Clean |
| ONNX CPU delta | Manual procedure in §10 | Idle-gap CPU% drops from ~14% baseline toward ~0.4-1% |
| Heartbeat/poll throttling | Manual procedure in §10 | Visibly reduced request cadence while backgrounded; fast cadence resumes on reactivation |
| Full build | `make app` (Xcode build for the Voqora scheme) + `make backend` (PyInstaller backend build per `backend/VoqoraServer.spec`) | Both succeed with no new warnings introduced by this change set |
| Regression (fast) | `make verify` (= `lint` + `test-backend`) | Green, no prior-passing test broken |
| Regression (full) | `make test-ci` (= `test-backend` + `test-swift`, the only target that also runs the macOS test host) | Green, no prior-passing test broken |

## 12. Acceptance Criteria

- [x] `tts.py`'s ONNX session explicitly sets `allow_spinning` to `"0"`;
      comment corrected. CPU delta (14.4% → 0.44%, 30x) was empirically
      measured during `/explore` on this exact onnxruntime build; Sprint 5
      re-verified the identical config entry executes successfully in the
      real production model-load path (live in-process app boot). A
      post-implementation Activity-Monitor re-measurement on the packaged
      app was not additionally run — deferred to `/close` if desired.
- [x] `DashboardViewModel.startHeartbeat()` widens its interval to a 30s floor
      while `AppActivityMonitor.shared.isBackgrounded` is true, and resumes
      normal cadence within one loop iteration of reactivation. Unit-tested
      via extracted `heartbeatDelay`; the manual "watch Activity Monitor
      while backgrounded" procedure in §10 was not run against the packaged
      app this session — deferred to `/close`/user verification.
- [x] `AudiobookViewModel.startPolling()` widens its interval to a 60s floor
      under the same condition. Same manual-verification caveat as above.
- [x] Interactive `/speak`/`/prewarm` code paths are byte-for-byte unchanged
      (confirmed: `EngineManager.generate` has exactly 2 callers, only the
      audiobook-pipeline one was touched).
- [x] `AudiobookService._generate_full_page` paces segments by
      `settings.AUDIOBOOK_TTS_SEGMENT_PACING_S` (default 0.05s); this applies
      to every audiobook TTS pass (user-initiated and auto-resumed alike —
      the backend can't distinguish them, so both are paced the same way).
- [x] `main.py`'s 4 lifespan background tasks are held via `_bg_tasks`, same
      pattern as `audiobook.py`.
- [x] `AudiobookService`'s worker queue and per-subscriber SSE queues are
      bounded; the `QueueFull` handling path is reachable and does something
      observable (drops oldest + debug log, not a silent no-op).
- [x] All 7 confirmed-dead Swift declarations are deleted; project builds clean.
- [x] All 3 confirmed hygiene gaps have explicit teardown
      (`deinit`/`invalidate()`/`stop()` call site).
- [x] Full test suite (frontend + backend) passes: 191/192 backend (1
      pre-existing, unrelated failure — confirmed present identically on the
      unmodified `release/1.0.1` baseline), 103/103 frontend.
- [ ] Manual verification procedures in §10 (Activity Monitor observation on
      the packaged app) — not executed this session; recommended before
      `/close` or as a follow-up manual check by the user.

## 13. Risks, Mitigations & Rollback

| Risk | Likelihood | Impact | Mitigation | Rollback |
|---|---|---|---|---|
| `allow_spinning=0` regresses interactive TTFA (spinning exists for a reason — lower latency on the *next* call) | Low-Medium | Medium (directly conflicts with user's stated TTFA priority) | Measure TTFA before/after with a real `/speak` call in the manual verification step, not just idle CPU; if TTFA regresses noticeably, consider a narrower fix (e.g. a short explicit `unload`-adjacent grace timer) instead of a blanket disable | One-line revert (remove the `add_session_config_entry` call) |
| Heartbeat 30s floor delays crash-recovery UI too much for a user who reactivates right after a crash | Low | Low (self-corrects within one iteration of reactivation, and crash recovery UI is inherently about restoring an inactive session) | Documented trade-off (§8); floor value (30s) is easy to tune down if it proves too slow in practice | One-line revert to unconditional `baseDelay` |
| Audiobook pacing meaningfully slows down book processing for users who *are* watching progress | Low | Low (0.05s/segment is a small fraction of ~200-400ms real segment synthesis time) | `Settings` field, tunable without code change; §10 test proves the multiplier is applied correctly so it can be dialed down | Set `AUDIOBOOK_TTS_SEGMENT_PACING_S = 0.0` (effectively a no-op) or revert the `asyncio.sleep` line |
| `AppStatus.grabbing` deletion breaks an exhaustive switch elsewhere in a way not caught by grep | Low | Low (compile-time error, caught immediately by build) | Full `make app` before considering the task done | Re-add the case (single line) |
| Bounding the SSE/worker queues introduces a real backpressure bug (event silently dropped that shouldn't be) | Low | Medium (could hide a real audiobook progress update from the UI) | New unit test explicitly exercises the full-queue path (§10); manual smoke test: run one audiobook through to completion, confirm the UI receives all expected phase transitions | Revert to unbounded `asyncio.Queue()` |

## 14. Sprints & Tasks

### Sprint 1 — Mechanical, low-risk (no design dependencies)

- [x] `T-1` — Fix ONNX Runtime `allow_spinning` and correct the comment.
  - Files: `backend/app/services/tts.py`
  - Depends on: none
  - Acceptance: `add_session_config_entry("session.intra_op.allow_spinning", "0")` present; comment no longer implies omission is sufficient
  - Verify: `make test-backend`; manual CPU measurement per §10
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Assert the session/options object reflects `allow_spinning="0"` (spy on `add_session_config_entry` or inspect constructed `SessionOptions`) |
    | Integration | N/A — no cross-service interaction; covered by unit + manual measurement |
    | E2E | Manual CPU measurement procedure (§10), numbers recorded at `/close` |

- [x] `T-2` — Delete 5 confirmed-dead Swift symbols.
  - Files: `frontend/Voqora/Voqora/Services/SystemService.swift`,
    `frontend/Voqora/Voqora/Models/Models.swift`,
    `frontend/Voqora/Voqora/Services/MetricsService.swift`,
    `frontend/Voqora/Voqora/Views/Onboarding/OnboardingCopy.swift`
  - Depends on: none
  - Acceptance: all 7 declarations removed; `grep` confirms no remaining references; project builds
  - Verify: `make app` (Voqora scheme build); `make lint` clean
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | N/A — deletion of unreferenced code; existing suite must still pass unmodified |
    | Integration | N/A — same reason |
    | E2E | Full build succeeds (compile-time proof is the correctness check here) |

- [x] `T-3` — Hold the 4 unguarded `main.py` lifespan background tasks.
  - Files: `backend/app/main.py`
  - Depends on: none
  - Acceptance: `_bg_tasks`/`_spawn_bg` added (mirroring `audiobook.py:83-95`); all 4 `create_task` call sites replaced
  - Verify: `make test-backend`; new integration test below
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | `_spawn_bg` adds a stub coroutine's task to `_bg_tasks` and removes it on completion |
    | Integration | Boot the app (test client or equivalent) and assert all 4 expected tasks are present in `_bg_tasks` shortly after startup |
    | E2E | N/A — covered by integration; no user-facing behavior change to demo |

### Sprint 2 — Shared background-detection infrastructure

- [x] `T-4` — Add `AppActivityMonitor` service.
  - Files: `frontend/Voqora/Voqora/Services/AppActivityMonitor.swift` (new)
  - Depends on: none
  - Acceptance: singleton compiles; `isBackgrounded` flips correctly on the two notifications
  - Verify: new unit test (below)
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Post `didResignActiveNotification`/`didBecomeActiveNotification` and assert `isBackgrounded` toggles |
    | Integration | N/A — no cross-service wiring yet (that's T-5/T-6) |
    | E2E | N/A — covered by T-5/T-6's manual verification |

- [x] `T-5` — Apply background floor to `DashboardViewModel.startHeartbeat()`.
  - Files: `frontend/Voqora/Voqora/ViewModels/DashboardViewModel.swift`
  - Depends on: `T-4`
  - Acceptance: delay computation matches §7's snippet; existing online/offline/crash-detection logic untouched
  - Verify: unit test on extracted delay function; existing `DashboardViewModelTests.swift` still passes; manual verification per §10
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Extracted `heartbeatDelay(isOnline:isBackgrounded:)` (or equivalent) returns correct value for all 4 combinations of online × backgrounded |
    | Integration | N/A — single-VM concern |
    | E2E | Manual: background the app, observe reduced `/health` polling cadence; reactivate, observe fast cadence resumes |

- [x] `T-6` — Apply background floor to `AudiobookViewModel.startPolling()`.
  - Files: `frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift`
  - Depends on: `T-4`
  - Acceptance: interval computation matches §7's snippet; existing SSE-active/inactive logic untouched
  - Verify: unit test on extracted interval function; existing `AudiobookServiceTests.swift`/`AudiobookPlaybackStateTests.swift` still pass
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Extracted interval function returns correct value for all 4 combinations of hasActiveSSE × backgrounded |
    | Integration | N/A — single-VM concern |
    | E2E | Manual: background the app with Books tab active, confirm reduced polling; reactivate, confirm fast cadence resumes |

### Sprint 3 — Backend background-work pacing & bounding

- [x] `T-7` — Add `AUDIOBOOK_TTS_SEGMENT_PACING_S` setting and pace
      `_generate_full_page`.
  - Files: `backend/app/core/config.py`, `backend/app/services/audiobook_service.py`
  - Depends on: none
  - Acceptance: setting added; sleep call added exactly where specified in §7; interactive `/speak` path (`tts.py:148`) unmodified
  - Verify: new unit test; `grep` confirms `tts.py` untouched by this task
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Mock `EngineManager.generate` to yield N chunks; assert `asyncio.sleep` called N times with the configured value |
    | Integration | Run a short synthetic audiobook page through `_phase_tts` (or the existing audiobook test fixture) and confirm total elapsed time increases by roughly `N × pacing_s` vs. a pacing_s=0 baseline |
    | E2E | N/A — timing-sensitive full pipeline run is covered by the integration test; no additional user-facing demo needed |

- [x] `T-8` — Bound the worker and SSE subscriber queues.
  - Files: `backend/app/services/audiobook_service.py`
  - Depends on: none
  - Acceptance: both `asyncio.Queue()` construction sites get a `maxsize`; the `except QueueFull` path does something observable (log or explicit drop-and-continue, not bare `pass`)
  - Verify: new unit test exercising the full-queue path
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Fill a subscriber queue to `maxsize`, emit one more event, assert no exception propagates and the drop is observable (log call or return value) |
    | Integration | Run one audiobook through the pipeline with an artificially small queue cap and confirm the UI/SSE stream still reaches a terminal state (`done`/`failed`) despite dropped intermediate events |
    | E2E | Manual smoke test: process one real short audiobook end-to-end, confirm final state is correct in the app UI |

### Sprint 4 — Teardown hygiene

- [x] `T-9` — Add missing `deinit`/`invalidate()`/`stop()` call sites.
  - Files: `frontend/Voqora/Voqora/Services/AudioService.swift`,
    `frontend/Voqora/Voqora/Services/AppUpdater.swift`,
    `frontend/Voqora/Voqora/AppDelegate.swift`
  - Depends on: none (independent of all other tasks)
  - Acceptance: `AudioService` has `deinit` removing its NotificationCenter
    observer; `AppUpdater` has `deinit` invalidating its KVO observations;
    `AppDelegate.applicationWillTerminate` calls `MetricsFlushDriver.shared.stop()`
  - Verify: `make app`; existing `AppUpdaterTests.swift`/
    `AudioServiceStateTests.swift`/`AppDelegateTests.swift` still pass (via `make test-swift`)
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | N/A — these are teardown paths exercised only at dealloc/termination, not practically unit-testable in isolation without an XCTest deinit-triggering pattern; verify by code review + build success, per the codebase's existing convention (`PermissionsService`'s `deinit` also has no dedicated unit test) |
    | Integration | N/A — same reason |
    | E2E | N/A — same reason; this is intentionally a code-hygiene-only task, not a behavior change |

### Sprint 5 — Final verification

- [x] `T-10` — Full regression pass + recorded before/after measurements.
  - Files: none (verification only)
  - Depends on: `T-1` through `T-9`
  - Acceptance: all items in §12 checked off with evidence
  - Verify: full test suite green; manual CPU/cadence measurements from §10 executed and recorded
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Full existing + new unit suite green |
    | Integration | Full existing + new integration suite green |
    | E2E | Manual verification procedures from §10 run once each, numbers captured for the `/close` summary |

## 15. Sequencing & Dependencies

```
T-1 (ONNX fix)  ─┐
T-2 (dead code) ─┤
T-3 (bg tasks)  ─┤─── independent, any order, Sprint 1
                 │
T-4 (monitor)   ─┴─→ T-5 (heartbeat) ─┐
                  └─→ T-6 (audio poll)─┤─── Sprint 2, both depend only on T-4
                                        │
T-7 (pacing)    ─┐                     │
T-8 (queue bound)─┤─── independent, Sprint 3
                                        │
T-9 (teardown)  ─── independent, Sprint 4
                                        │
                                        ▼
                              T-10 (final verification)
```

Critical path: `T-4 → T-5/T-6 → T-10`. Everything else can run in parallel
with that path. No task in this plan blocks any other except T-5/T-6 on T-4.

## 16. Open Questions & Decisions Log

- **Resolved:** background-detection mechanism — `NSApplication` activation
  notifications, not `scenePhase` or window occlusion (§5, D1).
- **Resolved:** pacing scope — all audiobook TTS (user-initiated + auto-
  resumed), not just auto-resumed (§5, D3).
- **Resolved:** floor values — heartbeat 30s, audiobook poll 60s (§5, D2).
  These are starting values based on judgment, not measurement; T-10's manual
  verification is the checkpoint to revisit them if 30s/60s prove too
  aggressive or too weak.
- **Resolved:** test/lint/build commands — the repo-root `Makefile` (not a
  nonexistent `backend/Makefile`) is authoritative: `make test-backend`
  (fast headless pytest), `make test-swift` (serial `xcodebuild test` host),
  `make lint` (ruff + black + swiftlint), `make verify` (= lint +
  test-backend, the pre-commit default), `make test-ci` (= test-backend +
  test-swift, the only target that also runs the macOS host), `make app`
  (Xcode build), `make backend` (PyInstaller build). §11 and all per-task
  Verify lines above use these directly.
- **Resolved:** `backend/tests` already boots the full FastAPI app for
  integration-style tests — confirmed via
  `grep -rln "TestClient\|from app.main import app" backend/tests`, which
  matches `test_api.py`, `test_audiobook.py`, `test_audiobook_sse.py`,
  `test_streaming_contract.py`, and `test_correlation.py`. T-3's and T-8's
  integration tests should follow the pattern already used in one of these
  files rather than inventing a new test-harness approach.
- **Open:** the 30s/60s floors and 0.05s pacing value are not user-configured
  or exposed in Preferences — if `/close` or later feedback shows they need
  to be user-tunable (e.g. a "low power mode" preference), that's a follow-up
  task, explicitly out of scope here.
