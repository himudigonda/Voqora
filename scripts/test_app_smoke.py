#!/usr/bin/env python3
"""End-to-end launch smoke test for the built Voqora.app.

Run with `make test-smoke` after `make app` (or point it at any built bundle
with `--app`). This is the layer that was missing when 1.2.x shipped: every
existing automated check either exercised pure Swift helpers or the FastAPI app
in-process, so "does the shipped app actually start, extract its backend, and
get a working connection to it" was verified only by a human launching it.

What it proves, end to end, in one real launch:

* The app bundle launches at all and stays up — the shape of the Sparkle /
  Hardened Runtime + Library Validation crash (bug 1), and of any code-signing
  or framework-loading regression, is an immediate exit here.
* LaunchManager verifies or extracts the packaged backend WITHOUT reporting an
  integrity failure (bug 2, where healthy installs were condemned as corrupt).
* BackendService launches the Python backend AND the backend reaches
  `startup.engine_load.ready`, which it can only do once uvicorn has begun
  serving on the listener descriptor the app handed it as stdin (bug 3, where
  the descriptor never arrived and the backend could not serve at all).

By default the app is launched with an isolated HOME, so it never touches the
developer's real audiobooks, history, or settings, and so the run always
exercises the cold first-launch path (extract, validate, install, stamp, launch)
rather than a warm cache. Pass `--use-real-home` to instead validate the exact
machine you are about to ship from; that mode refuses to run while another
Voqora is already up, because two instances would share one Application Support
directory and both try to resume the same in-progress audiobooks.
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_APP = REPO / "build/DerivedData/Build/Products/Release/Voqora.app"

# Each entry: (label, predicate over the accumulated stdout, whether it is required)
BACKEND_READY = "startup.engine_load.ready"
BACKEND_LAUNCHED = '"msg":"Backend launched"'
RUNTIME_OK = (
    '"msg":"Verified backend already extracted"',
    '"msg":"Backend extracted successfully"',
)

FATAL_MARKERS = (
    ("backend integrity/extraction failure", "runtime_extraction_failed"),
    ("backend binary never became executable", '"msg":"Backend binary not ready yet"'),
    ("backend connection setup failure", '"msg":"Backend connection setup failed"'),
    ("backend process launch failure", '"msg":"Backend launch failed"'),
    ("backend process exited early", '"msg":"Backend process exited"'),
)


def _fail(message: str, transcript: str = "") -> int:
    print(f"\nFAIL: {message}", file=sys.stderr)
    if transcript:
        print("\n--- last 120 lines of app output ---", file=sys.stderr)
        for line in transcript.splitlines()[-120:]:
            print(f"  {line}", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--app", type=Path, default=DEFAULT_APP, help="built Voqora.app to launch"
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=300.0,
        help="seconds to wait for a cold first launch (backend extraction can take 1-2 minutes)",
    )
    parser.add_argument(
        "--use-real-home",
        action="store_true",
        help=(
            "launch against the real user home instead of a throwaway one — validates this "
            "exact machine, but uses (and writes to) the developer's own Voqora data"
        ),
    )
    arguments = parser.parse_args()

    app = arguments.app.resolve()
    executable = app / "Contents/MacOS/Voqora"
    if not executable.is_file():
        return _fail(
            f"no built app at {app}. Run `make app` first, or pass --app <path to Voqora.app>."
        )

    if arguments.use_real_home:
        already_running = subprocess.run(
            ["/usr/bin/pgrep", "-f", "Voqora.app/Contents/MacOS/Voqora"],
            capture_output=True,
            text=True,
        )
        if already_running.returncode == 0:
            return _fail(
                "another Voqora is already running. Quit it before a --use-real-home smoke "
                "run: two instances share one Application Support directory and would both "
                "try to resume the same in-progress audiobooks."
            )

    home = (
        Path.home()
        if arguments.use_real_home
        else Path(tempfile.mkdtemp(prefix="voqora-smoke-home-"))
    )
    process: subprocess.Popen[bytes] | None = None
    transcript = ""

    try:
        environment = dict(os.environ)
        if not arguments.use_real_home:
            # Isolate every bit of app state: Application Support, preferences,
            # and the extracted backend all hang off the home directory.
            environment["HOME"] = str(home)
            environment["CFFIXED_USER_HOME"] = str(home)
        process = subprocess.Popen(
            [str(executable)],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

        print(f"▶ launched {executable.name} (pid {process.pid}) with HOME={home}")

        # VoqoraApp reopens stdout/stderr onto this file at init, so it is the
        # app's real console — including the `[BACKEND] …` lines it relays from
        # the Python child's own stdout.
        log_path = (
            home / "Library/Application Support/com.himudigonda.Voqora/frontend.log"
        )

        deadline = time.monotonic() + arguments.timeout
        seen_runtime_ok = False
        seen_backend_launched = False
        seen_backend_ready = False

        consumed = 0
        pending = ""
        while time.monotonic() < deadline:
            time.sleep(0.25)
            if log_path.is_file():
                with log_path.open("r", encoding="utf-8", errors="replace") as handle:
                    handle.seek(consumed)
                    chunk = handle.read()
                    consumed = handle.tell()
                transcript += chunk
                pending += chunk
            elif process.poll() is not None:
                return _fail(
                    f"the app exited (status {process.returncode}) without ever writing "
                    f"{log_path}",
                    transcript,
                )

            if process.poll() is not None:
                return _fail(
                    f"the app exited on its own (status {process.returncode}) before the "
                    "backend was ready",
                    transcript,
                )

            lines = pending.split("\n")
            pending = lines.pop()
            for line in lines:
                for label, marker in FATAL_MARKERS:
                    if marker in line:
                        return _fail(
                            f"{label} — the app reported: {line.strip()}", transcript
                        )

                if not seen_runtime_ok and any(marker in line for marker in RUNTIME_OK):
                    seen_runtime_ok = True
                    print(
                        "  ✓ backend runtime verified/extracted without an integrity failure"
                    )
                if not seen_backend_launched and BACKEND_LAUNCHED in line:
                    seen_backend_launched = True
                    print("  ✓ backend process launched")
                if not seen_backend_ready and BACKEND_READY in line:
                    seen_backend_ready = True
                    print(
                        "  ✓ backend served its own startup through the inherited listener"
                    )

            if seen_runtime_ok and seen_backend_launched and seen_backend_ready:
                break
        else:
            missing = [
                name
                for name, ok in (
                    ("runtime verification", seen_runtime_ok),
                    ("backend launch", seen_backend_launched),
                    ("backend readiness", seen_backend_ready),
                )
                if not ok
            ]
            return _fail(
                f"timed out after {arguments.timeout:.0f}s waiting for: {', '.join(missing)}",
                transcript,
            )

        # A backend that reaches readiness and then dies immediately is still a
        # broken launch, so hold briefly and re-check.
        time.sleep(3)
        if process.poll() is not None:
            return _fail(
                f"the app exited (status {process.returncode}) right after the backend came up",
                transcript,
            )

        print("\n✅ app launch smoke test passed")
        return 0
    finally:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=15)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if not arguments.use_real_home:
            shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
