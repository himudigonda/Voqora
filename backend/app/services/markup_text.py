"""Readable narration text from HTML and XHTML documents."""

from __future__ import annotations

import codecs
import os
import re
from dataclasses import dataclass

from lxml import etree, html

from app.core.config import settings
from app.services.import_limits import ImportLimitError

TOO_MUCH_TEXT = "This book has more text than Voqora can open safely."

_SKIPPED_TAGS = frozenset(
    {
        "audio",
        "button",
        "canvas",
        "embed",
        "form",
        "head",
        "iframe",
        "map",
        "math",
        "nav",
        "noscript",
        "object",
        "rp",
        "rt",
        "script",
        "select",
        "style",
        "svg",
        "template",
        "textarea",
        "title",
        "video",
    }
)
_BLOCK_TAGS = frozenset(
    {
        "address",
        "article",
        "aside",
        "blockquote",
        "body",
        "caption",
        "center",
        "dd",
        "details",
        "div",
        "dl",
        "dt",
        "figcaption",
        "figure",
        "footer",
        "header",
        "hgroup",
        "hr",
        "html",
        "li",
        "main",
        "ol",
        "p",
        "pre",
        "section",
        "summary",
        "ul",
    }
)
_HEADING_LEVELS = {"h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6}
_SKIPPED_SEMANTICS = frozenset(
    {
        "backlink",
        "doc-backlink",
        "doc-noteref",
        "doc-pagebreak",
        "noteref",
        "pagebreak",
    }
)
_SYMBOL_MARKER_RE = re.compile(r"^(?:[\[(]\w{1,4}[\])]|[*†‡§¶↩↑^]{1,3})$")
_NUMBER_MARKER_RE = re.compile(r"^(?:\d{1,4}|[ivxlcdm]{1,6})$", re.IGNORECASE)
_NOTE_HINT_RE = re.compile(r"note|fn|ref|back", re.IGNORECASE)
_INVISIBLE_RE = re.compile("[­​‌‍⁠︎️﻿]")
_WHITESPACE_RE = re.compile(r"\s+")
_XML_DECLARATION_RE = re.compile(r"^\s*<\?xml[^>]*\?>")
_XML_ENCODING_RE = re.compile(
    rb"""^\s*<\?xml[^>]*?encoding\s*=\s*["']([A-Za-z0-9._-]{1,40})["']"""
)
_META_CHARSET_RE = re.compile(
    rb"""<meta[^>]+charset\s*=\s*["']?([A-Za-z0-9._-]{1,40})""", re.IGNORECASE
)
_BOMS = (
    (codecs.BOM_UTF8, "utf-8-sig"),
    (codecs.BOM_UTF16_LE, "utf-16"),
    (codecs.BOM_UTF16_BE, "utf-16"),
)
_SNIFF_BYTES = 2048
_MAX_REPLACEMENT_CHAR_RATIO = 0.05


@dataclass(frozen=True)
class Heading:
    block_index: int
    title: str
    level: int


@dataclass(frozen=True)
class MarkupDocument:
    blocks: tuple[str, ...]
    chapters: tuple[Heading, ...]
    title: str | None = None
    author: str | None = None
    cover_member: str | None = None


def collapse(text: str, limit: int | None = None) -> str:
    collapsed = " ".join(_INVISIBLE_RE.sub("", text).split())
    return collapsed[:limit].rstrip() if limit else collapsed


def table_block(rows: list[list[str]]) -> str | None:
    if not rows:
        return None
    lines = ["| " + " | ".join(cells) + " |" for cells in rows]
    rule = "|" + " --- |" * len(rows[0])
    return "\n".join([lines[0], rule, *lines[1:]])


def _declared_encoding(head: bytes) -> str | None:
    for bom, name in _BOMS:
        if head.startswith(bom):
            return name
    match = _XML_ENCODING_RE.match(head) or _META_CHARSET_RE.search(head)
    if match is None:
        return None
    try:
        return codecs.lookup(match.group(1).decode("ascii")).name
    except LookupError:
        return None


def decode_markup(data: bytes) -> str:
    encoding = _declared_encoding(data[:_SNIFF_BYTES])
    if encoding is None:
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            text = data.decode("cp1252", errors="replace")
    else:
        text = data.decode(encoding, errors="replace")
    return _XML_DECLARATION_RE.sub("", text, count=1)


def parse_html(text: str) -> etree._Element | None:
    parser = html.HTMLParser(
        remove_comments=True, remove_pis=True, no_network=True, recover=True
    )
    try:
        return html.document_fromstring(text, parser=parser)
    except (etree.ParserError, etree.XMLSyntaxError, ValueError):
        return None


def tag_name(element: etree._Element) -> str | None:
    tag = element.tag
    if not isinstance(tag, str):
        return None
    return tag.rsplit("}", 1)[-1].lower()


def semantics(element: etree._Element) -> set[str]:
    values = f"{element.get('epub:type', '')} {element.get('role', '')}"
    return set(values.lower().split())


def _is_note_marker(element: etree._Element) -> bool:
    if "#" not in (element.get("href") or ""):
        return False
    text = collapse("".join(element.itertext()))
    if _SYMBOL_MARKER_RE.match(text):
        return True
    if not _NUMBER_MARKER_RE.match(text):
        return False
    parent = element.getparent()
    in_superscript = parent is not None and tag_name(parent) in {"sup", "sub"}
    has_superscript = any(tag_name(child) == "sup" for child in element)
    hints = f"{element.get('class', '')} {element.get('id', '')}"
    return in_superscript or has_superscript or bool(_NOTE_HINT_RE.search(hints))


def is_skipped(element: etree._Element, tag: str) -> bool:
    if tag in _SKIPPED_TAGS or element.get("hidden") is not None:
        return True
    if semantics(element) & _SKIPPED_SEMANTICS:
        return True
    return tag == "a" and _is_note_marker(element)


def inline_text(element: etree._Element, limit: int | None = None) -> str:
    parts: list[str] = []
    _collect_inline(element, parts)
    return collapse("".join(parts), limit)


def _collect_inline(element: etree._Element, parts: list[str]) -> None:
    tag = tag_name(element)
    if tag is None or is_skipped(element, tag):
        return
    spaced = tag in _BLOCK_TAGS or tag in _HEADING_LEVELS or tag == "br"
    if spaced:
        parts.append(" ")
    parts.append(element.text or "")
    for child in element:
        _collect_inline(child, parts)
        parts.append(child.tail or "")
    if spaced:
        parts.append(" ")


class BlockCollector:
    """Turns parsed documents into narration blocks, headings and anchors."""

    def __init__(self, char_limit: int) -> None:
        self.blocks: list[str] = []
        self.headings: list[Heading] = []
        self.anchors: dict[str, int] = {}
        self._char_limit = char_limit
        self._chars = 0
        self._parts: list[str] = []
        self._preformatted = 0
        self._document = ""

    def add_document(self, root: etree._Element | None, key: str) -> None:
        self._document = key
        self.anchors.setdefault(key, len(self.blocks))
        if root is None:
            return
        body = next((el for el in root.iter() if tag_name(el) == "body"), root)
        self._walk(body)
        self._flush()

    def _walk(self, element: etree._Element) -> None:
        tag = tag_name(element)
        if tag is None or is_skipped(element, tag):
            return
        self._register_anchor(element)
        if tag == "br":
            self._parts.append("\n")
            return
        if tag == "table":
            self._flush()
            self._add_table(element)
            return
        level = _HEADING_LEVELS.get(tag)
        is_block = level is not None or tag in _BLOCK_TAGS
        if is_block:
            self._flush()
        if tag == "pre":
            self._preformatted += 1
        self._add_text(element.text)
        for child in element:
            self._walk(child)
            self._add_text(child.tail)
        index = self._flush() if is_block else None
        if tag == "pre":
            self._preformatted -= 1
        if level is not None and index is not None:
            self.headings.append(Heading(index, collapse(self.blocks[index]), level))

    def _register_anchor(self, element: etree._Element) -> None:
        ident = element.get("id") or element.get("name")
        if ident:
            self.anchors.setdefault(f"{self._document}#{ident}", len(self.blocks))

    def _add_text(self, text: str | None) -> None:
        if not text:
            return
        text = _INVISIBLE_RE.sub("", text)
        if not self._preformatted:
            text = _WHITESPACE_RE.sub(" ", text)
        self._parts.append(text)

    def _add_table(self, table: etree._Element) -> None:
        for element in table.iter():
            if isinstance(element.tag, str):
                self._register_anchor(element)
        rows: list[list[str]] = []
        for row in table.iter():
            if tag_name(row) != "tr":
                continue
            cells = [
                inline_text(cell) for cell in row if tag_name(cell) in {"td", "th"}
            ]
            if any(cells):
                rows.append(cells)
        block = table_block(rows)
        if block:
            self._append(block)

    def _flush(self) -> int | None:
        raw = "".join(self._parts)
        self._parts.clear()
        if self._preformatted:
            lines = [line.rstrip() for line in raw.split("\n")]
        else:
            lines = [" ".join(line.split()) for line in raw.split("\n")]
        text = "\n".join(line for line in lines if line.strip())
        return self._append(text) if text else None

    def _append(self, text: str) -> int:
        self._chars += len(text)
        if self._chars > self._char_limit:
            raise ImportLimitError(TOO_MUCH_TEXT)
        self.blocks.append(text)
        return len(self.blocks) - 1


def chapter_headings(headings: list[Heading]) -> tuple[Heading, ...]:
    return tuple(heading for heading in headings if heading.level <= 2)


def _looks_binary(data: bytes, text: str) -> bool:
    is_utf16 = data.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE))
    if not is_utf16 and b"\x00" in data[:_SNIFF_BYTES]:
        return True
    return bool(text) and text.count("\ufffd") / len(text) > _MAX_REPLACEMENT_CHAR_RATIO


def read_html_document(path: str) -> MarkupDocument:
    if os.path.getsize(path) > settings.MAX_HTML_SOURCE_BYTES:
        raise ImportLimitError("This web page is too large to open safely.")
    with open(path, "rb") as source:
        data = source.read()
    text = decode_markup(data)
    if _looks_binary(data, text):
        raise ImportLimitError("This file doesn't look like a readable web page.")
    collector = BlockCollector(settings.MAX_EXTRACTED_TEXT_CHARS)
    collector.add_document(parse_html(text), "")
    return MarkupDocument(
        blocks=tuple(collector.blocks),
        chapters=chapter_headings(collector.headings),
    )
