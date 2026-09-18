#!/usr/bin/env python3
"""Zip a frozen PyInstaller backend into a deterministic, safety-checked archive.

Used by compile_backend.sh. Kept as a standalone, importable module (rather
than an inline heredoc) so its safety contract can be unit-tested directly:
see test_backend_archive_safety.py.
"""

from __future__ import annotations

import argparse
import stat
import zipfile
from pathlib import Path


def build_archive(root: Path, zip_path: Path) -> None:
    """Zip everything under `root` into `zip_path`, archive entries rooted at
    `root`'s own name (i.e. `root.parent`-relative paths).

    Stable traversal order, fixed timestamps, and preserved file modes make
    the archive byte-for-byte reproducible for a given input tree, which is
    what makes the detached integrity manifest meaningful.

    A symlink is only ever included if it resolves to a real FILE inside
    `root`; a symlink resolving to a directory inside `root` (for example a
    macOS framework's `Versions/Current`) is silently skipped, since the real
    files it points at live under their own genuine, non-symlink path
    elsewhere in the tree and get archived from there. Any symlink that
    resolves outside `root`, or to neither a file nor a directory (broken,
    a device node, etc.), is refused outright.
    """
    root = root.resolve()
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
            if path.is_symlink():
                target = path.resolve()
                if not target.is_relative_to(root):
                    raise SystemExit(f"refusing unsafe runtime entry: {path}")
                if target.is_dir():
                    continue
                if not target.is_file():
                    raise SystemExit(f"refusing unsafe runtime entry: {path}")
                source = target
            elif path.is_dir():
                continue
            else:
                source = path
            info = zipfile.ZipInfo(path.relative_to(root.parent).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IMODE(source.stat().st_mode) & 0o777) << 16
            with source.open("rb") as input_stream, archive.open(info, "w", force_zip64=True) as destination:
                while chunk := input_stream.read(1024 * 1024):
                    destination.write(chunk)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="Frozen bundle directory to archive")
    parser.add_argument("--output", required=True, type=Path, help="Path to write the resulting .zip archive")
    args = parser.parse_args()
    build_archive(args.root, args.output)


if __name__ == "__main__":
    main()
