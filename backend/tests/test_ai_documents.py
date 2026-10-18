from __future__ import annotations

import os
import shutil
import tempfile

import pytest
from ai_fakes import make_book
from pydantic import ValidationError

from app.services import ai_reader
from app.services.ai_documents import load_book_text
from app.services.ai_errors import AIToolError
from app.services.ai_reader import Citation, _AnswerOutput, _citations
from app.services.ai_retrieval import Passage
from app.services.audiobook_store import AudiobookStore


@pytest.fixture(autouse=True)
def isolated_library(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="ss_ai_docs_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


def test_malformed_sections_are_ignored_and_pages_keep_their_numbers():
    book_id = make_book(
        ["One.", "Two.", "Three."],
        sections=[
            "not a dict",
            {"title": "Broken", "start_page": "x"},
            {"title": "  ", "start_page": 1, "end_page": 3},
            {"title": "Second", "start_page": 2},
        ],
    )
    book = load_book_text(book_id)
    assert [(p.page, p.section_title) for p in book.pages] == [
        (1, ""),
        (2, "Second"),
        (3, ""),
    ]
    assert book.joined() == "One.\n\nSecond\n\nTwo.\n\nThree."


def test_page_count_is_capped_by_the_import_limit(monkeypatch):
    book_id = make_book(["A.", "B.", "C."])
    monkeypatch.setattr("app.services.ai_documents.settings.MAX_AUDIOBOOK_PAGES", 2)
    assert [p.page for p in load_book_text(book_id).pages] == [1, 2]


def test_a_book_directory_that_escapes_the_library_is_refused(isolated_library):
    book_id = make_book(["Inside."])
    outside = tempfile.mkdtemp(prefix="ss_ai_outside_")
    try:
        book_dir = AudiobookStore.book_dir(book_id)
        shutil.copytree(book_dir, os.path.join(outside, book_id))
        shutil.rmtree(book_dir)
        os.symlink(os.path.join(outside, book_id), book_dir)
        with pytest.raises(AIToolError) as caught:
            load_book_text(book_id)
        assert caught.value.status == 404
    finally:
        shutil.rmtree(outside, ignore_errors=True)


def test_long_quotes_and_fallback_quotes_are_bounded():
    passage = Passage(0, 4, "", "word " * 200)
    reply = _AnswerOutput(
        answer="a", citations=[{"passage": 1, "quote": "word " * 100}]
    )
    [citation] = _citations(reply, [passage])
    assert isinstance(citation, Citation)
    assert len(citation.quote) <= ai_reader._QUOTE_CHARS
    assert citation.quote.endswith("…")
    assert citation.section_title is None


@pytest.mark.parametrize("bad", ["", "   ", "x" * 501])
def test_quiz_choices_must_be_non_empty_and_bounded(bad):
    with pytest.raises(ValidationError):
        ai_reader.QuizQuestion(
            question="Q?", choices=["a", "b", "c", bad], answer_index=0
        )
