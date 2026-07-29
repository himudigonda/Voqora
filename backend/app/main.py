import asyncio
import os
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI

from app.api.audiobook import router as audiobook_router
from app.api.middleware import CorrelationMiddleware
from app.api.tts import router as tts_router
from app.core.config import settings
from app.core.logging import configure as configure_logging
from app.core.logging import get_logger
from app.services.engine_manager import EngineManager
from app.services.tts import TTSEngine

# Force asyncio backend for uvicorn compatibility
os.environ["ANYIO_BACKEND"] = "asyncio"

# Structured JSON logs (S1-G1). Idempotent.
configure_logging()
log = get_logger("voqora.main")

# PID of the Swift app that spawned us (captured at import time, before any fork).
_PARENT_PID = os.getppid()


async def _parent_watchdog() -> None:
    """Exit if the parent macOS app process disappears (crash, force-kill, etc.).

    Checks every 3 seconds whether the parent PID still exists via signal 0.
    When it's gone, calls os._exit(0) — a hard exit that bypasses Python
    shutdown hooks and ensures no zombie server lingers after an app crash.
    """
    while True:
        await asyncio.sleep(3)
        try:
            os.kill(_PARENT_PID, 0)  # 0 = existence check only, no signal sent
        except ProcessLookupError:
            log.info("watchdog.parent_gone")
            os._exit(0)
        except PermissionError:
            pass  # process exists but we lack permission to signal it — keep running


async def _load_engine_background() -> None:
    """Load Kokoro off the event loop so uvicorn starts immediately.

    /health returns {"status": "cold", "loaded": false} until this finishes.
    /speak calls EngineManager.ensure_loaded() which waits transparently.
    Idle-watcher task is started only after the model is in memory.
    """
    try:
        log.info("startup.engine_load.begin")
        # Use the public async API; TTSEngine.initialize is now invoked
        # transparently inside ensure_loaded(). See HARD-032.
        await EngineManager.ensure_loaded()
        log.info("startup.engine_load.ready")
    except Exception as exc:
        log.error("startup.engine_load.failed", extra={"err": str(exc)})
        return

    # Wire idle-unload watcher only after the model is in RAM.
    asyncio.create_task(TTSEngine.idle_watcher())


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Kick off model load as a background task — uvicorn starts serving
    # immediately and /health returns "cold" until loading finishes (~2-3 s).
    asyncio.create_task(_load_engine_background())

    # Audiobook orchestrator + crash-recovery (fast, no I/O blocking)
    from app.services.audiobook_service import AudiobookService

    AudiobookService.initialize()
    asyncio.create_task(AudiobookService.resume_in_progress())

    # Lifecycle watchdog: exit when the parent Swift app process disappears.
    # Runs even when launched from a terminal (harmless — exits when the shell dies).
    asyncio.create_task(_parent_watchdog())

    yield
    # Clean shutdown: cancel any in-flight audiobook pipeline at the next
    # page-boundary checkpoint, then release the thread pool. See HARD-073.
    from app.services.audiobook_service import AudiobookService as _AS

    await _AS.shutdown(grace_seconds=2.0)


app = FastAPI(title=settings.PROJECT_NAME, version=settings.VERSION, lifespan=lifespan)
app.add_middleware(CorrelationMiddleware)


app.include_router(tts_router)
app.include_router(audiobook_router)

if __name__ == "__main__":
    # This entry point is used by PyInstaller and Dev
    # log_config=None prevents uvicorn from overriding logging, access_log=False hides the health spam
    uvicorn.run(
        app,
        host=settings.HOST,
        port=settings.PORT,
        workers=1,
        loop="asyncio",
        log_config=None,
        access_log=False,
    )
