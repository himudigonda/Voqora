from __future__ import annotations

import asyncio
import json
import shutil
from collections import namedtuple
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from supertonic_fakes import mark_installed, write_model_files

from app.main import app
from app.services import supertonic_installer
from app.services.engine_errors import EngineBusyError, EngineInstallError
from app.services.engine_manager import EngineManager
from app.services.supertonic_catalog import (
    MODEL_ALLOW_PATTERNS,
    MODEL_REPO,
    MODEL_REVISION,
)
from app.services.supertonic_engine import SupertonicEngine
from app.services.supertonic_installer import (
    INSTALL_MARKER,
    SupertonicInstaller,
    directory_size,
)

client = TestClient(app)


def fake_snapshot(*, files=True, fail=None, record=None):
    def snapshot_download(**kwargs):
        if record is not None:
            record.append(kwargs)
        local_dir = supertonic_installer.Path(kwargs["local_dir"])
        local_dir.mkdir(parents=True, exist_ok=True)
        (local_dir / "partial.bin").write_bytes(b"x" * 64)
        if fail is not None:
            raise fail
        (local_dir / "partial.bin").unlink()
        (local_dir / ".cache" / "huggingface").mkdir(parents=True)
        if files:
            write_model_files(local_dir)
        return str(local_dir)

    return snapshot_download


async def install_with(snapshot):
    with patch.object(supertonic_installer, "snapshot_download", snapshot):
        SupertonicInstaller.start()
        await SupertonicInstaller.wait()


@pytest.mark.asyncio
async def test_install_downloads_the_pinned_revision_and_moves_it_into_place():
    calls: list[dict] = []
    await install_with(fake_snapshot(record=calls))

    assert calls == [
        {
            "repo_id": MODEL_REPO,
            "revision": MODEL_REVISION,
            "local_dir": str(SupertonicInstaller.partial_dir()),
            "allow_patterns": list(MODEL_ALLOW_PATTERNS),
        }
    ]
    final = SupertonicInstaller.model_dir()
    assert SupertonicInstaller.is_installed()
    assert json.loads((final / INSTALL_MARKER).read_text()) == {
        "revision": MODEL_REVISION
    }
    assert not (final / ".cache").exists()
    assert not SupertonicInstaller.partial_dir().exists()
    status = SupertonicInstaller.status()
    assert status == {
        "installed": True,
        "downloading": False,
        "progress": 1.0,
        "error": None,
    }


@pytest.mark.asyncio
async def test_status_reports_progress_while_downloading(monkeypatch):
    monkeypatch.setattr(supertonic_installer, "PROGRESS_POLL_SECONDS", 0.01)
    monkeypatch.setattr(supertonic_installer, "MODEL_SIZE_BYTES", 100)
    release = asyncio.Event()
    loop = asyncio.get_running_loop()
    seen: list[dict] = []

    def slow_download(**kwargs):
        local_dir = supertonic_installer.Path(kwargs["local_dir"])
        local_dir.mkdir(parents=True, exist_ok=True)
        (local_dir / "chunk.bin").write_bytes(b"x" * 50)
        asyncio.run_coroutine_threadsafe(release.wait(), loop).result(timeout=5)
        shutil.rmtree(local_dir)
        raise OSError("stopped")

    with patch.object(supertonic_installer, "snapshot_download", slow_download):
        SupertonicInstaller.start()
        for _ in range(200):
            await asyncio.sleep(0.01)
            status = SupertonicInstaller.status()
            if status["progress"] >= 0.5:
                seen.append(status)
                break
        release.set()
        await SupertonicInstaller.wait()

    assert seen[0]["downloading"] is True
    assert seen[0]["progress"] == pytest.approx(0.5)
    assert SupertonicInstaller.status()["downloading"] is False


@pytest.mark.asyncio
async def test_progress_never_reports_complete_before_the_move(monkeypatch):
    monkeypatch.setattr(supertonic_installer, "MODEL_SIZE_BYTES", 10)
    SupertonicInstaller._downloaded_bytes = 10_000
    SupertonicInstaller._task = asyncio.get_running_loop().create_future()
    try:
        assert SupertonicInstaller.status()["progress"] == 0.99
    finally:
        SupertonicInstaller._task.cancel()


@pytest.mark.asyncio
async def test_failed_download_keeps_partial_files_for_resume_and_can_retry():
    await install_with(fake_snapshot(fail=OSError("/private/path network down")))

    status = SupertonicInstaller.status()
    assert status["installed"] is False
    assert status["downloading"] is False
    assert status["error"] == supertonic_installer.DOWNLOAD_FAILED_MESSAGE
    assert "/private/path" not in status["error"]
    assert (SupertonicInstaller.partial_dir() / "partial.bin").exists()
    assert not SupertonicInstaller.model_dir().exists()

    await install_with(fake_snapshot())
    assert SupertonicInstaller.is_installed()
    assert SupertonicInstaller.status()["error"] is None
    assert not SupertonicInstaller.partial_dir().exists()


@pytest.mark.asyncio
async def test_incomplete_download_is_discarded_and_not_installed():
    await install_with(fake_snapshot(files=False))

    assert not SupertonicInstaller.is_installed()
    assert not SupertonicInstaller.partial_dir().exists()
    assert not SupertonicInstaller.model_dir().exists()
    assert SupertonicInstaller.status()["error"]


@pytest.mark.asyncio
async def test_install_refuses_when_the_disk_is_too_full():
    usage = namedtuple("usage", "total used free")
    with patch.object(
        supertonic_installer.shutil, "disk_usage", return_value=usage(10, 10, 0)
    ):
        await install_with(fake_snapshot())
    assert not SupertonicInstaller.is_installed()
    assert SupertonicInstaller.status()["error"] == (
        supertonic_installer.DISK_SPACE_MESSAGE
    )


@pytest.mark.asyncio
async def test_start_is_idempotent_while_downloading():
    release = asyncio.Event()
    loop = asyncio.get_running_loop()
    calls = []

    def blocked(**kwargs):
        calls.append(kwargs)
        asyncio.run_coroutine_threadsafe(release.wait(), loop).result(timeout=5)
        raise OSError("stopped")

    with patch.object(supertonic_installer, "snapshot_download", blocked):
        SupertonicInstaller.start()
        await asyncio.sleep(0.05)
        SupertonicInstaller.start()
        assert SupertonicInstaller.is_downloading()
        with pytest.raises(EngineBusyError):
            SupertonicInstaller.uninstall()
        release.set()
        await SupertonicInstaller.wait()
    assert len(calls) == 1


@pytest.mark.asyncio
async def test_start_is_a_no_op_when_already_installed():
    mark_installed(SupertonicInstaller.model_dir())
    with patch.object(supertonic_installer, "snapshot_download") as download:
        SupertonicInstaller.start()
        await SupertonicInstaller.wait()
    download.assert_not_called()


@pytest.mark.asyncio
async def test_reinstall_replaces_an_existing_incomplete_directory():
    stale = SupertonicInstaller.model_dir()
    stale.mkdir(parents=True)
    (stale / "stale.bin").write_bytes(b"old")
    await install_with(fake_snapshot())
    assert SupertonicInstaller.is_installed()
    assert not (stale / "stale.bin").exists()


def test_uninstall_removes_the_model_and_partial_downloads():
    mark_installed(SupertonicInstaller.model_dir())
    SupertonicInstaller.partial_dir().mkdir(parents=True)
    SupertonicInstaller._error = "old"
    SupertonicInstaller.uninstall()
    assert not SupertonicInstaller.model_dir().exists()
    assert not SupertonicInstaller.partial_dir().exists()
    assert SupertonicInstaller.status()["error"] is None


def test_a_stale_revision_marker_is_not_installed():
    directory = SupertonicInstaller.model_dir()
    mark_installed(directory)
    (directory / INSTALL_MARKER).write_text(json.dumps({"revision": "old"}))
    assert not SupertonicInstaller.is_installed()


@pytest.mark.parametrize("damage", ["marker", "voices", "onnx"])
def test_missing_pieces_are_not_installed(damage):
    directory = SupertonicInstaller.model_dir()
    mark_installed(directory)
    if damage == "marker":
        (directory / INSTALL_MARKER).unlink()
    elif damage == "voices":
        shutil.rmtree(directory / "voice_styles")
    else:
        (directory / "onnx" / "vocoder.onnx").unlink()
    assert not SupertonicInstaller.is_installed()


def test_directory_size_counts_nested_files(tmp_path):
    (tmp_path / "a" / "b").mkdir(parents=True)
    (tmp_path / "a" / "one").write_bytes(b"123")
    (tmp_path / "a" / "b" / "two").write_bytes(b"45")
    assert directory_size(tmp_path) == 5
    assert directory_size(tmp_path / "missing") == 0


def engine_entry(body, engine_id="supertonic"):
    return next(entry for entry in body["engines"] if entry["id"] == engine_id)


def test_engine_endpoint_lists_every_engine():
    body = client.get("/engine").json()
    assert body["engine"] == "kokoro"
    assert [entry["id"] for entry in body["engines"]] == [
        "kokoro",
        "supertonic",
        "ming",
    ]
    kokoro = engine_entry(body, "kokoro")
    assert kokoro["installed"] is True
    assert kokoro["downloading"] is False
    supertonic = engine_entry(body)
    assert set(supertonic) >= {
        "id",
        "name",
        "installed",
        "downloading",
        "progress",
        "size_bytes",
        "license",
        "languages",
        "voices",
    }
    assert supertonic["installed"] is False
    assert supertonic["size_bytes"] > 300 * 1024 * 1024
    assert "OpenRAIL-M" in supertonic["license"]
    assert "en" in supertonic["languages"]
    assert len(supertonic["languages"]) == 31
    assert supertonic["voices"][0]["id"].startswith("supertonic:")


def test_engine_endpoint_reports_installed_state():
    mark_installed(SupertonicInstaller.model_dir())
    supertonic = engine_entry(client.get("/engine").json())
    assert supertonic["installed"] is True
    assert supertonic["progress"] == 1.0


def test_install_endpoint_starts_the_download():
    with patch.object(SupertonicInstaller, "start") as start:
        response = client.post("/engine/supertonic/install")
    assert response.status_code == 202
    assert response.json()["id"] == "supertonic"
    start.assert_called_once_with()


def test_install_endpoint_rejects_unknown_engines():
    assert client.post("/engine/nope/install").status_code == 404


def test_installing_kokoro_is_a_no_op():
    response = client.post("/engine/kokoro/install")
    assert response.status_code == 202
    assert response.json()["installed"] is True


def test_uninstall_endpoint_removes_supertonic():
    mark_installed(SupertonicInstaller.model_dir())
    with patch("app.services.engine_manager.SupertonicEngine.unload") as unload:
        response = client.delete("/engine/supertonic")
    assert response.status_code == 200
    assert response.json()["installed"] is False
    unload.assert_called_once_with()
    assert not SupertonicInstaller.model_dir().exists()


def test_uninstall_endpoint_rejects_kokoro_and_unknown_engines():
    kokoro = client.delete("/engine/kokoro")
    assert kokoro.status_code == 400
    assert "built in" in kokoro.json()["detail"]
    assert client.delete("/engine/nope").status_code == 404


def test_uninstall_endpoint_conflicts_while_downloading():
    with patch.object(SupertonicInstaller, "is_downloading", return_value=True), patch(
        "app.services.engine_manager.SupertonicEngine.unload"
    ) as unload:
        response = client.delete("/engine/supertonic")
    assert response.status_code == 409
    unload.assert_not_called()


def test_uninstall_endpoint_conflicts_while_the_engine_is_busy():
    mark_installed(SupertonicInstaller.model_dir())
    with patch.object(SupertonicEngine, "is_busy", return_value=True), patch(
        "app.services.engine_manager.SupertonicEngine.unload"
    ) as unload:
        response = client.delete("/engine/supertonic")
    assert response.status_code == 409
    unload.assert_not_called()
    assert SupertonicInstaller.is_installed()


def test_select_engine_requires_a_known_installed_engine():
    assert client.post("/engine", json={"engine": "kokoro"}).status_code == 200
    unknown = client.post("/engine", json={"engine": "nope"})
    assert unknown.status_code == 400
    missing = client.post("/engine", json={"engine": "supertonic"})
    assert missing.status_code == 409
    assert "not installed" in missing.json()["detail"]
    mark_installed(SupertonicInstaller.model_dir())
    assert client.post("/engine", json={"engine": "supertonic"}).status_code == 200


def test_engine_manager_reports_per_engine_voices_and_defaults():
    assert EngineManager.default_voice() == "af_bella"
    assert EngineManager.default_voice("supertonic") == "supertonic:F1"
    assert "supertonic:M1" in EngineManager.voices("supertonic")
    assert all(not v.startswith("supertonic:") for v in EngineManager.voices())
    with pytest.raises(Exception, match="Unknown engine"):
        EngineManager.voices("nope")


def test_manager_reports_supertonic_missing_and_protects_kokoro():
    info = EngineManager.engine_info("supertonic")
    assert info["installed"] is False
    with pytest.raises(EngineInstallError):
        EngineManager.uninstall("kokoro")
