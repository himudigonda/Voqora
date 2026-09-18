#!/usr/bin/env python3
"""Create the sealed manifest consumed by LaunchManager.

The manifest deliberately lives beside, rather than inside, the archive so it
can contain the archive's own digest. Both resources are protected by the app
bundle signature in distribution builds. This script accepts only the layout
created by ``compile_backend.sh`` and fails on the archive features that the
runtime extractor intentionally refuses (links, duplicate names and unsafe
paths).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import stat
import zipfile
from pathlib import Path, PurePosixPath


ROOT = "VoqoraServer"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_member_path(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if (
        not name
        or name.startswith("/")
        or "\\" in name
        or any(part in {"", ".", ".."} for part in path.parts)
        or path.parts[0] != ROOT
    ):
        raise ValueError(f"unsafe archive member: {name!r}")
    return path


def build_manifest(archive: Path, version: str) -> dict[str, object]:
    entries: list[dict[str, object]] = []
    seen: set[str] = set()

    with zipfile.ZipFile(archive) as bundle:
        for info in bundle.infolist():
            path = safe_member_path(info.filename.rstrip("/"))
            canonical = "/".join(path.parts)
            if canonical in seen:
                raise ValueError(f"duplicate archive member: {canonical}")
            seen.add(canonical)

            unix_mode = (info.external_attr >> 16) & 0o7777
            file_type = stat.S_IFMT(info.external_attr >> 16)
            if info.is_dir():
                if file_type not in {0, stat.S_IFDIR}:
                    raise ValueError(f"non-directory mode on archive directory: {canonical}")
                continue
            if file_type not in {0, stat.S_IFREG}:
                raise ValueError(f"non-regular archive member: {canonical}")
            if unix_mode == 0:
                unix_mode = 0o644
            if unix_mode & ~0o777:
                raise ValueError(f"unsafe archive mode: {canonical}")
            relative = "/".join(path.parts[1:])
            entries.append(
                {
                    "path": relative,
                    "sha256": hashlib.sha256(bundle.read(info)).hexdigest(),
                    "mode": unix_mode,
                }
            )

    if not entries or "VoqoraServer" not in {entry["path"] for entry in entries}:
        raise ValueError("archive does not contain the VoqoraServer executable")

    entries.sort(key=lambda entry: str(entry["path"]))
    return {
        "format": 1,
        "version": version,
        "archive_sha256": sha256_file(archive),
        "root": ROOT,
        "files": entries,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()

    if (args.verify is None) == (args.output is None):
        parser.error("provide exactly one of --output or --verify")

    manifest = build_manifest(args.archive, args.version)
    if args.verify:
        existing = json.loads(args.verify.read_text(encoding="utf-8"))
        if existing != manifest:
            raise SystemExit("backend manifest does not match archive contents")
        return

    assert args.output is not None
    encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(encoded, encoding="utf-8")
    temporary.replace(args.output)


if __name__ == "__main__":
    main()
