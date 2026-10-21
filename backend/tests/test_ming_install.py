from __future__ import annotations

import asyncio
import io
import json
import subprocess
import sys
import tarfile
from collections import namedtuple
from pathlib import Path
from unittest.mock import patch

import pytest
from ming_fakes import mark_installed, write_install_files

from app.services import ming_installer
from app.services.engine_errors import EngineBusyError, EngineInstallError
from app.services.ming_catalog import (
    CODE_REVISION,
    CODE_TARBALL_URL,
    MODEL_IGNORE_PATTERNS,
    MODEL_REPO,
    MODEL_REVISION,
)
from app.services.ming_installer import (
    CODE_REQUIRED_FILES,
    INSTALL_MARKER,
    MODEL_REQUIRED_FILES,
    MingInstaller,
    extract_code,
    resolve_uv,
)

FAKE_UV = Path("/fake/bin/uv")
TOP_DIRECTORY = f"Ming-3.0-tts-{CODE_REVISION}"


def make_tarball(extra: dict[str, bytes] | None = None) -> bytes:
    members = {
        "ming_tts.py": b"print(1)",
        "tts_tasks.py": b"print(2)",
        "modeling_bailingmm.py": b"print(3)",
        "LICENSE": b"MIT",
        "LEGAL.md": b"legal",
        "README.md": b"readme",
        "requirements.txt": b"torch",
        "audio_tokenizer/tokenizer.py": b"a",
        "fm/dit.py": b"b",
        "frontend/toolkit.py": b"c",
        "frontend/talker_tn/data.fst": b"d",
        "cookbooks/guide.md": b"e",
        "figures/image.png": b"f",
        "ming_tiny/model.py": b"g",
        **(extra or {}),
    }
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        top = tarfile.TarInfo(TOP_DIRECTORY)
        top.type = tarfile.DIRTYPE
        tar.addfile(top)
        for name, body in members.items():
            info = tarfile.TarInfo(f"{TOP_DIRECTORY}/{name}")
            info.size = len(body)
            tar.addfile(info, io.BytesIO(body))
    return buffer.getvalue()


class FakeResponse:
    def __init__(self, body: bytes, status: int = 200) -> None:
        self._body = body
        self._status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def raise_for_status(self) -> None:
        if self._status >= 400:
            import httpx

            raise httpx.HTTPStatusError(
                "failed", request=httpx.Request("GET", "http://x"), response=None
            )

    def iter_bytes(self, size: int):
        for start in range(0, len(self._body), size):
            yield self._body[start : start + size]


class Recorder:
    def __init__(self, *, fail_on: str | None = None, torch_fails: bool = False):
        self.events: list[str] = []
        self.commands: list[list[str]] = []
        self.environments: list[dict] = []
        self.fail_on = fail_on
        self.torch_fails = torch_fails

    def run(self, command, **kwargs):
        self.commands.append(command)
        self.environments.append(kwargs["env"])
        if command[1:2] == ["venv"]:
            kind = "relink" if "--allow-existing" in command else "venv"
        elif command[1:3] == ["pip", "install"]:
            kind = "pip"
        else:
            kind = "import"
        self.events.append(kind)
        if kind == "venv":
            runtime = Path(command[-1])
            (runtime / "bin").mkdir(parents=True, exist_ok=True)
            (runtime / "bin" / "python").write_bytes(b"fake")
            python_dir = Path(kwargs["env"]["UV_PYTHON_INSTALL_DIR"])
            python_dir.mkdir(parents=True, exist_ok=True)
            (python_dir / "cpython").write_bytes(b"interpreter")
        if kind == "pip":
            Path(kwargs["env"]["UV_CACHE_DIR"]).mkdir(parents=True, exist_ok=True)
        failing = kind == self.fail_on or (kind == "import" and self.torch_fails)
        return subprocess.CompletedProcess(
            command,
            1 if failing else 0,
            stdout="",
            stderr="/Users/someone/private error detail",
        )

    def snapshot(self, **kwargs):
        self.events.append("model")
        model = Path(kwargs["local_dir"])
        model.mkdir(parents=True, exist_ok=True)
        (model / ".cache" / "huggingface").mkdir(parents=True)
        for name in MODEL_REQUIRED_FILES:
            (model / name).write_bytes(b"weights")
        self.snapshot_kwargs = kwargs
        return str(model)

    def stream(self, method, url, **kwargs):
        self.events.append("code")
        self.code_request = (method, url, kwargs)
        return FakeResponse(make_tarball())


@pytest.fixture
def uv(monkeypatch):
    monkeypatch.setattr(ming_installer, "resolve_uv", lambda: FAKE_UV)
    return FAKE_UV


async def install_with(recorder: Recorder):
    with (
        patch.object(ming_installer.subprocess, "run", recorder.run),
        patch.object(ming_installer, "snapshot_download", recorder.snapshot),
        patch.object(ming_installer.httpx, "stream", recorder.stream),
    ):
        MingInstaller.start()
        await MingInstaller.wait()


@pytest.mark.asyncio
async def test_install_runs_runtime_then_code_then_model_then_verifies_the_move(uv):
    recorder = Recorder()
    await install_with(recorder)

    assert recorder.events == ["venv", "pip", "code", "model", "relink", "import"]
    assert MingInstaller.is_installed()
    assert MingInstaller.status() == {
        "installed": True,
        "downloading": False,
        "progress": 1.0,
        "error": None,
    }
    final = MingInstaller.install_dir()
    assert json.loads((final / INSTALL_MARKER).read_text()) == {
        "code_revision": CODE_REVISION,
        "model_revision": MODEL_REVISION,
    }
    assert not MingInstaller.partial_dir().exists()
    assert not (final / ".uv-cache").exists()
    assert not list(final.glob(".step-*"))
    assert not (MingInstaller.model_dir() / ".cache").exists()


@pytest.mark.asyncio
async def test_uv_receives_isolated_directories_and_the_pinned_requirements(uv):
    recorder = Recorder()
    await install_with(recorder)

    partial = MingInstaller.partial_dir()
    final = MingInstaller.install_dir()
    venv, pip, relink, check = (
        recorder.commands[0],
        recorder.commands[1],
        recorder.commands[2],
        recorder.commands[3],
    )
    assert venv == [
        str(FAKE_UV),
        "venv",
        "--python",
        "3.11",
        "--python-preference",
        "only-managed",
        str(partial / "runtime"),
    ]
    assert pip == [
        str(FAKE_UV),
        "pip",
        "install",
        "--python",
        str(partial / "runtime" / "bin" / "python"),
        "-r",
        str(ming_installer.REQUIREMENTS_PATH),
    ]
    assert ming_installer.REQUIREMENTS_PATH.name == "requirements.txt"
    assert ming_installer.REQUIREMENTS_PATH.is_file()
    build_env = recorder.environments[0]
    assert build_env["UV_PYTHON_INSTALL_DIR"] == str(partial / "python")
    assert build_env["UV_CACHE_DIR"] == str(partial / ".uv-cache")
    assert build_env["UV_NO_CONFIG"] == "1"
    assert recorder.environments[1] == build_env
    assert relink[-1] == str(final / "runtime")
    assert "--allow-existing" in relink
    assert "--offline" in relink
    assert recorder.environments[2]["UV_PYTHON_INSTALL_DIR"] == str(final / "python")
    assert check == [
        str(final / "runtime" / "bin" / "python"),
        "-I",
        "-c",
        "import torch",
    ]


@pytest.mark.asyncio
async def test_code_comes_from_the_pinned_tarball_and_the_model_from_the_pinned_revision(
    uv,
):
    recorder = Recorder()
    await install_with(recorder)

    method, url, kwargs = recorder.code_request
    assert (method, url) == ("GET", CODE_TARBALL_URL)
    assert kwargs["follow_redirects"] is True
    assert recorder.snapshot_kwargs == {
        "repo_id": MODEL_REPO,
        "revision": MODEL_REVISION,
        "local_dir": str(MingInstaller.model_dir(MingInstaller.partial_dir())),
        "ignore_patterns": list(MODEL_IGNORE_PATTERNS),
    }
    assert "figures/*" in recorder.snapshot_kwargs["ignore_patterns"]
    assert "README.md" in recorder.snapshot_kwargs["ignore_patterns"]


def test_extract_code_strips_the_top_directory_and_keeps_only_the_runtime_files(
    tmp_path,
):
    archive = tmp_path / "code.tar.gz"
    archive.write_bytes(make_tarball())
    destination = tmp_path / "code"
    extract_code(archive, destination)

    kept = sorted(
        str(path.relative_to(destination))
        for path in destination.rglob("*")
        if path.is_file()
    )
    assert kept == [
        "LEGAL.md",
        "LICENSE",
        "audio_tokenizer/tokenizer.py",
        "fm/dit.py",
        "frontend/talker_tn/data.fst",
        "frontend/toolkit.py",
        "ming_tts.py",
        "modeling_bailingmm.py",
        "tts_tasks.py",
    ]


def test_extract_code_refuses_members_that_escape_the_destination(tmp_path):
    archive = tmp_path / "code.tar.gz"
    archive.write_bytes(make_tarball({"fm/../../escape.py": b"boom"}))
    with pytest.raises(tarfile.TarError):
        extract_code(archive, tmp_path / "code")
    assert not (tmp_path / "escape.py").exists()


@pytest.mark.asyncio
async def test_a_failed_runtime_step_reports_a_short_message_and_logs_the_detail(
    uv, caplog
):
    recorder = Recorder(fail_on="pip")
    await install_with(recorder)

    status = MingInstaller.status()
    assert status["installed"] is False
    assert status["error"] == ming_installer.RUNTIME_FAILED_MESSAGE
    assert "/Users/someone" not in status["error"]
    assert recorder.events == ["venv", "pip"]
    assert any("private error detail" in str(r.__dict__) for r in caplog.records)
    assert not MingInstaller.model_dir(MingInstaller.partial_dir()).exists()


@pytest.mark.asyncio
async def test_a_retry_resumes_after_the_finished_steps(uv):
    failing = Recorder()

    def broken_snapshot(**kwargs):
        raise OSError("network down")

    with (
        patch.object(ming_installer.subprocess, "run", failing.run),
        patch.object(ming_installer, "snapshot_download", broken_snapshot),
        patch.object(ming_installer.httpx, "stream", failing.stream),
    ):
        MingInstaller.start()
        await MingInstaller.wait()
    assert MingInstaller.status()["error"] == ming_installer.DOWNLOAD_FAILED_MESSAGE
    assert failing.events == ["venv", "pip", "code"]

    retry = Recorder()
    await install_with(retry)
    assert retry.events == ["model", "relink", "import"]
    assert MingInstaller.is_installed()
    assert MingInstaller.status()["error"] is None


@pytest.mark.asyncio
async def test_a_failed_code_download_is_reported(uv):
    recorder = Recorder()

    def broken_stream(method, url, **kwargs):
        recorder.events.append("code")
        return FakeResponse(b"", status=404)

    with (
        patch.object(ming_installer.subprocess, "run", recorder.run),
        patch.object(ming_installer, "snapshot_download", recorder.snapshot),
        patch.object(ming_installer.httpx, "stream", broken_stream),
    ):
        MingInstaller.start()
        await MingInstaller.wait()
    assert MingInstaller.status()["error"] == ming_installer.CODE_FAILED_MESSAGE
    assert "model" not in recorder.events


@pytest.mark.asyncio
async def test_a_broken_relocated_runtime_is_not_installed_and_keeps_the_download(uv):
    recorder = Recorder(torch_fails=True)
    await install_with(recorder)

    assert not MingInstaller.is_installed()
    assert MingInstaller.status()["error"] == ming_installer.RUNTIME_FAILED_MESSAGE
    assert not MingInstaller.install_dir().exists()
    partial = MingInstaller.partial_dir()
    assert (partial / "model" / "model.safetensors").is_file()
    assert not (partial / "runtime").exists()

    retry = Recorder()
    await install_with(retry)
    assert retry.events == ["venv", "pip", "relink", "import"]
    assert MingInstaller.is_installed()


@pytest.mark.asyncio
async def test_an_interrupted_move_reuses_the_finished_download(uv):
    final = MingInstaller.install_dir()
    write_install_files(final)
    (final / "references").mkdir()
    assert not MingInstaller.partial_dir().exists()

    recorder = Recorder()
    await install_with(recorder)

    assert recorder.events == ["venv", "pip", "relink", "import"]
    assert MingInstaller.is_installed()
    assert MingInstaller.status()["error"] is None
    assert not MingInstaller.partial_dir().exists()


@pytest.mark.asyncio
async def test_an_interrupted_move_with_a_missing_model_only_redownloads_the_model(
    uv,
):
    final = MingInstaller.install_dir()
    write_install_files(final)
    (MingInstaller.model_dir(final) / "model.safetensors").unlink()

    recorder = Recorder()
    await install_with(recorder)

    assert recorder.events == ["venv", "pip", "model", "relink", "import"]
    assert MingInstaller.is_installed()


@pytest.mark.asyncio
async def test_a_stale_install_is_not_reused_for_a_new_revision(uv):
    final = MingInstaller.install_dir()
    mark_installed(final)
    (final / INSTALL_MARKER).write_text(
        json.dumps({"code_revision": "old", "model_revision": "old"})
    )

    recorder = Recorder()
    await install_with(recorder)

    assert recorder.events == ["venv", "pip", "code", "model", "relink", "import"]
    assert MingInstaller.is_installed()


@pytest.mark.asyncio
async def test_a_missing_uv_is_a_clear_error(monkeypatch):
    monkeypatch.delenv(ming_installer.UV_PATH_ENVIRONMENT_VARIABLE, raising=False)
    monkeypatch.setattr(ming_installer.shutil, "which", lambda name: None)
    monkeypatch.setattr(ming_installer, "FALLBACK_UV_PATHS", ())
    monkeypatch.setattr(sys, "executable", "/nonexistent/bin/python")
    MingInstaller.start()
    await MingInstaller.wait()
    assert MingInstaller.status()["error"] == ming_installer.UV_MISSING_MESSAGE
    assert "uv" in ming_installer.UV_MISSING_MESSAGE


def make_executable(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n")
    path.chmod(0o755)
    return path


def isolate_uv_lookup(monkeypatch, tmp_path):
    monkeypatch.delenv(ming_installer.UV_PATH_ENVIRONMENT_VARIABLE, raising=False)
    monkeypatch.setattr(ming_installer.shutil, "which", lambda name: None)
    monkeypatch.setattr(ming_installer, "FALLBACK_UV_PATHS", ())
    monkeypatch.setattr(sys, "executable", str(tmp_path / "empty" / "python"))
    monkeypatch.delattr(sys, "frozen", raising=False)


def test_uv_resolution_prefers_the_environment_override(monkeypatch, tmp_path):
    isolate_uv_lookup(monkeypatch, tmp_path)
    override = make_executable(tmp_path / "override" / "uv")
    make_executable(tmp_path / "empty" / "uv")
    monkeypatch.setenv(ming_installer.UV_PATH_ENVIRONMENT_VARIABLE, str(override))
    assert resolve_uv() == override


def test_uv_resolution_then_checks_next_to_the_executable(monkeypatch, tmp_path):
    isolate_uv_lookup(monkeypatch, tmp_path)
    beside = make_executable(tmp_path / "empty" / "uv")
    on_path = make_executable(tmp_path / "path" / "uv")
    monkeypatch.setattr(ming_installer.shutil, "which", lambda name: str(on_path))
    assert resolve_uv() == beside


def test_uv_resolution_checks_the_frozen_bundle(monkeypatch, tmp_path):
    isolate_uv_lookup(monkeypatch, tmp_path)
    bundled = make_executable(tmp_path / "bundle" / "uv")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path / "bundle"), raising=False)
    assert resolve_uv() == bundled


def test_uv_resolution_falls_back_to_path_then_known_locations(monkeypatch, tmp_path):
    isolate_uv_lookup(monkeypatch, tmp_path)
    on_path = make_executable(tmp_path / "path" / "uv")
    known = make_executable(tmp_path / "known" / "uv")
    monkeypatch.setattr(ming_installer, "FALLBACK_UV_PATHS", (known,))
    monkeypatch.setattr(ming_installer.shutil, "which", lambda name: str(on_path))
    assert resolve_uv() == on_path
    monkeypatch.setattr(ming_installer.shutil, "which", lambda name: None)
    assert resolve_uv() == known


def test_uv_resolution_ignores_non_executable_candidates(monkeypatch, tmp_path):
    isolate_uv_lookup(monkeypatch, tmp_path)
    plain = tmp_path / "empty" / "uv"
    plain.parent.mkdir()
    plain.write_text("not executable")
    plain.chmod(0o644)
    with pytest.raises(EngineInstallError):
        resolve_uv()


@pytest.mark.asyncio
async def test_install_refuses_when_the_disk_is_too_full(uv):
    usage = namedtuple("usage", "total used free")
    recorder = Recorder()
    with patch.object(
        ming_installer.shutil, "disk_usage", return_value=usage(10, 10, 0)
    ):
        await install_with(recorder)
    assert recorder.events == []
    assert MingInstaller.status()["error"] == ming_installer.DISK_SPACE_MESSAGE


@pytest.mark.asyncio
async def test_disk_check_counts_what_is_already_downloaded(uv, monkeypatch):
    monkeypatch.setattr(ming_installer, "SIZE_BYTES", 1000)
    partial = MingInstaller.partial_dir()
    partial.mkdir(parents=True)
    (partial / "chunk.bin").write_bytes(b"x" * 1000)
    usage = namedtuple("usage", "total used free")
    recorder = Recorder()
    with patch.object(
        ming_installer.shutil, "disk_usage", return_value=usage(10, 10, 0)
    ):
        await install_with(recorder)
    assert MingInstaller.status()["error"] != ming_installer.DISK_SPACE_MESSAGE


def test_progress_is_weighted_by_step(monkeypatch):
    monkeypatch.setattr(ming_installer, "MODEL_SIZE_BYTES", 100)
    monkeypatch.setitem(ming_installer.STEP_SIZES, "model", 100)
    partial = MingInstaller.partial_dir()
    partial.mkdir(parents=True)
    assert MingInstaller._measure_progress() == 0
    (partial / ".step-runtime.done").touch()
    assert MingInstaller._measure_progress() == pytest.approx(0.2)
    (partial / ".step-code.done").touch()
    assert MingInstaller._measure_progress() == pytest.approx(0.22)
    model = partial / "model"
    model.mkdir()
    (model / "w.bin").write_bytes(b"x" * 50)
    assert MingInstaller._measure_progress() == pytest.approx(0.22 + 0.78 * 0.5)
    (partial / ".step-model.done").touch()
    assert MingInstaller._measure_progress() == pytest.approx(1.0)


def test_progress_inside_a_step_never_reaches_its_full_weight(monkeypatch):
    monkeypatch.setitem(ming_installer.STEP_SIZES, "runtime", 10)
    partial = MingInstaller.partial_dir()
    (partial / "runtime").mkdir(parents=True)
    (partial / "runtime" / "big.bin").write_bytes(b"x" * 1000)
    assert MingInstaller._measure_progress() < 0.2


@pytest.mark.asyncio
async def test_status_reports_monotonic_progress_while_installing(uv, monkeypatch):
    monkeypatch.setattr(ming_installer, "PROGRESS_POLL_SECONDS", 0.01)
    release = asyncio.Event()
    loop = asyncio.get_running_loop()
    recorder = Recorder()

    def blocked_snapshot(**kwargs):
        asyncio.run_coroutine_threadsafe(release.wait(), loop).result(timeout=10)
        raise OSError("stopped")

    seen: list[float] = []
    with (
        patch.object(ming_installer.subprocess, "run", recorder.run),
        patch.object(ming_installer, "snapshot_download", blocked_snapshot),
        patch.object(ming_installer.httpx, "stream", recorder.stream),
    ):
        MingInstaller.start()
        for _ in range(300):
            await asyncio.sleep(0.01)
            status = MingInstaller.status()
            seen.append(status["progress"])
            if status["progress"] >= 0.22:
                break
        release.set()
        await MingInstaller.wait()
    assert seen == sorted(seen)
    assert seen[-1] >= 0.22
    assert MingInstaller.status()["downloading"] is False


@pytest.mark.asyncio
async def test_start_is_idempotent_and_blocks_uninstall_while_installing(uv):
    release = asyncio.Event()
    loop = asyncio.get_running_loop()
    recorder = Recorder()

    def blocked_snapshot(**kwargs):
        asyncio.run_coroutine_threadsafe(release.wait(), loop).result(timeout=10)
        raise OSError("stopped")

    with (
        patch.object(ming_installer.subprocess, "run", recorder.run),
        patch.object(ming_installer, "snapshot_download", blocked_snapshot),
        patch.object(ming_installer.httpx, "stream", recorder.stream),
    ):
        MingInstaller.start()
        await asyncio.sleep(0.2)
        MingInstaller.start()
        assert MingInstaller.is_downloading()
        with pytest.raises(EngineBusyError):
            MingInstaller.uninstall()
        release.set()
        await MingInstaller.wait()
    assert recorder.events.count("venv") == 1


@pytest.mark.asyncio
async def test_start_is_a_no_op_when_already_installed(uv):
    mark_installed()
    recorder = Recorder()
    await install_with(recorder)
    assert recorder.events == []


def test_uninstall_removes_the_install_and_partial_downloads():
    mark_installed()
    MingInstaller.partial_dir().mkdir(parents=True)
    MingInstaller._error = "old"
    MingInstaller.uninstall()
    assert not MingInstaller.install_dir().exists()
    assert not MingInstaller.partial_dir().exists()
    assert MingInstaller.status()["error"] is None


@pytest.mark.parametrize("field", ["code_revision", "model_revision"])
def test_a_stale_revision_in_the_marker_is_not_installed(field):
    mark_installed()
    marker = MingInstaller.install_dir() / INSTALL_MARKER
    record = json.loads(marker.read_text())
    record[field] = "old"
    marker.write_text(json.dumps(record))
    assert not MingInstaller.is_installed()


@pytest.mark.parametrize("damage", ["marker", "python", "code", "model"])
def test_missing_pieces_are_not_installed(damage):
    mark_installed()
    root = MingInstaller.install_dir()
    if damage == "marker":
        (root / INSTALL_MARKER).unlink()
    elif damage == "python":
        MingInstaller.runtime_python().unlink()
    elif damage == "code":
        (MingInstaller.code_dir() / CODE_REQUIRED_FILES[0]).unlink()
    else:
        (MingInstaller.model_dir() / MODEL_REQUIRED_FILES[1]).unlink()
    assert not MingInstaller.is_installed()


def test_a_dangling_runtime_link_is_not_installed(tmp_path):
    mark_installed()
    python = MingInstaller.runtime_python()
    python.unlink()
    python.symlink_to(tmp_path / "gone" / "python")
    assert not MingInstaller.is_installed()


def test_write_install_files_makes_a_complete_install(tmp_path):
    write_install_files(tmp_path)
    assert MingInstaller._has_files(tmp_path)
