"""Adversarial document-boundary checks for public-release imports."""

from __future__ import annotations

import os
import tempfile
import zipfile

import pytest

from app.services.import_limits import (
    ImportLimitError,
    validate_docx_archive,
    validate_magic,
)


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
