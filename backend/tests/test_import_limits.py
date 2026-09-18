"""Adversarial document-boundary checks for public-release imports."""

from __future__ import annotations

import collections
import os
import shutil
import tempfile
import zipfile

import pytest

from app.core.config import settings
from app.services.import_limits import (
    ImportLimitError,
    ensure_storage_capacity,
    validate_docx_archive,
    validate_magic,
)

_DiskUsage = collections.namedtuple("usage", "total used free")


def _docx(path: str, entries: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", b"<Types/>")
        archive.writestr("word/document.xml", b"<w:document/>")
        for name, content in entries.items():
            archive.writestr(name, content)


def test_docx_validator_accepts_a_normal_container():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "book.docx")
        _docx(path, {"word/styles.xml": b"<styles/>"})
        validate_magic(path, "docx")
        validate_docx_archive(path)


def test_docx_validator_rejects_zip_traversal():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "unsafe.docx")
        _docx(path, {"../outside.txt": b"nope"})
        with pytest.raises(ImportLimitError, match="unsafe"):
            validate_docx_archive(path)


def test_docx_validator_rejects_excessive_compression():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "bomb.docx")
        _docx(path, {"word/media/repeated.bin": b"a" * 2_000_000})
        with pytest.raises(ImportLimitError, match="compressed"):
            validate_docx_archive(path)


def test_magic_validator_rejects_renamed_pdf_and_docx():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "not-a-document")
        with open(path, "wb") as out:
            out.write(b"not a document")
        with pytest.raises(ImportLimitError, match="PDF"):
            validate_magic(path, "pdf")
        with pytest.raises(ImportLimitError, match="DOCX"):
            validate_magic(path, "docx")


# ---------- ensure_storage_capacity (disk-space / library-quota edges) ----------
#
# Previously untested: neither the per-library quota branch nor the
# free-disk-space branch had a single regression test, despite gating a
# real HTTP 413 at upload time (see app/api/audiobook.py's ensure_storage_capacity
# call). A messy user environment -- a nearly-full disk, or a library that
# has grown close to its 20 GB cap -- is exactly the kind of edge this test
# suite is meant to catch.


def test_ensure_storage_capacity_allows_room_within_quota_and_free_disk(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(settings, "MAX_AUDIOBOOK_LIBRARY_BYTES", 10**12)
    monkeypatch.setattr(settings, "MIN_FREE_DISK_BYTES", 0)
    monkeypatch.setattr(
        shutil, "disk_usage", lambda _path: _DiskUsage(10**12, 0, 10**12)
    )
    # Must not raise.
    ensure_storage_capacity(1_000, 10.0, library_root=str(tmp_path))


def test_ensure_storage_capacity_rejects_when_library_quota_exceeded(
    tmp_path, monkeypatch
):
    """An existing library already near its cap must reject a new import
    even when the machine itself has plenty of free disk space."""
    (tmp_path / "existing_book_audio.wav").write_bytes(b"x" * 5_000)
    monkeypatch.setattr(settings, "MAX_AUDIOBOOK_LIBRARY_BYTES", 5_000)
    monkeypatch.setattr(settings, "MIN_FREE_DISK_BYTES", 0)
    monkeypatch.setattr(
        shutil, "disk_usage", lambda _path: _DiskUsage(10**12, 0, 10**12)
    )
    with pytest.raises(ImportLimitError, match="library is full"):
        ensure_storage_capacity(1_000, 10.0, library_root=str(tmp_path))


def test_ensure_storage_capacity_rejects_when_free_disk_space_too_low(
    tmp_path, monkeypatch
):
    """A near-full disk must reject the import even when the library's own
    quota has plenty of headroom -- these are deliberately independent
    checks (see the module docstring)."""
    monkeypatch.setattr(settings, "MAX_AUDIOBOOK_LIBRARY_BYTES", 10**12)
    monkeypatch.setattr(settings, "MIN_FREE_DISK_BYTES", 2 * 1024**3)
    monkeypatch.setattr(
        shutil, "disk_usage", lambda _path: _DiskUsage(10**9, 10**9 - 100, 100)
    )
    with pytest.raises(ImportLimitError, match="not enough free disk space"):
        ensure_storage_capacity(1_000, 10.0, library_root=str(tmp_path))


def test_ensure_storage_capacity_ignores_unreadable_and_broken_entries(
    tmp_path, monkeypatch
):
    """A dangling symlink left behind in the library root (e.g. from a
    partially-cleaned-up book) must not crash the usage scan -- os.walk +
    os.path.getsize is expected to skip anything it can't stat."""
    broken_link = tmp_path / "dangling.wav"
    broken_link.symlink_to(tmp_path / "does_not_exist.wav")
    monkeypatch.setattr(settings, "MAX_AUDIOBOOK_LIBRARY_BYTES", 10**12)
    monkeypatch.setattr(settings, "MIN_FREE_DISK_BYTES", 0)
    monkeypatch.setattr(
        shutil, "disk_usage", lambda _path: _DiskUsage(10**12, 0, 10**12)
    )
    # Must not raise OSError -- the broken symlink contributes 0 bytes.
    ensure_storage_capacity(1_000, 10.0, library_root=str(tmp_path))
