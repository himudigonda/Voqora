#!/usr/bin/env python3
"""Exercise the exact frozen backend archive that will ship in the app.

This deliberately uses macOS's ``unzip`` and the inherited-listener launch
contract used by ``BackendService``.  Importing the source app in a test does
not prove that PyInstaller collected every module, preserved executable modes,
or honoured the authenticated FD hand-off.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time


class FrozenBackendError(RuntimeError):
    """A concise release-gate failure without exposing the IPC secret."""


def request(
    port: int,
    path: str,
    token: str | None,
    method: str = "GET",
    body: bytes | None = None,
    timeout: float = 3,
) -> tuple[int, bytes]:
    headers: dict[str, str] = {}
    if token:
        headers["X-Voqora-IPC-Token"] = token
    if body is not None:
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(len(body))
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def wait_for_authenticated_health(port: int, token: str, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 45
    last_error = "server did not accept a request"
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise FrozenBackendError(f"frozen backend exited during startup ({process.returncode})")
        try:
            status, _ = request(port, "/health", token)
            if status == 200:
                return
            last_error = f"authenticated /health returned HTTP {status}"
        except (OSError, http.client.HTTPException) as error:
            last_error = f"authenticated /health was unavailable ({type(error).__name__})"
        time.sleep(0.25)
    raise FrozenBackendError(last_error)


def stop_process_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=8)
    except ProcessLookupError:
        return
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=8)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--archive",
        type=Path,
        default=Path("frontend/Voqora/Voqora/Resources/VoqoraServer.zip"),
        help="sealed VoqoraServer.zip to exercise",
    )
    arguments = parser.parse_args()
    archive = arguments.archive.resolve()
    if not archive.is_file():
        raise FrozenBackendError(f"backend archive is missing: {archive}")

    with tempfile.TemporaryDirectory(prefix="voqora-frozen-backend-") as temporary:
        root = Path(temporary)
        subprocess.run(["/usr/bin/unzip", "-q", str(archive), "-d", str(root)], check=True)
        executable = root / "VoqoraServer" / "VoqoraServer"
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise FrozenBackendError("frozen archive did not extract an executable VoqoraServer")

        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(socket.SOMAXCONN)
        port = listener.getsockname()[1]
        token = secrets.token_urlsafe(32)
        environment = os.environ | {
            "VOQORA_IPC_LISTENER_FD": str(listener.fileno()),
            "VOQORA_IPC_TOKEN": token,
            "VOQORA_DATA_DIR": str(root / "data"),
        }
        process = subprocess.Popen(
            [str(executable)],
            env=environment,
            pass_fds=(listener.fileno(),),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            wait_for_authenticated_health(port, token, process)
            unauthenticated_status, _ = request(port, "/health", None)
            if unauthenticated_status != 401:
                raise FrozenBackendError(
                    f"unauthenticated /health returned HTTP {unauthenticated_status}, expected 401"
                )

            engine_status, engine_body = request(port, "/engine", token)
            if engine_status != 200 or not isinstance(json.loads(engine_body), dict):
                raise FrozenBackendError(f"authenticated /engine returned HTTP {engine_status}")

            speech = json.dumps({"text": "Release check.", "voice": "af_bella"}).encode()
            wav_status, wav_body = request(port, "/speak", token, "POST", speech, timeout=120)
            if wav_status != 200 or not wav_body.startswith(b"RIFF") or b"WAVE" not in wav_body[:16]:
                raise FrozenBackendError(f"authenticated /speak did not return a WAV response (HTTP {wav_status})")
        finally:
            listener.close()
            stop_process_group(process)
            if process.returncode not in (0, -signal.SIGTERM):
                stderr = process.stderr.read().decode("utf-8", errors="replace")[-2000:]
                if stderr:
                    print(stderr, file=sys.stderr)
                raise FrozenBackendError(f"frozen backend exited unexpectedly ({process.returncode})")

    print("PASS frozen backend: authenticated health, engine, and WAV; unauthenticated health rejected")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FrozenBackendError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"FAIL frozen backend: {error}", file=sys.stderr)
        raise SystemExit(1) from error
