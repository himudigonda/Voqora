import math

from hypothesis import given, settings
from hypothesis import strategies as st

from app.services.transcript_export import (
    MAX_CUE_LINE_CHARS,
    MAX_CUE_LINES,
    Cue,
    TimedLine,
    build_cues,
    chapter_markers,
    format_srt,
    format_vtt,
    transcript_lines,
    with_word_timings,
    word_timings,
)


def _transcript(*pages: list[dict]) -> dict:
    return {"lines": {str(n): lines for n, lines in enumerate(pages, start=1)}}


def _line(text: str, start: float, end: float, paragraph: int = 0) -> dict:
    return {"paragraph": paragraph, "text": text, "start": start, "end": end}


# ---------- timestamps and formats ----------


def test_srt_formats_cues_with_comma_milliseconds_and_blank_line_separators():
    cues = [Cue(0, 1500, ("Hello there.",)), Cue(1500, 3000, ("Second", "line."))]

    assert format_srt(cues) == (
        "1\n00:00:00,000 --> 00:00:01,500\nHello there.\n\n"
        "2\n00:00:01,500 --> 00:00:03,000\nSecond\nline.\n\n"
    )


def test_vtt_has_header_dot_milliseconds_and_escapes_markup():
    cues = [Cue(0, 1000, ("Fish & chips <b>now</b> --> later",))]

    assert format_vtt(cues) == (
        "WEBVTT\n\n"
        "1\n00:00:00.000 --> 00:00:01.000\n"
        "Fish &amp; chips &lt;b&gt;now&lt;/b&gt; --&gt; later\n\n"
    )


def test_timestamps_beyond_one_hour_and_ten_hours():
    lines = [
        TimedLine("Late line.", 3661.5, 3662.25),
        TimedLine("Very late.", 36000.0, 86399.999),
    ]

    srt = format_srt(build_cues(lines))

    assert "01:01:01,500 --> 01:01:02,250" in srt
    assert "10:00:00,000 --> 23:59:59,999" in srt


def test_timestamps_round_to_the_nearest_millisecond():
    srt = format_srt(build_cues([TimedLine("Rounded.", 0.0004, 1.9996)]))

    assert "00:00:00,000 --> 00:00:02,000" in srt


def test_empty_transcript_exports_empty_but_valid_documents():
    cues = build_cues(transcript_lines({"lines": {}}))

    assert cues == []
    assert format_srt(cues) == ""
    assert format_vtt(cues) == "WEBVTT\n\n"
    assert transcript_lines({}) == []
    assert transcript_lines({"lines": ["not", "a", "dict"]}) == []


# ---------- wrapping and cue splitting ----------


def test_long_sentence_wraps_at_42_chars_and_two_lines_per_cue():
    text = " ".join(f"word{n:02d}" for n in range(40))
    cues = build_cues([TimedLine(text, 10.0, 30.0)])

    assert len(cues) > 1
    for cue in cues:
        assert 1 <= len(cue.lines) <= MAX_CUE_LINES
        assert all(len(line) <= MAX_CUE_LINE_CHARS for line in cue.lines)
    assert " ".join(" ".join(cue.lines) for cue in cues) == text
    assert cues[0].start_ms == 10_000
    assert cues[-1].end_ms == 30_000
    for previous, current in zip(cues, cues[1:], strict=False):
        assert previous.end_ms == current.start_ms


def test_cue_time_is_split_in_proportion_to_text_length():
    text = ("a" * 40 + " ") * 2 + "b" * 40
    cues = build_cues([TimedLine(text, 0.0, 3.0)])

    assert [cue.lines for cue in cues] == [("a" * 40, "a" * 40), ("b" * 40,)]
    assert cues[0].end_ms == 2000


def test_word_longer_than_a_line_is_broken():
    cues = build_cues([TimedLine("x" * 100, 0.0, 1.0)])

    assert all(len(line) <= MAX_CUE_LINE_CHARS for cue in cues for line in cue.lines)
    assert "".join("".join(cue.lines) for cue in cues) == "x" * 100


def test_whitespace_inside_a_line_is_collapsed():
    cues = build_cues(transcript_lines(_transcript([_line("A\n\tB   C", 0, 1)])))

    assert cues == [Cue(0, 1000, ("A B C",))]


# ---------- ordering and overlap ----------


def test_cues_never_overlap_even_when_source_lines_do():
    lines = [
        TimedLine("First.", 0.0, 2.0),
        TimedLine("Overlapping.", 1.0, 3.0),
        TimedLine("Swallowed.", 1.5, 2.5),
        TimedLine("After.", 3.0, 4.0),
    ]

    cues = build_cues(lines)

    assert [cue.lines[0] for cue in cues] == ["First.", "Overlapping.", "After."]
    for previous, current in zip(cues, cues[1:], strict=False):
        assert previous.end_ms <= current.start_ms
    assert cues[1].start_ms == 2000


def test_zero_length_lines_are_dropped():
    cues = build_cues([TimedLine("Silent.", 1.0, 1.0), TimedLine("Spoken.", 1.0, 2.0)])

    assert [cue.lines for cue in cues] == [("Spoken.",)]


def test_pages_are_read_in_numeric_order():
    transcript = {
        "lines": {
            "10": [_line("Ten.", 10, 11)],
            "2": [_line("Two.", 2, 3)],
            "1": [_line("One.", 0, 1)],
        }
    }

    texts = [line.text for line in transcript_lines(transcript)]

    assert texts == ["One.", "Two.", "Ten."]


def test_malformed_lines_are_skipped():
    transcript = _transcript(
        [
            "not a dict",
            {"text": 5, "start": 0, "end": 1},
            {"text": "   ", "start": 0, "end": 1},
            {"text": "NaN.", "start": math.nan, "end": 1},
            {"text": "Neg.", "start": -1, "end": 1},
            {"text": "Back.", "start": 2, "end": 1},
            {"text": "Bool.", "start": True, "end": 2},
            {"text": "Missing end.", "start": 0},
            _line("Good.", 0, 1),
        ]
    )
    transcript["lines"]["2"] = "not a list"

    assert [line.text for line in transcript_lines(transcript)] == ["Good."]


def test_heading_lines_are_their_own_cue():
    transcript = _transcript(
        [
            _line("Chapter One", 0.0, 1.0, paragraph=0),
            _line("It began on a Tuesday.", 1.0, 3.0, paragraph=1),
        ]
    )

    cues = build_cues(transcript_lines(transcript))

    assert [cue.lines for cue in cues] == [
        ("Chapter One",),
        ("It began on a Tuesday.",),
    ]


def test_unicode_text_survives_both_formats():
    lines = [
        TimedLine("Café déjà vu.", 0.0, 1.0),
        TimedLine("你好，世界。", 1.0, 2.0),
        TimedLine("Emoji 🎧 ok.", 2.0, 3.0),
    ]

    cues = build_cues(lines)

    for document in (format_srt(cues), format_vtt(cues)):
        assert "Café déjà vu." in document
        assert "你好，世界。" in document
        assert "🎧" in document
        document.encode("utf-8")


@settings(max_examples=60, deadline=None)
@given(
    st.lists(
        st.tuples(
            st.text(min_size=1, max_size=200),
            st.floats(min_value=0, max_value=90_000),
            st.floats(min_value=0, max_value=600),
        ),
        max_size=25,
    )
)
def test_cue_invariants_hold_for_arbitrary_lines(raw):
    lines = [TimedLine(" ".join(t.split()), s, s + d) for t, s, d in raw if t.split()]

    cues = build_cues(sorted(lines, key=lambda line: line.start))

    for cue in cues:
        assert cue.start_ms < cue.end_ms
        assert 1 <= len(cue.lines) <= MAX_CUE_LINES
        assert all(len(line) <= MAX_CUE_LINE_CHARS for line in cue.lines)
    for previous, current in zip(cues, cues[1:], strict=False):
        assert previous.end_ms <= current.start_ms


# ---------- word timings ----------


def test_words_split_duration_by_spoken_length_with_punctuation_attached():
    words = word_timings("Hi, there!", 1.0, 2.4)

    assert words == [
        {"text": "Hi,", "start": 1.0, "end": 1.4},
        {"text": "there!", "start": 1.4, "end": 2.4},
    ]


def test_standalone_punctuation_joins_the_previous_word():
    words = word_timings("Wait — what ?", 0.0, 1.0)

    assert [word["text"] for word in words] == ["Wait —", "what ?"]


def test_leading_punctuation_joins_the_first_word():
    words = word_timings("— Well then", 0.0, 1.0)

    assert [word["text"] for word in words] == ["— Well", "then"]


def test_punctuation_only_sentence_is_one_word():
    assert word_timings(" ... ", 0.0, 1.0) == [
        {"text": "...", "start": 0.0, "end": 1.0}
    ]
    assert word_timings("", 0.0, 1.0) == []
    assert word_timings("   ", 0.0, 1.0) == []


def test_cjk_text_is_timed_per_character():
    words = word_timings("你好。世界", 0.0, 4.0)

    assert [word["text"] for word in words] == ["你", "好。", "世", "界"]
    assert [word["end"] for word in words] == [1.0, 2.0, 3.0, 4.0]


def test_custom_weight_such_as_phoneme_count_is_used():
    phonemes = {"strengths": 8, "a": 1}

    words = word_timings("strengths a", 0.0, 0.9, weight=lambda w: phonemes[w])

    assert words[0]["end"] == 0.8


def test_words_are_monotonic_and_inside_the_sentence():
    text = "The quick brown fox, jumps over the lazy dog; twice!"
    words = word_timings(text, 12.345, 15.678)

    assert words[0]["start"] == 12.345
    assert words[-1]["end"] == 15.678
    for word in words:
        assert 12.345 <= word["start"] <= word["end"] <= 15.678
    for previous, current in zip(words, words[1:], strict=False):
        assert previous["end"] == current["start"]


def test_zero_duration_sentence_gives_zero_length_words():
    words = word_timings("one two", 5.0, 5.0)

    assert all(word["start"] == word["end"] == 5.0 for word in words)


def test_with_word_timings_adds_words_without_dropping_fields():
    transcript = {
        "book_id": "abc",
        "lines": {
            "1": [_line("Hello world.", 0.0, 1.0), "junk"],
            "2": "not a list",
        },
    }

    timed = with_word_timings(transcript)

    first = timed["lines"]["1"][0]
    assert first["paragraph"] == 0 and first["text"] == "Hello world."
    assert [word["text"] for word in first["words"]] == ["Hello", "world."]
    assert timed["lines"]["1"][1] == "junk"
    assert "words" not in transcript["lines"]["1"][0]
    assert timed["book_id"] == "abc"
    assert with_word_timings({"lines": None}) == {"lines": None}


# ---------- chapters ----------


def test_chapters_are_contiguous_and_cover_the_whole_book():
    transcript = {
        "total_audio_seconds": 100.0,
        "sections": [
            {"title": "One", "start_page": 1, "start_time": 0.0},
            {"title": "Two", "start_page": 3, "start_time": 40.5},
            {"title": "Three", "start_page": 5, "start_time": 70.0},
        ],
    }

    assert chapter_markers(transcript, "Book") == [
        {"title": "One", "start_seconds": 0.0, "end_seconds": 40.5},
        {"title": "Two", "start_seconds": 40.5, "end_seconds": 70.0},
        {"title": "Three", "start_seconds": 70.0, "end_seconds": 100.0},
    ]


def test_chapters_fall_back_to_page_times_sort_and_clamp():
    transcript = {
        "total_audio_seconds": 50.0,
        "page_to_time": {"1": 0.0, "4": 20.0},
        "sections": [
            {"title": "Late", "start_page": 9, "start_time": 80.0},
            {"title": "  Spaced \n title ", "start_page": 4},
            {"title": "", "start_page": 1, "start_time": 5.0},
            "junk",
            {"title": "No time", "start_page": 7},
        ],
    }

    assert chapter_markers(transcript, "Book") == [
        {"title": "Untitled", "start_seconds": 0.0, "end_seconds": 20.0},
        {"title": "Spaced title", "start_seconds": 20.0, "end_seconds": 50.0},
    ]


def test_sections_sharing_a_start_keep_the_last_one():
    transcript = {
        "total_audio_seconds": 10.0,
        "sections": [
            {"title": "Front Matter", "start_time": 0.0},
            {"title": "Chapter 1", "start_time": 0.0},
        ],
    }

    assert [c["title"] for c in chapter_markers(transcript, "Book")] == ["Chapter 1"]


def test_chapters_use_fallback_title_and_handle_empty_books():
    assert chapter_markers({"total_audio_seconds": 12.0}, "My Book") == [
        {"title": "My Book", "start_seconds": 0.0, "end_seconds": 12.0}
    ]
    assert chapter_markers({"total_audio_seconds": 0, "sections": []}, "B") == []
    assert chapter_markers({}, "B") == []
    assert chapter_markers({"total_audio_seconds": "x"}, "B") == []


def test_chapter_titles_are_bounded():
    transcript = {
        "total_audio_seconds": 1.0,
        "sections": [{"title": "T" * 500, "start_time": 0.0}],
    }

    assert len(chapter_markers(transcript, "B")[0]["title"]) == 200
