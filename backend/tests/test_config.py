"""Config surface tests — paths resolve correctly, both in-source and in-bundle."""

from __future__ import annotations

import os
import sys
from unittest.mock import patch

from app.core.config import Settings


def test_default_settings_smoke() -> None:
    s = Settings()
    assert s.PROJECT_NAME == "Voqora Backend"
    assert s.PORT == 10101
    assert s.HOST == "127.0.0.1"
    assert os.path.isabs(s.BASE_DIR)


def test_resource_path_uses_meipass_when_frozen() -> None:
    s = Settings()
    with patch.object(sys, "frozen", True, create=True), patch.object(
        sys, "_MEIPASS", "/tmp/pyinstaller-bundle", create=True
    ):
        assert s.RESOURCE_PATH == "/tmp/pyinstaller-bundle"


def test_resource_path_uses_base_dir_in_source() -> None:
    s = Settings()
    # Sanity — when not frozen, RESOURCE_PATH == BASE_DIR
    # (sys.frozen is not set in source layout)
    assert s.RESOURCE_PATH == s.BASE_DIR


def test_model_paths_are_under_resource_path() -> None:
    s = Settings()
    assert s.MODEL_PATH.startswith(s.RESOURCE_PATH)
    assert s.MODEL_PATH.endswith("kokoro-v1.0.onnx")
    assert s.VOICES_PATH.endswith("voices-v1.0.bin")


def test_active_model_path_prefers_int8_when_present(tmp_path) -> None:
    s = Settings()
    int8_path = s.MODEL_PATH.replace(".onnx", "-int8.onnx")
    with patch("app.core.config.os.path.exists", return_value=True):
        assert s.ACTIVE_MODEL_PATH == int8_path


def test_active_model_path_falls_back_to_fp32_when_int8_missing() -> None:
    s = Settings()
    with patch("app.core.config.os.path.exists", return_value=False):
        assert s.ACTIVE_MODEL_PATH == s.MODEL_PATH


def test_user_data_dir_is_under_application_support() -> None:
    s = Settings()
    assert "Application Support" in s.USER_DATA_DIR
    assert s.USER_DATA_DIR.endswith("com.himudigonda.Voqora")


def test_audiobooks_dir_is_created_on_access(tmp_path, monkeypatch) -> None:
    s = Settings()
    fake_root = tmp_path / "Application Support" / "com.himudigonda.Voqora"
    monkeypatch.setattr(type(s), "USER_DATA_DIR", property(lambda self: str(fake_root)))
    path = s.AUDIOBOOKS_DIR
    assert os.path.isdir(path)
    assert path == os.path.join(str(fake_root), "audiobooks")
