from __future__ import annotations

import io
import shutil
import tempfile

import pytest
from docx import Document
from fastapi.testclient import TestClient

from app.main import app
from app.services.audiobook_store import AudiobookStore

DOCX_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="ss_audiobooks_test_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


def _upload(filename: str, content: bytes, content_type: str = "text/plain"):
    return TestClient(app).post(
        "/audiobook",
        files={"file": (filename, io.BytesIO(content), content_type)},
    )


@pytest.mark.parametrize(
    ("filename", "content"),
    [
        ("blank.txt", b"   \n\n\t  \n   "),
        ("blank.md", b"\n\n   \n\n  \n"),
    ],
)
def test_whitespace_only_text_upload_is_rejected(filename, content):
    response = _upload(filename, content)

    assert response.status_code == 400
    assert "no extractable content" in response.json()["detail"]
    assert AudiobookStore.list_books() == []


def test_whitespace_only_docx_upload_is_rejected():
    doc = Document()
    doc.add_paragraph("   ")
    doc.add_paragraph("")
    buffer = io.BytesIO()
    doc.save(buffer)

    response = _upload("blank.docx", buffer.getvalue(), DOCX_TYPE)

    assert response.status_code == 400
    assert "no extractable content" in response.json()["detail"]
    assert AudiobookStore.list_books() == []


def test_genuinely_empty_upload_is_still_rejected():
    response = _upload("empty.txt", b"")

    assert response.status_code == 400
    assert "empty" in response.json()["detail"].lower()


def test_single_page_txt_with_content_is_accepted():
    response = _upload("note.txt", b"This is a real, short note.")

    assert response.status_code == 200
    body = response.json()
    assert body["page_count"] == 1
    assert AudiobookStore.read_meta(body["book_id"]) is not None


def test_multi_page_txt_upload_is_unaffected():
    content = ("Page one content. " * 50 + "\n\n" + "Page two content. " * 400).encode()

    response = _upload("book.txt", content)

    assert response.status_code == 200
    assert response.json()["page_count"] >= 2


def test_text_upload_persists_is_image_only_false():
    response = _upload("note.txt", b"This is a real, short note.")

    meta = AudiobookStore.read_meta(response.json()["book_id"])
    assert meta["is_image_only"] is False
