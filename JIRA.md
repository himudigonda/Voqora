# Voqora v1 release-readiness board

**Rule:** this is a release gate, not a wish list. A row may move to `Done`
only with linked source, automated evidence, and where relevant a real packaged
app or public-surface check. `Blocked` means an external decision or account is
required, not that the work has been silently skipped.

**Release state:** no new version, tag, DMG, GitHub release, or campaign is
authorised while this board contains an open P0 or P1 item.

## Conversation reconciliation: every requested outcome

This section is deliberately broader than the engineering release gates below.
It is the working inventory of the product, public-story, legacy, and
operational asks made for Voqora. A checkbox is not evidence; it only prevents
an instruction from disappearing between work sessions.

| ID | Requested outcome | State today |
| --- | --- | --- |
| R-01 | Treat Voqora as a new public product, not a flimsy rename announcement. | Partial: source and product copy are Voqora-first; public surfaces still need a final audit. |
| R-02 | Keep the v1.1 multilingual/experimental work private until next week. | Done locally: `develop` is local-only; its multilingual implementation is absent from `main`. It must not be pushed, merged into public main, or included in v1. |
| R-03 | Keep public main and private successor work cleanly separated. | Done locally: public work is on `main`; `main...develop` shows the successor-only multilingual code and voice assets. Current v1 reliability hardening is merged into `develop` locally, so a later private-to-public feature decision is explicit rather than a hidden dependency. `main` remains ahead of its public remote while this release gate is open. |
| R-04 | Do not make another release until development, QA, GTM, and evidence are complete. | Active rule. No new release is being made. |
| R-05 | Freeze SuperSay as a public legacy product with no experimental work. | Partial: Voqora has an explicit successor path; legacy repository/archive and public banner still need inspection. |
| R-06 | Give SuperSay an unmistakable successor notice and route old discovery to Voqora. | Partial: copy exists locally; legacy repository and live pages need a route-by-route proof. |
| R-07 | Let Voqora detect SuperSay and offer an explicit preference import/removal guidance. | Partial: source and unit coverage exist; live filesystem flow still needs proof. |
| R-08 | Never silently delete SuperSay, user data, or user choices. | Implemented in source; manual migration test still open. |
| R-09 | Use Voqora as the real product name everywhere in the app, source, website, repository, assets, and docs. | Partial: intentional legacy references remain; an exhaustive visible-brand audit is open. |
| R-10 | Remove Google sign-in/auth residue and make the product usable without an account. | Partial: current identity is optional email only; repository-wide residue audit is open. |
| R-11 | Start every fresh Voqora install with Bella, not Chinese or a stale voice. | Partial: migration and isolated-default tests reset unsupported voices to `af_bella`; the exact local Release candidate showed Bella. A downloaded candidate DMG still needs the same clean-profile proof. |
| R-12 | Repair onboarding, permission prompting, and the stuck/blank first-run screen. | Partial: root cause fixed and live local first-run shown; clean installed-DMG permission completion remains. |
| R-13 | Use the real Voqora icon in the app, not a placeholder. | Partial: current first-run candidate uses the bundled Voqora icon and readable copy. A mounted-DMG visual proof remains. |
| R-14 | Make the DMG feel like Voqora’s product UI, with visible text and a literal drag instruction. | Partial: artwork and copy redesigned locally; no candidate DMG has been built or visually inspected. |
| R-15 | Make installer behavior truthful and easy: drag to Applications, then open. | Implemented locally; candidate-DMG test remains. |
| R-16 | Fix the update path, settings toggle, manual check UI, signature failure, and release-cycle automation. | Partial: local pipeline now publishes an immutable GitHub DMG before Pages exposes its appcast. Preferences now distinguishes preparing, checking, up-to-date, and retry-safe failure states instead of making a manual check look inert. The live feed remains behind the current tag and an installed older-to-newer update has not succeeded yet. |
| R-17 | Keep testing from launching many apps or consuming runaway CPU. | Done for the harness: v1 main runs one serial Swift host (73 tests) and 184 backend tests headlessly. After the local merge, private v1.1 passed 177 Swift and 389 backend tests in the same serial/headless shape, with its SSE lifecycle test fully isolated from the loopback backend. Local run tooling, reset tooling, and app shutdown require an exact owned process or an explicit user quit; none kills every similarly named process. |
| R-18 | Test every real app flow, not only unit tests. | Open: this is the core remaining release-readiness work. |
| R-19 | Ensure selected-text reading, pause/resume/stop, no-selection feedback, history, and WAV export are solid. | Partial: exact bundled backend produced a valid 24 kHz WAV; tests cover empty export rejection, unique filenames, history persistence, and no-playback feedback. Accessibility-authorised selected-text and full GUI export remain manual gates. |
| R-20 | Ensure document audiobook import, processing, errors, resume, cancellation, and optional Gemini cleanup are solid. | Partial: local-first default and Gemini-only-on-explicit-choice are covered by focused backend tests. Fixture-driven PDF, TXT, DOCX, and Markdown import, cancellation, resume, corrupt-file, and user-visible error passes remain. |
| R-21 | Make settings clear, durable, and visually polished, especially onboarding reset, identity, and telemetry. | Partial: identity UI now states plainly that Voqora works without an account, explains the optional aggregate-adoption purpose, and gives a visible reason when Save is disabled. Visual/accessibility pass remains. |
| R-22 | Make optional email storage/removal and anonymous usage accounting truthful. | Blocked on production reconciliation: local API/unit coverage and removal code exist, but the deployed metrics endpoint is on an older schema. No claim about remote storage/removal is valid until migration and end-to-end receipt. |
| R-23 | Count anonymous installations without pretending installations equal people. | Blocked on production reconciliation: local canonical-installation schema is ready, but current live counts use the older contract. Fresh retry/idempotency proof must run only after the matching schema and website are deployed together. |
| R-24 | Track intentional download clicks separately from installs and make HEAD/previews non-counting. | Done: endpoint tests and live redirect check pass. |
| R-25 | Make Supabase, himudigonda.me, and the dashboard lean, Voqora-only for active reporting, and internally consistent. | Partial: the inspected production project contains only `voqora_*` active tables/views. The website deployment is stale relative to the local Voqora-only schema/API, so counts disagree; no destructive database cleanup is allowed while that mismatch exists. |
| R-26 | Make analytics/dashboard language exact and product-manager-quality. | Partial: local API/dashboard labels use non-overlapping metric names and the dashboard now fails clearly on an old schema rather than displaying zeros. Production still needs a matching migration, website deploy, and browser comparison. |
| R-27 | Use the actual app screenshot as GitHub, website blog, and project hero. | Implemented locally and in source; public rendered audit remains. |
| R-28 | Make GitHub the primary trust destination and preserve a separately measured download CTA. | Partial: source links are wired; public rendered journey needs proof. |
| R-29 | Restore the detailed old SuperSay article at its legacy destination, with one clear Voqora handoff. | Partial: local content path changed; redirects and public render remain. |
| R-30 | Write a long, technical Voqora deep dive in the same calibre and voice as SuperZen, about Voqora itself. | Partial: the local Voqora article is now a 3,600+ word product/engineering deep dive with architecture diagrams and no rebrand monologue. Editorial comparison and public rendered proof remain. |
| R-31 | Remove excessive SuperSay/rebrand narration from the Voqora article. | Implemented locally; not deployed. |
| R-32 | Make all blog, project, and route names consistent (`/supersay`, `/blog/supersay`, `/blog/voqora`). | Open: route/canonical-link audit is required. |
| R-33 | Produce polished v1 and v1.1 marketing packages on Desktop: LinkedIn, Reddit, HN, X, video scripts, slides, benchmarks. | Open: no public-facing package should be called final until candidate capabilities are locked. |
| R-34 | Make launch assets visually premium, landscape, concise, product-led, and aligned with the real app UI. | Open: existing assets need an editorial/visual inventory and rebuild pass. |
| R-35 | Include credible benchmarks and one understandable technical-detail slide. | Open: benchmark source exists, but publication assets are not final. |
| R-36 | Make README, changelog, install guide, pipeline docs, and support guidance as polished as the original project. | Partial: major docs exist; source-to-artifact audit and support journey remain. |
| R-37 | Keep the new public repository/license/history coherent and non-commercial source-available. | Partial: license is present; repository/release-boundary audit remains. |
| R-38 | Prove public DMG install works despite Gatekeeper friction. | Blocked: current public DMG is not notarized and is objectively rejected by Gatekeeper. |
| R-39 | Make a deliberate final `v1.0.x` only after a full Go/No-Go review. | Open. |
| R-40 | Keep v1.1 as the later experimental/multilingual release, not part of this launch. | Done locally: the branch audit confirms the multilingual feature set stays only on local `develop`; it is not in `main` or any current public release candidate. |

### Reconciliation rule

Rows R-01 through R-40 and VQ-001 through VQ-052 are both release gates.
Before a release, each must be explicitly `Done`, `Blocked` with an accepted
owner decision, or `Not applicable` with a written reason. Nothing is inferred
from a green unit-test run or a prettier screenshot.

## P0: must be true before a public build

| ID | Area | Outcome | Evidence required | Status |
| --- | --- | --- | --- | --- |
| VQ-001 | First launch | A brand-new install lands in onboarding, never a blank player or hidden sheet. | Fresh-state run plus onboarding unit/UI coverage. | Partial: a freshly rebuilt local Release bundle visibly opened Voqora's Welcome screen with its real icon, and coordinator tests pass. The final downloaded DMG still needs the same evidence. |
| VQ-002 | Permissions | Accessibility permission is explained, requested at the right time, and recoverable from Settings. | Manual macOS permission-path check. | Open |
| VQ-003 | Core reading | Selected text starts, pauses, resumes, stops, and reports useful failures when no selection exists. | Service tests plus one live selection run. | Open |
| VQ-004 | App startup | Local speech backend has a bounded startup path, visible recovery state, and no indefinite loading screen. | Cold-start timing and failure-path run. | In progress: the latest exact Release bundle reached `ready/loaded: true`; a real `/speak` response is accepted by both `afinfo` and Python's WAV parser as 24 kHz mono PCM; empty text is rejected with HTTP 422. Forced-failure recovery remains. |
| VQ-005 | Default voice | A fresh profile starts in Bella and does not inherit an unexpected language/voice. | Fresh-state preference assertion and manual run. | Partial: regression test and exact local Release UI prove Bella; final downloaded DMG proof remains. |
| VQ-006 | Playback state | Double actions and stale error timers cannot overwrite a later correct state. | Deterministic regression tests. | Done locally: state/timer tests and a controlled delayed-audiobook fetch prove Stop invalidates the request, clears loading state, and suppresses its late error. |
| VQ-007 | History/export | Saved history and WAV export either succeed or give an actionable, non-destructive error. | File-system integration test. | Partial: deterministic tests prove valid WAV headers, collision-safe filenames, empty-audio rejection, and history write failure reporting; an interactive export to a real Finder location is open. |
| VQ-008 | Audiobooks | Document import, validation, progress, cancel, retry, resume, and corrupt-file recovery are clear and safe. | Fixture-driven tests and manual import. | Partial: local-first and Gemini-explicit backend behavior is covered; PDF, TXT, DOCX, and Markdown fixture/UI proof is open. |
| VQ-009 | Preferences | Voice, speed, volume, shortcuts, appearance, onboarding reset, and email controls are understandable and durable. | Preference persistence test and visual pass. | In progress |
| VQ-010 | Migration | Detecting SuperSay offers an explicit, reversible preference import; it never deletes another app or claims a migration that did not happen. | File-system fixture test and manual smoke test. | Open |
| VQ-011 | DMG install | Mounted DMG contains the intended app, Applications alias, version, icon, and readable install instructions. | Mounted-DMG inspection receipt. | In progress: mounted v1.0.2 has the right bundle ID, version, app, and Applications alias; redesigned candidate artwork still needs a candidate DMG. |
| VQ-012 | Gatekeeper | The documented free-install path works from a clean download. The stricter notarized route is clearly separated. | Clean-machine/manual Gatekeeper evidence. | Blocked: actual v1.0.2 artifact is Gatekeeper-rejected until Developer ID/notarization is available. The ship command now refuses an accidental repeat by default; the free fallback requires an explicit release-owner override. |
| VQ-013 | Update safety | No installed user is offered an update whose archive byte stream cannot pass Sparkle verification. | Live appcast + `sign_update --verify` against uploaded asset. | Blocked: the live feed does not yet expose the current candidate; old screenshot evidence of a signature error means no updater claim is permitted before live byte/signature and installed-client proof. |
| VQ-014 | Update UX | Automatic checks respect the preference; manual check is visible and errors are readable. | App behavior run with controlled feed. | Partial: local preference copy now makes preparing, active checking, update-ready, up-to-date, and retry-safe failure states explicit while retaining Sparkle's native dialog. Controlled-feed behavior is still open. |
| VQ-015 | Release automation | Packaging, feed generation, validation, upload, tag, and notes cannot rebuild the DMG after it is signed for the appcast. | Pipeline success and intentional-mismatch failure check. | In progress: exact-byte pipeline proof passes; default shipment now requires Developer ID, stapling, and Gatekeeper acceptance while the free fallback is an explicit override. Intentional mismatch check remains. |

## P1: product, metrics, and trust

| ID | Area | Outcome | Evidence required | Status |
| --- | --- | --- | --- | --- |
| VQ-016 | Anonymous install metric | One installation receives one durable anonymous ID and retry-safe install event. | Fresh install event and idempotency test. | Blocked: source has a durable anonymous ID and event IDs, but production ingestion/views are older than the local contract. Do not create synthetic production rows until both change together. |
| VQ-017 | Optional email | Email is opt-in, validated, removable locally and remotely, and never required for use. | API integration test plus dashboard row inspection. | Partial: the product copy makes the no-account path, aggregate-adoption purpose, validation state, and local removal clear. The app now removes the email from the Mac immediately even while offline, retains only a retry marker for remote-contact deletion, and retries quietly at the next launch. Success and offline-queue regressions pass locally. End-to-end production persistence/removal remains blocked on the reconciled production contract. |
| VQ-018 | Event semantics | Installations, active use, downloads, migrations, and contacts are distinct metrics with no fake person-level deduplication. | Schema/API/dashboard contract check. | Blocked: migration `0004_metric_semantics.sql` and local API encode the correct model, while the live API still returns pre-`0004` fields. |
| VQ-019 | Download attribution | Website CTA counts a real GET redirect once, while previews and HEAD checks do not inflate acquisition. | Endpoint tests and production header check. | Partial: endpoint tests and a live redirect check were observed, but the next website deployment must be verified against the matching production schema before acquisition metrics are declared ready. |
| VQ-020 | Dashboard | Labels state whether a number is installations, events, opted-in contacts, or clicks. | Screenshot and API-to-dashboard comparison. | Partial: dashboard labels are exact and it now rejects stale API responses visibly. Production browser/API comparison is open. |
| VQ-021 | Failure telemetry | Network errors and optional telemetry failures cannot block reading or onboarding. | Offline/failure-path test. | Partial: metrics has a persistent outbox and unit coverage, but a real offline-to-retry app pass remains. |
| VQ-022 | Privacy | Product copy, README, privacy policy, and actual collection behavior agree exactly. | Line-by-line source-to-policy audit. | Partial: current local README/Privacy wording matches the verified local app boundary; exact deployed website and production service must be rechecked after reconciliation. |
| VQ-023 | Accessibility | Keyboard operation, focus order, labels, contrast, Dynamic Type-size resilience, and VoiceOver names are checked in major flows. | Accessibility Inspector/manual checklist. | Open |
| VQ-024 | Performance | First launch, backend readiness, and normal selected-text start are measured on the release machine, with no runaway test/app process fan-out. | Timing receipt and process-count observation. | Partial: mixed passage benchmark measured 458 ms first audio and 2.7x real-time generation; medium passages measured 2.8–2.9x. One serial test host ran cleanly. End-to-end hotkey latency and final DMG process receipt remain. |
| VQ-025 | Crash recovery | Restart after forced backend/process interruption leaves the app usable rather than stuck. | Controlled restart test. | Open |
| VQ-026 | Data safety | Reset, deletion, failed export, and failed ingestion do not destroy existing user content or settings. | Regression tests. | Partial: history and export failure tests avoid false success and the migration code does not delete the legacy app; reset/delete/retry manual cases are open. |

## P1: public story and GTM readiness

| ID | Area | Outcome | Evidence required | Status |
| --- | --- | --- | --- | --- |
| VQ-027 | Product positioning | Every primary surface says plainly: Voqora reads the text you select on your Mac, on-device. | Content audit. | Partial: local README/site copy is plain product-first; live GitHub/site/release surfaces still need crawl evidence. |
| VQ-028 | README | Hero uses the real app, first action is clear, install path is accurate, and the page links to docs and releases. | Rendered GitHub-page check. | Partial: source uses the real hero, GitHub is primary, and the separate download CTA is explicit; public render awaits the release gate. |
| VQ-029 | Website project card | Uses the real hero, names Voqora first, and links to GitHub plus the download CTA. | Production browser check. | Partial: local source/build use the real hero and correct CTA split; production render is open. |
| VQ-030 | Voqora technical blog | Is a deep Voqora product/engineering article in the site’s normal voice, not a rebrand explanation. | Editorial review and production render. | Partial: local 3,600+ word article is Voqora-first, uses the real hero and architecture diagrams, and site tests/build pass. Production editorial/render review is open. |
| VQ-031 | SuperSay continuity | Dedicated legacy page preserves the old article and has one calm handoff to Voqora without polluting Voqora’s story. | Route/link crawl. | Partial: local legacy post is distinct and concise; route crawl/public render are open. |
| VQ-032 | Link integrity | `/supersay`, old blog links, project links, repository, release, privacy, and docs have no dead ends. | Automated link crawl plus manual spot-check. | Open |
| VQ-033 | Launch assets | Screenshot, post copy, demo script, slide deck, and release notes all describe the same shipped capability. | Asset inventory and editorial approval. | Open |
| VQ-034 | CTA funnel | GitHub is the primary trust destination; explicit download CTA reaches the release asset and records only intentional clicks. | Browser journey and metric receipt. | Open |
| VQ-035 | Support path | README and in-app help make permissions, install friction, updates, privacy, and issue reporting easy to find. | User-journey review. | Open |

## P2: release operations and future-proofing

| ID | Area | Outcome | Evidence required | Status |
| --- | --- | --- | --- | --- |
| VQ-036 | Version discipline | Source, bundle, backend, changelog, Git tag, DMG, appcast, and GitHub release agree. | Release receipt script. | Partial: release docs and `ship.sh` now prevent Pages from publishing an appcast before its immutable DMG asset exists. No version has been selected or released for this candidate. |
| VQ-037 | CI | Backend, Swift, web, dashboard, package validation, and Pages workflows are green for the candidate commit. | CI URLs/statuses. | Open |
| VQ-038 | Rollback | Broken feed entries can be withdrawn without mutating a released binary; process is documented. | Controlled feed rollback test. | In progress |
| VQ-039 | Private successor | v1.1 multilingual work stays isolated from public main until a later intentional release. | Branch/remotes audit. | Done locally: `develop` contains the private multilingual candidate; `main` does not. Public remote state still needs final release-time audit. |
| VQ-040 | Legacy product | SuperSay remains frozen, clearly points to Voqora, and never receives v1.1/private work. | Repository/tag/page audit. | Partial: successor behavior/copy is separated in local Voqora source. The separate legacy repository, public banner, release page, and archive decision are intentionally not being changed during this no-publish pass. |
| VQ-041 | Support triage | Known install/update symptoms have precise diagnostics and user-facing recovery steps. | Troubleshooting documentation review. | Open |
| VQ-042 | Release decision | A final checklist records passed, failed, blocked, and waived items before any public action. | Signed-off release report. | Open |

### Evidence-backed items discovered during the current pass

| ID | Area | Outcome | Evidence required | Status |
| --- | --- | --- | --- | --- |
| VQ-043 | Process ownership | Development, test, and app shutdown code never kills another Voqora candidate merely because it shares a process name. | Exact-path process inspection plus Swift regression/build. | Partial: source now scopes cleanup to the exact bundle/app-support executable, and tests/build pass. A multi-copy manual candidate check remains. |
| VQ-044 | First-launch cleanup | An interrupted backend extraction cannot accumulate stale temporary directories or delete a fresh concurrent extraction. | Deterministic old/new directory test. | Done locally: cleanup deletes only an hour-old Voqora staging directory; v1 main passed 73 Swift tests and the private-v1.1 successor passed 177 Swift / 389 backend tests after its local merge. |
| VQ-045 | Audiobook input contract | The UI offers only the document types the public backend accepts and does not silently discard an invalid or unreadable choice. | File-import and drop-path manual proof. | Partial: app accepts PDF, TXT, DOCX, and Markdown, stages each in a unique temporary folder, sends its correct MIME type and metric label, and leaves a readable error state on upload failure. Interactive Finder/import proof remains. |
| VQ-046 | Claim discipline | First-use, project-card, README, blog, and privacy copy distinguish normal local speech from optional external PDF cleanup, telemetry, and unverified updater delivery. | Source-to-surface audit. | Partial: misleading “no cloud/no upload” onboarding copy and premature updater-validation claim were corrected locally. Public render audit remains. |
| VQ-047 | Metrics deployment contract | Website API, Supabase views, and dashboard must declare a compatible metric version before showing adoption figures. | Deliberately stale-payload test plus live post-deploy receipt. | Partial: the website now declares `2026-07-30.1`; the dashboard rejects a missing or different version and incomplete fields rather than silently showing zeros. Production migration/deploy is deliberately deferred until final validation. |
| VQ-048 | Global document intake | Dropping a supported document anywhere in the app uses the same safe staging, error copy, estimate flow, MIME type, and metrics contract as the Library importer. | Shared-contract regression test plus manual Finder drop. | Partial: the global drop path now accepts only PDF, TXT, DOCX, and Markdown, stages the source before switching views, and gives a readable error instead of silently ignoring it. Interactive Finder proof remains. |
| VQ-049 | First-run brand and voice | A first launch always shows the actual Voqora mark and Bella, rather than a generic symbol or stale multilingual profile. | Isolated-default test plus fresh Release visual. | Partial: migration v7 resets prior stale v6 defaults to `af_bella`, preserves later user choices, and the current local Release candidate visibly showed the bundled app icon. Clean-DMG proof remains. |
| VQ-050 | Process-safe exit and reset | Menu-bar quit, app termination, and data reset stop only the backend started by this exact app, and never kill a parallel copy by name. | AppDelegate regression test, source audit, and multi-copy/manual candidate proof. | Partial: the app now owns a single shutdown callback, the menu exit stops its child synchronously, and `make nuke` refuses to proceed while a candidate/backend runs. Multi-copy proof remains. |
| VQ-051 | Stop semantics | Global Stop, menu-bar Stop, and in-window Stop cancel an active speech stream before stopping output, so a late network chunk cannot restart audio. | Cancellation-aware unit coverage and Accessibility/manual shortcut pass. | Partial: all stop affordances now enter `DashboardViewModel.stopPlayback()`, which advances the request generation, cancels the task, preserves audiobook resume bookkeeping, then stops output. A real global-hotkey proof remains. |
| VQ-052 | Honest speaking state | The dashboard says “Speaking” only after actual audio is buffered, not while an engine request is merely pending. | Audio-service state regression test and slow-response manual observation. | Partial: `prepareForStream()` now keeps the state in “Thinking” until `startPlayback()` receives a buffer, and the headless regression test keeps Core Audio unconfigured. A throttled-backend visual pass remains. |

## Full manual product-validation matrix

This is the executable product QA plan, not a second wish list. Run it against
one immutable candidate copied out of its DMG. Do not mark a row complete from
source inspection, a unit test, or a previous app build. Every row needs a
dated result, candidate SHA/version, tester, and a link to the relevant
screenshot, file, log excerpt, response, or public URL.

### Run rules

1. Use a clean macOS user profile or a documented fresh Voqora profile. Do
   not erase an existing user’s data just to make a test easier.
2. Use only the candidate being evaluated. Record the bundle path, marketing
   version, build number, DMG checksum, and backend archive checksum first.
3. Keep Accessibility changes opt-in and user-authorised. A tester must state
   whether it was granted, denied, revoked, or not exercised.
4. Run one Xcode test host at a time. Manual app runs must quit their exact
   candidate and verify that its owned backend also exits before the next run.
5. Test both a happy path and the promised recovery path. “Works once” is not
   a release result when the product claims to recover from interruption.
6. A network, database, feed, or analytics result is valid only if its request
   and read model are from the same deployed metric contract.
7. Never create fabricated launch, email, migration, or download rows to make
   the dashboard look healthy. Test activity is labelled as test activity.

### First launch, permissions, and core reading

| ID | Journey | Pass condition | Evidence to retain | Current state |
| --- | --- | --- | --- | --- |
| QA-001 | Mount the DMG and inspect its first Finder window. | Voqora icon, Applications alias, drag direction, contrast, and labels are readable at normal Finder scale. | Finder screenshot and mounted-volume listing. | Not run on a final candidate. |
| QA-002 | Copy Voqora to Applications and open it for the first time. | Welcome is the front-most surface; no blank player, hidden sheet, or backend curtain blocks it. | Screen recording or two screenshots, frontend log. | Local Release-only proof exists; DMG proof open. |
| QA-003 | Start while the local engine is still cold. | Onboarding remains usable while the engine warms; status is explanatory and bounded. | Timestamped screen recording and backend log. | Not run on candidate. |
| QA-004 | Deny or leave Accessibility ungranted. | The guide explains the requirement and Next stays blocked with a useful reason, without an app hang. | Screenshot and accessibility-state note. | Not run interactively. |
| QA-005 | Grant Accessibility from System Settings, return to Voqora. | The guide observes the change and allows progress without relaunch. | Screen recording plus permissions-state screenshot. | Not run interactively. |
| QA-006 | Revoke Accessibility after onboarding has completed. | Voqora brings the user back to recoverable setup rather than leaving a dead shortcut. | Before/after screenshots. | Unit-covered; manual proof open. |
| QA-007 | Decline notifications. | Setup can continue and later reading still works. | Onboarding screenshot. | Not run interactively. |
| QA-008 | Leave email blank. | Setup completes, no account is required, and no error implies that email is mandatory. | Completion screenshot and local preferences check. | Not run interactively. |
| QA-009 | Enter an invalid optional email. | Save is disabled or gives a precise validation message; it does not send a request. | Screenshot and local request log. | UI/unit covered; manual proof open. |
| QA-010 | Enter a valid optional email on the reconciled backend. | Save succeeds once, UI confirms it, and product use remains unchanged. | Request/response receipt and read-model check. | Blocked on production contract. |
| QA-011 | Trigger Speak with no selected text. | The user sees a concise recovery message, no empty audio is exported, and the app stays ready. | Screenshot and log excerpt. | Unit-covered; manual proof open. |
| QA-012 | Select a short paragraph in Safari. | The default hotkey starts local speech and displays Bella only after audio has buffered. | Screen recording and backend request log. | Blocked on user-authorised Accessibility pass. |
| QA-013 | Select text in a native app such as Notes. | The same shortcut and recovery copy work outside Safari. | Screen recording. | Not run. |
| QA-014 | Select text in a PDF reader and in an IDE. | Both are handled or each failure tells the user exactly what to retry. | Two recordings/screenshots. | Not run. |
| QA-015 | Press Speak twice quickly with different selections. | The newer selection wins; the earlier stream cannot resume later. | Screen recording and request ordering. | Regression-covered; manual proof open. |
| QA-016 | Wait for a slow first audio buffer. | The state is Thinking, not Speaking 0:00, until a real buffer arrives. | Throttled-response recording. | Unit-covered; manual proof open. |
| QA-017 | Play, pause, resume, and stop mid-clip. | Time, state, and controls remain truthful; Stop ends the request and output. | Screen recording and process/audio observation. | Unit-covered; manual proof open. |
| QA-018 | Stop just before a delayed response arrives. | No late chunk restarts playback or creates a stale error toast. | Delayed-network recording. | Deterministic regression-covered; manual proof open. |
| QA-019 | Use the menu-bar Speak and Stop actions. | They match the global shortcut’s state and do not create a second player. | Screen recording. | Not run. |
| QA-020 | Change voice, speed, and volume, then speak again. | User choices apply to new speech, are visible, and survive app restart. | Before/after audio-state recording and preferences screenshot. | Unit/source coverage; manual proof open. |
| QA-021 | Restart before and after the local model is ready. | No duplicate backend is left, startup recovers, and the visible state is not frozen. | Two launch logs and process listing. | Local owned-backend proof; candidate proof open. |
| QA-022 | Quit from the app and from the menu bar. | The exact candidate and its owned backend exit; another installed copy is not touched. | Exact-path process listing before/after. | Local single-copy proof; multi-copy proof open. |

### History, export, audiobooks, and data integrity

| ID | Journey | Pass condition | Evidence to retain | Current state |
| --- | --- | --- | --- | --- |
| QA-023 | Complete a selected-text clip and inspect History. | The entry is readable, ordered correctly, and contains no unintended text leakage in telemetry/logs. | History screenshot and redacted log review. | Unit/source coverage; manual proof open. |
| QA-024 | Export the latest clip to a chosen Finder location. | A valid playable WAV is created once with a collision-safe name and a user-facing success state. | Exported file, `afinfo` output, screenshot. | Header path verified locally; Finder proof open. |
| QA-025 | Export with no clip available. | No file is created and the message explains what to do first. | Screenshot and directory listing. | Unit-covered; manual proof open. |
| QA-026 | Export twice with the same destination/name. | Existing audio is never overwritten silently. | Both files and names. | Unit-covered; manual proof open. |
| QA-027 | Add a normal text PDF. | Estimate, explicit start, progress, ready state, playback, and resume point all work. | Input fixture, recording, resulting local book. | Not run. |
| QA-028 | Add a TXT file. | It follows the same estimate and progress flow as PDF. | Input fixture and screenshot. | Not run. |
| QA-029 | Add a DOCX file. | It follows the same estimate and progress flow as PDF. | Input fixture and screenshot. | Not run. |
| QA-030 | Add a Markdown file. | It follows the same estimate and progress flow as PDF. | Input fixture and screenshot. | Not run. |
| QA-031 | Drag each supported type into the window outside Library. | The shared intake path stages it safely, routes to Library, and does not silently discard it. | Four short recordings. | Source covered; Finder proof open. |
| QA-032 | Choose an unsupported or malformed file. | It is rejected before processing with a clear reason; existing books remain intact. | Screenshot and library before/after. | Partial source coverage; manual proof open. |
| QA-033 | Start the same document twice. | Duplicate processing is prevented or made visibly intentional, never producing duplicate silent work. | Library state and backend log. | Backend-covered; manual proof open. |
| QA-034 | Cancel during extraction, cleanup, and narration. | Work stops, sibling cleanup is cancelled, and the user can retry without corrupt state. | Three logs/screenshots. | Not run. |
| QA-035 | Kill/restart the backend during document work. | The app clearly reports/reconnects or leaves a retryable state rather than a permanently spinning card. | Process action, recording, logs. | Not run. |
| QA-036 | Resume an audiobook after pausing, then after app relaunch. | Resume point is sensible and does not skip to another book. | Timestamped playback screenshots. | Unit/source coverage; manual proof open. |
| QA-037 | Switch from audiobook playback to selected-text speech. | Book state is saved correctly and selected-text speech becomes the only active output. | Recording and resume check. | Source/regression coverage; manual proof open. |
| QA-038 | Switch between two audiobooks while one is loading. | Previous state tears down normally; delayed audio cannot revive the deleted/switched book. | Delayed-load recording. | Deterministic regression-covered; manual proof open. |
| QA-039 | Delete a ready audiobook and a loading audiobook. | Correct item disappears, active playback stops if applicable, and unrelated books remain. | Library before/after plus logs. | Source coverage; manual proof open. |
| QA-040 | Use Gemini cleanup only after explicit choice and a supplied key. | Local default remains local; no cleanup request happens without the user’s explicit action. | Network capture/redacted request evidence. | Backend-covered; manual proof open. |
| QA-041 | Use a scanned/poor PDF without a key. | Voqora explains the available local/optional-cleanup path without pretending narration succeeded. | Screenshot. | Not run. |
| QA-042 | Try an invalid Gemini key. | Verification failure is actionable, preserves the old verified key state, and does not leak the key in UI/logs. | Screenshot and redacted logs. | Not run. |
| QA-043 | Trigger a failed local file write, full disk, or unavailable export location. | Existing history/books/settings survive and the user receives a recovery message. | Controlled fixture and before/after listing. | Unit coverage partial; manual proof open. |

### Settings, migration, privacy, and analytics

| ID | Journey | Pass condition | Evidence to retain | Current state |
| --- | --- | --- | --- | --- |
| QA-044 | Re-run onboarding from Preferences. | It returns to the first-use guide without erasing voice, history, books, or email. | Preferences and data before/after. | Unit-covered; manual proof open. |
| QA-045 | Toggle anonymous analytics off. | New events stop, queued events are cleared, and core reading remains fully usable offline. | Local outbox before/after and reading recording. | Unit/source coverage; manual proof open. |
| QA-046 | Lose network while analytics is enabled, then restore it. | Reading/onboarding do not block; the same event ID retries once without multiplication. | Network trace plus API/read-model receipt. | Blocked on reconciled production contract. |
| QA-047 | Save then remove optional email while online. | Email disappears locally and the remote contact removal is confirmed, while anonymous event history stays anonymous. | API request/response and database/read-model receipt. | Blocked on reconciled production contract. |
| QA-048 | Attempt optional-email removal while offline. | The app makes the local privacy state clear and does not falsely claim remote deletion succeeded. | Screenshot and retained retry/diagnostic evidence. | Local behaviour and deterministic regressions covered; visual proof open. |
| QA-049 | Inspect analytics payload for selected text, document, export, and migration. | It contains only approved count/category/hash fields, never text, filenames, audio, API keys, or email except the explicit identity endpoint. | Captured, redacted payloads. | Source whitelist exists; end-to-end proof open. |
| QA-050 | Compare install, event, contact, and download counts. | Dashboard labels match the authoritative API contract and do not call installations “people.” | API JSON, dashboard screenshot, metric definitions. | Blocked on production reconciliation. |
| QA-051 | Launch without email and inspect reporting. | Anonymous installation/activity is represented only under its exact installation/event metric. | One real test installation receipt. | Blocked on production reconciliation. |
| QA-052 | Enter the same email on a second test Mac. | The dashboard deduplicates only the opted-in contact, not anonymous installations. | Two installation receipts and contact read model. | Blocked on production reconciliation. |
| QA-053 | Install both legacy SuperSay and Voqora test copies. | Voqora detects the legacy app locally, offers a choice, and never auto-deletes or auto-imports. | Finder layout and alert recording. | Unit-covered; manual proof open. |
| QA-054 | Import legacy-compatible preferences. | Only documented compatible preferences move; documents, audio, history, credentials, email, shortcuts, and telemetry choice do not. | Preferences diff and fixture log. | Unit/source coverage; manual proof open. |
| QA-055 | Decline migration and reveal legacy app in Finder. | Nothing is modified, Finder opens the intended legacy copy, and Voqora remains usable. | Recording. | Not run. |
| QA-056 | Record legacy migration telemetry. | Events represent real detection/completion/removal actions and cannot inflate total people. | Event payload/read-model proof. | Blocked on production reconciliation. |

### Installer, updater, public story, and GTM journey

| ID | Journey | Pass condition | Evidence to retain | Current state |
| --- | --- | --- | --- | --- |
| QA-057 | Download the exact DMG from the public release URL. | It is the immutable candidate byte stream whose checksum/version matches the release note and appcast. | URL, checksum, version receipt. | Not run: no candidate release. |
| QA-058 | Open the downloaded DMG with normal Gatekeeper policy. | Behaviour matches documentation exactly; no claim of notarization exists without actual notarization evidence. | Gatekeeper result screenshot. | Blocked: current build has no Developer ID team identity. |
| QA-059 | Follow the documented official-download recovery route. | `Open Anyway` and, only if necessary, the one-app `xattr` command work on the copied Applications app. | Clean-profile recording and `spctl`/launch result. | Blocked on candidate/manual proof. |
| QA-060 | Start Voqora directly from the disk image. | It tells the user to move the app to Applications and does not pretend updates are reliable from a mounted image. | Alert screenshot. | Not run. |
| QA-061 | Check for updates manually with a no-update feed. | Preferences visibly reaches an up-to-date state; the button never looks dead. | Recording and feed log. | Source/test coverage; controlled-feed proof open. |
| QA-062 | Check for updates with an offline or malformed feed. | The current app remains usable and gives retry-safe, honest feedback. | Recording and log. | Source/test coverage; controlled-feed proof open. |
| QA-063 | Install a real older public Voqora version and update to the exact newer candidate. | Sparkle verifies the exact archive, shows the native dialog, installs, relaunches, and preserves expected settings. | Old/new versions, appcast URL/signature, video. | Blocked until real signed candidate/feed. |
| QA-064 | Toggle automatic update checks off then on. | Sparkle preference survives restart and manual checking remains understandable. | Preferences before/after restart. | Unit/source coverage; manual proof open. |
| QA-065 | Load the GitHub repository page on desktop and mobile. | Real app hero appears, first action is clear, docs/license are linked, and the project page is the primary trust destination. | Two rendered screenshots and link crawl. | Local source only. |
| QA-066 | Use the direct download CTA. | It records an intentional GET click once then redirects to the exact release asset; HEAD, preview, and bots do not inflate it. | Browser network trace and metric receipt. | Endpoint/local proof; production proof blocked. |
| QA-067 | Read the Voqora blog from the project card. | It is Voqora-first, technically substantive, and contains no confusing rebrand monologue. | Rendered page/editorial sign-off. | Local source only. |
| QA-068 | Follow old SuperSay project/blog URLs. | Each reaches one concise legacy bridge or the archived deep dive, then gives a clear Voqora destination without loops or dead ends. | Route/canonical/link crawl. | Not run. |
| QA-069 | Compare README, project card, blog, DMG, release notes, and in-app copy. | Product name, hero, shortcuts, supported document formats, benchmarks, privacy, and install/update caveats agree. | Content diff checklist. | Open. |
| QA-070 | Review the LinkedIn, X, Reddit, Hacker News, and demo video package. | Every claim is traceable to the final candidate; no private v1.1 feature, invented user count, or unverified speed claim appears. | Approved source pack and citations. | Open: rebuild only after release facts lock. |
| QA-071 | Review the public landscape deck. | Uses the real product hero, visual hierarchy matching the app, direct language, credible benchmarks, and one scoped technical slide. | Rendered slide PDF and speaker-note source list. | Open: rebuild from scratch after candidate lock. |
| QA-072 | Run a 15-minute external-user smoke test. | A person unfamiliar with the code can install, grant permission, speak selected text, find help, and describe the value correctly. | Notes, recording consent, issues found. | Not run. |

### Release evidence packet required after the matrix

The final `Go` review must contain all of the following, in this order:

1. Candidate commit, clean working tree, version/build, branch/remotes, and
   exact DMG checksum.
2. `make verify` and one serial `make test-swift` receipt from that commit.
3. One Release-bundle cold-start/speech/WAV proof and one mounted-DMG proof.
4. The Accessibility-authorised selected-text recording and the denied/revoked
   permission recovery recordings.
5. One document fixture for each supported format plus cancellation/retry and
   resume proof.
6. Explicit test results for optional email, telemetry disabled, offline retry,
   and metrics semantics after the same production schema/API/dashboard deploy.
7. Live GitHub, website, blog, legacy bridge, privacy, support, and CTA crawl.
8. Live appcast enclosure/signature validation plus a real older-to-newer
   Sparkle update. A source-level update UI test does not replace this.
9. Final marketing inventory with every benchmark, screenshot, and claim
   linked to its source receipt.
10. A one-page Go/No-Go decision that lists every remaining known limitation,
    owner, and explicit waiver. No unstated risk is silently accepted.

## Current stop-the-line findings

1. The prior `v1.0.2` Sparkle update incident showed why local signing is not
   update proof. The currently inspected live feed is behind the current tag,
   so it cannot validate the candidate or be used to claim an update path.
2. The existing distribution artifact is not yet evidenced as Developer ID
   signed and notarized. Sparkle signing and Apple/Gatekeeper distribution
   signing are separate checks.
3. The product requires a complete live-flow pass, not only unit tests. The
   first-launch blank screen and updater report prove why source-only confidence
   is insufficient.
4. Any metric described publicly as a “user” must be renamed to its exact
   meaning unless it has a real, opted-in identity basis.
5. The inspected production database and live website are not on the same
   metric contract as the local Voqora schema/API/dashboard. This explains the
   conflicting installation counts. The safe correction is one ordered deploy:
   schema migration, website API, dashboard, then a fresh anonymous event and
   read-model receipt. Do not send synthetic events or delete tables to make
   the numbers look tidy.

## Evidence ledger: what is proved now, what is not

This is intentionally a receipt, not a confidence score. “Local” means a
command or interaction in the current checkout. “Public” means an actual
deployed URL or downloadable artifact. A green local result never substitutes
for a public result.

| Surface | Current evidence | What it proves | What it does **not** prove | Gate |
| --- | --- | --- | --- | --- |
| Branch boundary | `main...develop` diff; `develop` is local-only | v1.1 multilingual files are absent from v1 `main` | That a later remote push cannot expose it | Audit remotes before every publish |
| Release app build | `make app` built `build/DerivedData/Build/Products/Release/Voqora.app` | Current Swift source compiles into the named Release bundle | A mounted/downloaded DMG works | Build a final candidate only after version decision |
| Swift tests | `make test-swift`: 73 passed, serial host, no candidate Voqora app/backend process left | Pure services, onboarding state, telemetry shaping, history/export helpers, delayed audiobook-stop invalidation, optional-email removal retry, and test-mode updater isolation compile and pass | Accessibility, Finder, Sparkle, or real user journeys | Manual release matrix |
| Backend tests | `make test-backend`: 184 passed | Local speech and API logic pass headlessly | Packaged app/backend wiring and actual model UX | Exact candidate launch and manual speech pass |
| Private successor tests | After the local `main` merge, `develop` passed 177 Swift tests in one serial host and 389 backend tests headlessly | The private v1.1 multilingual branch retains current v1 reliability work; subscription lifecycle tests make no real loopback request | That private code is safe to publish or that multilingual UX works in a distributed candidate | Keep local-only and run dedicated v1.1 manual QA next week |
| Bundled speech contract | Exact Release bundle health reached `ready/loaded`; `/speak` returned a valid PCM WAV; blank text was rejected | App bundle can host its local server and generate valid audio | Global shortcut and full player UI under Accessibility | User-authorised manual pass |
| Default voice | Isolated migration test plus current Release UI showed `af_bella` | Current candidate defaults to Bella | Fresh downloaded DMG on a clean profile | DMG first-run receipt |
| Test/process safety | Serial test host, scoped process targeting, no residual Voqora processes observed | Tests no longer fan out into multiple Voqora app hosts | Long-running performance under unrelated system load | Candidate soak check |
| Metrics schema | Local `0004_metric_semantics.sql`, API tests, dashboard contract test | Intended measurements are disjoint and clearly named | The current production API/read models use that contract | Ordered production reconciliation |
| Live metrics | Live endpoint returns old field names; remote table counts conflict with it | Production mismatch is real and visible | Any current adoption number is reliable | Do not publicise a count yet |
| Website | Local site test suite passed and production build succeeded | Local article/card/routes compile | The deployed site renders those sources | Deploy then crawl routes/CTAs |
| Dashboard | Local tests/build passed; stale payload is now rejected rather than shown as zero | A mismatch becomes visible to the operator | Live endpoint will become compatible automatically | Deploy after matching website/schema |
| Release tooling | Shell syntax and local validation scripts pass; asset-before-feed ordering is encoded | Future ship order avoids feed-to-404 race | Current public appcast/archive signature is valid | Final dry run plus live fetch |
| Updater | Source has visible automatic/manual controls; live feed is behind candidate | UI can express state and feed config exists | A user can update successfully | Installed-old-to-newer test |
| Gatekeeper | Current distribution is documented as a free-install fallback route | Support docs do not misrepresent ad-hoc distribution | Gatekeeper acceptance or notarization | Developer ID/notarization decision and real DMG test |
| Marketing collateral | Existing decks are explicitly rejected, not being reused | No inaccurate new collateral is being called final | Posts/slides/video are ready | Rebuild after release facts lock |

## Ordered release proof, once development is closed

1. Freeze a clean `main` commit and choose the next semantic version. Do not
   reuse an existing version or replace an older DMG in place.
2. Run `make verify`, `make test-swift`, and a targeted manual app matrix from
   the exact Release bundle. Capture command output and screenshots, not just
   a verbal “works.”
3. Build one DMG from that same commit. Mount it, inspect icon/window/text,
   copy it to Applications, and test the documented open/quarantine recovery
   route on a clean profile.
4. Resolve the separate distribution-signing decision. Sparkle archive signing
   is not Apple Developer ID signing or notarization.
5. Apply the reviewed Voqora metric migration, deploy the matching website API
   and dashboard together, and verify one anonymous launch, one optional
   identity save/remove path, one intentional download CTA, and the dashboard
   read model. Do not infer people from installations.
6. Generate the appcast from the exact signed DMG. Publish the immutable
   GitHub asset before the Pages branch exposes its enclosure. Re-fetch both
   externally and verify the signature against those uploaded bytes.
7. Install an older public Voqora build and complete a real update to the
   newer build. This is the only proof that the update UX is working.
8. Crawl GitHub README, project card, Voqora blog, SuperSay bridge, privacy,
   support, and download CTA. Confirm every public claim matches the final
   artifact.
9. Rebuild the public v1 and private v1.1 launch packs only from this signed
   evidence. The public pack must not mention or preview multilingual work.
10. Record every passed, failed, blocked, and waived item in VQ-042, then make
    one deliberate Go/No-Go decision. Only after Go is publication allowed.

## Definition of done for this board

Before release, produce one dated receipt containing: candidate commit and
version; all automated results; installed-DMG result; onboarding and core
reading result; updater result; production website/download/analytics result;
CI/Pages status; known external limitations; and a clear Go/No-Go decision.
