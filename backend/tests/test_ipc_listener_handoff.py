"""End-to-end smoke test for the real backend's launch contract.

Everything else in this suite talks to the FastAPI app in-process through
Starlette's TestClient. That proves routes and middleware behave, and proves
nothing at all about whether the shipped backend can actually be *started* the
way the macOS app starts it — which is precisely the gap that let 1.2.x ship a
backend the app could never reach.

The macOS app binds its own ephemeral loopback listener, hands the descriptor to
the child as **stdin** (``standardInput``), and sets
``VOQORA_IPC_LISTENER_FD=0``. It does this because ``Foundation.Process``
launches through ``posix_spawn``, which closes every descriptor except
stdin/stdout/stderr regardless of ``FD_CLOEXEC`` — so the previous approach of
advertising the raw descriptor number could never work. ``uvicorn.run(app,
fd=0)`` is therefore a load-bearing, and slightly unusual, configuration: fd 0
is normally stdin, not a listening socket.

This module launches the real ``python -m app.main`` with exactly that wiring
and checks that it serves authenticated traffic, so a regression in the launch
path fails in CI instead of on a user's machine.

``HOME`` is redirected at spawn time: ``Settings.USER_DATA_DIR`` resolves
``~/Library/Application Support/com.himudigonda.Voqora``, and the backend's
lifespan calls ``AudiobookService.resume_in_progress()`` on startup. Without the
redirect this test would resume synthesis of a developer's real audiobooks.
"""

from __future__ import annotations

import http.client
import os
import secrets
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

BACKEND_ROOT = Path(__file__).resolve().parents[1]
STARTUP_TIMEOUT_S = 90.0


def _request(
    port: int,
    path: str = "/health",
    token: str | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, bytes]:
    merged = dict(headers or {})
    if token is not None:
        merged["X-Voqora-IPC-Token"] = token
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request("GET", path, headers=merged)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def _terminate(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=15)
    except ProcessLookupError:
        return
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=15)


class _LaunchedBackend:
    def __init__(self, port: int, token: str, process: subprocess.Popen[bytes]) -> None:
        self.port = port
        self.token = token
        self.process = process


def _spawn_backend(
    home: Path, listener_fd_value: str
) -> tuple[_LaunchedBackend, socket.socket]:
    """Start the real backend exactly the way BackendService.swift does."""
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(socket.SOMAXCONN)
    port = listener.getsockname()[1]
    token = secrets.token_urlsafe(32)

    environment = os.environ | {
        "HOME": str(home),
        "VOQORA_IPC_LISTENER_FD": listener_fd_value,
        "VOQORA_IPC_TOKEN": token,
        "PYTHONUNBUFFERED": "1",
    }
    process = subprocess.Popen(
        [sys.executable, "-m", "app.main"],
        cwd=str(BACKEND_ROOT),
        env=environment,
        # The app hands the listener over as the child's stdin. Reproducing
        # that here — rather than subprocess's `pass_fds`, which the Swift
        # launch path has no equivalent of — is the entire point.
        stdin=listener.fileno(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    return _LaunchedBackend(port, token, process), listener


@pytest.fixture(scope="module")
def backend(tmp_path_factory: pytest.TempPathFactory):
    home = tmp_path_factory.mktemp("voqora-home")
    launched, listener = _spawn_backend(home, "0")

    try:
        deadline = time.monotonic() + STARTUP_TIMEOUT_S
        last_error = "the backend never accepted a request"
        while time.monotonic() < deadline:
            if launched.process.poll() is not None:
                output = (launched.process.stdout.read() or b"").decode(
                    errors="replace"
                )
                pytest.fail(
                    "the backend exited during startup "
                    f"({launched.process.returncode}):\n{output[-4000:]}"
                )
            try:
                status, _ = _request(launched.port, token=launched.token)
                if status == 200:
                    break
                last_error = f"authenticated /health returned HTTP {status}"
            except (OSError, http.client.HTTPException) as error:
                last_error = f"/health was unavailable ({type(error).__name__})"
            time.sleep(0.25)
        else:
            _terminate(launched.process)
            pytest.fail(
                "the backend never served traffic on its inherited stdin listener: "
                f"{last_error}"
            )
        yield launched
    finally:
        _terminate(launched.process)
        if launched.process.stdout is not None:
            launched.process.stdout.close()
        listener.close()


def test_serves_authenticated_health_on_the_inherited_stdin_listener(backend) -> None:
    """The load-bearing assertion: the backend adopted fd 0 as a *listening
    socket* and is serving the app's own ephemeral port."""
    status, body = _request(backend.port, token=backend.token)

    assert status == 200, body
    assert b'"status"' in body


def test_rejects_an_unauthenticated_request(backend) -> None:
    status, _ = _request(backend.port)
    assert status == 401


def test_rejects_a_wrong_token(backend) -> None:
    status, _ = _request(backend.port, token=secrets.token_urlsafe(32))
    assert status == 401


def test_rejects_an_empty_token_header(backend) -> None:
    status, _ = _request(backend.port, token="")
    assert status == 401


def test_rejects_a_token_that_only_shares_a_prefix(backend) -> None:
    """Guards against a `startswith`-style comparison creeping in."""
    status, _ = _request(backend.port, token=backend.token[:-1])
    assert status == 401

    status, _ = _request(backend.port, token=backend.token + "x")
    assert status == 401


def test_rejects_a_browser_origin_even_with_a_valid_token(backend) -> None:
    """A page in the user's browser must never be able to drive the local
    engine, token leak or not."""
    status, _ = _request(
        backend.port,
        token=backend.token,
        headers={"Origin": "https://evil.example"},
    )
    assert status == 403


def test_does_not_also_bind_the_development_fallback_port(backend) -> None:
    """Given an inherited descriptor, the backend must serve on that and only
    that — never additionally on the hardcoded dev port, which another local
    process could otherwise reach."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.settimeout(2)
    try:
        connected = probe.connect_ex(("127.0.0.1", 10101))
    finally:
        probe.close()

    assert (
        connected != 0
    ), "the backend must not listen on the development fallback port 10101"


def test_refuses_to_start_without_an_ipc_token(tmp_path: Path) -> None:
    """A release launch with no token would be an unauthenticated local server.
    The backend must exit rather than serve one."""
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    try:
        environment = os.environ | {
            "HOME": str(tmp_path),
            "VOQORA_IPC_LISTENER_FD": "0",
            "VOQORA_IPC_TOKEN": "",
        }
        completed = subprocess.run(
            [sys.executable, "-m", "app.main"],
            cwd=str(BACKEND_ROOT),
            env=environment,
            stdin=listener.fileno(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=STARTUP_TIMEOUT_S,
        )
    finally:
        listener.close()

    assert completed.returncode != 0
    assert b"VOQORA_IPC_TOKEN" in completed.stdout


def test_fails_fast_when_the_advertised_descriptor_is_not_a_socket(
    tmp_path: Path,
) -> None:
    """If the hand-off ever regresses to advertising a descriptor the child did
    not actually receive, the backend must die loudly instead of appearing to
    start while the app waits forever for a health check."""
    environment = os.environ | {
        "HOME": str(tmp_path),
        # A descriptor number the child definitively does not hold.
        "VOQORA_IPC_LISTENER_FD": "99",
        "VOQORA_IPC_TOKEN": secrets.token_urlsafe(32),
    }
    completed = subprocess.run(
        [sys.executable, "-m", "app.main"],
        cwd=str(BACKEND_ROOT),
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=STARTUP_TIMEOUT_S,
    )

    assert completed.returncode != 0, completed.stdout[-2000:]
