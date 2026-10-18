"""Subtitle, chapter, and word-timing views over a finished transcript.

Pure functions over the persisted `transcript.json` shape, so every export
reads the same sentence timings the player highlights with.
"""

from __future__ import annotations

import math
import re
import textwrap
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

MAX_CUE_LINE_CHARS = 42
MAX_CUE_LINES = 2
MAX_CHAPTER_TITLE_CHARS = 200

_CJK = "぀-ヿ㐀-䶿一-鿿豈-﫿가-힯"
_TOKEN = re.compile(rf"[{_CJK}]|[^\s{_CJK}]+")
_VTT_ESCAPES = str.maketrans({"&": "&amp;", "<": "&lt;", ">": "&gt;"})


@dataclass(frozen=True, slots=True)
class TimedLine:
    text: str
    start: float
    end: float


@dataclass(frozen=True, slots=True)
class Cue:
    start_ms: int
    end_ms: int
    lines: tuple[str, ...]


def transcript_lines(transcript: dict[str, Any]) -> list[TimedLine]:
    pages = transcript.get("lines")
    if not isinstance(pages, dict):
        return []
    lines: list[TimedLine] = []
    for key in sorted(pages, key=_page_order):
        entries = pages[key]
        if not isinstance(entries, list):
            continue
        lines.extend(line for line in map(_timed_line, entries) if line is not None)
    return sorted(lines, key=lambda line: line.start)


def build_cues(lines: list[TimedLine]) -> list[Cue]:
    cues: list[Cue] = []
    floor_ms = 0
    for line in lines:
        for start_ms, end_ms, text_lines in _split_line(line):
            start_ms = max(start_ms, floor_ms)
            if end_ms <= start_ms:
                continue
            cues.append(Cue(start_ms, end_ms, text_lines))
            floor_ms = end_ms
    return cues


def format_srt(cues: list[Cue]) -> str:
    blocks = [
        f"{index}\n{_timestamp(cue.start_ms, ',')} --> "
        f"{_timestamp(cue.end_ms, ',')}\n" + "\n".join(cue.lines)
        for index, cue in enumerate(cues, start=1)
    ]
    return "".join(f"{block}\n\n" for block in blocks)


def format_vtt(cues: list[Cue]) -> str:
    blocks = [
        f"{index}\n{_timestamp(cue.start_ms, '.')} --> "
        f"{_timestamp(cue.end_ms, '.')}\n"
        + "\n".join(line.translate(_VTT_ESCAPES) for line in cue.lines)
        for index, cue in enumerate(cues, start=1)
    ]
    return "WEBVTT\n\n" + "".join(f"{block}\n\n" for block in blocks)


def chapter_markers(
    transcript: dict[str, Any], fallback_title: str
) -> list[dict[str, Any]]:
    total = total_audio_seconds(transcript)
    if total <= 0:
        return []
    page_to_time = transcript.get("page_to_time")
    if not isinstance(page_to_time, dict):
        page_to_time = {}
    sections = transcript.get("sections")
    starts = sorted(
        (
            (min(start, total), title)
            for start, title in (
                _section_start(section, page_to_time)
                for section in (sections if isinstance(sections, list) else [])
            )
            if start is not None
        ),
        key=lambda entry: entry[0],
    )
    markers: list[dict[str, Any]] = []
    for index, (start, title) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else total
        if end <= start:
            continue
        markers.append(
            {
                "title": title,
                "start_seconds": 0.0 if not markers else round(start, 3),
                "end_seconds": round(end, 3),
            }
        )
    if not markers:
        title = starts[-1][1] if starts else _clean_title(fallback_title)
        markers.append(
            {"title": title, "start_seconds": 0.0, "end_seconds": round(total, 3)}
        )
    return markers


def total_audio_seconds(transcript: dict[str, Any]) -> float:
    return _non_negative(transcript.get("total_audio_seconds")) or 0.0


def word_timings(
    text: str,
    start: float,
    end: float,
    weight: Callable[[str], int] | None = None,
) -> list[dict[str, Any]]:
    words = _words(text)
    if not words:
        return []
    measure = weight or spoken_length
    weights = [max(1, measure(word)) for word in words]
    total = sum(weights)
    begin = round(start, 3)
    duration = max(0.0, round(end, 3) - begin)
    timings: list[dict[str, Any]] = []
    previous = begin
    cumulative = 0
    for word, share in zip(words, weights, strict=True):
        cumulative += share
        boundary = round(begin + duration * cumulative / total, 3)
        timings.append({"text": word, "start": previous, "end": boundary})
        previous = boundary
    return timings


def with_word_timings(transcript: dict[str, Any]) -> dict[str, Any]:
    pages = transcript.get("lines")
    if not isinstance(pages, dict):
        return transcript
    timed_pages = {
        key: [_line_with_words(line) for line in entries]
        for key, entries in pages.items()
        if isinstance(entries, list)
    }
    return {**transcript, "lines": timed_pages}


def spoken_length(word: str) -> int:
    return sum(1 for char in word if char.isalnum())


def _line_with_words(line: Any) -> Any:
    timed = _timed_line(line)
    if timed is None:
        return line
    return {**line, "words": word_timings(line["text"], timed.start, timed.end)}


def _words(text: str) -> list[str]:
    words: list[str] = []
    leading: int | None = None
    span_start = 0
    for match in _TOKEN.finditer(text):
        if spoken_length(match.group()) == 0:
            if words:
                words[-1] = text[span_start : match.end()]
            elif leading is None:
                leading = match.start()
            continue
        span_start = match.start() if leading is None else leading
        leading = None
        words.append(text[span_start : match.end()])
    if not words and leading is not None:
        words.append(text[leading:].strip())
    return words


def _split_line(line: TimedLine) -> list[tuple[int, int, tuple[str, ...]]]:
    wrapped = textwrap.wrap(
        line.text,
        width=MAX_CUE_LINE_CHARS,
        break_long_words=True,
        break_on_hyphens=False,
    )
    chunks = [
        tuple(wrapped[index : index + MAX_CUE_LINES])
        for index in range(0, len(wrapped), MAX_CUE_LINES)
    ]
    start_ms = _milliseconds(line.start)
    end_ms = _milliseconds(line.end)
    weights = [sum(len(part) for part in chunk) for chunk in chunks]
    total = sum(weights) or 1
    pieces: list[tuple[int, int, tuple[str, ...]]] = []
    cumulative = 0
    previous = start_ms
    for chunk, share in zip(chunks, weights, strict=True):
        cumulative += share
        boundary = start_ms + round((end_ms - start_ms) * cumulative / total)
        pieces.append((previous, boundary, chunk))
        previous = boundary
    return pieces


def _timed_line(line: Any) -> TimedLine | None:
    if not isinstance(line, dict):
        return None
    text = line.get("text")
    if not isinstance(text, str):
        return None
    text = " ".join(text.split())
    start = _non_negative(line.get("start"))
    end = _non_negative(line.get("end"))
    if not text or start is None or end is None or end < start:
        return None
    return TimedLine(text, start, end)


def _section_start(
    section: Any, page_to_time: dict[str, Any]
) -> tuple[float | None, str]:
    if not isinstance(section, dict):
        return None, ""
    start = _non_negative(section.get("start_time"))
    if start is None:
        start = _non_negative(page_to_time.get(str(section.get("start_page"))))
    return start, _clean_title(section.get("title"))


def _clean_title(value: Any) -> str:
    title = " ".join(str(value or "").split())[:MAX_CHAPTER_TITLE_CHARS]
    return title or "Untitled"


def _non_negative(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if not math.isfinite(number) or number < 0:
        return None
    return number


def _page_order(key: Any) -> tuple[int, int, str]:
    text = str(key)
    if text.isascii() and text.isdigit():
        return 0, int(text), ""
    return 1, 0, text


def _milliseconds(seconds: float) -> int:
    return int(round(seconds * 1000))


def _timestamp(ms: int, separator: str) -> str:
    hours, remainder = divmod(ms, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    seconds, millis = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}{separator}{millis:03d}"
