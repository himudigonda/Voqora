import json
import os

import pytest

from app.services import json_store
from app.services.json_store import JsonDocument


def test_missing_document_loads_empty(tmp_path):
    assert JsonDocument(lambda: str(tmp_path / "none.json"), "t").load() == {}


def test_save_creates_directory_and_round_trips_unicode(tmp_path):
    path = tmp_path / "deep" / "doc.json"
    document = JsonDocument(lambda: str(path), "t")
    document.save({"name": "café 北京"})
    assert document.load() == {"name": "café 北京"}
    assert os.listdir(path.parent) == ["doc.json"]


def test_oversized_document_is_ignored(tmp_path, monkeypatch):
    path = tmp_path / "doc.json"
    path.write_text(json.dumps({"x": "y" * 100}))
    monkeypatch.setattr(json_store, "_MAX_DOCUMENT_BYTES", 10)
    assert JsonDocument(lambda: str(path), "t").load() == {}


def test_failed_save_keeps_old_file_and_removes_temp(tmp_path, monkeypatch):
    path = tmp_path / "doc.json"
    document = JsonDocument(lambda: str(path), "t")
    document.save({"version": 1})

    def broken_replace(_src, _dst):
        raise OSError("disk full")

    monkeypatch.setattr(json_store.os, "replace", broken_replace)
    with pytest.raises(OSError):
        document.save({"version": 2})
    assert json.loads(path.read_text()) == {"version": 1}
    assert os.listdir(tmp_path) == ["doc.json"]
