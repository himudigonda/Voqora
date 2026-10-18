"""Embedded local API server: start, restart, stop, bind errors, IPC control."""

from __future__ import annotations

import asyncio
import errno
import socket
from collections.abc import AsyncIterator, Iterator
from unittest.mock import AsyncMock, patch

import httpx
import pytest
import pytest_asyncio
from fastapi.testclient import TestClient

from app.api import integrations
from app.api.public_app import create_public_app
from app.main import app, lifespan
from app.services.audiobook_service import AudiobookService
from app.services.engine_manager import EngineManager
from app.services.local_api_server import (
    LocalAPIConfig,
    LocalAPIServer,
    LocalAPIStartError,
    LocalAPIStatus,
    bind_loopback,
)
from app.services.speech_relay import speech_relay
from conftest import TEST_IPC_TOKEN

KEY_A = "a" * 40
KEY_B = "b" * 40


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def _server(**overrides: float) -> LocalAPIServer:
    options = {"max_connections": 8, "start_timeout_s": 5.0, "stop_timeout_s": 5.0}
    options.update(overrides)
    return LocalAPIServer(create_public_app, **options)


@pytest_asyncio.fixture
async def server() -> AsyncIterator[LocalAPIServer]:
    instance = _server()
    yield instance
    await instance.shutdown()


@pytest.fixture(autouse=True)
def clean_relay() -> Iterator[None]:
    speech_relay.close_all()
    yield
    speech_relay.close_all()


async def _get(port: int, key: str, path: str = "/v1/models") -> httpx.Response:
    async with httpx.AsyncClient(
        base_url=f"http://127.0.0.1:{port}", trust_env=False, timeout=5
    ) as client:
        return await client.get(path, headers={"Authorization": f"Bearer {key}"})


@pytest.mark.asyncio
async def test_initial_status_is_disabled(server: LocalAPIServer) -> None:
    assert server.status().to_dict() == {"enabled": False, "running": False}


@pytest.mark.asyncio
async def test_start_serves_on_loopback_and_stop_closes(
    server: LocalAPIServer,
) -> None:
    port = _free_port()
    status = await server.apply(True, LocalAPIConfig(port, KEY_A))
    assert status == LocalAPIStatus(enabled=True, port=port, running=True)
    response = await _get(port, KEY_A)
    assert response.status_code == 200
    assert response.json()["object"] == "list"
    assert (await _get(port, KEY_B)).status_code == 401

    status = await server.apply(False, None)
    assert status.to_dict() == {"enabled": False, "port": port, "running": False}
    with pytest.raises(httpx.ConnectError):
        await _get(port, KEY_A)


@pytest.mark.asyncio
async def test_same_config_does_not_restart(server: LocalAPIServer) -> None:
    config = LocalAPIConfig(_free_port(), KEY_A)
    await server.apply(True, config)
    listener = server._listener
    await server.apply(True, config)
    assert server._listener is listener


@pytest.mark.asyncio
async def test_key_change_restarts_with_new_key(server: LocalAPIServer) -> None:
    port = _free_port()
    await server.apply(True, LocalAPIConfig(port, KEY_A))
    status = await server.apply(True, LocalAPIConfig(port, KEY_B))
    assert status.running
    assert (await _get(port, KEY_A)).status_code == 401
    assert (await _get(port, KEY_B)).status_code == 200


@pytest.mark.asyncio
async def test_port_change_moves_listener(server: LocalAPIServer) -> None:
    first, second = _free_port(), _free_port()
    await server.apply(True, LocalAPIConfig(first, KEY_A))
    status = await server.apply(True, LocalAPIConfig(second, KEY_A))
    assert status.port == second and status.running
    assert (await _get(second, KEY_A)).status_code == 200
    with pytest.raises(httpx.ConnectError):
        await _get(first, KEY_A)


@pytest.mark.asyncio
async def test_port_in_use_is_reported(server: LocalAPIServer) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as squatter:
        squatter.bind(("127.0.0.1", 0))
        squatter.listen()
        port = squatter.getsockname()[1]
        status = await server.apply(True, LocalAPIConfig(port, KEY_A))
    assert status.running is False
    assert status.enabled is True
    assert status.error_code == "port_in_use"
    assert str(port) in status.error


@pytest.mark.asyncio
async def test_recovers_after_port_in_use(server: LocalAPIServer) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as squatter:
        squatter.bind(("127.0.0.1", 0))
        squatter.listen()
        port = squatter.getsockname()[1]
        await server.apply(True, LocalAPIConfig(port, KEY_A))
    status = await server.apply(True, LocalAPIConfig(_free_port(), KEY_A))
    assert status.running and status.error is None


@pytest.mark.asyncio
async def test_disable_clears_error(server: LocalAPIServer) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as squatter:
        squatter.bind(("127.0.0.1", 0))
        squatter.listen()
        await server.apply(True, LocalAPIConfig(squatter.getsockname()[1], KEY_A))
    status = await server.apply(False, None)
    assert status.error is None and status.error_code is None


@pytest.mark.parametrize(
    "code,expected",
    [
        (errno.EADDRINUSE, "port_in_use"),
        (errno.EACCES, "permission_denied"),
        (errno.EADDRNOTAVAIL, "bind_failed"),
    ],
)
def test_bind_errors_are_classified(code: int, expected: str) -> None:
    with patch("socket.socket.bind", side_effect=OSError(code, "nope")):
        with pytest.raises(LocalAPIStartError) as raised:
            bind_loopback(12345)
    assert raised.value.code == expected
    assert "nope" not in raised.value.message


def test_bind_loopback_never_binds_all_interfaces() -> None:
    sock = bind_loopback(0)
    try:
        assert sock.getsockname()[0] == "127.0.0.1"
    finally:
        sock.close()


@pytest.mark.asyncio
async def test_start_failure_inside_uvicorn_is_reported() -> None:
    server = _server()
    with patch(
        "app.services.local_api_server._EmbeddedServer.serve",
        new=AsyncMock(side_effect=RuntimeError("boom")),
    ):
        status = await server.apply(True, LocalAPIConfig(_free_port(), KEY_A))
    assert status.error_code == "start_failed"
    assert status.running is False


@pytest.mark.asyncio
async def test_start_timeout_is_reported() -> None:
    server = _server(start_timeout_s=0.05)

    async def never_starts(self, sockets=None) -> None:
        await asyncio.Event().wait()

    with patch("app.services.local_api_server._EmbeddedServer.serve", never_starts):
        status = await server.apply(True, LocalAPIConfig(_free_port(), KEY_A))
    assert status.error_code == "start_timeout"
    assert server._listener is None


@pytest.mark.asyncio
async def test_stop_timeout_forces_exit() -> None:
    server = _server(stop_timeout_s=0.05)

    async def ignores_exit(self, sockets=None) -> None:
        self.started = True
        await asyncio.Event().wait()

    with patch("app.services.local_api_server._EmbeddedServer.serve", ignores_exit):
        status = await server.apply(True, LocalAPIConfig(_free_port(), KEY_A))
        assert status.running
        listener = server._listener
        await server.shutdown()
    assert server._listener is None
    assert listener.task.cancelled()
    assert listener.sock.fileno() == -1


@pytest.mark.asyncio
async def test_unexpected_exit_is_reported(server: LocalAPIServer) -> None:
    await server.apply(True, LocalAPIConfig(_free_port(), KEY_A))
    listener = server._listener
    assert listener is not None
    listener.server.should_exit = True
    await asyncio.wait_for(asyncio.shield(listener.task), timeout=5)
    status = server.status()
    assert status.running is False
    assert status.error_code == "stopped"


@pytest.mark.asyncio
async def test_concurrent_applies_are_serialized(server: LocalAPIServer) -> None:
    ports = [_free_port() for _ in range(3)]
    statuses = await asyncio.gather(
        *(server.apply(True, LocalAPIConfig(port, KEY_A)) for port in ports)
    )
    assert all(status.running for status in statuses)
    assert server.status().port == ports[-1]
    assert (await _get(ports[-1], KEY_A)).status_code == 200


@pytest.mark.asyncio
async def test_public_speak_reaches_app_subscriber_over_real_server(
    server: LocalAPIServer,
) -> None:
    port = _free_port()
    await server.apply(True, LocalAPIConfig(port, KEY_A))
    queue = speech_relay.subscribe()
    async with httpx.AsyncClient(
        base_url=f"http://127.0.0.1:{port}", trust_env=False, timeout=5
    ) as client:
        response = await client.post(
            "/v1/voqora/speak",
            json={"text": "From an agent"},
            headers={"Authorization": f"Bearer {KEY_A}"},
        )
    assert response.status_code == 202
    assert queue.get_nowait()["text"] == "From an agent"


@pytest_asyncio.fixture
async def ipc() -> AsyncIterator[httpx.AsyncClient]:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ipc",
        headers={"X-Voqora-IPC-Token": TEST_IPC_TOKEN},
    ) as client:
        yield client
    await integrations.local_api_server.shutdown()
    await integrations.local_api_server.apply(False, None)


@pytest.mark.asyncio
async def test_ipc_get_status_never_includes_key(ipc: httpx.AsyncClient) -> None:
    port = _free_port()
    response = await ipc.post(
        "/integrations/local-api",
        json={"enabled": True, "port": port, "api_key": KEY_A},
    )
    assert response.status_code == 200
    assert response.json() == {"enabled": True, "port": port, "running": True}
    status = await ipc.get("/integrations/local-api")
    assert status.json() == {"enabled": True, "port": port, "running": True}
    assert KEY_A not in status.text
    assert (await _get(port, KEY_A)).status_code == 200

    stopped = await ipc.post("/integrations/local-api", json={"enabled": False})
    assert stopped.status_code == 200
    assert stopped.json()["running"] is False


@pytest.mark.asyncio
async def test_ipc_port_in_use_is_409(ipc: httpx.AsyncClient) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as squatter:
        squatter.bind(("127.0.0.1", 0))
        squatter.listen()
        port = squatter.getsockname()[1]
        response = await ipc.post(
            "/integrations/local-api",
            json={"enabled": True, "port": port, "api_key": KEY_A},
        )
    assert response.status_code == 409
    body = response.json()
    assert body["error_code"] == "port_in_use"
    assert body["running"] is False
    assert body["enabled"] is True
    assert body["error"]


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"enabled": True},
        {"enabled": True, "port": 8080},
        {"enabled": True, "api_key": KEY_A},
        {"enabled": True, "port": 80, "api_key": KEY_A},
        {"enabled": True, "port": 65536, "api_key": KEY_A},
        {"enabled": True, "port": 8080, "api_key": "short"},
        {"enabled": True, "port": 8080, "api_key": "x" * 129},
        {"enabled": True, "port": 8080, "api_key": "has space " + "x" * 32},
        {"enabled": True, "port": 8080, "api_key": "é" * 40},
        {"enabled": "maybe", "port": 8080, "api_key": KEY_A},
    ],
)
def test_ipc_settings_validation(body: dict) -> None:
    with patch.object(integrations.local_api_server, "apply") as apply:
        response = TestClient(app).post("/integrations/local-api", json=body)
    assert response.status_code == 422
    apply.assert_not_called()


def test_ipc_settings_accept_bounds() -> None:
    for port, key in ((1024, "k" * 32), (65535, "k" * 128)):
        with patch.object(
            integrations.local_api_server,
            "apply",
            new=AsyncMock(return_value=LocalAPIStatus(True, port, True)),
        ) as apply:
            response = TestClient(app).post(
                "/integrations/local-api",
                json={"enabled": True, "port": port, "api_key": key},
            )
        assert response.status_code == 200
        apply.assert_awaited_once_with(True, LocalAPIConfig(port, key))


def test_ipc_control_requires_ipc_token() -> None:
    client = TestClient(app, headers={"X-Voqora-IPC-Token": "wrong"})
    assert client.get("/integrations/local-api").status_code == 401
    assert (
        client.post("/integrations/local-api", json={"enabled": False}).status_code
        == 401
    )


def test_ipc_control_rejects_browser_origin() -> None:
    response = TestClient(app).get(
        "/integrations/local-api", headers={"Origin": "chrome-extension://abc"}
    )
    assert response.status_code == 403


@pytest.mark.asyncio
async def test_lifespan_shutdown_stops_local_api_and_relay() -> None:
    queue = speech_relay.subscribe()
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(AudiobookService, "initialize"),
        patch.object(AudiobookService, "resume_in_progress", new=AsyncMock()),
        patch.object(AudiobookService, "shutdown", new=AsyncMock()),
        patch.object(
            integrations.local_api_server, "shutdown", new=AsyncMock()
        ) as shutdown,
        patch("app.main._parent_watchdog", new=AsyncMock()),
    ):
        async with lifespan(app):
            pass
    shutdown.assert_awaited_once()
    assert queue.get_nowait() is None
    from app.main import _bg_tasks

    pending = list(_bg_tasks)
    for task in pending:
        task.cancel()
    await asyncio.gather(*pending, return_exceptions=True)
