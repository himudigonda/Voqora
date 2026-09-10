"""strip_markdown_for_narration — Markdown-to-narration conversion.

The single canonical text-cleaning pass for everything Voqora narrates. Every
path that produces spoken audio runs text through here before it reaches the
phonemizer:

* the audiobook cleaning phase, on *every* branch — Gemini success, Gemini
  timeout, Gemini error, cost-capped, and the local-first no-LLM default
  (audiobook_service._phase_clean);
* the interactive /speak endpoint (api.tts.speak), so the backend is safe
  regardless of what a client sends.

It does two things, both required for the result to sound like real narration
rather than a character-by-character transcript of source formatting:

1. Strips Markdown syntax markers so literal symbols (#, **, *, `, >, |, ~)
   never reach the TTS phonemizer and get vocalized as literal words (e.g.
   a stray "#" read as "pound", a stray "*" as "asterisk").
2. Converts structural Markdown (lists, tables) into actual spoken sentences
   — "First, ... Second, ..." for lists, "The following is a table. X is Y,
   ... End of table." for tables — rather than just deleting the markers
   and leaving disjoint fragments.

Two properties matter as much as the stripping itself, and both are pinned by
tests:

* **Idempotence.** f(f(x)) == f(x). Already-clean text (e.g. Gemini's output)
  must pass through unchanged, because this now runs as a final pass over
  every branch including the ones that already cleaned their text.
* **Preservation.** Removing too much is a worse failure than leaving a symbol
  in: a deleted sentence is silent and undetectable, while a spoken "asterisk"
  at least announces itself. Rules here are deliberately conservative and
  anchored — see _HTML_TAG_RE and _ITALIC_RE, both of which previously ate
  ordinary prose.
"""

import html
import re

# ---------------------------------------------------------------- block-level

_CODE_FENCE_LINE_RE = re.compile(r"^ {0,3}(?:```|~~~)")

# Anchored to something that actually looks like an HTML tag: "<", an optional
# "/", then a letter. Crucially the body excludes newlines and further angle
# brackets. The previous pattern was r"<[^>]+>", where [^>] also matches "\n",
# so the span from the first "<" in a document to the next ">" *anywhere* —
# across paragraphs — was deleted with no warning. That silently destroyed any
# prose using inequalities or generic types:
#   "If x < y then swap them. Otherwise if a > b, stop." -> "If x b, stop."
#   "Use List<int> and Map<String, Value>."  -> "Use List and Map."
# on the default (local-first) narration path.
# Only *known* HTML element names are treated as tags. Matching any
# letter-led name instead would delete generic-type syntax that happens to look
# like one -- "List<int>" reads as a tag named "int" and vanished, while
# "Map<String, Value>" survived only because of its comma. An allowlist makes
# the two behave consistently and keeps the rule from inventing tags.
_HTML_ELEMENTS = (
    "a|abbr|address|article|aside|audio|b|blockquote|body|br|button|canvas|"
    "caption|cite|code|col|colgroup|dd|del|details|div|dl|dt|em|embed|fieldset|"
    "figcaption|figure|footer|form|h1|h2|h3|h4|h5|h6|head|header|hr|html|i|"
    "iframe|img|input|ins|kbd|label|legend|li|link|main|map|mark|meta|nav|"
    "object|ol|optgroup|option|p|param|picture|pre|q|s|samp|script|section|"
    "select|small|source|span|strong|style|sub|summary|sup|table|tbody|td|"
    "textarea|tfoot|th|thead|time|title|tr|track|u|ul|var|video|wbr"
)
_HTML_TAG_RE = re.compile(
    r"</?(?:" + _HTML_ELEMENTS + r")(?:\s[^<>\n]*)?/?>", re.IGNORECASE
)
_HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)

# A bare autolink has no label to speak, and reading a raw URL aloud is worse
# than skipping it — narrators skip URLs. Dropped explicitly here rather than
# as an accidental side effect of the HTML-tag rule.
_AUTOLINK_RE = re.compile(r"<(?:https?://|mailto:)[^<>\s]*>")

_IMAGE_RE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
_LINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
_REF_LINK_RE = re.compile(r"\[([^\]]+)\]\[[^\]]*\]")
_LINK_DEF_LINE_RE = re.compile(r"^ {0,3}\[[^\]^]+\]:\s*\S+.*$")
_FOOTNOTE_DEF_LINE_RE = re.compile(r"^ {0,3}\[\^[^\]]+\]:\s*(.*)$")
_FOOTNOTE_REF_RE = re.compile(r"\[\^[^\]]+\]")

# Trailing "#"s are valid CommonMark ATX closing syntax. "\s*" (not "\s+")
# after the opening run so "#NoSpaceHeading" — which a phonemizer would read
# as "hash NoSpaceHeading" — is caught too.
_HEADER_LINE_RE = re.compile(r"^ {0,3}#{1,6}\s*(.*?)\s*#*\s*$")
_SETEXT_UNDERLINE_RE = re.compile(r"^ {0,3}(?:={2,}|-{2,})\s*$")

_BLOCKQUOTE_LINE_RE = re.compile(r"^ {0,3}>+\s?")
_HR_LINE_RE = re.compile(r"^ {0,3}(?:-{3,}|\*{3,}|_{3,}|={3,})\s*$")

# A table separator row orphaned from its header — e.g. because split_pages cut
# the table across a page boundary. Without this it narrates as "dash dash dash".
_TABLE_RULE_LINE_RE = re.compile(r"^ {0,3}\|[\s:|-]*$|^ {0,3}[\s:-]*\|[\s:|-]*$")

# Leading whitespace is unbounded (was "^ {0,3}") so nested list items are
# recognized as items rather than left with a literal "-" to be spoken.
_UNORDERED_ITEM_RE = re.compile(r"^\s*[-*+]\s+(.*)$")
_ORDERED_ITEM_RE = re.compile(r"^\s*\d+[.)]\s+(.*)$")
_TASK_BOX_RE = re.compile(r"^\[[ xX]\]\s*")

_SEP_CELL_RE = re.compile(r"^:?-{1,}:?$")

# --------------------------------------------------------------- inline-level

_BOLD_RE = re.compile(r"\*\*(.+?)\*\*|__(.+?)__")

# Anchored so a delimiter must sit at a real word boundary and hug its content.
# The previous pattern paired the first delimiter on a line with the nearest
# later one anywhere on that line, corrupting ordinary text:
#   "Call get_user_name and max_retry_count." -> "Call getusername and maxretrycount."
#   "5 * 3 and 4 * 8"                         -> "5 3 and 4 8"   (operators gone)
# The character classes exclude the delimiter itself so a match can never span
# an intervening one.
_ITALIC_RE = re.compile(
    r"(?<![*\w])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![*\w])"
    r"|(?<![\w_])_(?!\s)([^_\n]+?)(?<!\s)_(?![\w_])"
)
_STRIKE_RE = re.compile(r"~~(.+?)~~")
_INLINE_CODE_RE = re.compile(r"`+([^`]*)`+")

# Emphasis that wraps a soft line break. Run as a bounded final pass, after the
# line-oriented work, because the line-level rules deliberately never match
# across "\n". Bounded length so a pair of unrelated "**"s far apart in a
# document can't swallow everything between them.
_BOLD_MULTILINE_RE = re.compile(r"\*\*([^*]{1,300}?)\*\*", re.DOTALL)

_ESCAPABLE = "\\`*_{}[]()#+-.!|~><"
_ESCAPE_RE = re.compile(r"\\([" + re.escape(_ESCAPABLE) + r"])")
_ESCAPE_SENTINELS = {c: chr(0xE000 + i) for i, c in enumerate(_ESCAPABLE)}
# Escaped markup characters are dropped rather than restored. An author writing
# "\\*not italic\\*" wants the asterisks seen, not obeyed -- but a narrator has no
# way to "show" one, and the phonemizer would just say "asterisk". Restoring
# them also broke idempotence: the restored "*" looked like real markup to a
# second pass, and this function now runs as a final pass over text an earlier
# stage may already have cleaned. Punctuation that reads naturally aloud is
# still restored.
_ESCAPE_DROPPED = set("`*_#~|")
_UNESCAPE_SENTINELS = {
    v: ("" if k in _ESCAPE_DROPPED else k) for k, v in _ESCAPE_SENTINELS.items()
}

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


def _protect_escapes(text: str) -> str:
    r"""Swap backslash-escaped punctuation for a private-use sentinel.

    An author writing "\*not italic\*" means the asterisks to be literal *and*
    unspoken. Without this the emphasis rule consumed them as markup anyway and
    left the backslashes behind, so the output was "\not italic\" — the exact
    opposite of both intents. Restored by _restore_escapes after all markup
    processing has run.
    """
    return _ESCAPE_RE.sub(lambda m: _ESCAPE_SENTINELS[m.group(1)], text)


def _restore_escapes(text: str) -> str:
    for sentinel, char in _UNESCAPE_SENTINELS.items():
        text = text.replace(sentinel, char)
    return text


def _inline_clean(text: str) -> str:
    """Strip inline (single-line) Markdown syntax, keeping the words."""
    t = _AUTOLINK_RE.sub("", text)
    t = _IMAGE_RE.sub(r"\1", t)
    t = _LINK_RE.sub(r"\1", t)
    t = _REF_LINK_RE.sub(r"\1", t)
    t = _FOOTNOTE_REF_RE.sub("", t)
    t = _BOLD_RE.sub(_first_group, t)
    t = _ITALIC_RE.sub(_first_group, t)
    t = _STRIKE_RE.sub(r"\1", t)
    t = _INLINE_CODE_RE.sub(r"\1", t)
    t = _TASK_BOX_RE.sub("", t)
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


def _parse_table_block(lines: list[str], start: int) -> tuple[list[str] | None, int]:
    """lines[start] is a header row; lines[start + 1] must be its separator.

    Returns (one spoken line per row, index after the table) or (None, start) if
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
    # One row per line. Newlines cost nothing in audio -- TTSEngine._split_segments
    # flattens them before synthesis -- but a whole table joined into a single
    # run-on line is unreadable in the transcript panel, which is where a reader
    # follows along.
    return parts, i


def _parse_list_block(
    lines: list[str], start: int, item_re: re.Pattern
) -> tuple[list[str] | None, int]:
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
        return [items[0]], i
    # One item per line. Joining every bullet into a single sentence is what made
    # a five-item list render as one dense paragraph blob in the transcript.
    return [f"{_ordinal(n)}, {item}." for n, item in enumerate(items)], i


def _ensure_blank_before(out: list[str]) -> None:
    """Open a block with a blank line so it doesn't run into the prose above it.

    The counterpart to _ensure_blank_separator, which only ever closed a block.
    Without this a heading was glued to the end of the preceding paragraph --
    separated below but not above -- so it read as the last line of that
    paragraph rather than the title of the next one.
    """
    if out and out[-1] != "":
        out.append("")


def _ensure_blank_separator(out: list[str], lines: list[str], next_i: int) -> None:
    """Force a blank line after a heading/list/table block so it reads as its
    own paragraph in the transcript, matching the script-style formatting the
    Gemini cleanup path now also produces — even when the source Markdown had
    no blank line of its own between that block and the next line."""
    if out and out[-1] != "" and next_i < len(lines) and lines[next_i].strip():
        out.append("")


def _strip_front_matter(lines: list[str]) -> list[str]:
    """Drop a leading YAML front-matter block.

    The "---" delimiters already matched the horizontal-rule rule, but the
    metadata between them matched no block rule at all and was narrated as the
    book's opening sentences ("title: My Book. author: Jane.").
    """
    if not lines or lines[0].strip() not in ("---", "+++"):
        return lines
    delim = lines[0].strip()
    for i in range(1, len(lines)):
        if lines[i].strip() == delim:
            return lines[i + 1 :]
    return lines


def _skip_fence(lines: list[str], i: int) -> int:
    """Return the index just past a fenced code block opening at `lines[i]`.

    If no closing fence exists — which happens routinely when split_pages cuts
    a fenced block across a page boundary — only the opening line is consumed.
    Previously the scanner ran to end-of-input looking for a close, silently
    swallowing the rest of the page's real prose.
    """
    n = len(lines)
    for j in range(i + 1, n):
        if _CODE_FENCE_LINE_RE.match(lines[j]):
            return j + 1
    return i + 1


def _skip_indented_code(lines: list[str], i: int) -> int:
    """Consume a 4-space-indented code block, mirroring fenced-block handling."""
    n = len(lines)
    j = i
    while j < n and (not lines[j].strip() or lines[j].startswith(("    ", "\t"))):
        j += 1
    while j > i and not lines[j - 1].strip():
        j -= 1
    return j


_SENTENCE_END = ".!?:;\"')]”’"


def _reflow(lines: list[str]) -> list[str]:
    """Join soft-wrapped lines, keep structural ones on their own line.

    A source document hard-wraps prose at some column, so a paragraph arrives as
    several lines that belong to one sentence. Those must be joined or the
    transcript shows mid-sentence breaks. But list items, table rows and
    headings are *deliberately* one per line, and joining those is what made a
    bullet list render as a single dense blob.

    The two are told apart by how the previous line ends: a line broken
    mid-sentence ends on a word or a comma, while a complete one ends on
    terminal punctuation. So a line is appended to the previous only when the
    previous did not end a sentence.

    This is also what keeps the pass idempotent. A naive "join every consecutive
    line" would merge the very list items this function just put on separate
    lines the moment it ran a second time -- and it now runs as a final pass
    over text an earlier stage may already have cleaned.
    """
    out: list[str] = []
    for line in lines:
        if not line:
            out.append("")
            continue
        if out and out[-1] and out[-1][-1] not in _SENTENCE_END:
            out[-1] = f"{out[-1]} {line}"
        else:
            out.append(line)
    return out


def strip_markdown_for_narration(text: str) -> str:
    """Convert Markdown source text into natural narration text.

    Idempotent: running this over its own output is a no-op, so it is safe as a
    final pass over text another stage (Gemini) already cleaned.

    Conservative by design: unmatched/ambiguous inline symbols (e.g. a stray
    "*" used as a multiplication sign, a "<" used as "less than") are left
    as-is rather than risking deletion of real content.
    """
    if not text:
        return text

    unescaped = html.unescape(text)
    unescaped = _HTML_COMMENT_RE.sub("", unescaped)
    unescaped = _HTML_TAG_RE.sub("", unescaped)
    unescaped = _protect_escapes(unescaped)
    lines = unescaped.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    lines = _strip_front_matter(lines)

    out: list[str] = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]

        if _CODE_FENCE_LINE_RE.match(line):
            i = _skip_fence(lines, i)
            continue

        if not line.strip():
            out.append("")
            i += 1
            continue

        # Indented code, but only where it can't be a lazy continuation or a
        # nested list item — both of which are legitimately indented prose.
        if (
            line.startswith(("    ", "\t"))
            and (not out or out[-1] == "")
            and not _UNORDERED_ITEM_RE.match(line)
            and not _ORDERED_ITEM_RE.match(line)
        ):
            i = _skip_indented_code(lines, i)
            continue

        if _LINK_DEF_LINE_RE.match(line):
            i += 1
            continue

        fn_def = _FOOTNOTE_DEF_LINE_RE.match(line)
        if fn_def:
            body = _inline_clean(fn_def.group(1)).strip()
            if body:
                out.append(body)
            i += 1
            continue

        if _HR_LINE_RE.match(line) or _TABLE_RULE_LINE_RE.match(line):
            i += 1
            continue

        if i + 1 < n and "|" in line and _is_separator_row(lines[i + 1]):
            sentence, next_i = _parse_table_block(lines, i)
            if sentence is not None:
                _ensure_blank_before(out)
                out.extend(sentence)
                i = next_i
                _ensure_blank_separator(out, lines, i)
                continue

        # Setext heading: this line is the title, the next is its underline.
        if (
            i + 1 < n
            and _SETEXT_UNDERLINE_RE.match(lines[i + 1])
            and not _UNORDERED_ITEM_RE.match(line)
            and not _ORDERED_ITEM_RE.match(line)
        ):
            _ensure_blank_before(out)
            out.append(_inline_clean(line).strip())
            i += 2
            _ensure_blank_separator(out, lines, i)
            continue

        item_re = None
        if _UNORDERED_ITEM_RE.match(line):
            item_re = _UNORDERED_ITEM_RE
        elif _ORDERED_ITEM_RE.match(line):
            item_re = _ORDERED_ITEM_RE
        if item_re is not None:
            sentence, next_i = _parse_list_block(lines, i, item_re)
            if sentence is not None:
                _ensure_blank_before(out)
                out.extend(sentence)
                i = next_i
                _ensure_blank_separator(out, lines, i)
                continue

        header_match = _HEADER_LINE_RE.match(line)
        if header_match:
            heading = _inline_clean(header_match.group(1)).strip()
            if heading:
                _ensure_blank_before(out)
                out.append(heading)
                i += 1
                _ensure_blank_separator(out, lines, i)
            else:
                i += 1
            continue

        bq_match = _BLOCKQUOTE_LINE_RE.match(line)
        if bq_match:
            out.append(_inline_clean(line[bq_match.end() :]).strip())
            i += 1
            continue

        out.append(_inline_clean(line))
        i += 1

    result = "\n".join(_reflow(out))
    # Emphasis that wrapped a soft line break, which the line-oriented rules
    # above deliberately never match across.
    result = _BOLD_MULTILINE_RE.sub(r"\1", result)
    # Any stray/malformed pipe that wasn't part of a recognized table.
    result = result.replace("|", " ")
    result = _restore_escapes(result)
    result = re.sub(r"[ \t]+", " ", result)
    result = re.sub(r"\n{3,}", "\n\n", result)
    return result.strip()


# ----------------------------------------------------------- residual markup

_RESIDUAL_CHECKS: list[tuple[str, re.Pattern]] = [
    ("heading", re.compile(r"^ {0,3}#{1,6}[^\S\n]", re.MULTILINE)),
    ("bold", re.compile(r"\*\*")),
    ("blockquote", re.compile(r"^ {0,3}>", re.MULTILINE)),
    ("code", re.compile(r"`")),
    ("table", re.compile(r"\|")),
    ("link", re.compile(r"\[[^\]]*\]\([^)]*\)")),
    ("html", _HTML_TAG_RE),
    ("strikethrough", re.compile(r"~~")),
]


def has_residual_markup(text: str) -> list[str]:
    """Names of Markdown constructs still present in `text`.

    Empty list means the text is safe to narrate. Used two ways: as a runtime
    log.warning when a Gemini response comes back still containing markup
    (observability — the model is instructed not to, but nothing enforced it
    before), and as a test assertion so a regression fails CI rather than
    reaching a listener as "hash hash hash".
    """
    if not text:
        return []
    return [name for name, pattern in _RESIDUAL_CHECKS if pattern.search(text)]
