from __future__ import annotations

import asyncio
import json
import os
import shutil
from pathlib import Path

from huggingface_hub import snapshot_download
from huggingface_hub.utils import disable_progress_bars
from supertonic.config import CFG_REL_PATH, UNICODE_INDEXER_REL_PATH, VOICE_STYLES_DIR
from supertonic.loader import has_all_onnx_modules

from app.core.config import settings
from app.core.logging import get_logger
from app.services.engine_errors import EngineBusyError, EngineInstallError
from app.services.supertonic_catalog import (
    MODEL_ALLOW_PATTERNS,
    MODEL_NAME,
    MODEL_REPO,
    MODEL_REVISION,
    MODEL_SIZE_BYTES,
)

log = get_logger(__name__)

INSTALL_MARKER = ".voqora-install.json"
PROGRESS_POLL_SECONDS = 0.5
MAX_REPORTED_PROGRESS = 0.99
DOWNLOAD_FAILED_MESSAGE = (
    "The download did not finish. Check your connection and try again."
)
DISK_SPACE_MESSAGE = "Not enough free disk space to download Supertonic."


def directory_size(path: Path) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                continue
    return total


class SupertonicInstaller:
    _task: asyncio.Task | None = None
    _error: str | None = None
    _downloaded_bytes: int = 0

    @classmethod
    def reset(cls) -> None:
        cls._task = None
        cls._error = None
        cls._downloaded_bytes = 0

    @classmethod
    def model_dir(cls) -> Path:
        return Path(settings.MODELS_DIR) / MODEL_NAME

    @classmethod
    def partial_dir(cls) -> Path:
        return Path(settings.MODELS_DIR) / f".{MODEL_NAME}.partial"

    @classmethod
    def _has_files(cls, directory: Path) -> bool:
        if not has_all_onnx_modules(directory):
            return False
        required = (directory / CFG_REL_PATH, directory / UNICODE_INDEXER_REL_PATH)
        if not all(path.is_file() for path in required):
            return False
        return any((directory / VOICE_STYLES_DIR).glob("*.json"))

    @classmethod
    def is_installed(cls) -> bool:
        directory = cls.model_dir()
        try:
            marker = json.loads((directory / INSTALL_MARKER).read_text())
        except (OSError, ValueError):
            return False
        return marker.get("revision") == MODEL_REVISION and cls._has_files(directory)

    @classmethod
    def is_downloading(cls) -> bool:
        return cls._task is not None and not cls._task.done()

    @classmethod
    def status(cls) -> dict:
        installed = cls.is_installed()
        downloading = cls.is_downloading()
        if installed:
            progress = 1.0
        elif downloading:
            progress = min(
                cls._downloaded_bytes / MODEL_SIZE_BYTES, MAX_REPORTED_PROGRESS
            )
        else:
            progress = 0.0
        return {
            "installed": installed,
            "downloading": downloading,
            "progress": round(progress, 4),
            "error": None if installed or downloading else cls._error,
        }

    @classmethod
    def start(cls) -> None:
        if cls.is_installed() or cls.is_downloading():
            return
        cls._error = None
        cls._downloaded_bytes = 0
        cls._task = asyncio.get_running_loop().create_task(cls._run())

    @classmethod
    async def wait(cls) -> None:
        if cls._task is not None:
            await asyncio.shield(cls._task)

    @classmethod
    async def _run(cls) -> None:
        loop = asyncio.get_running_loop()
        download = loop.run_in_executor(None, cls._download)
        while True:
            done, _ = await asyncio.wait({download}, timeout=PROGRESS_POLL_SECONDS)
            cls._downloaded_bytes = directory_size(cls.partial_dir())
            if done:
                break
        try:
            download.result()
        except EngineInstallError as error:
            cls._error = str(error)
        except Exception:
            log.error(
                "supertonic.install_failed",
                extra={"failure_code": "supertonic_download_failed"},
                exc_info=True,
            )
            cls._error = DOWNLOAD_FAILED_MESSAGE
        else:
            log.info("supertonic.installed")

    @classmethod
    def _download(cls) -> None:
        final = cls.model_dir()
        partial = cls.partial_dir()
        final.parent.mkdir(parents=True, exist_ok=True)
        remaining = max(MODEL_SIZE_BYTES - directory_size(partial), 0)
        if shutil.disk_usage(final.parent).free < remaining * 1.25:
            raise EngineInstallError(DISK_SPACE_MESSAGE)
        disable_progress_bars()
        snapshot_download(
            repo_id=MODEL_REPO,
            revision=MODEL_REVISION,
            local_dir=str(partial),
            allow_patterns=list(MODEL_ALLOW_PATTERNS),
        )
        if not cls._has_files(partial):
            shutil.rmtree(partial, ignore_errors=True)
            raise EngineInstallError(DOWNLOAD_FAILED_MESSAGE)
        shutil.rmtree(partial / ".cache", ignore_errors=True)
        (partial / INSTALL_MARKER).write_text(json.dumps({"revision": MODEL_REVISION}))
        if final.exists():
            shutil.rmtree(final)
        os.replace(partial, final)

    @classmethod
    def uninstall(cls) -> None:
        if cls.is_downloading():
            raise EngineBusyError("Wait for the download to finish before removing it.")
        shutil.rmtree(cls.model_dir(), ignore_errors=True)
        shutil.rmtree(cls.partial_dir(), ignore_errors=True)
        cls._error = None
        cls._downloaded_bytes = 0
