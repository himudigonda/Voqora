from __future__ import annotations

import os
import shutil
import tempfile
import time

import pytest

from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore


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


@pytest.fixture(autouse=True)
def reset_audiobook_service():
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    AudiobookService._executor = None
    yield
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    if AudiobookService._executor is not None:
        AudiobookService._executor.shutdown(wait=False, cancel_futures=True)
        AudiobookService._executor = None


def _heading(title: str, start_page: int, level: int) -> dict:
    return {"title": title, "start_page": start_page, "level": level}


def test_headings_sharing_a_page_collapse_into_non_overlapping_sections():
    outline = [
        _heading("A", 2, 1),
        _heading("B", 2, 1),
        _heading("C", 2, 1),
        _heading("D", 5, 1),
    ]

    sections = AudiobookService._outline_sections(outline, 8)

    assert sections == [
        {"title": "A", "start_page": 2, "end_page": 4},
        {"title": "D", "start_page": 5, "end_page": 8},
    ]


def test_only_the_shallowest_level_with_multiple_chapters_is_kept():
    outline = [
        _heading("Book Title", 1, 1),
        _heading("Chapter One", 1, 2),
        _heading("Section 1.1", 2, 3),
        _heading("Chapter Two", 4, 2),
        _heading("Section 2.1", 5, 3),
        _heading("Chapter Three", 7, 2),
    ]

    sections = AudiobookService._outline_sections(outline, 9)

    assert [s["title"] for s in sections] == [
        "Chapter One",
        "Chapter Two",
        "Chapter Three",
    ]
    assert [(s["start_page"], s["end_page"]) for s in sections] == [
        (1, 3),
        (4, 6),
        (7, 9),
    ]


def test_minimum_level_wins_when_it_has_several_distinct_pages():
    outline = [
        _heading("Part One", 1, 0),
        _heading("Chapter One", 2, 1),
        _heading("Part Two", 6, 0),
    ]

    sections = AudiobookService._outline_sections(outline, 10)

    assert [s["title"] for s in sections] == ["Part One", "Part Two"]
    assert sections[0]["end_page"] == 5


def test_single_entry_outline_still_yields_one_section():
    sections = AudiobookService._outline_sections([_heading("Only", 3, 0)], 6)

    assert sections == [{"title": "Only", "start_page": 3, "end_page": 6}]


def test_sections_never_overlap_for_unordered_duplicate_pages():
    outline = [
        _heading("B", 4, 1),
        _heading("A", 1, 1),
        _heading("A2", 1, 1),
        _heading("B2", 4, 1),
        _heading("C", 4, 1),
    ]

    sections = AudiobookService._outline_sections(outline, 6)

    previous_end = 0
    for section in sections:
        assert section["start_page"] > previous_end
        assert section["end_page"] >= section["start_page"]
        previous_end = section["end_page"]
    assert [s["title"] for s in sections] == ["A", "B"]


def test_sweep_removes_only_stale_tmp_files(isolated_audiobooks_dir):
    book_dir = os.path.join(isolated_audiobooks_dir, "book")
    os.makedirs(os.path.join(book_dir, "pages"))
    stale = os.path.join(book_dir, "pages", "1.txt.abc.tmp")
    fresh = os.path.join(book_dir, "pages", "2.txt.def.tmp")
    keeper = os.path.join(book_dir, "pages", "3.txt")
    stale_keeper = os.path.join(book_dir, "meta.json")
    for path in (stale, fresh, keeper, stale_keeper):
        with open(path, "w") as f:
            f.write("x")
    old = time.time() - 7200
    os.utime(stale, (old, old))
    os.utime(stale_keeper, (old, old))

    removed = AudiobookService.sweep_stale_tmp_files(isolated_audiobooks_dir)

    assert removed == 1
    assert not os.path.exists(stale)
    assert os.path.exists(fresh)
    assert os.path.exists(keeper)
    assert os.path.exists(stale_keeper)


@pytest.mark.asyncio
async def test_resume_in_progress_sweeps_stale_tmp_files(isolated_audiobooks_dir):
    bid = AudiobookStore.create_book("Old.txt")
    stale = os.path.join(AudiobookStore.book_dir(bid), "audio.wav.tmp")
    with open(stale, "w") as f:
        f.write("x")
    old = time.time() - 7200
    os.utime(stale, (old, old))

    await AudiobookService.resume_in_progress()

    assert not os.path.exists(stale)
