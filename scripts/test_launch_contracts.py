#!/usr/bin/env python3
"""Static release guards for the four launch-critical fixes in 1.2.4.

Exercised by `make test-release-scripts`, alongside test_ship_modes.sh and
test_backend_archive_safety.py. Every check here corresponds to a bug that
shipped to users during the 1.1.3 -> 1.2.4 cycle and was caught only by manual
click-through testing:

1. Sparkle crashed on update because Hardened Runtime + Library Validation is
   incompatible with the ad-hoc-signed frameworks Voqora ships. Fixed by
   RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION in the Xcode project. This file
   asserts that invariant for every configuration that enables Hardened
   Runtime, so it can never be lost in an Xcode settings round-trip.
2. The backend integrity check failed on healthy installs. Its behaviour is
   covered functionally by VoqoraTests/LaunchManagerRuntimeIntegrityTests.swift;
   this file only pins the `.bundle_version` marker exclusion textually, because
   that line is the one a "tidy up the validator" refactor is most likely to
   drop.
3. The backend could never receive the app-owned listener socket, because
   Foundation.Process launches via posix_spawn and closes every descriptor
   except stdin/stdout/stderr. Fixed by handing it over as `standardInput`
   (fd 0). Behaviourally proven in
   VoqoraTests/BackendListenerHandoffIntegrationTests.swift; pinned textually
   here so a revert to the FD-number environment variable is caught without a
   macOS test host.
4. The audiobook player stayed on screen after a tab switch, because
   NavigationSplitView ties its detail column's navigation identity to the
   structural position of the view passed to `detail:`. Fixed with
   `.id(vm.selectedTab)` plus the path reset in AudiobookLibraryView. This
   check is the ONLY automated coverage of that fix: reproducing the bug
   behaviourally needs a real app window driven through XCUITest with a seeded
   audiobook library, because SwiftUI keeps a torn-down destination's body,
   lifecycle callbacks and state alive in an offscreen NSHostingView — every
   in-process signal reports "still mounted" for the fixed and broken code
   alike. Until that UI target exists, do not delete this check.

These are deliberately cheap textual invariants, not a substitute for the Swift
suites named above — they are the layer that still runs when nobody is willing
to spin up a macOS test host, which is exactly the situation in which the
original reverts would slip through.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PBXPROJ = REPO / "frontend/Voqora/Voqora.xcodeproj/project.pbxproj"
LAUNCH_MANAGER = REPO / "frontend/Voqora/Voqora/Services/LaunchManager.swift"
BACKEND_SERVICE = REPO / "frontend/Voqora/Voqora/Services/BackendService.swift"
BACKEND_CONNECTION = REPO / "frontend/Voqora/Voqora/Services/BackendConnection.swift"
VOQORA_WINDOW = REPO / "frontend/Voqora/Voqora/Views/VoqoraWindow.swift"
BACKEND_MAIN = REPO / "backend/app/main.py"

FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        FAILURES.append(message)


def read(path: Path) -> str:
    if not path.is_file():
        FAILURES.append(f"missing source file: {path.relative_to(REPO)}")
        return ""
    return path.read_text(encoding="utf-8")


# --- Bug 1: Hardened Runtime must never re-enable Library Validation ---------


def test_hardened_runtime_disables_library_validation() -> None:
    """Sparkle's updater dlopens Voqora's own ad-hoc-signed frameworks. With
    Hardened Runtime on and Library Validation left enabled, that combination
    hard-crashes the updater the moment a user checks for updates."""
    source = read(PBXPROJ)
    if not source:
        return

    # Each build configuration is a `{ ... }` block in the pbxproj plist. Only
    # the ones that actually turn Hardened Runtime on carry the requirement.
    blocks = re.findall(r"buildSettings = \{(.*?)\n\t\t\t\};", source, re.DOTALL)
    hardened = [
        b for b in blocks if re.search(r"\bENABLE_HARDENED_RUNTIME\s*=\s*YES\s*;", b)
    ]

    check(
        len(hardened) >= 2,
        "expected Hardened Runtime to be enabled for both app build configurations "
        f"(found {len(hardened)})",
    )
    for block in hardened:
        check(
            re.search(
                r"\bRUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION\s*=\s*YES\s*;", block
            )
            is not None,
            "a build configuration enables ENABLE_HARDENED_RUNTIME without "
            "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION = YES; this crashes the "
            "Sparkle updater against ad-hoc-signed frameworks",
        )

    # The exceptions that must stay OFF. Turning any of these on would weaken
    # the runtime well beyond what the Sparkle fix requires.
    for setting in (
        "RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES",
        "RUNTIME_EXCEPTION_ALLOW_JIT",
        "RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY",
        "RUNTIME_EXCEPTION_DEBUGGING_TOOL",
        "RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION",
    ):
        check(
            not re.search(rf"\b{setting}\s*=\s*YES\s*;", source),
            f"{setting} must stay NO — only library validation needed an exception",
        )


# --- Bug 2: the integrity validator's own marker file stays excluded ---------


def test_integrity_validator_excludes_its_own_marker() -> None:
    source = read(LAUNCH_MANAGER)
    if not source:
        return

    check(
        'relative == ".bundle_version"' in source,
        "validateInstalledRuntime must skip the `.bundle_version` fast-path marker it "
        "writes itself, or every launch after the first reports a healthy install as corrupt",
    )
    # The ancestor walk that replaced the old immediate-parent-only computation.
    check(
        "for depth in 1 ..< components.count" in source,
        "validateInstalledRuntime must register EVERY ancestor directory of each manifest "
        "entry, not just each entry's immediate parent — package directories containing "
        "only subdirectories are otherwise reported as unexpected",
    )


# --- Bug 3: the listener descriptor rides in on stdin, never on its number ---


def test_listener_descriptor_is_handed_over_through_standard_input() -> None:
    service = read(BACKEND_SERVICE)
    if not service:
        return

    check(
        'env["VOQORA_IPC_LISTENER_FD"] = "0"' in service,
        "BackendService must tell the backend the listener is on fd 0; any other value "
        "assumes Process preserves arbitrary descriptors across posix_spawn, which it does not",
    )
    check(
        "p.standardInput = FileHandle(fileDescriptor: launchConfiguration.listenerFD"
        in service,
        "BackendService must attach the listener socket as the child's standardInput — "
        "this is the only Foundation-supported way to hand a Process an arbitrary descriptor",
    )
    check(
        "closeOnDealloc: false" in service,
        "the listener FileHandle must not close the app-owned descriptor when it deallocs",
    )

    connection = read(BACKEND_CONNECTION)
    if connection:
        check(
            "FD_CLOEXEC" in connection,
            "BackendConnection is still expected to clear FD_CLOEXEC on the listener",
        )

    main = read(BACKEND_MAIN)
    if main:
        check(
            "uvicorn.run(app, fd=settings.IPC_LISTENER_FD" in main,
            "the backend must serve on the inherited descriptor rather than rebinding a port",
        )


# --- Bug 4: the detail column is re-identified on every tab change -----------


def test_detail_column_is_reidentified_per_tab() -> None:
    source = read(VOQORA_WINDOW)
    if not source:
        return

    check(
        ".id(vm.selectedTab)" in source,
        "VoqoraWindow's NavigationSplitView detail column must carry .id(vm.selectedTab); "
        "without it a pushed audiobook player keeps rendering on every other tab",
    )

    # It has to be on the detail column, not somewhere incidental. The detail
    # closure is the last thing before the split view's own modifiers.
    detail_index = source.find("} detail: {")
    id_index = source.find(".id(vm.selectedTab)")
    check(
        detail_index != -1 and id_index > detail_index,
        ".id(vm.selectedTab) must appear inside the NavigationSplitView `detail:` closure",
    )


def main() -> int:
    for test in (
        test_hardened_runtime_disables_library_validation,
        test_integrity_validator_excludes_its_own_marker,
        test_listener_descriptor_is_handed_over_through_standard_input,
        test_detail_column_is_reidentified_per_tab,
    ):
        before = len(FAILURES)
        test()
        print(f"{'✗' if len(FAILURES) > before else '✓'} {test.__name__}")

    if FAILURES:
        print("\nFAIL: launch-contract guards", file=sys.stderr)
        for failure in FAILURES:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print("\n✅ launch-contract guards passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
