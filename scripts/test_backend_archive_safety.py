#!/usr/bin/env python3
"""Regression test for seal_backend_archive.py's symlink safety contract.

Exercised by `make test-release-scripts` (see scripts/test_ship_modes.sh for
the sibling release-channel harness). This does not touch a real PyInstaller
build; it builds small synthetic trees that reproduce the two shapes that
matter: a benign macOS-framework-style directory symlink (which must be
archived without error) and a symlink that tries to escape the archive root
(which must still be refused).
"""

from __future__ import annotations

import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from seal_backend_archive import build_archive  # noqa: E402


def _fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def test_benign_framework_style_tree(tmp: Path) -> None:
    """A directory symlink inside root (e.g. Python.framework/Versions/Current)
    must be skipped, not rejected, and its real files archived from their
    genuine path."""
    root = tmp / "VoqoraServerA"
    root.mkdir()
    (root / "VoqoraServer").write_text("binary stub")
    framework = root / "_internal" / "Python.framework"
    (framework / "Versions" / "3.14" / "Resources").mkdir(parents=True)
    (framework / "Versions" / "3.14" / "Resources" / "Info.plist").write_text("plist content")
    (framework / "Versions" / "Current").symlink_to("3.14", target_is_directory=True)
    (framework / "Resources").symlink_to("Versions/Current/Resources", target_is_directory=True)
    real_lib = root / "_internal" / "reallib.dylib"
    real_lib.write_text("dylib bytes")
    (root / "_internal" / "shortcut.dylib").symlink_to(real_lib)

    zip_path = tmp / "good.zip"
    try:
        build_archive(root, zip_path)
    except SystemExit as exc:
        _fail(f"benign framework-style tree was rejected: {exc}")

    with zipfile.ZipFile(zip_path) as archive:
        names = set(archive.namelist())
    expected = {
        "VoqoraServerA/VoqoraServer",
        "VoqoraServerA/_internal/Python.framework/Versions/3.14/Resources/Info.plist",
        "VoqoraServerA/_internal/reallib.dylib",
        "VoqoraServerA/_internal/shortcut.dylib",
    }
    if names != expected:
        _fail(f"unexpected archive contents: {names}")


def test_symlink_escaping_root_to_directory_is_refused(tmp: Path) -> None:
    root = tmp / "VoqoraServerB"
    root.mkdir()
    (root / "evil").symlink_to(tmp, target_is_directory=True)
    try:
        build_archive(root, tmp / "bad_dir_escape.zip")
        _fail("a directory symlink escaping root was accepted")
    except SystemExit:
        pass


def test_symlink_escaping_root_to_file_is_refused(tmp: Path) -> None:
    root = tmp / "VoqoraServerC"
    root.mkdir()
    external_file = tmp / "outside_file.txt"
    external_file.write_text("nope")
    (root / "evil_file").symlink_to(external_file)
    try:
        build_archive(root, tmp / "bad_file_escape.zip")
        _fail("a file symlink escaping root was accepted")
    except SystemExit:
        pass


def test_broken_symlink_is_refused(tmp: Path) -> None:
    root = tmp / "VoqoraServerD"
    root.mkdir()
    (root / "broken").symlink_to(root / "does_not_exist")
    try:
        build_archive(root, tmp / "broken.zip")
        _fail("a broken symlink was accepted")
    except SystemExit:
        pass


def main() -> None:
    tmp = Path(tempfile.mkdtemp()).resolve()
    try:
        test_benign_framework_style_tree(tmp)
        test_symlink_escaping_root_to_directory_is_refused(tmp)
        test_symlink_escaping_root_to_file_is_refused(tmp)
        test_broken_symlink_is_refused(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("✅ Backend archive safety checks passed.")


if __name__ == "__main__":
    main()
