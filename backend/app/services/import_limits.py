"""Defence-in-depth validation and capacity planning for imported books.

The upload byte ceiling is not a resource ceiling: DOCX and EPUB are ZIP
containers, PDF pages can rasterise into enormous images, and narration
creates at least two copies of PCM while the final WAV is assembled.  Keep
these checks close to the import boundary so no parser/model work is started
for a document we cannot safely retain.
"""

from __future__ import annotations

import os
import shutil
import zipfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import PurePosixPath

from app.core.config import settings

_ZIP_MAGIC = b"PK\x03\x04"
_SYMLINK_MODE = 0o120000
_FILE_TYPE_MASK = 0o170000


class ImportLimitError(ValueError):
    """A safe, user-actionable import rejection."""


def validate_magic(path: str, extension: str) -> None:
    """Reject a renamed binary before a parser has to interpret it."""
    with open(path, "rb") as source:
        prefix = source.read(8)
    if extension == "pdf" and not prefix.startswith(b"%PDF-"):
        raise ImportLimitError("This file is not a valid PDF document.")
    if extension == "docx" and not prefix.startswith(_ZIP_MAGIC):
        raise ImportLimitError("This file is not a valid DOCX document.")
    if extension == "epub" and not prefix.startswith(_ZIP_MAGIC):
        raise ImportLimitError("This file is not a valid EPUB book.")


@dataclass(frozen=True)
class _ArchiveRules:
    label: str
    max_members: int
    max_expanded_bytes: int
    max_compression_ratio: int
    required_member: str
    member_byte_limit: Callable[[str], int | None]
    oversized_member_message: str


def _docx_member_limit(name: str) -> int | None:
    if name == "word/document.xml":
        return settings.MAX_DOCX_DOCUMENT_XML_BYTES
    return None


def _epub_member_limit(_name: str) -> int | None:
    return settings.MAX_EPUB_MEMBER_BYTES


def _docx_rules() -> _ArchiveRules:
    return _ArchiveRules(
        label="DOCX",
        max_members=settings.MAX_DOCX_MEMBERS,
        max_expanded_bytes=settings.MAX_DOCX_EXPANDED_BYTES,
        max_compression_ratio=settings.MAX_DOCX_COMPRESSION_RATIO,
        required_member="word/document.xml",
        member_byte_limit=_docx_member_limit,
        oversized_member_message="This DOCX has more text than Voqora can open safely.",
    )


def _epub_rules() -> _ArchiveRules:
    return _ArchiveRules(
        label="EPUB",
        max_members=settings.MAX_EPUB_MEMBERS,
        max_expanded_bytes=settings.MAX_EPUB_EXPANDED_BYTES,
        max_compression_ratio=settings.MAX_EPUB_COMPRESSION_RATIO,
        required_member="META-INF/container.xml",
        member_byte_limit=_epub_member_limit,
        oversized_member_message=(
            "This EPUB has a file that is too large to open safely."
        ),
    )


def is_safe_member_name(filename: str) -> bool:
    if not filename or "\\" in filename or "\x00" in filename:
        return False
    name = PurePosixPath(filename)
    return not (name.is_absolute() or ".." in name.parts or ":" in name.parts[0])


def _check_member(member: zipfile.ZipInfo, rules: _ArchiveRules) -> None:
    if not is_safe_member_name(member.filename):
        raise ImportLimitError(f"This {rules.label} contains an unsafe file path.")
    if (member.external_attr >> 16) & _FILE_TYPE_MASK == _SYMLINK_MODE:
        raise ImportLimitError(f"This {rules.label} contains an unsupported link.")
    if (
        member.file_size >= settings.DOCX_RATIO_CHECK_MIN_BYTES
        and member.file_size
        > max(member.compress_size, 1) * rules.max_compression_ratio
    ):
        raise ImportLimitError(
            f"This {rules.label} is compressed too aggressively to open safely."
        )
    limit = rules.member_byte_limit(member.filename)
    if limit is not None and member.file_size > limit:
        raise ImportLimitError(rules.oversized_member_message)


def _validate_archive(path: str, rules: _ArchiveRules) -> None:
    unreadable = f"This file is not a readable {rules.label} document."
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            if not members or len(members) > rules.max_members:
                raise ImportLimitError(
                    f"This {rules.label} has too many embedded files."
                )

            expanded = 0
            compressed = 0
            for member in members:
                _check_member(member, rules)
                expanded += member.file_size
                compressed += member.compress_size
                if expanded > rules.max_expanded_bytes:
                    raise ImportLimitError(
                        f"This {rules.label} expands beyond Voqora's safety limit."
                    )

            if rules.required_member not in {m.filename for m in members}:
                raise ImportLimitError(unreadable)
            if compressed and expanded / compressed > rules.max_compression_ratio:
                raise ImportLimitError(
                    f"This {rules.label} is compressed too aggressively to open "
                    "safely."
                )
    except zipfile.BadZipFile as exc:
        raise ImportLimitError(unreadable) from exc


def validate_docx_archive(path: str) -> None:
    """Bound ZIP expansion and reject archive traversal/symlink entries."""
    _validate_archive(path, _docx_rules())


def validate_epub_archive(path: str) -> None:
    """Bound EPUB expansion and reject archive traversal/symlink entries."""
    _validate_archive(path, _epub_rules())


def estimated_pcm_bytes(audio_seconds: float) -> int:
    # 24 kHz mono signed 16-bit PCM; reserve two copies during concat plus a
    # conservative source/text overhead before allowing background work.
    return max(0, int(audio_seconds * settings.AUDIO_SAMPLE_RATE * 2))


def ensure_storage_capacity(
    source_bytes: int,
    estimated_audio_seconds: float,
    *,
    library_root: str | None = None,
    reserved_bytes: int = 0,
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
    peak_increment = source_bytes * 3 + pcm * 2 + max(0, reserved_bytes)
    if used + peak_increment > settings.MAX_AUDIOBOOK_LIBRARY_BYTES:
        raise ImportLimitError(
            "Your Voqora library is full. Delete books before importing another one."
        )
    free = shutil.disk_usage(root).free
    if free < peak_increment + settings.MIN_FREE_DISK_BYTES:
        raise ImportLimitError(
            "There is not enough free disk space to safely create this audiobook."
        )
