"""Defence-in-depth validation and capacity planning for imported books.

The upload byte ceiling is not a resource ceiling: DOCX is a ZIP container,
PDF pages can rasterise into enormous images, and narration creates at least
two copies of PCM while the final WAV is assembled.  Keep these checks close
to the import boundary so no parser/model work is started for a document we
cannot safely retain.
"""

from __future__ import annotations

import os
import shutil
import zipfile
from pathlib import PurePosixPath

from app.core.config import settings


class ImportLimitError(ValueError):
    """A safe, user-actionable import rejection."""


def validate_magic(path: str, extension: str) -> None:
    """Reject a renamed binary before a parser has to interpret it."""
    with open(path, "rb") as source:
        prefix = source.read(8)
    if extension == "pdf" and not prefix.startswith(b"%PDF-"):
        raise ImportLimitError("This file is not a valid PDF document.")
    if extension == "docx" and not prefix.startswith(b"PK\x03\x04"):
        raise ImportLimitError("This file is not a valid DOCX document.")


def validate_docx_archive(path: str) -> None:
    """Bound ZIP expansion and reject archive traversal/symlink entries."""
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            if not members or len(members) > settings.MAX_DOCX_MEMBERS:
                raise ImportLimitError("This DOCX has too many embedded files.")

            expanded = 0
            compressed = 0
            has_document_xml = False
            for member in members:
                name = PurePosixPath(member.filename)
                if name.is_absolute() or ".." in name.parts or not member.filename:
                    raise ImportLimitError("This DOCX contains an unsafe file path.")
                # Unix file mode in ZipInfo.external_attr. Symlinks have the
                # file-type bits 0120000 and must never be followed on extract.
                if (member.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ImportLimitError("This DOCX contains an unsupported link.")
                expanded += member.file_size
                compressed += member.compress_size
                if expanded > settings.MAX_DOCX_EXPANDED_BYTES:
                    raise ImportLimitError(
                        "This DOCX expands beyond Voqora's 1 GB safety limit."
                    )
                if member.filename == "word/document.xml":
                    has_document_xml = True

            if not has_document_xml:
                raise ImportLimitError("This file is not a readable DOCX document.")
            # ZIP metadata can report zero compressed bytes for empty entries;
            # only apply a ratio when there is meaningful expanded content.
            if (
                compressed
                and expanded / compressed > settings.MAX_DOCX_COMPRESSION_RATIO
            ):
                raise ImportLimitError(
                    "This DOCX is compressed too aggressively to open safely."
                )
    except zipfile.BadZipFile as exc:
        raise ImportLimitError("This file is not a readable DOCX document.") from exc


def estimated_pcm_bytes(audio_seconds: float) -> int:
    # 24 kHz mono signed 16-bit PCM; reserve two copies during concat plus a
    # conservative source/text overhead before allowing background work.
    return max(0, int(audio_seconds * settings.AUDIO_SAMPLE_RATE * 2))


def ensure_storage_capacity(
    source_bytes: int,
    estimated_audio_seconds: float,
    *,
    library_root: str | None = None,
) -> None:
    """Ensure both library quota and free-space reserve before processing."""
    root = library_root or settings.AUDIOBOOKS_DIR
    used = 0
    for base, _, names in os.walk(root):
        for name in names:
            try:
                used += os.path.getsize(os.path.join(base, name))
            except OSError:
                continue

    pcm = estimated_pcm_bytes(estimated_audio_seconds)
    # Source + extracted/cleaned text allowance + page WAVs + final WAV.
    peak_increment = source_bytes * 3 + pcm * 2
    if used + peak_increment > settings.MAX_AUDIOBOOK_LIBRARY_BYTES:
        raise ImportLimitError(
            "Your Voqora library is full. Delete books before importing another one."
        )
    free = shutil.disk_usage(root).free
    if free < peak_increment + settings.MIN_FREE_DISK_BYTES:
        raise ImportLimitError(
            "There is not enough free disk space to safely create this audiobook."
        )
