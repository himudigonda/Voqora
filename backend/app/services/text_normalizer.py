"""strip_markdown_for_narration — Markdown-to-narration conversion.

Used only by the local-first (no-Gemini) audiobook cleanup path, where raw
extracted text (e.g. from a .md source) is narrated with no LLM pass. This
does two things, both required for the result to sound like real narration
rather than a character-by-character transcript of source formatting:

1. Strips Markdown syntax markers so literal symbols (#, **, *, `, >, |)
   never reach the TTS phonemizer and get vocalized as literal words (e.g.
   a stray "#" read as "pound", a stray "*" as "asterisk").
2. Converts structural Markdown (lists, tables) into actual spoken sentences
   — "First, ... Second, ..." for lists, "The following is a table. X is Y,
   ... End of table." for tables — rather than just deleting the markers
   and leaving disjoint fragments.

Not used on the Gemini cleanup path: GEMINI_CLEAN_SYSTEM_PROMPT handles this
via its own instructions instead, using the same table/list phrasing so the
two paths sound consistent regardless of which one narrated a given book.
"""

import html
import re

_CODE_FENCE_LINE_RE = re.compile(r"^ {0,3}```")
_HTML_TAG_RE = re.compile(r"<[^>]+>")
_IMAGE_RE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
_LINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
_HEADER_LINE_RE = re.compile(r"^ {0,3}#{1,6}\s+(.*)$")
_BLOCKQUOTE_LINE_RE = re.compile(r"^ {0,3}>+\s?")
_HR_LINE_RE = re.compile(r"^ {0,3}(?:-{3,}|\*{3,}|_{3,})\s*$")
_UNORDERED_ITEM_RE = re.compile(r"^ {0,3}[-*+]\s+(.*)$")
_ORDERED_ITEM_RE = re.compile(r"^ {0,3}\d+[.)]\s+(.*)$")
_BOLD_RE = re.compile(r"\*\*(.+?)\*\*|__(.+?)__")
_ITALIC_RE = re.compile(
    r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)|(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"
)
_INLINE_CODE_RE = re.compile(r"`([^`]*)`")
_SEP_CELL_RE = re.compile(r"^:?-{1,}:?$")

_ORDINALS = [
    "First",
    "Second",
    "Third",
    "Fourth",
    "Fifth",
    "Sixth",
    "Seventh",
    "Eighth",
    "Ninth",
    "Tenth",
]


def _ordinal(i: int) -> str:
    return _ORDINALS[i] if i < len(_ORDINALS) else f"Item {i + 1}"


def _first_group(m: re.Match) -> str:
    return next(g for g in m.groups() if g is not None)


def _inline_clean(text: str) -> str:
    """Strip inline (single-line) Markdown syntax, keeping the words."""
    t = _IMAGE_RE.sub(r"\1", text)
    t = _LINK_RE.sub(r"\1", t)
    t = _BOLD_RE.sub(_first_group, t)
    t = _ITALIC_RE.sub(_first_group, t)
    t = _INLINE_CODE_RE.sub(r"\1", t)
    return t


def _split_row(line: str) -> list[str]:
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip() for c in s.split("|")]


def _is_separator_row(line: str) -> bool:
    cells = _split_row(line)
    if not cells or all(c == "" for c in cells):
        return False
    return all(_SEP_CELL_RE.match(c) for c in cells if c != "")


def _parse_table_block(lines: list[str], start: int) -> tuple[str | None, int]:
    """lines[start] is a header row; lines[start + 1] must be its separator.

    Returns (spoken sentence, index after the table) or (None, start) if
    this isn't actually a well-formed table (falls back to line-by-line
    handling, which still strips the stray pipes so nothing is vocalized).
    """
    headers = [_inline_clean(h) for h in _split_row(lines[start])]
    i = start + 2
    rows: list[list[str]] = []
    while i < len(lines) and lines[i].strip() and "|" in lines[i]:
        rows.append([_inline_clean(c) for c in _split_row(lines[i])])
        i += 1
    if not rows:
        return None, start

    parts = ["The following is a table."]
    for row in rows:
        cells = []
        for idx, value in enumerate(row):
            if not value:
                continue
            header = headers[idx] if idx < len(headers) else ""
            cells.append(f"{header} is {value}" if header else value)
        if cells:
            parts.append(", ".join(cells) + ".")
    parts.append("End of table.")
    return " ".join(parts), i


def _parse_list_block(
    lines: list[str], start: int, item_re: re.Pattern
) -> tuple[str | None, int]:
    items: list[str] = []
    i = start
    while i < len(lines):
        m = item_re.match(lines[i])
        if not m:
            break
        item_text = _inline_clean(m.group(1)).strip()
        if item_text:
            items.append(item_text)
        i += 1
    if not items:
        return None, start
    if len(items) == 1:
        return items[0], i
    sentence = " ".join(f"{_ordinal(n)}, {item}." for n, item in enumerate(items))
    return sentence, i


def strip_markdown_for_narration(text: str) -> str:
    """Convert Markdown source text into natural narration text.

    Best-effort: unmatched/ambiguous inline symbols (e.g. a stray "*" used
    as a multiplication sign) are left as-is rather than risking deletion
    of real content.
    """
    if not text:
        return text

    unescaped = html.unescape(text)
    unescaped = _HTML_TAG_RE.sub("", unescaped)
    lines = unescaped.replace("\r\n", "\n").replace("\r", "\n").split("\n")

    out: list[str] = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]

        if _CODE_FENCE_LINE_RE.match(line):
            i += 1
            while i < n and not _CODE_FENCE_LINE_RE.match(lines[i]):
                i += 1
            i += 1  # skip the closing fence too
            continue

        if not line.strip():
            out.append("")
            i += 1
            continue

        if _HR_LINE_RE.match(line):
            i += 1
            continue

        if i + 1 < n and "|" in line and _is_separator_row(lines[i + 1]):
            sentence, next_i = _parse_table_block(lines, i)
            if sentence is not None:
                out.append(sentence)
                i = next_i
                continue

        item_re = None
        if _UNORDERED_ITEM_RE.match(line):
            item_re = _UNORDERED_ITEM_RE
        elif _ORDERED_ITEM_RE.match(line):
            item_re = _ORDERED_ITEM_RE
        if item_re is not None:
            sentence, next_i = _parse_list_block(lines, i, item_re)
            if sentence is not None:
                out.append(sentence)
                i = next_i
                continue

        header_match = _HEADER_LINE_RE.match(line)
        if header_match:
            out.append(_inline_clean(header_match.group(1)).strip())
            i += 1
            continue

        bq_match = _BLOCKQUOTE_LINE_RE.match(line)
        if bq_match:
            out.append(_inline_clean(line[bq_match.end() :]).strip())
            i += 1
            continue

        out.append(_inline_clean(line))
        i += 1

    result = "\n".join(out)
    # Any stray/malformed pipe that wasn't part of a recognized table.
    result = result.replace("|", " ")
    result = re.sub(r"[ \t]+", " ", result)
    result = re.sub(r"\n{3,}", "\n\n", result)
    return result.strip()
