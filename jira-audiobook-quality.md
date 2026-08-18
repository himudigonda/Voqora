# Audiobook Quality — Voqora

**Status:** Planned · **Created:** 2026-08-18 · **Owner:** himudigonda

## 1. Intent (the WHY)

Real users report the audiobook feature is "buggy" and "bad in different sides,"
and specifically that transcripts "don't scroll well." A 4-agent `/explore` pass
(frontend player/transcript, frontend library/modals, frontend ViewModel state,
backend pipeline — every relevant file read in full) found this isn't one bug:
it's ~20 independently-confirmed defects spanning three layers:

1. **Backend data correctness** — the pipeline can silently produce a transcript
   whose text doesn't match its audio (TTS failure degrades to near-silence
   without touching the already-written transcript text), and the book still
   reports `"done"` with no signal anything went wrong.
2. **Frontend state races** — `AudiobookViewModel` has three independent async
   writers (SSE stream, polling, user actions) touching the same `@Published`
   dictionaries with no ordering, including one **code-provable** race (a
   `defer` cleanup wiping out a newer subscription's registration) and a
   **universal gap** — the backend's real "sectioning" phase (every book goes
   through it, up to 120s on the Gemini path) is completely unhandled by three
   separate frontend status-mapping switches, so every book looks stuck or
   reverts to "queued" during that window.
3. **Transcript scroll UX** — no scroll-to-current-page on open, no
   user-scroll detection (auto-scroll fights manual reading), and an
   unmemoized full-transcript sort re-run on every 250ms tick via a
   structurally decoupled timer instead of real reactive state.

The outcome we want: audiobook processing state is always accurate and never
regresses/flickers, transcript data is never silently wrong, the transcript
panel scrolls the way a user expects (tracks playback, doesn't fight manual
scrolling), and the surrounding library/modal UI is visually and behaviorally
consistent. This is a correctness-and-UX pass, not a reskin — most tasks below
are bug fixes, not redesigns.

## 2. Definition of Done

- A book that reaches `"done"` never shows transcript text for a page whose
  audio actually failed — the transcript reflects what's audible, and a
  failed page is visibly marked as such, not silently blended in.
- Every book visibly progresses through every real backend phase, including
  `sectioning` — no phase silently reverts the UI to "queued" or freezes it.
- `processingState` never regresses (shows an older value after a newer one
  was already applied) due to a race between SSE, polling, or a user action.
- An SSE subscription for a book is never silently torn down and
  reconnected by its own predecessor's cleanup race.
- Deleting a book while it's processing cannot resurrect its progress state
  or leave an orphaned SSE task running.
- Opening the transcript panel (or having it load mid-book) scrolls to the
  actually-playing page immediately, not on the next page boundary.
- Manually scrolling the transcript is never fought by auto-scroll while the
  user is actively reading elsewhere.
- The transcript panel's per-render cost no longer re-sorts the whole
  transcript on every tick; it reflects the real audio clock, not a
  decoupled timer.
- Library search actually works. The processing-card context menu (with the
  only "Cancel Processing" affordance) is reachable while a card is
  processing. Modal sizes, card/grid sizing, and error-message visibility are
  consistent across the feature.
- Every fix has a test that would have caught the original bug, or an
  explicit documented reason one isn't practical. `make verify`/`make
  test-ci` and the Swift suite are green throughout.

## 3. Context Dump

### Architecture recap
Same app as `jira-cpu-ram-optimization.md`: macOS SwiftUI frontend
(`frontend/Voqora/Voqora`) + local Python/FastAPI backend
(`backend/app`). Audiobook-specific surface:

- Backend: `app/services/audiobook_service.py` (`AudiobookService`, the
  extract → clean → section → tts → concatenate pipeline),
  `app/services/audiobook_store.py` (SQLite metadata), `app/api/audiobook.py`
  (HTTP + SSE surface).
- Frontend: `ViewModels/AudiobookViewModel.swift` (state + SSE/poll
  orchestration), `Models/Audiobook.swift` (status mapping),
  `Views/Audiobook/*.swift` (library grid, cards, modals, player/transcript).

### Verified findings (file:line spot-checked this session; full findings from
the 4-agent `/explore` pass, cross-referenced against `JIRA.md`)

**Backend — transcript/audio desync on TTS failure**
([audiobook_service.py:697-709](backend/app/services/audiobook_service.py:697),
[audiobook_service.py:816-823](backend/app/services/audiobook_service.py:816)):
on a TTS exception, the page is added to `failed_pages` and a 0.5s silence WAV
is written, but the page's *clean text file* — the thing `transcript.json` is
built from verbatim — is left completely untouched. The book still reaches
`status="done"`
([audiobook_service.py:330-334](backend/app/services/audiobook_service.py:330))
and the `"done"` SSE payload never carries `failed_pages`, so nothing tells
the frontend a page is broken. `page_to_time`
([audiobook_service.py:753-768](backend/app/services/audiobook_service.py:753))
is computed from actual per-page WAV byte sizes, so a failed page only
contributes ~0.5s to the timeline — transcript scroll-sync will race past or
skip that page almost instantly even if the desync itself were fixed.

**Backend — duplicate-page dedup shows a bare `"-"`**
([audiobook_service.py:402-428](backend/app/services/audiobook_service.py:402),
[audiobook_service.py:694-696](backend/app/services/audiobook_service.py:694)):
byte-identical duplicate pages (e.g. a repeated scanned cover) get `"-"`
written as their clean text to skip redundant Gemini/TTS cost. Transcript
building shows that literal `"-"` with zero explanation — reads as corrupted
data.

**Backend — TTS phase progress stalls for pages with missing clean text**
([audiobook_service.py:685-689](backend/app/services/audiobook_service.py:685)):
the early `continue` for a missing `clean_path` skips the `phase_progress`
meta update and `page_done` SSE emit that normally follow
(lines 711-716) — progress bar can undercount/stall for that page.

**Backend — cancellation is coarse-grained**
([audiobook_service.py:562-567](backend/app/services/audiobook_service.py:562)
clean phase, checked once per page at semaphore-acquire before a call that
can take up to 90-120s;
[audiobook_service.py:720-740](backend/app/services/audiobook_service.py:720)
TTS segment loop has no cancellation check inside it at all, only at the
outer per-page loop boundary): a mid-page cancel can take a long time to
actually stop, looking "stuck."

**Backend — cancel + immediate delete race** (lower confidence, needs a
stress-test repro):
[audiobook_service.py:651-654](backend/app/services/audiobook_service.py:651)'s
`asyncio.gather` in `_phase_clean` doesn't cancel sibling tasks when one
raises `AudiobookCancelled` — a straggler can later call `update_meta` after
the book's directory was already `rmtree`'d by `delete_book`, resurrecting a
zombie DB row.

**Backend — `retry_failed` over-re-cleans** (cost, not correctness)
([audiobook_service.py:206-215](backend/app/services/audiobook_service.py:206)):
deletes and re-cleans (costly Gemini call) every failed page regardless of
whether cleaning or only TTS failed for it.

**Frontend — universal "sectioning" status gap (highest-leverage fix)**
verified this session at all three sites, byte-for-byte matching the
`/explore` report:
- [Models/Audiobook.swift:36-58](frontend/Voqora/Voqora/Models/Audiobook.swift:36)
  `displayStatus` — no `"sectioning"` case, falls to `default: return .queued`.
- [ViewModels/AudiobookViewModel.swift:389-402](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:389)
  `applyStatus` (SSE `snapshot` handler) — identical gap.
- [ViewModels/AudiobookViewModel.swift:404-413](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:404)
  `applyPhase` (live `phase_started`/`page_done` handler) — silently
  `default: return`s on `"sectioning"`, so `processingState` stays frozen at
  the last extraction percentage.
Backend confirmed universal this session: `_phase_section`
([audiobook_service.py:443-532](backend/app/services/audiobook_service.py:443))
runs unconditionally for every book (`status="sectioning"` at line 447,
emitted regardless of file type or whether Gemini's outline path is used —
the up-to-120s wait only applies on the Gemini-detect-sections branch,
lines 490-504, but the status/phase itself always fires).

**Frontend — `sseTasks` defer race (code-provable)** verified this session at
[AudiobookViewModel.swift:328-332](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:328):
```swift
private func subscribe(to bookID: String) {
    sseTasks[bookID]?.cancel()
    sseTasks[bookID] = Task { [weak self] in
        defer { self?.sseTasks[bookID] = nil }
        guard let self else { return }
        for await event in service.subscribe(to: bookID) { ... }
    }
}
```
The `defer` unconditionally nils the dict entry when *this* task ends,
without checking it's still the current registration for `bookID`. Traced
repro: `startProcessing()`
([AudiobookViewModel.swift:268-269](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:268))
does `await refresh(); subscribe(to: bookID)` — `refresh()`'s loop
([:142-147](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:142))
auto-subscribes (task T1, since `sseTasks[bookID]` was nil) if the book is
processing, then the explicit `subscribe()` call immediately after cancels T1
and registers T2. T1's `defer` fires later (URLSession cancellation isn't
instant) and nils out **T2's live registration**. Consequence: `hasActiveSSE`
([:173](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:173)) can
read `false` while a connection is actually live; the next poll tick's
`refresh()` sees `sseTasks[bookID] == nil` and calls `subscribe()` again,
tearing down and reconnecting a healthy stream — any event sent during the
reconnect gap is lost. Same pattern reproduces via `retry()`
([:311-320](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:311)).
**Precedent for the fix already exists in this codebase**:
[AudioService.swift:117-122](frontend/Voqora/Voqora/Services/AudioService.swift:117)
solves the exact same bug class for volume-ramp timers via a `volumeRampToken:
UUID?` captured per attempt and checked before the deferred cleanup applies
(documented as `HARD-020`) — the fix below reuses that established idiom
rather than inventing a new one.

**Frontend — `processingState`/`completionSummary` unguarded races** verified
this session:
[AudiobookViewModel.swift:389-413](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:389)
(SSE writes) vs.
[AudiobookViewModel.swift:142-147](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:142)
(`refresh()`'s list-loop, which unconditionally overwrites
`processingState[book.bookID]` from a GET snapshot with no check for whether
that book has a live SSE subscription that already applied a newer update) —
called from 5+ overlapping sites (`retry`, `startProcessing`, `cancel`, the
poll loop, and inside the SSE loop itself on terminal events). A stale
in-flight `list()` response can overwrite `processingState` back to older
data after a newer SSE event already advanced it — progress bar visibly
regresses then self-corrects.
[AudiobookViewModel.swift:346-359](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:346)
`completionSummary` (single `@Published`, no ordering) can be clobbered when
two books finish close together — `fetchDetailWithFallback`
([:371-387](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:371))
takes up to ~600ms+, so whichever of two concurrent "done" events *resolves*
last wins, regardless of which actually *happened* last.
**Established precedent for the fix**:
[DashboardViewModel.swift:131,259-260,276,280,303,311,329,376](frontend/Voqora/Voqora/ViewModels/DashboardViewModel.swift:131)
(`speakGeneration`) and
[:144,398-410](frontend/Voqora/Voqora/ViewModels/DashboardViewModel.swift:144)
(`errorResetGeneration`) already solve this exact bug class (VQ-006/VQ-051 in
`JIRA.md`) for playback state via a captured-before/checked-after integer
generation token. `AudiobookViewModel` already has the equivalent
(`playbackGeneration`,
[:422](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:422)) for
`play()`/`stopPlayback()` only — never extended to processing/completion
state.

**Frontend — `delete()` doesn't cancel its SSE task**
([AudiobookViewModel.swift:660-683](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:660)):
stops playback, calls `service.delete`, clears `lastPlayedBookID`, removes
`processingState[bookID]` — but never touches `sseTasks[bookID]`. A live SSE
connection for a just-deleted book can deliver one more event that
re-populates `processingState[bookID]` right after `delete()` cleared it.
`processingState` is also never pruned for books that vanish from the
library via another window/session (only removed by `delete()`).

**Frontend — speculative completion-mis-attribution timing race** (lower
confidence, not reproduced live):
[AudioService.swift:387-409](frontend/Voqora/Voqora/Services/AudioService.swift:387)
`stop()` never resets `playbackCompleted`; the natural-completion path sets it
via a `Task { @MainActor ... }` dispatched from an `AVAudioEngine`
buffer-drain handler
([AudioService.swift:561-576](frontend/Voqora/Voqora/Services/AudioService.swift:561)).
`AudiobookViewModel`'s `completionObserver` sink
([:120-129](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:120))
reads `self.nowPlaying` **at sink-execution time**, not at the time
completion actually happened. If a user starts book B in the exact instant
book A finishes, B's resume position could theoretically be wrongly cleared.
Timing-dependent; the fix below is a narrow, low-risk mitigation, not a full
redesign, and the plan flags this confidence level explicitly.

**Frontend — transcript scroll gaps** verified this session at
[AudiobookPlayerView.swift](frontend/Voqora/Voqora/Views/Audiobook/AudiobookPlayerView.swift):
- No initial scroll-to-current-page on panel open or transcript load mid-book
  — `.onChange(of:)` doesn't fire for the baseline value, so it opens on
  page 1 regardless of actual position.
- Zero user-scroll detection — the moment the tracked "current page" value
  changes, `withAnimation(.easeOut(duration: 0.4)) { proxy.scrollTo(newPage,
  anchor: .center) }` runs unconditionally, yanking the view back even if the
  user manually scrolled elsewhere to read ahead/back.
- `orderedPages()`/`currentPageID()` (transcriptPanel helpers) do an
  unmemoized full `compactMap`+`sort` over the *entire* transcript's
  `pages`/`pageToTime` dicts, re-run on every tick.
- Architectural root cause: `AudiobookPlayerView` never declares
  `@EnvironmentObject var audio: AudioService` (confirmed: `AudiobookViewModel`
  stores `let audio: AudioService` as a plain non-`@Published` property, line
  17, so reading `bookVM.audio.currentTime` establishes no Combine
  subscription at all). The whole screen instead force-redraws via a
  hand-rolled `@State private var ticker` set by a decoupled `Timer.publish(every:
  0.25, ...)`. Confirmed this session (`grep -n "ticker\b"
  AudiobookPlayerView.swift`) that `ticker`'s value is **never read anywhere**
  — its only purpose is poking `@State` to force a full body re-evaluation.
  Confirmed this session that `AudiobookPlayerView` **is** a descendant of the
  environment scope where `audio` is injected
  (`AudiobookPlayerView(book:)` is pushed from
  [AudiobookLibraryView.swift:105](frontend/Voqora/Voqora/Views/Audiobook/AudiobookLibraryView.swift:105),
  itself rendered inside `VoqoraWindow`'s tab switch, and `VoqoraApp.swift`
  injects `.environmentObject(audio)` on the root `VoqoraWindow()` — a
  `NavigationStack` push does not leave that environment scope), so adding a
  real `@EnvironmentObject var audio: AudioService` here is safe and won't
  crash at runtime.
- `currentSection` lookup (used by `currentSectionLabel`, `sectionRow` per
  row, and `NowPlayingBar`) has the same unmemoized-sort-per-render pattern,
  lower severity since section counts are small.

**Explicitly NOT a bug — out of scope for this pass**: transcript sync is
page-level granularity (one highlighted block per page, not per
sentence/word). Fixing this properly needs new backend timing data
(sentence/word-level timestamps), which is a real feature addition, not a bug
fix — see §4 non-goals.

**Frontend — UI/UX polish findings** (all verified by the `/explore` pass,
not independently re-spot-checked line-by-line this session given their
mechanical nature, but each has a concrete file:line source):
library search field is fully wired (`AudiobookLibraryView.swift:30`,
`:190-204`) but never rendered anywhere (no `.searchable()`/`TextField`);
the only "Cancel Processing" affordance
(`AudiobookCardView.swift:45-51`) is unreachable because the parent card
`Button` sets `.allowsHitTesting(!isProcessing)`
(`AudiobookLibraryView.swift:162-174`), blocking right-click exactly when
processing; `UploadEstimateModal.swift:49` (520×640) and
`CompletionSummaryModal.swift:67` (460×540) are visibly different sizes in
the same upload→completion flow; the grid's adaptive column
(`AudiobookLibraryView.swift:53`, 200-240pt) doesn't match the card's hard
180pt width (`AudiobookCardView.swift:41,89`); caption `Text` has no
`.lineLimit` (`AudiobookCardView.swift:220-247`) unlike the title's
`lineLimit(2)`; no distinct "library failed to load" state (falls back to
the same empty-shelf UI as a genuinely empty library); error toasts
truncate at `.lineLimit(2)` and auto-dismiss after exactly 4s
(`AudiobookToastView.swift:14-17`, `AudiobookViewModel.swift:288-294`) with
no way to re-read them; the Start-Processing button
(`UploadEstimateModal.swift:210`) doesn't proactively disable for a missing
Gemini key the way it does for the image-only case; zero accessibility
labels across the six audited views.

## 4. Scope

**In scope:**
- Backend: transcript/audio desync fix, duplicate-page dash marker fix, TTS
  progress-stall fix, cancellation responsiveness, cancel+delete race
  mitigation, `retry_failed` re-clean scoping.
- Frontend: the sectioning status gap (all 3 sites), the SSE task race, the
  processingState/completionSummary generation-guard, delete-cancels-SSE,
  the speculative completion-mis-attribution mitigation, transcript
  initial-scroll + user-scroll-detection + memoization, making
  `AudiobookPlayerView` genuinely reactive (removing the decoupled ticker),
  the library/modal UI polish batch (search, context-menu reachability,
  modal/grid sizing, caption line limits, load-failure state, toast
  readability, Start-Processing button gating, accessibility labels).
- Tests for every fix, following the existing conventions in
  `AudiobookServiceTests.swift`, `AudiobookPlaybackStateTests.swift`,
  `test_audiobook.py`, `test_audiobook_sse.py`.

**Out of scope / non-goals (explicit):**
- Sentence/word-level transcript sync granularity — a real feature addition
  (needs new backend timing data), not a bug fix. Noted as a legitimate
  future enhancement, not attempted here.
- Any redesign of the upload/estimate/completion visual design language —
  this pass makes existing surfaces *consistent*, it doesn't restyle them.
- Gemini cleanup logic, PDF/text extraction correctness, or cost-estimation
  accuracy — untouched; only the *pipeline orchestration* bugs above are
  addressed.
- The `jira-cpu-ram-optimization.md` branch's own scope (already merged/done
  as of this plan) — not re-touched here except where a file naturally
  overlaps (e.g. `audiobook_service.py`, already at its post-CPU/RAM-fix
  state per this session's re-reads).
- Any change to `AudioService`'s core playback engine beyond the narrow
  `playbackCompleted` mitigation in T-10.

## 5. Architecture & Design Decisions

### D1 — `sseTasks` defer race: per-subscription UUID token
**Choice:** add `private var sseGeneration: [String: UUID] = [:]`. `subscribe(to:)`
mints a `UUID` before creating the task, stores it in `sseGeneration[bookID]`,
and the task's `defer` only clears `sseTasks[bookID]`/`sseGeneration[bookID]`
if `sseGeneration[bookID]` still equals the UUID it captured.

**Alternatives considered:** comparing `Task` instances directly — rejected,
`Task<Success,Failure>` isn't `Equatable`/`Hashable` in a way usable for this.
A single global "generation" counter instead of per-book UUIDs — rejected,
would require carrying an `Int` per book anyway (same complexity) and a UUID
avoids any wraparound/collision reasoning entirely.

**Rationale:** this is a direct reuse of the codebase's own established fix
for this exact bug class — `AudioService.swift`'s `volumeRampToken` (HARD-020)
— which the reviewer/rules.md's "boring is good" principle favors over a novel
mechanism.

### D2 — `processingState`/`completionSummary` races: respect SSE ownership + generation-guard the poll
**Choice:** two complementary guards, not a single generic token:
1. `refresh()`'s per-book loop skips overwriting `processingState[book.bookID]`
   for any book that currently has a live SSE subscription
   (`sseTasks[book.bookID] != nil`) — this makes the code *actually* honor
   the "SSE is source of truth" comment already present at
   [AudiobookViewModel.swift:159-163](frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift:159),
   which today only gates whether `refresh()` is *called*, not what it
   *writes* once called from elsewhere (`retry`/`startProcessing`/`cancel`).
2. `refresh()` also gets its own monotonic call-generation token (mirroring
   `DashboardViewModel.speakGeneration`), so two overlapping `refresh()` HTTP
   round-trips for a book with **no** active SSE (plain polling, or two
   closely-spaced user actions) can't apply out of order either.
3. `completionSummary` gets a single incrementing `completionGeneration: Int`,
   captured the moment a `"done"` SSE event is *received* (before the
   `await refresh()`/`fetchDetailWithFallback` work), and the eventual
   `completionSummary = book` assignment is gated on
   `generation == completionGeneration` — a direct, faithful port of the
   `DashboardViewModel.errorResetGeneration` idiom, chosen specifically
   because it makes "last event *received*" win, not "last network call to
   *resolve*" win, which is the semantically correct behavior here.

**Alternatives considered:** a single generic "one token protects everything"
scheme — rejected as less precise: the processingState race is fundamentally
about *ownership* (SSE vs. poll, not just staleness), so a pure staleness
token alone would still let a legitimate but slow poll response silently
overwrite fresher SSE data for a book that has no active subscription. The
hybrid directly encodes both failure modes found in the evidence.

**Rationale:** minimal, targeted, matches existing codebase idioms in two
different established places rather than inventing a third pattern.

### D3 — Transcript panel: make it genuinely reactive, remove the decoupled ticker
**Choice:** add `@EnvironmentObject var audio: AudioService` to
`AudiobookPlayerView` (verified safe — it's within the environment injection
scope, confirmed this session by tracing the presentation chain). Replace
reads of `bookVM.audio.currentTime`/`.progress`/`.isPlaying` with direct reads
of the environment object's `@Published` properties, which re-render the view
at `AudioService`'s own real ~10Hz internal cadence via Combine, not a
separate 4Hz poke. Remove the `ticker`/`Timer.publish(every: 0.25, ...)`
mechanism entirely; move its one non-cosmetic side effect (checking
`playbackCompleted && sleepUntilEndOfBook` to cancel the sleep timer) to an
`.onChange(of: audio.playbackCompleted)` handler instead.

**Alternatives considered:** just increasing the ticker rate to 0.1s to match
`AudioService`'s real cadence — rejected: this papers over the root cause
(no real subscription) without fixing it, keeps the redundant/wasteful
timer, and doesn't fix the *architectural inconsistency* between this screen
and `NowPlayingBar` (which already uses the correct pattern via
`VoqoraWindow`'s existing `@EnvironmentObject var audio: AudioService`,
[VoqoraWindow.swift:7](frontend/Voqora/Voqora/Views/VoqoraWindow.swift:7)).
Given the fix is verified-safe and not materially riskier than the papering-
over alternative, this plan does the real fix.

**Trade-off accepted:** slightly larger diff on `AudiobookPlayerView.swift`
than the minimal patch, but directly matches "find root causes, not
symptoms" (`rules.md` §1) and eliminates an entire class of future staleness
bugs in this view, not just the transcript-scroll symptom.

### D4 — Transcript/`currentSection` memoization
**Choice:** cache `orderedPages` (sorted page list) and a pre-sorted
`(page, startTime)` array keyed by the transcript's identity (recomputed only
when a *new* transcript loads, not on every render); look up the current page
via binary search into that cached sorted array against `audio.currentTime`
(O(log M) instead of O(M log M) every render). Apply the same pattern to
`currentSection`.

**Rationale:** the underlying data (`pageToTime`, `book.sections`) is static
for a given loaded transcript — only `currentTime` changes per tick — so
re-sorting on every render was always wasted work; caching the sort and
binary-searching the *position* is the standard fix and needs no new
dependencies.

### D5 — Transcript auto-scroll: initial scroll + user-scroll pause
**Choice:** (a) trigger `proxy.scrollTo(currentPage, anchor: .center)` once
when the transcript panel appears / when a transcript first loads for the
current book, in addition to the existing `.onChange`-driven scroll on page
transitions. (b) Add a `@State private var userScrolledAt: Date?` set via a
`DragGesture` (or `.onScrollGeometryChange` if targeting a new-enough macOS —
confirm target deployment version before implementation) on the transcript
`ScrollView`; suppress the auto-scroll-on-page-change effect while
`userScrolledAt` is within the last ~4 seconds, matching the existing toast
auto-dismiss duration used elsewhere in this feature for consistency.

**Alternatives considered:** permanently disabling auto-scroll once the user
manually scrolls (until they tap a "jump to now playing" button) — rejected
as a bigger UX change than the bug fix calls for; a timeout-based pause is
the more common, less surprising pattern (as used in music apps' lyric
views) and is a smaller, lower-risk change.

## 6. Interfaces, Data Models & Contracts

**Backend `_emit("done", ...)` payload** gains a `failed_pages` field
(already computed and stored in meta, just not included in the terminal SSE
event) so a listening client can know immediately, without a separate GET:
```python
cls._emit(book_id, "done", actual=actual, failed_pages=cls_failed_pages_snapshot)
```
(exact variable name to be confirmed against the live `_run_pipeline` scope
at implementation time — `failed_pages` is tracked per-phase in `_phase_tts`'s
local `failed: list[int]`, not currently threaded back to the `_run_pipeline`
caller; this needs plumbing, see T-1).

**Backend transcript page marking** — a new sentinel distinct from both real
text and the existing `"-"` dedup marker, e.g. a `page_status` side-channel
in `transcript.json` (`{"pages": {...}, "page_status": {"7": "tts_failed", "12": "duplicate"}}`)
so the frontend can render a failed/duplicate page distinctly instead of
either showing wrong text or an unexplained dash. Exact schema finalized in
T-1 (a genuine but small design choice — see Open Questions).

**Frontend `AudiobookViewModel` new private state:**
```swift
private var sseGeneration: [String: UUID] = [:]
private var refreshGeneration = 0
private var completionGeneration = 0
```

**`AudiobookPlayerView` new dependency:**
```swift
@EnvironmentObject var audio: AudioService
```
(alongside its existing `vm: DashboardViewModel`, `bookVM: AudiobookViewModel`).

## 7. File-by-File Change Map

### Backend

- **`backend/app/services/audiobook_service.py`**:
  - `_phase_tts` (~lines 659-716): on TTS failure, in addition to the
    existing silence-WAV write, mark the page in a new `page_status` map
    (or equivalent — see T-1) instead of leaving the clean text file
    untouched; ensure `failed_pages` is threaded to `_run_pipeline`'s completion
    so it can be included in the `"done"` emit.
  - `_phase_concat`'s transcript-building loop (~lines 816-823): when writing
    `transcript.json`, include the `page_status` map alongside `pages` so a
    failed/duplicate page is distinctly marked, not shown as full text or a
    bare `"-"`.
  - `_run_pipeline`'s `"done"` emit (~lines 330-334): include `failed_pages`.
  - TTS phase's missing-clean-text branch (~lines 685-689): after the
    `continue`, still perform the `phase_progress` meta update and `page_done`
    emit that the rest of the loop does (lines 711-716), just with the
    already-known silence-page outcome.
  - `_phase_clean`'s per-page cancel check (~line 566) and `_generate_full_page`
    (~lines 720-740): add a cancellation check inside the TTS segment loop
    (between segments, not just at the page boundary) so a mid-page cancel
    responds within one segment's synthesis time, not a whole page's.
  - `_phase_clean`'s `asyncio.gather` (~lines 651-654): switch to
    `asyncio.gather(*(clean_one(n) for n in pending), return_exceptions=True)`
    and inspect results afterward, cancelling any still-pending sibling
    coroutines' underlying work explicitly (or restructure with a shared
    `asyncio.Event`/cancel-scope) so a cancelled clean phase can't leave
    stragglers mutating meta after the book is logically terminal. Exact
    mechanism is a real design choice — see T-4/Open Questions.
  - `retry_failed` (~lines 206-215): only delete+re-clean a failed page's
    clean text if that page's `page_status` indicates a cleaning failure;
    leave clean text alone (only re-run TTS) for TTS-only failures.

### Frontend

- **`frontend/Voqora/Voqora/Models/Audiobook.swift`**: `displayStatus`
  (lines 36-58) gains a `case "sectioning": return .sectioning` (a new
  `ProcessingStatus` case — check `ProcessingStatus`'s definition location
  and add the case there too, with a caption/overlay consistent with the
  other in-progress cases).
- **`frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift`**:
  - `applyStatus` (389-402) and `applyPhase` (404-413): add the matching
    `"sectioning"` case in both.
  - `subscribe(to:)` (328-366): add `sseGeneration` UUID-token guard per D1.
  - `refresh()` (136-152): add the SSE-ownership skip + `refreshGeneration`
    guard per D2.
  - The `"done"` handler inside `subscribe(to:)` (346-359): add
    `completionGeneration` guard per D2.
  - `delete()` (660-683): cancel and remove `sseTasks[bookID]` alongside the
    existing `processingState.removeValue`.
  - `completionObserver` sink (120-129) and `AudioService.stop()`
    (`Services/AudioService.swift:387-409`): narrow mitigation for the
    speculative timing race — capture the relevant book identity at the time
    the completion Task is scheduled rather than reading `self.nowPlaying`
    fresh in the sink (see T-10 for exact mechanism).
  - `refresh()`'s catch path (~line 149, T-17): set a distinguishable
    load-failure flag/state (not just the existing transient toast) so
    `AudiobookLibraryView` can render a state visibly different from "empty
    library."
- **`frontend/Voqora/Voqora/Views/Audiobook/AudiobookPlayerView.swift`**:
  add `@EnvironmentObject var audio: AudioService`; remove `ticker`/
  `tickerTimer`; replace `bookVM.audio.*` reads with `audio.*`; memoize
  `orderedPages`/`currentPageID`/`currentSection` per D4; add initial-scroll
  and user-scroll-pause per D5.
- **`frontend/Voqora/Voqora/Views/Audiobook/AudiobookLibraryView.swift`**:
  wire up `.searchable(text: $searchText)` (or an inline `TextField`,
  matching `VaultView.swift`'s existing `.searchable()` convention for
  consistency); add a "no results" empty state for a non-empty search with
  zero matches; change `.allowsHitTesting(!isProcessing)` so it only disables
  the primary tap action, not the whole subtree (e.g. move it to the inner
  `Button`'s own gesture rather than the wrapping `contentShape`); add a
  distinct load-failure state when `refresh()`'s catch path fires on first
  load, instead of falling back to `emptyState`.
- **`frontend/Voqora/Voqora/Views/Audiobook/AudiobookCardView.swift`**: fix
  card/cover width to track the adaptive grid column (or clamp consistently)
  instead of a hard 180pt; add `.lineLimit(1)` to caption `Text` views.
  `SkeletonCard` (in `AudiobookLibraryView.swift`) gets the matching width fix.
- **`frontend/Voqora/Voqora/Views/Audiobook/UploadEstimateModal.swift`** /
  **`CompletionSummaryModal.swift`**: reconcile `.frame(width:height:)` to a
  shared size (pick one, e.g. `520×640`, and apply to both — the larger of
  the two avoids clipping either modal's content).
- **`UploadEstimateModal.swift`**: Start-Processing button's `.disabled(...)`
  condition gains a missing-Gemini-key check alongside the existing
  `requiresGeminiOCR` check when Gemini cleanup is toggled on.
- **`frontend/Voqora/Voqora/Views/Audiobook/AudiobookToastView.swift`** /
  **`ViewModels/AudiobookViewModel.swift`** `showToast`/`toastDismissTask`
  (276-294): increase error-toast duration and/or remove the `.lineLimit(2)`
  cap specifically for `.error` kind toasts (keep the shorter/truncated
  behavior for `.info`/`.success`, which are less likely to carry essential
  detail).
- Accessibility labels added to icon-only buttons in `AudiobookToastView.swift`,
  `UploadEstimateModal.swift`, and the sort `Picker` in
  `AudiobookLibraryView.swift`.

## 8. Edge Cases & Failure Modes

- **A book with `failed_pages` from before this fix ships** (already `done`
  with a stale desynced transcript): the new `page_status`/`failed_pages`
  plumbing only applies going forward — an already-completed book's
  `transcript.json` won't retroactively gain the new field. Acceptable: no
  data migration is in scope; a user can `retry_failed` to regenerate
  affected pages correctly under the new code.
- **Every book already has `sectioning` in its status history** (this isn't
  a new phase, just newly-handled) — no backend change needed for T-6, this
  is purely a frontend mapping gap. Confirm no other frontend code path
  assumes the old `default: .queued` fallback intentionally (grep before
  changing).
- **`sseGeneration` map growth**: like `processingState`, never proactively
  pruned except on `delete()` — same bounded-by-library-size concern as
  today's `processingState`, not made worse by this change; not fixed here
  (out of scope, matches existing `processingState` behavior pre-fix).
- **User scrolls the transcript exactly as a new page boundary is crossed**:
  the 4s pause window (D5) means auto-scroll stays suppressed briefly even
  past that boundary — acceptable, matches the chosen UX trade-off; document
  in the code comment so it isn't "fixed" back to unconditional later without
  understanding why.
- **A book finishes (`"done"`) while its transcript panel is open and mid-
  scroll**: the initial-scroll-on-load logic (D5) should not re-trigger just
  because the transcript data becomes available "more complete" mid-session —
  key the one-time initial scroll off "transcript identity + book identity"
  first becoming non-nil, not off every transcript data change.
- **Cancel arriving after a book already reached a terminal state** (finding
  #5's race): the `asyncio.gather` restructure (T-4) must ensure a
  known-terminal book's meta can never be mutated by a straggler — verify
  with a test that explicitly races this.

## 9. Security & Privacy

No new trust boundaries. `page_status`/`failed_pages` additions to the SSE
payload and `transcript.json` carry only processing-state metadata already
computed server-side, not new user input surface. No secrets, auth, or PII
implications beyond what the existing audiobook pipeline already handles.

## 10. Test Plan

**Backend (pytest, `backend/tests`, following `test_audiobook.py`/
`test_audiobook_sse.py` conventions):**
- Unit: TTS-failure page marking — mock a TTS exception for one page, assert
  `page_status`/`failed_pages` reflects it and the transcript doesn't show
  that page's text as if it were narrated successfully.
- Unit: `"done"` SSE payload includes `failed_pages`.
- Unit: TTS phase's missing-clean-text branch still emits `page_done` and
  updates `phase_progress`.
- Unit: cancellation check fires mid-page in the TTS segment loop (mock a
  multi-segment page, cancel mid-loop, assert it stops before the last
  segment).
- Integration: cancel + immediate delete race — mock a slow `clean_one`,
  cancel then delete rapidly, assert no zombie DB row exists afterward
  (`AudiobookStore.list_books()` doesn't contain the deleted book_id).
- Unit: `retry_failed` only re-cleans pages whose `page_status` indicates a
  cleaning failure, not TTS-only failures.

**Frontend (XCTest, `VoqoraTests`, following `AudiobookPlaybackStateTests.swift`
conventions — extract pure logic into testable functions per that file's
established style):**
- Unit: `displayStatus`/`applyStatus`/`applyPhase` all correctly map
  `"sectioning"`.
- Unit: `sseGeneration` token — simulate two overlapping `subscribe()` calls
  for the same book, assert the older task's deferred cleanup doesn't clear
  the newer registration.
- Unit: `refresh()`'s SSE-ownership skip — assert `processingState` isn't
  overwritten for a book with an active `sseTasks` entry.
- Unit: `completionGeneration` guard — simulate two out-of-order-resolving
  "done" fetches for different books, assert `completionSummary` reflects
  the one whose SSE event was received last, not resolved last.
- Unit: `delete()` cancels and removes the book's `sseTasks` entry.
- Unit: memoized `orderedPages`/`currentPageID`/`currentSection` return
  identical results to the old unmemoized versions for the same inputs
  (regression-proof the optimization).
- Unit: initial-scroll and user-scroll-pause logic (extract as pure
  functions where possible, matching the `heartbeatDelay`-style extraction
  precedent from `jira-cpu-ram-optimization.md`).
- Existing suite: `AudiobookServiceTests.swift`, `AudiobookPlaybackStateTests.swift`
  continue passing unmodified.

**Manual verification (documented, not automatable in CI):**
- Process a real multi-page PDF/document through the full pipeline, open the
  transcript panel mid-processing and mid-playback, confirm: correct phase
  progression through sectioning, no progress regression/flicker, transcript
  panel opens scrolled to the right page, manual scroll isn't fought,
  right-click works on a processing card, both modals are the same size,
  search actually filters the library.

## 11. Verification Plan (how we PROVE it)

Commands confirmed against the repo-root `Makefile` (same as
`jira-cpu-ram-optimization.md`):

| Area | Command / Action | Expected |
|---|---|---|
| Backend unit/integration tests | `make test-backend` | All tests pass, including new ones |
| Frontend unit tests | `make test-swift` | All tests pass, including new ones |
| Lint | `make lint` | Clean |
| Fast regression | `make verify` | Green |
| Full regression | `make test-ci` | Green |
| Manual pipeline run | Process a real document end-to-end per §10 | Every phase visibly progresses correctly; no desync; scroll behaves as specified |

## 12. Acceptance Criteria

- [ ] A TTS-failed page is marked distinctly in the transcript, not shown as
      matching text or a bare `"-"`; `failed_pages` reaches the frontend via
      the `"done"` SSE payload.
- [ ] Duplicate-page dedup marker is distinguishable from a real failure.
- [ ] TTS phase progress never stalls for a missing-clean-text page.
- [ ] Mid-page cancellation responds within one segment, not a whole page.
- [ ] Cancel + immediate delete cannot resurrect a deleted book's DB row
      (tested).
- [ ] `retry_failed` only re-cleans pages that actually failed cleaning.
- [ ] `displayStatus`/`applyStatus`/`applyPhase` all handle `"sectioning"` —
      no book ever visibly regresses to "queued" or freezes during it.
- [ ] The `sseTasks` defer race cannot wipe out a newer subscription
      (tested).
- [ ] `processingState` never regresses due to a stale poll response racing
      a newer SSE event (tested).
- [ ] `completionSummary` reflects event-receipt order, not resolution
      order, when two books finish close together (tested).
- [ ] `delete()` cancels the book's SSE task; no post-delete state
      resurrection.
- [ ] The transcript panel scrolls to the current page immediately on open/
      load, and auto-scroll pauses for ~4s after manual scrolling.
- [ ] `orderedPages`/`currentPageID`/`currentSection` are memoized, not
      re-sorted every tick.
- [ ] `AudiobookPlayerView` reads live playback state via a real
      `@EnvironmentObject`, not a decoupled ticker; the ticker is removed.
- [ ] Library search is reachable and functional; a no-results state exists.
- [ ] The processing-card context menu (Cancel Processing) is reachable
      while a card is processing.
- [ ] Upload-estimate and completion modals are the same size.
- [ ] Card/cover width tracks the grid column consistently; captions don't
      wrap and misalign grid rows.
- [ ] A library load failure shows a distinct state from "empty library."
- [ ] Error toasts are readable in full (no premature truncation/dismissal
      for errors specifically).
- [ ] Start-Processing button proactively disables for a missing Gemini key,
      matching the existing image-only-case behavior.
- [ ] Icon-only buttons and the sort picker have accessibility labels.
- [ ] Full test suite (frontend + backend) passes; lint clean.

## 13. Risks, Mitigations & Rollback

| Risk | Likelihood | Impact | Mitigation | Rollback |
|---|---|---|---|---|
| `page_status`/`failed_pages` schema change breaks an existing consumer of `transcript.json` | Low | Medium | New field is additive (existing `pages`/`pageToTime` keys untouched); grep all frontend consumers of `Transcript` before shipping | Revert the schema addition, keep silence-marking without the visible signal |
| Removing `AudiobookPlayerView`'s ticker regresses something relying on its 0.25s side effect beyond the one identified (sleep-timer check) | Low | Medium | Grep-confirmed only one non-cosmetic side effect exists (§7); re-verify via full manual playback test before merging | Revert to the ticker, keep only the memoization fixes (partial win) |
| `asyncio.gather` restructure for cancel-safety in `_phase_clean` introduces a subtler concurrency bug | Medium | Medium | This is the most architecturally involved backend change — write the stress test (T-4) first, verify it fails on old code and passes on new | Revert to current gather behavior; the zombie-row race is rare/edge-case enough to defer if the fix proves risky |
| `refresh()`'s SSE-ownership skip accidentally makes a book's state never update if its SSE task is wrongly believed alive | Medium | Medium | Directly covered by the T-7 fix (the defer race that could cause exactly this) — sequence T-7 before T-8 so the ownership-skip is trustworthy | Revert the skip, fall back to unconditional overwrite (reintroduces the flicker but not a stuck state) |
| 4s auto-scroll-pause window feels wrong in practice (too short/long) | Low | Low | Easy to tune; not a structural risk | Adjust constant |

## 14. Sprints & Tasks

### Sprint 1 — Backend pipeline correctness (independent, can start immediately)

- [ ] `T-1` — Fix transcript/audio desync on TTS failure + duplicate-page marker.
  - Files: `backend/app/services/audiobook_service.py`
  - Depends on: none
  - Acceptance: a TTS-failed page's transcript text is distinctly marked
    (not shown as narrated text, not a bare unexplained `"-"`); duplicate
    pages are also distinctly marked; `failed_pages` reaches the `"done"`
    SSE payload
  - Verify: `make test-backend`; new unit tests below
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Mock a TTS exception for one page of a multi-page book; assert transcript's `page_status` (or equivalent) marks it, and `pages[n]` is not presented as clean narrated text |
    | Integration | Run `_phase_tts` + `_phase_concat` end-to-end with one forced failure; assert the final `transcript.json` and `"done"` SSE payload both reflect it |
    | E2E | N/A — covered by integration; full pipeline run is exercised manually per §10 |

- [ ] `T-2` — Fix TTS-phase progress stall for missing-clean-text pages.
  - Files: `backend/app/services/audiobook_service.py`
  - Depends on: none
  - Acceptance: the missing-clean-text branch still emits `page_done` and
    updates `phase_progress`
  - Verify: `make test-backend`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Simulate a page with no clean file present at TTS time; assert `phase_progress.page_done` advances and a `page_done` SSE event fires |
    | Integration | N/A — single-phase concern, covered by unit |
    | E2E | N/A |

- [ ] `T-3` — Responsive mid-page cancellation.
  - Files: `backend/app/services/audiobook_service.py`
  - Depends on: none
  - **Needs plumbing**: `_generate_full_page(cls, text: str, voice: str,
    speed: float) -> np.ndarray`
    ([audiobook_service.py:721-723](backend/app/services/audiobook_service.py:721))
    has no `book_id` parameter, and `_check_cancel(cls, book_id: str)`
    ([:233](backend/app/services/audiobook_service.py:233)) requires one.
    Thread `book_id` (or a cancel-check callback) into
    `_generate_full_page`'s signature and its one caller in `_phase_tts`
    (~line 684) as part of this task.
  - Acceptance: cancelling mid-page stops within roughly one TTS segment's
    synthesis time, not a whole page
  - Verify: `make test-backend`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Mock a multi-segment page generation; set the cancel flag mid-loop; assert generation stops before the final segment |
    | Integration | N/A — covered by unit against the real segment loop structure |
    | E2E | N/A |

- [ ] `T-4` — Fix cancel + immediate delete zombie-row race.
  - Files: `backend/app/services/audiobook_service.py`
  - Depends on: none
  - Acceptance: a straggler clean-phase task cannot mutate meta for an
    already-deleted book; no resurrected DB row
  - Verify: `make test-backend`; the stress test below must fail on the
    pre-fix code and pass after
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | N/A — this is inherently a concurrency/integration concern |
    | Integration | Mock a slow `clean_one` (e.g. `asyncio.sleep` inside a patched Gemini call), cancel the book, immediately delete it, then assert `AudiobookStore.list_books()` doesn't contain the deleted book_id after the straggler would have run |
    | E2E | N/A |

- [ ] `T-5` — Scope `retry_failed` re-cleaning to actual cleaning failures.
  - Files: `backend/app/services/audiobook_service.py`
  - Depends on: `T-1` (needs `page_status` to distinguish failure type)
  - Acceptance: a TTS-only failure's retry doesn't re-run Gemini cleaning
  - Verify: `make test-backend`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Set up a book with one TTS-only-failed page and one cleaning-failed page; call `retry_failed`; assert only the cleaning-failed page's clean text is deleted/regenerated |
    | Integration | N/A — covered by unit |
    | E2E | N/A |

### Sprint 2 — Frontend sectioning status gap (independent, highest leverage — do early)

- [x] `T-6` — Handle `"sectioning"` in all three status-mapping sites.
  - Files: `frontend/Voqora/Voqora/Models/Audiobook.swift`,
    `frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift`
  - Depends on: none
  - Acceptance: `displayStatus`, `applyStatus`, and `applyPhase` all
    correctly reflect a `"sectioning"` book with a distinct, non-regressing
    UI state
  - Verify: `make test-swift`; new unit tests below
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | `displayStatus` for `status: "sectioning"` returns the new case, not `.queued`; `applyStatus`/`applyPhase` likewise for the SSE/phase paths |
    | Integration | N/A — pure mapping logic |
    | E2E | Manual: process a real book, confirm the card doesn't revert to "QUEUED" or freeze during sectioning |

### Sprint 3 — Frontend state-race fixes (sequenced: T-7 before T-8, since T-8 depends on SSE ownership being trustworthy)

- [ ] `T-7` — Fix `sseTasks` defer race with a per-subscription UUID token.
  - Files: `frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift`
  - Depends on: none
  - Acceptance: an older subscription's cleanup cannot clear a newer one's
    registration
  - Verify: `make test-swift`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Simulate calling `subscribe(to:)` twice in quick succession for the same book (as `startProcessing`/`retry` do); let the first task's cleanup run after the second is registered; assert `sseTasks[bookID]` still holds the second task |
    | Integration | N/A — covered by unit against the real dictionary/token logic |
    | E2E | Manual: retry a failed book repeatedly, confirm progress doesn't stall/reset |

- [ ] `T-8` — Guard `processingState` and `completionSummary` against races.
  - Files: `frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift`
  - Depends on: `T-7`
  - Acceptance: `refresh()` never overwrites `processingState` for a book
    with a live SSE subscription; overlapping `refresh()` calls apply in
    generation order; `completionSummary` reflects SSE-event-receipt order
  - Verify: `make test-swift`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | `refresh()` with a mocked list response for a book that has an active `sseTasks` entry — assert `processingState` is unchanged by the list response |
    | Unit | Two overlapping `refresh()` calls resolving out of order — assert only the newer generation's write applies |
    | Unit | Two "done" events for different books, second one received first but resolving `fetchDetailWithFallback` second — assert `completionSummary` reflects receipt order |
    | E2E | Manual: process two books concurrently, confirm the completion modal shows the correct one and progress never visibly regresses |

- [ ] `T-9` — `delete()` cancels its SSE task; prune `processingState` for
      vanished books.
  - Files: `frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift`
  - Depends on: `T-7` (reuses the generation-token bookkeeping)
  - Acceptance: deleting a processing book cancels its SSE task; a late
    event can't resurrect its `processingState` entry
  - Verify: `make test-swift`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Delete a book with an active `sseTasks` entry; assert the task is cancelled and removed; simulate a late event arriving after delete and assert it's a no-op |
    | Integration | N/A — covered by unit |
    | E2E | N/A |

- [ ] `T-10` — Narrow mitigation for the speculative completion-mis-attribution race.
  - Files: `frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift`,
    `frontend/Voqora/Voqora/Services/AudioService.swift`
  - Depends on: none
  - Acceptance: the completion handler uses the book identity captured at
    the time playback for that book started, not `self.nowPlaying` read
    fresh at sink-execution time
  - Verify: `make test-swift`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Simulate `nowPlaying` changing to book B between a completion event for book A being scheduled and the sink executing; assert A's (not B's) resume-position/metrics are affected |
    | Integration | N/A — this is inherently timing-dependent; the unit test above is the practical ceiling of automated coverage per the plan's own confidence caveat |
    | E2E | N/A — documented as a low-confidence/edge-case fix; no live repro attempted |

### Sprint 4 — Transcript scroll + player reactivity

- [ ] `T-11` — Make `AudiobookPlayerView` reactive via `@EnvironmentObject`;
      remove the decoupled ticker.
  - Files: `frontend/Voqora/Voqora/Views/Audiobook/AudiobookPlayerView.swift`
  - Depends on: none
  - Acceptance: the view reads `audio` via a real `@EnvironmentObject`; the
    `ticker`/`tickerTimer` are removed; the sleep-timer-cancel side effect
    moves to an `.onChange(of: audio.playbackCompleted)` handler
  - Verify: `make test-swift`; manual playback check
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | N/A — this is a SwiftUI view wiring change, not independently unit-testable in isolation beyond what T-13's memoization tests cover |
    | Integration | N/A — same reason |
    | E2E | Manual: play a book, confirm scrubber/highlight/elapsed-time all update smoothly during playback; confirm sleep-timer-at-end-of-book still cancels correctly on natural completion |

- [ ] `T-12` — Memoize `orderedPages`/`currentPageID`/`currentSection`.
  - Files: `frontend/Voqora/Voqora/Views/Audiobook/AudiobookPlayerView.swift`
  - Depends on: `T-11` (needs the real `audio.currentTime` source to key
    the cache invalidation correctly)
  - Acceptance: the transcript's page-sort and section-sort are computed
    once per transcript load, not once per render; current-page/-section
    lookup is O(log M)
  - Verify: `make test-swift`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Memoized `orderedPages`/`currentPageID`/`currentSection` return identical results to a reference (old unmemoized) implementation across a range of `currentTime` values, including boundaries |
    | Integration | N/A |
    | E2E | Manual, on a long (100+ page) book: confirm no visible scroll jank while playing and dragging the transcript |

- [ ] `T-13` — Transcript initial-scroll + user-scroll-pause.
  - Files: `frontend/Voqora/Voqora/Views/Audiobook/AudiobookPlayerView.swift`
  - Depends on: `T-11`, `T-12`
  - Acceptance: opening the transcript panel (or loading a transcript
    mid-book) scrolls immediately to the current page; auto-scroll is
    suppressed for ~4s after a detected manual scroll
  - Verify: `make test-swift`; manual check
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Extracted pure logic (e.g. "should auto-scroll now given `userScrolledAt` and current time") tested directly, matching the `heartbeatDelay`-extraction precedent |
    | Integration | N/A |
    | E2E | Manual: open the transcript 20 minutes into a book, confirm it opens scrolled to the right page; manually scroll during playback, confirm it isn't immediately yanked back |

### Sprint 5 — Library/modal UI polish (mechanical, lower risk, can run in parallel with Sprint 3/4)

- [ ] `T-14` — Wire up library search + no-results state.
  - Files: `frontend/Voqora/Voqora/Views/Audiobook/AudiobookLibraryView.swift`
  - Depends on: none
  - Acceptance: `.searchable()` is actually rendered and filters the grid;
    a zero-match search shows a distinct "no results" message, not a blank
    area
  - Verify: `make test-swift`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | `filteredSorted` (existing logic) already covered if tested; add a case for the new no-results state trigger condition |
    | Integration | N/A |
    | E2E | Manual: type a search term matching nothing, confirm the message appears |

- [ ] `T-15` — Fix processing-card hit-testing blocking the context menu.
  - Files: `frontend/Voqora/Voqora/Views/Audiobook/AudiobookLibraryView.swift`
  - Depends on: none
  - Acceptance: right-clicking a processing card opens its context menu
    (Cancel Processing reachable); the primary tap-to-open action is still
    correctly disabled while processing
  - Verify: `make test-swift`; manual check (this is fundamentally a
    gesture-recognition behavior, per §10's E2E note)
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | N/A — SwiftUI hit-testing/gesture behavior isn't practically unit-testable |
    | Integration | N/A |
    | E2E | Manual: right-click a processing card, confirm the context menu (with Cancel Processing) appears |

- [ ] `T-16` — Reconcile modal sizes and card/grid width consistency.
  - Files: `frontend/Voqora/Voqora/Views/Audiobook/UploadEstimateModal.swift`,
    `CompletionSummaryModal.swift`, `AudiobookCardView.swift`,
    `AudiobookLibraryView.swift`
  - Depends on: none
  - Acceptance: both modals share one frame size; card/cover width tracks
    the grid column consistently; caption text has a line limit matching
    the title's pattern
  - Verify: `make test-swift`; visual check
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | N/A — layout/frame values, not logic |
    | Integration | N/A |
    | E2E | Manual: compare the two modals side by side; resize the library window and confirm cards/grid stay visually consistent |

- [ ] `T-17` — Distinct library-load-failure state.
  - Files: `frontend/Voqora/Voqora/Views/Audiobook/AudiobookLibraryView.swift`,
    `frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift`
  - Depends on: none
  - Acceptance: a first-load failure (e.g. backend unreachable) shows a
    state visibly distinct from "you have no books yet"
  - Verify: `make test-swift`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | `refresh()`'s catch path sets a distinguishable error flag/state, not just a transient toast |
    | Integration | N/A |
    | E2E | Manual: simulate a backend-down first load, confirm the distinct message appears |

- [ ] `T-18` — Improve error-toast readability.
  - Files: `frontend/Voqora/Voqora/Views/Audiobook/AudiobookToastView.swift`,
    `frontend/Voqora/Voqora/ViewModels/AudiobookViewModel.swift`
  - Depends on: none
  - Acceptance: error-kind toasts are not truncated to 2 lines and/or persist
    longer than 4s (info/success toasts keep current behavior)
  - Verify: `make test-swift`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | `showToast`'s dismiss-timing logic differentiates by `kind` (error vs. info/success) |
    | Integration | N/A |
    | E2E | Manual: trigger a long error message, confirm it's fully readable before dismissal |

- [ ] `T-19` — Start-Processing button gates on missing Gemini key.
  - Files: `frontend/Voqora/Voqora/Views/Audiobook/UploadEstimateModal.swift`
  - Depends on: none
  - Acceptance: toggling Gemini cleanup on without a saved key proactively
    disables Start, matching the existing image-only-case affordance
  - Verify: `make test-swift`
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | The button's disabled-condition logic (extracted if not already pure) returns `true` for "Gemini cleanup on, no key saved" |
    | Integration | N/A |
    | E2E | Manual: toggle Gemini cleanup with no key saved, confirm Start is disabled |

- [ ] `T-20` — Accessibility labels sweep.
  - Files: `frontend/Voqora/Voqora/Views/Audiobook/AudiobookToastView.swift`,
    `UploadEstimateModal.swift`, `AudiobookLibraryView.swift`
  - Depends on: none
  - Acceptance: icon-only buttons and the sort `Picker` have meaningful
    `.accessibilityLabel`s
  - Verify: `make test-swift`; VoiceOver spot-check if feasible
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | N/A — accessibility labels aren't practically unit-tested here |
    | Integration | N/A |
    | E2E | Manual: VoiceOver walk-through of the affected controls, or at minimum visual confirmation labels are set |

### Sprint 6 — Final verification

- [ ] `T-21` — Full regression pass across both languages.
  - Files: none (verification only)
  - Depends on: `T-1` through `T-20`
  - Acceptance: all items in §12 checked off with evidence
  - Verify: `make test-ci`; `make lint`; manual pipeline run per §10
  - Tests:
    | Layer | Test |
    |---|---|
    | Unit | Full existing + new unit suite green (both languages) |
    | Integration | Full existing + new integration suite green |
    | E2E | Manual verification procedure from §10 executed once, findings recorded for the `/close` summary |

## 15. Sequencing & Dependencies

```
Sprint 1 (backend, independent)        Sprint 2 (T-6, independent)
T-1 ──→ T-5                             T-6
T-2 (independent)
T-3 (independent)
T-4 (independent)

Sprint 3 (frontend state races)        Sprint 4 (transcript/player)
T-7 ─→ T-8 ─→ T-9                      T-11 ─→ T-12 ─→ T-13
T-10 (independent)

Sprint 5 (UI polish, all independent of each other and of 1-4)
T-14, T-15, T-16, T-17, T-18, T-19, T-20

                    ↓ (all of the above)
                  T-21 (final verification)
```

Critical paths: `T-7 → T-8 → T-9` and `T-11 → T-12 → T-13`. Sprint 1, Sprint 2,
`T-10`, and all of Sprint 5 are independent of everything else and of each
other — maximum parallelism available across implementer agents during
`/implement`.

## 16. Open Questions & Decisions Log

- **Resolved:** `sseTasks` race fix mechanism — UUID token per subscription,
  reusing the codebase's own `AudioService.volumeRampToken`/HARD-020 idiom
  (§5, D1).
- **Resolved:** `processingState`/`completionSummary` race fix — hybrid
  SSE-ownership + generation-token, not a single generic token (§5, D2).
- **Resolved:** transcript reactivity — real `@EnvironmentObject`, ticker
  removed, verified safe against the actual environment injection chain
  (§5, D3).
- **Resolved:** sentence/word-level transcript sync — explicitly out of
  scope, it's a feature addition not a bug fix (§4).
- **Open:** exact `page_status`/`failed_pages` schema for T-1 — the plan
  proposes a `page_status: {"7": "tts_failed", "12": "duplicate"}` side
  channel in `transcript.json`, but the precise shape (a parallel dict vs.
  richer per-page objects vs. reusing the existing `failed_pages` list plus
  a new `duplicate_pages` list) should be finalized at implementation time
  by whoever picks up T-1 — grep all frontend consumers of `Transcript`
  first (per §13's risk row) to pick the least-disruptive shape.
- **Open:** `_phase_clean`'s `asyncio.gather` cancel-safety restructure
  (T-4) — the plan identifies the bug and the general direction
  (`return_exceptions=True` + explicit straggler handling, or a shared
  cancel-scope) but the exact implementation is a real design decision for
  whoever picks up T-4; write the stress test first (per the task's own
  Verify step) so the fix is provably correct regardless of which specific
  mechanism is chosen.
- **Open:** `.onScrollGeometryChange` (newer API) vs. a `DragGesture`-based
  approach for user-scroll detection in T-13 — depends on this project's
  minimum deployment target, which wasn't checked this session; confirm via
  the Xcode project's `MACOSX_DEPLOYMENT_TARGET` before implementation.
- **Open:** exact toast duration/truncation values for T-18 (increased from
  4s/2 lines to what, specifically) — left as an implementation judgment
  call within the stated goal ("error toasts are fully readable before they
  vanish"), not pre-specified, since the right number depends on typical
  error-message length seen in practice.
