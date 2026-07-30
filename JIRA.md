# Voqora v1 release-readiness board

**Rule:** this is a release gate, not a wish list. A row may move to `Done`
only with linked source, automated evidence, and where relevant a real packaged
app or public-surface check. `Blocked` means an external decision or account is
required, not that the work has been silently skipped.

**Release state:** no new version, tag, DMG, GitHub release, or campaign is
authorised while this board contains an open P0 or P1 item.

## P0: must be true before a public build

| ID | Area | Outcome | Evidence required | Status |
| --- | --- | --- | --- | --- |
| VQ-001 | First launch | A brand-new install lands in onboarding, never a blank player or hidden sheet. | Fresh-state run plus onboarding unit/UI coverage. | Done: live Release build showed the onboarding overlay first. |
| VQ-002 | Permissions | Accessibility permission is explained, requested at the right time, and recoverable from Settings. | Manual macOS permission-path check. | Open |
| VQ-003 | Core reading | Selected text starts, pauses, resumes, stops, and reports useful failures when no selection exists. | Service tests plus one live selection run. | Open |
| VQ-004 | App startup | Local speech backend has a bounded startup path, visible recovery state, and no indefinite loading screen. | Cold-start timing and failure-path run. | In progress: live cold start reached `loaded: true`; forced-failure recovery remains. |
| VQ-005 | Default voice | A fresh profile starts in Bella and does not inherit an unexpected language/voice. | Fresh-state preference assertion and manual run. | Done: regression test resets unsupported persisted voices to `af_bella`. |
| VQ-006 | Playback state | Double actions and stale error timers cannot overwrite a later correct state. | Deterministic regression tests. | In progress |
| VQ-007 | History/export | Saved history and WAV export either succeed or give an actionable, non-destructive error. | File-system integration test. | Open |
| VQ-008 | Audiobooks | PDF import, validation, progress, cancel, retry, resume, and corrupt-PDF recovery are clear and safe. | Fixture-driven tests and manual import. | Open |
| VQ-009 | Preferences | Voice, speed, volume, shortcuts, appearance, onboarding reset, and email controls are understandable and durable. | Preference persistence test and visual pass. | In progress |
| VQ-010 | Migration | Detecting SuperSay offers an explicit, reversible preference import; it never deletes another app or claims a migration that did not happen. | File-system fixture test and manual smoke test. | Open |
| VQ-011 | DMG install | Mounted DMG contains the intended app, Applications alias, version, icon, and readable install instructions. | Mounted-DMG inspection receipt. | In progress: mounted v1.0.2 has the right bundle ID, version, app, and Applications alias; redesigned candidate artwork still needs a candidate DMG. |
| VQ-012 | Gatekeeper | The documented free-install path works from a clean download. The stricter notarized route is clearly separated. | Clean-machine/manual Gatekeeper evidence. | Blocked: actual v1.0.2 artifact is Gatekeeper-rejected until Developer ID/notarization is available. |
| VQ-013 | Update safety | No installed user is offered an update whose archive byte stream cannot pass Sparkle verification. | Live appcast + `sign_update --verify` against uploaded asset. | In progress |
| VQ-014 | Update UX | Automatic checks respect the preference; manual check is visible and errors are readable. | App behavior run with controlled feed. | Open |
| VQ-015 | Release automation | Packaging, feed generation, validation, upload, tag, and notes cannot rebuild the DMG after it is signed for the appcast. | Pipeline success and intentional-mismatch failure check. | In progress: exact-byte pipeline proof passes; intentional mismatch check remains. |

## P1: product, metrics, and trust

| ID | Area | Outcome | Evidence required | Status |
| --- | --- | --- | --- | --- |
| VQ-016 | Anonymous install metric | One installation receives one durable anonymous ID and retry-safe install event. | Fresh install event and idempotency test. | Open |
| VQ-017 | Optional email | Email is opt-in, validated, removable locally and remotely, and never required for use. | API integration test plus dashboard row inspection. | In progress |
| VQ-018 | Event semantics | Installations, active use, downloads, migrations, and contacts are distinct metrics with no fake person-level deduplication. | Schema/API/dashboard contract check. | Open |
| VQ-019 | Download attribution | Website CTA counts a real GET redirect once, while previews and HEAD checks do not inflate acquisition. | Endpoint tests and production header check. | Done: endpoint tests pass and production HEAD returns a redirect without increasing clicks. |
| VQ-020 | Dashboard | Labels state whether a number is installations, events, opted-in contacts, or clicks. | Screenshot and API-to-dashboard comparison. | Open |
| VQ-021 | Failure telemetry | Network errors and optional telemetry failures cannot block reading or onboarding. | Offline/failure-path test. | Open |
| VQ-022 | Privacy | Product copy, README, privacy policy, and actual collection behavior agree exactly. | Line-by-line source-to-policy audit. | Open |
| VQ-023 | Accessibility | Keyboard operation, focus order, labels, contrast, Dynamic Type-size resilience, and VoiceOver names are checked in major flows. | Accessibility Inspector/manual checklist. | Open |
| VQ-024 | Performance | First launch, backend readiness, and normal selected-text start are measured on the release machine, with no runaway test/app process fan-out. | Timing receipt and process-count observation. | In progress: serial Swift host is verified; backend package no longer bundles the Gemini SDK test suite. |
| VQ-025 | Crash recovery | Restart after forced backend/process interruption leaves the app usable rather than stuck. | Controlled restart test. | Open |
| VQ-026 | Data safety | Reset, deletion, failed export, and failed ingestion do not destroy existing user content or settings. | Regression tests. | Open |

## P1: public story and GTM readiness

| ID | Area | Outcome | Evidence required | Status |
| --- | --- | --- | --- | --- |
| VQ-027 | Product positioning | Every primary surface says plainly: Voqora reads the text you select on your Mac, on-device. | Content audit. | Open |
| VQ-028 | README | Hero uses the real app, first action is clear, install path is accurate, and the page links to docs and releases. | Rendered GitHub-page check. | Open |
| VQ-029 | Website project card | Uses the real hero, names Voqora first, and links to GitHub plus the download CTA. | Production browser check. | Open |
| VQ-030 | Voqora technical blog | Is a deep Voqora product/engineering article in the site’s normal voice, not a rebrand explanation. | Editorial review and production render. | In progress |
| VQ-031 | SuperSay continuity | Dedicated legacy page preserves the old article and has one calm handoff to Voqora without polluting Voqora’s story. | Route/link crawl. | In progress |
| VQ-032 | Link integrity | `/supersay`, old blog links, project links, repository, release, privacy, and docs have no dead ends. | Automated link crawl plus manual spot-check. | Open |
| VQ-033 | Launch assets | Screenshot, post copy, demo script, slide deck, and release notes all describe the same shipped capability. | Asset inventory and editorial approval. | Open |
| VQ-034 | CTA funnel | GitHub is the primary trust destination; explicit download CTA reaches the release asset and records only intentional clicks. | Browser journey and metric receipt. | Open |
| VQ-035 | Support path | README and in-app help make permissions, install friction, updates, privacy, and issue reporting easy to find. | User-journey review. | Open |

## P2: release operations and future-proofing

| ID | Area | Outcome | Evidence required | Status |
| --- | --- | --- | --- | --- |
| VQ-036 | Version discipline | Source, bundle, backend, changelog, Git tag, DMG, appcast, and GitHub release agree. | Release receipt script. | Open |
| VQ-037 | CI | Backend, Swift, web, dashboard, package validation, and Pages workflows are green for the candidate commit. | CI URLs/statuses. | Open |
| VQ-038 | Rollback | Broken feed entries can be withdrawn without mutating a released binary; process is documented. | Controlled feed rollback test. | In progress |
| VQ-039 | Private successor | v1.1 multilingual work stays isolated from public main until a later intentional release. | Branch/remotes audit. | Open |
| VQ-040 | Legacy product | SuperSay remains frozen, clearly points to Voqora, and never receives v1.1/private work. | Repository/tag/page audit. | Open |
| VQ-041 | Support triage | Known install/update symptoms have precise diagnostics and user-facing recovery steps. | Troubleshooting documentation review. | Open |
| VQ-042 | Release decision | A final checklist records passed, failed, blocked, and waived items before any public action. | Signed-off release report. | Open |

## Current stop-the-line findings

1. The published `v1.0.2` Sparkle feed describes bytes that are not the bytes
   attached to the GitHub release. This must be removed from the live feed now;
   it is not a valid auto-update.
2. The existing distribution artifact is not yet evidenced as Developer ID
   signed and notarized. Sparkle signing and Apple/Gatekeeper distribution
   signing are separate checks.
3. The product requires a complete live-flow pass, not only unit tests. The
   first-launch blank screen and updater report prove why source-only confidence
   is insufficient.
4. Any metric described publicly as a “user” must be renamed to its exact
   meaning unless it has a real, opted-in identity basis.

## Definition of done for this board

Before release, produce one dated receipt containing: candidate commit and
version; all automated results; installed-DMG result; onboarding and core
reading result; updater result; production website/download/analytics result;
CI/Pages status; known external limitations; and a clear Go/No-Go decision.
