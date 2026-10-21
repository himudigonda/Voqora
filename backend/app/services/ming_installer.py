from __future__ import annotations

import asyncio
import json
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

import httpx
from huggingface_hub import snapshot_download
from huggingface_hub.utils import disable_progress_bars

from app.core.config import settings
from app.core.logging import get_logger
from app.services.engine_errors import EngineBusyError, EngineInstallError
from app.services.ming_catalog import (
    CODE_PROGRESS_WEIGHT,
    CODE_REVISION,
    CODE_SIZE_BYTES,
    CODE_TARBALL_URL,
    CODE_TOP_LEVEL_DIRECTORIES,
    CODE_TOP_LEVEL_FILES,
    INSTALL_DIR_NAME,
    MODEL_IGNORE_PATTERNS,
    MODEL_PROGRESS_WEIGHT,
    MODEL_REPO,
    MODEL_REVISION,
    MODEL_SIZE_BYTES,
    RUNTIME_PROGRESS_WEIGHT,
    RUNTIME_SIZE_BYTES,
    SIZE_BYTES,
)

log = get_logger(__name__)

INSTALL_MARKER = ".voqora-install.json"
PROGRESS_POLL_SECONDS = 0.5
MAX_REPORTED_PROGRESS = 0.99
MAX_STEP_FRACTION = 0.95
PYTHON_VERSION = "3.11"
UV_PATH_ENVIRONMENT_VARIABLE = "VOQORA_UV_PATH"
FALLBACK_UV_PATHS = (
    Path("/opt/homebrew/bin/uv"),
    Path.home() / ".local" / "bin" / "uv",
)
UV_TIMEOUT_SECONDS = 3600
IMPORT_CHECK_TIMEOUT_SECONDS = 300
CODE_DOWNLOAD_TIMEOUT_SECONDS = 120.0
CODE_CHUNK_BYTES = 1024 * 1024
LOG_TAIL_CHARS = 2000
REQUIREMENTS_PATH = (
    Path(settings.RESOURCE_PATH) / "app" / "engines" / "ming" / "requirements.txt"
)

STEP_RUNTIME = "runtime"
STEP_CODE = "code"
STEP_MODEL = "model"
STEPS = (STEP_RUNTIME, STEP_CODE, STEP_MODEL)
STEP_WEIGHTS = {
    STEP_RUNTIME: RUNTIME_PROGRESS_WEIGHT,
    STEP_CODE: CODE_PROGRESS_WEIGHT,
    STEP_MODEL: MODEL_PROGRESS_WEIGHT,
}
STEP_SIZES = {
    STEP_RUNTIME: RUNTIME_SIZE_BYTES,
    STEP_CODE: CODE_SIZE_BYTES,
    STEP_MODEL: MODEL_SIZE_BYTES,
}

DOWNLOAD_FAILED_MESSAGE = (
    "The download did not finish. Check your connection and try again."
)
DISK_SPACE_MESSAGE = "Not enough free disk space to download Ming."
UV_MISSING_MESSAGE = (
    "Voqora could not find the setup tool (uv) that Ming needs. "
    "Reinstall Voqora, or install uv, then try again."
)
RUNTIME_FAILED_MESSAGE = (
    "Voqora could not set up the Ming runtime. Check your connection and try again."
)
CODE_FAILED_MESSAGE = (
    "Voqora could not download the Ming code. Check your connection and try again."
)

MODEL_REQUIRED_FILES = ("config.json", "model.safetensors", "campplus.onnx")
CODE_REQUIRED_FILES = ("ming_tts.py", "tts_tasks.py", "modeling_bailingmm.py")


def directory_size(path: Path) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                continue
    return total


def resolve_uv() -> Path:
    candidates: list[Path] = []
    override = os.environ.get(UV_PATH_ENVIRONMENT_VARIABLE)
    if override:
        candidates.append(Path(override))
    candidates.append(Path(sys.executable).parent / "uv")
    if getattr(sys, "frozen", False):
        candidates.append(Path(sys._MEIPASS) / "uv")
    found = shutil.which("uv")
    if found:
        candidates.append(Path(found))
    candidates.extend(FALLBACK_UV_PATHS)
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise EngineInstallError(UV_MISSING_MESSAGE)


def _kept_in_code(member: tarfile.TarInfo, relative: str) -> bool:
    top, separator, _ = relative.partition("/")
    if separator or member.isdir():
        return top in CODE_TOP_LEVEL_DIRECTORIES
    return relative.endswith(".py") or relative in CODE_TOP_LEVEL_FILES


def extract_code(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            _, separator, relative = member.name.partition("/")
            if not separator or not relative or not _kept_in_code(member, relative):
                continue
            member.name = relative
            tar.extract(member, destination, filter="data")


class MingInstaller:
    _task: asyncio.Task | None = None
    _error: str | None = None
    _progress: float = 0.0

    @classmethod
    def reset(cls) -> None:
        cls._task = None
        cls._error = None
        cls._progress = 0.0

    @classmethod
    def install_dir(cls) -> Path:
        return Path(settings.MODELS_DIR) / INSTALL_DIR_NAME

    @classmethod
    def partial_dir(cls) -> Path:
        return Path(settings.MODELS_DIR) / f".{INSTALL_DIR_NAME}.partial"

    @classmethod
    def runtime_python(cls, root: Path | None = None) -> Path:
        return (root or cls.install_dir()) / "runtime" / "bin" / "python"

    @classmethod
    def code_dir(cls, root: Path | None = None) -> Path:
        return (root or cls.install_dir()) / "code"

    @classmethod
    def model_dir(cls, root: Path | None = None) -> Path:
        return (root or cls.install_dir()) / "model"

    @classmethod
    def references_dir(cls) -> Path:
        return cls.install_dir() / "references"

    @classmethod
    def _has_files(cls, root: Path) -> bool:
        if not cls.runtime_python(root).is_file():
            return False
        code = cls.code_dir(root)
        model = cls.model_dir(root)
        return all((code / name).is_file() for name in CODE_REQUIRED_FILES) and all(
            (model / name).is_file() for name in MODEL_REQUIRED_FILES
        )

    @classmethod
    def _has_marker(cls, root: Path) -> bool:
        return (root / INSTALL_MARKER).exists()

    @classmethod
    def is_installed(cls) -> bool:
        root = cls.install_dir()
        try:
            marker = json.loads((root / INSTALL_MARKER).read_text())
        except (OSError, ValueError):
            return False
        return (
            marker.get("code_revision") == CODE_REVISION
            and marker.get("model_revision") == MODEL_REVISION
            and cls._has_files(root)
        )

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
            progress = min(cls._progress, MAX_REPORTED_PROGRESS)
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
        cls._progress = 0.0
        cls._task = asyncio.get_running_loop().create_task(cls._run())

    @classmethod
    async def wait(cls) -> None:
        if cls._task is not None:
            await asyncio.shield(cls._task)

    @classmethod
    def _step_done_marker(cls, partial: Path, step: str) -> Path:
        return partial / f".step-{step}.done"

    @classmethod
    def _step_directories(cls, partial: Path, step: str) -> tuple[Path, ...]:
        if step == STEP_RUNTIME:
            return (partial / "runtime", partial / "python")
        return (partial / step,)

    @classmethod
    def _measure_progress(cls) -> float:
        partial = cls.partial_dir()
        total = 0.0
        for step in STEPS:
            if cls._step_done_marker(partial, step).exists():
                total += STEP_WEIGHTS[step]
                continue
            size = sum(
                directory_size(path) for path in cls._step_directories(partial, step)
            )
            fraction = min(size / STEP_SIZES[step], MAX_STEP_FRACTION)
            total += STEP_WEIGHTS[step] * fraction
        return total

    @classmethod
    async def _run(cls) -> None:
        loop = asyncio.get_running_loop()
        install = loop.run_in_executor(None, cls._install)
        while True:
            done, _ = await asyncio.wait({install}, timeout=PROGRESS_POLL_SECONDS)
            measured = await loop.run_in_executor(None, cls._measure_progress)
            cls._progress = max(cls._progress, measured)
            if done:
                break
        try:
            install.result()
        except EngineInstallError as error:
            cls._error = str(error)
        except Exception:
            log.error(
                "ming.install_failed",
                extra={"failure_code": "ming_download_failed"},
                exc_info=True,
            )
            cls._error = DOWNLOAD_FAILED_MESSAGE
        else:
            log.info("ming.installed")

    @classmethod
    def _uv_environment(cls, python_dir: Path, cache_dir: Path) -> dict[str, str]:
        environment = {
            key: value
            for key, value in os.environ.items()
            if key not in {"PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"}
        }
        environment["UV_PYTHON_INSTALL_DIR"] = str(python_dir)
        environment["UV_CACHE_DIR"] = str(cache_dir)
        environment["UV_NO_CONFIG"] = "1"
        return environment

    @classmethod
    def _run_command(
        cls,
        command: list[str],
        environment: dict[str, str],
        failure_message: str,
        timeout: int,
    ) -> None:
        try:
            result = subprocess.run(
                command,
                env=environment,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            log.error(
                "ming.command_failed",
                extra={"failure_code": "ming_command_failed"},
                exc_info=True,
            )
            raise EngineInstallError(failure_message) from None
        if result.returncode != 0:
            log.error(
                "ming.command_failed",
                extra={
                    "failure_code": "ming_command_failed",
                    "exit_code": result.returncode,
                    "stderr_tail": result.stderr[-LOG_TAIL_CHARS:],
                },
            )
            raise EngineInstallError(failure_message)

    @classmethod
    def _install_runtime(cls, uv: Path, partial: Path) -> None:
        marker = cls._step_done_marker(partial, STEP_RUNTIME)
        if marker.exists():
            return
        python_dir = partial / "python"
        cache_dir = partial / ".uv-cache"
        runtime = partial / "runtime"
        shutil.rmtree(runtime, ignore_errors=True)
        environment = cls._uv_environment(python_dir, cache_dir)
        cls._run_command(
            [
                str(uv),
                "venv",
                "--python",
                PYTHON_VERSION,
                "--python-preference",
                "only-managed",
                str(runtime),
            ],
            environment,
            RUNTIME_FAILED_MESSAGE,
            UV_TIMEOUT_SECONDS,
        )
        cls._run_command(
            [
                str(uv),
                "pip",
                "install",
                "--python",
                str(cls.runtime_python(partial)),
                "-r",
                str(REQUIREMENTS_PATH),
            ],
            environment,
            RUNTIME_FAILED_MESSAGE,
            UV_TIMEOUT_SECONDS,
        )
        shutil.rmtree(cache_dir, ignore_errors=True)
        marker.touch()

    @classmethod
    def _install_code(cls, partial: Path) -> None:
        marker = cls._step_done_marker(partial, STEP_CODE)
        if marker.exists():
            return
        archive = partial / ".code.tar.gz"
        code = cls.code_dir(partial)
        shutil.rmtree(code, ignore_errors=True)
        try:
            with httpx.stream(
                "GET",
                CODE_TARBALL_URL,
                follow_redirects=True,
                timeout=CODE_DOWNLOAD_TIMEOUT_SECONDS,
            ) as response:
                response.raise_for_status()
                with archive.open("wb") as handle:
                    for chunk in response.iter_bytes(CODE_CHUNK_BYTES):
                        handle.write(chunk)
            extract_code(archive, code)
        except (httpx.HTTPError, tarfile.TarError, OSError):
            log.error(
                "ming.code_failed",
                extra={"failure_code": "ming_code_failed"},
                exc_info=True,
            )
            shutil.rmtree(code, ignore_errors=True)
            raise EngineInstallError(CODE_FAILED_MESSAGE) from None
        finally:
            archive.unlink(missing_ok=True)
        if not all((code / name).is_file() for name in CODE_REQUIRED_FILES):
            shutil.rmtree(code, ignore_errors=True)
            raise EngineInstallError(CODE_FAILED_MESSAGE)
        marker.touch()

    @classmethod
    def _install_model(cls, partial: Path) -> None:
        marker = cls._step_done_marker(partial, STEP_MODEL)
        if marker.exists():
            return
        model = cls.model_dir(partial)
        disable_progress_bars()
        snapshot_download(
            repo_id=MODEL_REPO,
            revision=MODEL_REVISION,
            local_dir=str(model),
            ignore_patterns=list(MODEL_IGNORE_PATTERNS),
        )
        shutil.rmtree(model / ".cache", ignore_errors=True)
        if not all((model / name).is_file() for name in MODEL_REQUIRED_FILES):
            shutil.rmtree(model, ignore_errors=True)
            raise EngineInstallError(DOWNLOAD_FAILED_MESSAGE)
        marker.touch()

    @classmethod
    def _relink_runtime(cls, uv: Path, root: Path) -> None:
        cache_dir = root / ".uv-cache"
        environment = cls._uv_environment(root / "python", cache_dir)
        try:
            cls._run_command(
                [
                    str(uv),
                    "venv",
                    "--python",
                    PYTHON_VERSION,
                    "--python-preference",
                    "only-managed",
                    "--offline",
                    "--allow-existing",
                    str(root / "runtime"),
                ],
                environment,
                RUNTIME_FAILED_MESSAGE,
                UV_TIMEOUT_SECONDS,
            )
            cls._run_command(
                [str(cls.runtime_python(root)), "-I", "-c", "import torch"],
                environment,
                RUNTIME_FAILED_MESSAGE,
                IMPORT_CHECK_TIMEOUT_SECONDS,
            )
        finally:
            shutil.rmtree(cache_dir, ignore_errors=True)

    @classmethod
    def _install(cls) -> None:
        final = cls.install_dir()
        partial = cls.partial_dir()
        final.parent.mkdir(parents=True, exist_ok=True)
        if final.exists() and not partial.exists() and not cls._has_marker(final):
            cls._return_to_partial(final, partial)
        remaining = max(SIZE_BYTES - directory_size(partial), 0)
        if shutil.disk_usage(final.parent).free < remaining * 1.25:
            raise EngineInstallError(DISK_SPACE_MESSAGE)
        uv = resolve_uv()
        partial.mkdir(parents=True, exist_ok=True)
        cls._install_runtime(uv, partial)
        cls._install_code(partial)
        cls._install_model(partial)
        if not cls._has_files(partial):
            shutil.rmtree(partial, ignore_errors=True)
            raise EngineInstallError(DOWNLOAD_FAILED_MESSAGE)
        for step in STEPS:
            cls._step_done_marker(partial, step).unlink(missing_ok=True)
        if final.exists():
            shutil.rmtree(final)
        os.replace(partial, final)
        try:
            cls._relink_runtime(uv, final)
        except EngineInstallError:
            cls._return_to_partial(final, partial)
            raise
        (final / INSTALL_MARKER).write_text(
            json.dumps(
                {"code_revision": CODE_REVISION, "model_revision": MODEL_REVISION}
            )
        )

    @classmethod
    def _return_to_partial(cls, final: Path, partial: Path) -> None:
        shutil.rmtree(final / "runtime", ignore_errors=True)
        shutil.rmtree(final / "python", ignore_errors=True)
        shutil.rmtree(partial, ignore_errors=True)
        os.replace(final, partial)
        if all(
            (cls.code_dir(partial) / name).is_file() for name in CODE_REQUIRED_FILES
        ):
            cls._step_done_marker(partial, STEP_CODE).touch()
        if all(
            (cls.model_dir(partial) / name).is_file() for name in MODEL_REQUIRED_FILES
        ):
            cls._step_done_marker(partial, STEP_MODEL).touch()

    @classmethod
    def uninstall(cls) -> None:
        if cls.is_downloading():
            raise EngineBusyError("Wait for the download to finish before removing it.")
        shutil.rmtree(cls.install_dir(), ignore_errors=True)
        shutil.rmtree(cls.partial_dir(), ignore_errors=True)
        cls._error = None
        cls._progress = 0.0
