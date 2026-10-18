from __future__ import annotations

import asyncio
import contextlib
import errno
import socket
from collections.abc import Callable, Iterator
from dataclasses import asdict, dataclass

import uvicorn
from starlette.types import ASGIApp

from app.core.logging import get_logger

log = get_logger("voqora.local_api")

LOOPBACK_HOST = "127.0.0.1"
_POLL_INTERVAL_S = 0.02
_GRACEFUL_SHUTDOWN_S = 2


@dataclass(frozen=True)
class LocalAPIConfig:
    port: int
    api_key: str


@dataclass(frozen=True)
class LocalAPIStatus:
    enabled: bool
    port: int | None
    running: bool
    error: str | None = None
    error_code: str | None = None

    def to_dict(self) -> dict[str, object]:
        return {key: value for key, value in asdict(self).items() if value is not None}


class LocalAPIStartError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class _EmbeddedServer(uvicorn.Server):
    @contextlib.contextmanager
    def capture_signals(self) -> Iterator[None]:
        yield


@dataclass
class _Listener:
    server: _EmbeddedServer
    task: asyncio.Task[None]
    sock: socket.socket


class LocalAPIServer:
    def __init__(
        self,
        app_factory: Callable[[str], ASGIApp],
        *,
        max_connections: int,
        start_timeout_s: float,
        stop_timeout_s: float,
    ) -> None:
        self._app_factory = app_factory
        self._max_connections = max_connections
        self._start_timeout_s = start_timeout_s
        self._stop_timeout_s = stop_timeout_s
        self._lock = asyncio.Lock()
        self._enabled = False
        self._config: LocalAPIConfig | None = None
        self._listener: _Listener | None = None
        self._error: LocalAPIStartError | None = None

    @property
    def running(self) -> bool:
        listener = self._listener
        return (
            listener is not None
            and listener.server.started
            and not listener.task.done()
        )

    def status(self) -> LocalAPIStatus:
        error = self._error or self._unexpected_exit()
        return LocalAPIStatus(
            enabled=self._enabled,
            port=self._config.port if self._config else None,
            running=self.running,
            error=error.message if error else None,
            error_code=error.code if error else None,
        )

    async def apply(
        self, enabled: bool, config: LocalAPIConfig | None
    ) -> LocalAPIStatus:
        async with self._lock:
            if not enabled or config is None:
                await self._stop()
                self._enabled, self._error = False, None
                return self.status()
            if self.running and config == self._config:
                return self.status()
            await self._stop()
            self._enabled, self._config, self._error = True, config, None
            try:
                await self._start(config)
            except LocalAPIStartError as exc:
                self._error = exc
                log.warning(
                    "local_api.start_failed",
                    extra={"failure_code": exc.code, "port": config.port},
                )
            return self.status()

    async def shutdown(self) -> None:
        async with self._lock:
            await self._stop()

    async def _start(self, config: LocalAPIConfig) -> None:
        sock = bind_loopback(config.port)
        server = _EmbeddedServer(self._uvicorn_config(config.api_key))
        task = asyncio.create_task(server.serve(sockets=[sock]))
        self._listener = _Listener(server, task, sock)
        try:
            await self._wait_until_started(server, task)
        except LocalAPIStartError:
            await self._stop()
            raise
        log.info("local_api.started", extra={"port": config.port})

    def _uvicorn_config(self, api_key: str) -> uvicorn.Config:
        return uvicorn.Config(
            self._app_factory(api_key),
            lifespan="off",
            loop="asyncio",
            log_config=None,
            access_log=False,
            proxy_headers=False,
            server_header=False,
            limit_concurrency=self._max_connections,
            timeout_graceful_shutdown=_GRACEFUL_SHUTDOWN_S,
        )

    async def _wait_until_started(
        self, server: _EmbeddedServer, task: asyncio.Task[None]
    ) -> None:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + self._start_timeout_s
        while not server.started:
            if task.done():
                raise LocalAPIStartError(
                    "start_failed", "The local API failed to start."
                )
            if loop.time() >= deadline:
                raise LocalAPIStartError(
                    "start_timeout", "The local API did not start in time."
                )
            await asyncio.sleep(_POLL_INTERVAL_S)

    async def _stop(self) -> None:
        listener, self._listener = self._listener, None
        if listener is None:
            return
        server, task = listener.server, listener.task
        server.should_exit = True
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout=self._stop_timeout_s)
        except TimeoutError:
            server.force_exit = True
            task.cancel()
        except Exception:
            log.warning(
                "local_api.stop_failed",
                extra={"failure_code": "local_api_stop_failed"},
                exc_info=True,
            )
        await asyncio.gather(task, return_exceptions=True)
        listener.sock.close()
        log.info("local_api.stopped")

    def _unexpected_exit(self) -> LocalAPIStartError | None:
        listener = self._listener
        if self._enabled and listener is not None and listener.task.done():
            return LocalAPIStartError("stopped", "The local API stopped unexpectedly.")
        return None


def bind_loopback(port: int) -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((LOOPBACK_HOST, port))
        sock.setblocking(False)
    except OSError as exc:
        sock.close()
        raise _bind_error(exc, port) from None
    return sock


def _bind_error(exc: OSError, port: int) -> LocalAPIStartError:
    if exc.errno == errno.EADDRINUSE:
        return LocalAPIStartError(
            "port_in_use", f"Port {port} is already in use. Choose another port."
        )
    if exc.errno == errno.EACCES:
        return LocalAPIStartError(
            "permission_denied", f"Voqora is not allowed to use port {port}."
        )
    return LocalAPIStartError("bind_failed", f"Could not open port {port}.")
