"""Readable-article extraction: main content of a web page as text and Markdown.

All functions are sync and CPU-bound; callers wrap them in run_in_executor.
"""

from __future__ import annotations

import codecs
import re
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field
from typing import Literal
from urllib.parse import unquote, urlsplit

from lxml import etree
from lxml import html as lxml_html

from app.services.article_errors import ArticleError, ArticleFailure

MIN_ARTICLE_WORDS = 40
MAX_TREE_DEPTH = 200
MAX_TITLE_CHARS = 300
MAX_BYLINE_CHARS = 200
MAX_SITE_NAME_CHARS = 120

_HEADINGS = frozenset({"h1", "h2", "h3", "h4", "h5", "h6"})
_BLOCK_TAGS = frozenset(
    {
        "address",
        "article",
        "body",
        "caption",
        "center",
        "dd",
        "details",
        "div",
        "dl",
        "dt",
        "fieldset",
        "figcaption",
        "figure",
        "footer",
        "form",
        "header",
        "legend",
        "li",
        "main",
        "p",
        "section",
        "summary",
        "table",
        "tbody",
        "td",
        "tfoot",
        "th",
        "thead",
    }
)
_ALWAYS_DROPPED = frozenset(
    {
        "audio",
        "button",
        "canvas",
        "datalist",
        "embed",
        "iframe",
        "img",
        "input",
        "link",
        "map",
        "math",
        "meta",
        "noscript",
        "object",
        "option",
        "picture",
        "script",
        "select",
        "source",
        "style",
        "svg",
        "template",
        "textarea",
        "track",
        "video",
    }
)
_CHROME_TAGS = frozenset({"aside", "dialog", "footer", "header", "menu", "nav"})
_CHROME_ROLES = frozenset(
    {
        "alertdialog",
        "banner",
        "complementary",
        "contentinfo",
        "dialog",
        "menu",
        "menubar",
        "navigation",
        "search",
        "toolbar",
    }
)
_CHROME_TOKENS = frozenset(
    {
        "ad",
        "ads",
        "adsense",
        "advert",
        "advertisement",
        "advertising",
        "banner",
        "breadcrumb",
        "breadcrumbs",
        "comment",
        "comments",
        "consent",
        "cookie",
        "cookies",
        "disqus",
        "footer",
        "gdpr",
        "masthead",
        "menu",
        "modal",
        "nav",
        "navbar",
        "navigation",
        "newsletter",
        "outbrain",
        "overlay",
        "pagination",
        "popular",
        "popup",
        "promo",
        "promotion",
        "recommended",
        "related",
        "share",
        "sharing",
        "sidebar",
        "signup",
        "social",
        "sponsor",
        "sponsored",
        "subscribe",
        "taboola",
        "toolbar",
        "trending",
    }
)
_PAYWALL_TOKENS = frozenset(
    {"paywall", "paywalled", "piano", "premium", "subscriber", "subscribers"}
)
_SEMANTIC_XPATH = (
    "descendant-or-self::*[@itemprop='articleBody' or local-name()='article' "
    "or local-name()='main' or @role='main']"
)
_CONTENT_ANCESTORS = (
    "ancestor-or-self::*[@itemprop='articleBody' or local-name()='article']",
    "ancestor-or-self::*[local-name()='main' or @role='main']",
)
_SCORED_TAGS = ("p", "pre", "td", "blockquote")
_LINK_DENSE_TAGS = frozenset({"div", "dl", "ol", "p", "section", "table", "ul"})
_HIDDEN_STYLE_RE = re.compile(r"display\s*:\s*none|visibility\s*:\s*hidden", re.I)
_TOKEN_SPLIT_RE = re.compile(r"[^a-z0-9]+")
_SPACE_RE = re.compile(r"[ \t\r\f\v\u00a0\u200b]+")
_FREE_FALSE_RE = re.compile(r'"isAccessibleForFree"\s*:\s*"?false', re.I)
_LANGUAGE_RE = re.compile(r"^[a-z]{2,3}(?:-[a-z0-9]{1,8}){0,4}$")
_BYLINE_PREFIX_RE = re.compile(r"^(?:by|written by|posted by)\s+", re.I)
_MD_MARKER_RE = re.compile(r"^( {0,3})(#{1,6}(?=\s)|[-+*](?=\s)|>|\||```|~~~)")
_MD_ORDERED_RE = re.compile(r"^( {0,3}\d{1,9})([.)])(?=\s)")
_LAYOUT_ROW_XPATH = (
    ".//p|.//div|.//br|.//table|.//ul|.//ol|.//pre|.//blockquote"
    "|.//h1|.//h2|.//h3|.//h4|.//h5|.//h6"
)
_FENCE_LINE_RE = re.compile(r"^ {0,3}(?:```|~~~)")
_LINE_BREAK = "\x00"
_PARAGRAPH_BREAK_RE = re.compile(r"(?:\x00\s*){2,}")
_META_SNIFF_BYTES = 4096
_META_CHARSET_RE = re.compile(
    rb"<meta[^>]+charset\s*=\s*[\"']?\s*([A-Za-z0-9._:-]{1,40})", re.I
)
_XML_DECLARATION_RE = re.compile(r"^\s*<\?xml[^>]*\?>")
_BOMS = (
    (codecs.BOM_UTF8, "utf-8"),
    (codecs.BOM_UTF16_LE, "utf-16-le"),
    (codecs.BOM_UTF16_BE, "utf-16-be"),
)
_WEB_CODEC_ALIASES = {"ascii": "cp1252", "iso8859-1": "cp1252"}
_TITLE_SEPARATORS = (" | ", " - ", " \u2013 ", " \u2014 ", " :: ", " \u00b7 ")

BlockKind = Literal["heading", "paragraph", "item", "quote", "code"]


@dataclass(frozen=True)
class Article:
    title: str
    byline: str | None
    site_name: str | None
    language: str | None
    text: str
    markdown: str
    word_count: int


@dataclass(frozen=True)
class _Block:
    kind: BlockKind
    text: str
    level: int = 0
    marker: str = ""


@dataclass(frozen=True)
class _PageMeta:
    title: str
    byline: str | None
    site_name: str | None
    language: str | None
    paywall_hint: bool


def extract_html(document: bytes, url: str, charset: str | None = None) -> Article:
    root = _parse(document, charset)
    meta = _page_meta(root, url)
    body = root.find("body")
    if body is None:
        raise _no_content(meta.paywall_hint)
    _strip_chrome(body)
    nodes = _main_content(body)
    blocks = _render(nodes)
    return _assemble(meta, blocks)


def extract_text(document: bytes, url: str, charset: str | None = None) -> Article:
    text = _decode(document, _codec(charset))
    blocks = [
        _Block("paragraph", paragraph)
        for paragraph in (
            _normalize_lines(chunk) for chunk in re.split(r"\n\s*\n", text)
        )
        if paragraph
    ]
    site_name = _host_name(url)
    meta = _PageMeta(
        title=_title_from_url(url) or site_name or "Untitled article",
        byline=None,
        site_name=site_name,
        language=None,
        paywall_hint=False,
    )
    return _assemble(meta, blocks)


def title_from_url(url: str) -> str:
    return _title_from_url(url) or _host_name(url) or "Untitled document"


# ---------- parsing ----------


def _codec(charset: str | None) -> str | None:
    if not charset:
        return None
    try:
        name = codecs.lookup(charset).name
    except LookupError:
        return None
    return _WEB_CODEC_ALIASES.get(name, name)


def _meta_codec(document: bytes) -> str | None:
    match = _META_CHARSET_RE.search(document[:_META_SNIFF_BYTES])
    if match is None:
        return None
    name = _codec(match.group(1).decode("ascii"))
    return "utf-8" if name and name.startswith("utf-16") else name


def _decode(document: bytes, codec: str | None) -> str:
    for bom, name in _BOMS:
        if document.startswith(bom):
            return document[len(bom) :].decode(name, errors="replace")
    if codec is not None:
        try:
            return document.decode(codec, errors="replace")
        except LookupError:
            pass
    try:
        return document.decode("utf-8")
    except UnicodeDecodeError:
        return document.decode("cp1252", errors="replace")


def _parse(document: bytes, charset: str | None) -> lxml_html.HtmlElement:
    text = _decode(document, _codec(charset) or _meta_codec(document))
    parser = lxml_html.HTMLParser(
        remove_comments=True,
        remove_pis=True,
        no_network=True,
    )
    try:
        return lxml_html.document_fromstring(
            _XML_DECLARATION_RE.sub("", text, count=1), parser=parser
        )
    except (etree.ParserError, ValueError) as exc:
        raise _no_content(False) from exc


def _no_content(paywall_hint: bool) -> ArticleError:
    if paywall_hint:
        return ArticleError(
            ArticleFailure.PAYWALLED,
            "This article is behind a paywall, so Voqora can't read it.",
        )
    return ArticleError(
        ArticleFailure.NO_READABLE_CONTENT,
        "Voqora couldn't find readable article text on this page.",
    )


# ---------- metadata ----------


def _collapse(value: str | None, limit: int) -> str | None:
    if not value:
        return None
    collapsed = " ".join(value.split())[:limit].strip()
    return collapsed or None


def _meta_tags(root: lxml_html.HtmlElement) -> dict[str, str]:
    found: dict[str, str] = {}
    for element in root.iter("meta"):
        key = (
            element.get("property")
            or element.get("name")
            or element.get("itemprop")
            or element.get("http-equiv")
            or ""
        )
        content = _collapse(element.get("content"), 1000)
        if key and content:
            found.setdefault(key.strip().lower(), content)
    return found


def _first(*values: str | None) -> str | None:
    return next((value for value in values if value), None)


def _host_name(url: str) -> str | None:
    host = urlsplit(url).hostname or ""
    host = host.removeprefix("www.")
    return host or None


def _title_from_url(url: str) -> str | None:
    segment = unquote(urlsplit(url).path.rstrip("/").rsplit("/", 1)[-1])
    stem = segment.rsplit(".", 1)[0] if "." in segment else segment
    words = re.sub(r"[-_+]+", " ", stem)
    return _collapse(words, MAX_TITLE_CHARS)


def _strip_site_name(title: str, site_name: str | None) -> str:
    if not site_name:
        return title
    site = site_name.casefold()
    for separator in _TITLE_SEPARATORS:
        head, found, tail = title.rpartition(separator)
        if found and head and tail.strip().casefold() == site:
            return head.strip()
        head, found, tail = title.partition(separator)
        if found and tail and head.strip().casefold() == site:
            return tail.strip()
    return title


def _first_text(root: lxml_html.HtmlElement, xpath: str, limit: int) -> str | None:
    for element in root.xpath(xpath):
        text = _collapse(element.text_content(), limit)
        if text:
            return text
    return None


def _byline(root: lxml_html.HtmlElement, tags: dict[str, str]) -> str | None:
    article_author = tags.get("article:author", "")
    candidate = _first(
        tags.get("author"),
        None if "://" in article_author else article_author,
        tags.get("dc.creator"),
        tags.get("parsely-author"),
        _first_text(
            root,
            "//body//*[@rel='author' or @itemprop='author' "
            "or contains(concat(' ', normalize-space(@class), ' '), ' byline ')]",
            MAX_BYLINE_CHARS,
        ),
    )
    if not candidate:
        return None
    return _collapse(_BYLINE_PREFIX_RE.sub("", candidate), MAX_BYLINE_CHARS)


def _language(root: lxml_html.HtmlElement, tags: dict[str, str]) -> str | None:
    raw = _first(
        root.get("lang"),
        root.get("xml:lang"),
        tags.get("content-language"),
        tags.get("og:locale"),
    )
    if not raw:
        return None
    candidate = raw.split(",")[0].strip().replace("_", "-").lower()
    return candidate if _LANGUAGE_RE.fullmatch(candidate) else None


def _paywall_hint(root: lxml_html.HtmlElement) -> bool:
    for script in root.iter("script"):
        if (script.get("type") or "").lower() == "application/ld+json" and (
            _FREE_FALSE_RE.search(script.text or "")
        ):
            return True
    return any(
        _tokens(element) & _PAYWALL_TOKENS
        for element in root.iter()
        if isinstance(element.tag, str)
    )


def _page_meta(root: lxml_html.HtmlElement, url: str) -> _PageMeta:
    tags = _meta_tags(root)
    site_name = _collapse(
        _first(tags.get("og:site_name"), tags.get("application-name"))
        or _host_name(url),
        MAX_SITE_NAME_CHARS,
    )
    document_title = _first_text(root, "//head/title", MAX_TITLE_CHARS)
    title = _first(
        tags.get("og:title"),
        tags.get("twitter:title"),
        _strip_site_name(document_title, site_name) if document_title else None,
        _first_text(root, "//body//h1", MAX_TITLE_CHARS),
        site_name,
    )
    return _PageMeta(
        title=_collapse(title, MAX_TITLE_CHARS) or "Untitled article",
        byline=_byline(root, tags),
        site_name=site_name,
        language=_language(root, tags),
        paywall_hint=_paywall_hint(root),
    )


# ---------- boilerplate removal ----------


def _tag(element: lxml_html.HtmlElement) -> str:
    return element.tag.lower() if isinstance(element.tag, str) else ""


def _tokens(element: lxml_html.HtmlElement) -> set[str]:
    raw = f"{element.get('class') or ''} {element.get('id') or ''}".lower()
    return {token for token in _TOKEN_SPLIT_RE.split(raw) if token}


def _is_hidden(element: lxml_html.HtmlElement) -> bool:
    return (
        element.get("hidden") is not None
        or (element.get("aria-hidden") or "").lower() == "true"
        or bool(_HIDDEN_STYLE_RE.search(element.get("style") or ""))
    )


def _paragraph_chars(element: lxml_html.HtmlElement) -> int:
    return sum(_text_length(paragraph) for paragraph in element.iter("p"))


def _looks_like_chrome(
    element: lxml_html.HtmlElement, tag: str, page_chars: int
) -> bool:
    if tag in _CHROME_TAGS or _is_hidden(element):
        return True
    if (element.get("role") or "").lower() in _CHROME_ROLES:
        return True
    if not _tokens(element) & _CHROME_TOKENS:
        return False
    return page_chars == 0 or _paragraph_chars(element) * 2 < page_chars


def _is_chrome(element: lxml_html.HtmlElement, page_chars: int) -> bool:
    tag = _tag(element)
    if tag in _ALWAYS_DROPPED:
        return True
    if tag in {"body", "html", "article", "main"}:
        return False
    return _looks_like_chrome(element, tag, page_chars) and not element.xpath(
        _SEMANTIC_XPATH
    )


def _strip_chrome(body: lxml_html.HtmlElement) -> None:
    page_chars = _paragraph_chars(body)
    doomed: list[lxml_html.HtmlElement] = []
    pending = [child for child in body if isinstance(child.tag, str)]
    while pending:
        element = pending.pop()
        if _is_chrome(element, page_chars):
            doomed.append(element)
        else:
            pending.extend(child for child in element if isinstance(child.tag, str))
    for element in doomed:
        element.drop_tree()


# ---------- main-content selection ----------


def _text_length(element: lxml_html.HtmlElement) -> int:
    return len(" ".join(element.text_content().split()))


def _link_density(element: lxml_html.HtmlElement) -> float:
    total = _text_length(element)
    if total == 0:
        return 0.0
    linked = sum(_text_length(link) for link in element.iter("a"))
    return min(1.0, linked / total)


def _paragraph_scores(
    body: lxml_html.HtmlElement,
) -> dict[lxml_html.HtmlElement, float]:
    scores: dict[lxml_html.HtmlElement, float] = {}
    for paragraph in body.iter(*_SCORED_TAGS):
        text = " ".join(paragraph.text_content().split())
        if len(text) < 25:
            continue
        score = 1 + text.count(",") + min(len(text) // 100, 3)
        parent = paragraph.getparent()
        if parent is None:
            continue
        scores[parent] = scores.get(parent, 0.0) + score
        grandparent = parent.getparent()
        if grandparent is not None:
            scores[grandparent] = scores.get(grandparent, 0.0) + score / 2
    return {
        element: score * (1 - _link_density(element))
        for element, score in scores.items()
    }


def _semantic_ancestor(
    element: lxml_html.HtmlElement,
) -> lxml_html.HtmlElement | None:
    for xpath in _CONTENT_ANCESTORS:
        found = element.xpath(xpath)
        if found:
            return found[-1]
    return None


def _with_siblings(
    best: lxml_html.HtmlElement, scores: dict[lxml_html.HtmlElement, float]
) -> list[lxml_html.HtmlElement]:
    parent = best.getparent()
    if parent is None:
        return [best]
    threshold = max(10.0, scores[best] * 0.2)
    chosen = []
    for sibling in parent:
        if sibling is best or scores.get(sibling, 0.0) >= threshold:
            chosen.append(sibling)
        elif _tag(sibling) == "p" and _text_length(sibling) > 80:
            if _link_density(sibling) < 0.25:
                chosen.append(sibling)
    return chosen


def _fallback_container(body: lxml_html.HtmlElement) -> lxml_html.HtmlElement:
    semantic = [
        element
        for element in body.xpath(_SEMANTIC_XPATH)
        if element is not body and _text_length(element) > 0
    ]
    return max(semantic, key=_text_length) if semantic else body


def _main_content(body: lxml_html.HtmlElement) -> list[lxml_html.HtmlElement]:
    scores = _paragraph_scores(body)
    if not scores:
        nodes = [_fallback_container(body)]
    else:
        best = max(scores, key=lambda element: scores[element])
        container = _semantic_ancestor(best)
        nodes = [container] if container is not None else _with_siblings(best, scores)
    for node in nodes:
        _drop_link_lists(node)
    return nodes


def _drop_link_lists(node: lxml_html.HtmlElement) -> None:
    doomed = [
        element
        for element in node.iter(*_LINK_DENSE_TAGS)
        if element is not node
        and _link_density(element) > 0.5
        and not element.xpath(".//h1|.//h2|.//h3|.//h4|.//h5|.//h6|.//pre")
    ]
    for element in doomed:
        element.drop_tree()


# ---------- rendering ----------


def _normalize_lines(value: str) -> str:
    lines = (_SPACE_RE.sub(" ", line).strip() for line in value.split("\n"))
    return "\n".join(line for line in lines if line)


@dataclass
class _Renderer:
    blocks: list[_Block] = field(default_factory=list)
    _inline: list[str] = field(default_factory=list)
    _context: list[tuple[BlockKind, str]] = field(default_factory=list)

    def walk(self, element: lxml_html.HtmlElement, depth: int = 0) -> None:
        tag = _tag(element)
        if tag in _HEADINGS:
            self._heading(element, int(tag[1]))
        elif tag == "pre":
            self._code(element)
        elif tag == "br":
            self._inline.append(_LINE_BREAK)
        elif tag == "hr":
            self.flush()
        elif tag in {"ul", "ol"}:
            self._list(element, tag == "ol", depth)
        elif tag == "blockquote":
            self._nested("quote", "", element, depth)
        elif tag == "tr" and not element.xpath(_LAYOUT_ROW_XPATH):
            self._row(element)
        elif tag in _BLOCK_TAGS:
            self.flush()
            self._children(element, depth)
            self.flush()
        else:
            self._children(element, depth)

    def _children(self, element: lxml_html.HtmlElement, depth: int) -> None:
        if element.text:
            self._inline.append(element.text)
        for child in element:
            if isinstance(child.tag, str):
                if depth >= MAX_TREE_DEPTH:
                    self._inline.append(child.text_content())
                else:
                    self.walk(child, depth + 1)
            if child.tail:
                self._inline.append(child.tail)

    def _heading(self, element: lxml_html.HtmlElement, level: int) -> None:
        self.flush()
        text = _collapse(element.text_content(), 500)
        if text:
            self.blocks.append(_Block("heading", text, level=level))

    def _code(self, element: lxml_html.HtmlElement) -> None:
        self.flush()
        lines = [line.rstrip() for line in element.text_content().split("\n")]
        code = "\n".join(lines).strip("\n")
        if code.strip():
            self.blocks.append(_Block("code", code))

    def _row(self, element: lxml_html.HtmlElement) -> None:
        self.flush()
        cells = (
            _collapse(cell.text_content(), 2000) for cell in element.iter("td", "th")
        )
        text = "; ".join(cell for cell in cells if cell)
        if text:
            self.blocks.append(_Block("paragraph", text))

    def _list(self, element: lxml_html.HtmlElement, ordered: bool, depth: int) -> None:
        self.flush()
        number = _list_start(element)
        for child in element:
            if _tag(child) == "li":
                marker = f"{number}." if ordered else "-"
                number += 1
                self._nested("item", marker, child, depth + 1)
            elif isinstance(child.tag, str) and depth < MAX_TREE_DEPTH:
                self.walk(child, depth + 1)
        self.flush()

    def _nested(
        self,
        kind: BlockKind,
        marker: str,
        element: lxml_html.HtmlElement,
        depth: int,
    ) -> None:
        self.flush()
        self._context.append((kind, marker))
        self._children(element, depth)
        self.flush()
        self._context.pop()

    def flush(self) -> None:
        raw = "".join(self._inline).replace("\n", " ")
        self._inline.clear()
        for chunk in _PARAGRAPH_BREAK_RE.split(raw):
            text = _normalize_lines(chunk.replace(_LINE_BREAK, "\n"))
            if text:
                self._emit(text)

    def _emit(self, text: str) -> None:
        kind, marker = self._context[-1] if self._context else ("paragraph", "")
        self.blocks.append(_Block(kind, text, marker=marker))
        if kind == "item":
            self._context[-1] = ("paragraph", "")


def _list_start(element: lxml_html.HtmlElement) -> int:
    try:
        return max(0, min(int(element.get("start") or 1), 1_000_000))
    except ValueError:
        return 1


def _render(nodes: Iterable[lxml_html.HtmlElement]) -> list[_Block]:
    renderer = _Renderer()
    for node in nodes:
        renderer.walk(node)
        renderer.flush()
    return renderer.blocks


# ---------- assembly ----------


def _without_title_heading(blocks: list[_Block], title: str) -> list[_Block]:
    for index, block in enumerate(blocks):
        if block.kind != "heading":
            continue
        if block.level <= 2 and block.text.casefold() == title.casefold():
            return blocks[:index] + blocks[index + 1 :]
        return blocks
    return blocks


def _plain(block: _Block) -> str:
    if block.kind == "item" and block.marker != "-":
        return f"{block.marker} {block.text}"
    return block.text


def _escape_line(line: str) -> str:
    escaped = _MD_ORDERED_RE.sub(r"\1\\\2", line)
    return _MD_MARKER_RE.sub(r"\1\\\2", escaped)


def _escape_lines(text: str) -> Iterator[str]:
    return (_escape_line(line) for line in text.split("\n"))


def _fenced(code: str) -> str:
    lines = (
        f"    {line}" if _FENCE_LINE_RE.match(line) else line
        for line in code.split("\n")
    )
    body = "\n".join(lines)
    return f"```\n{body}\n```"


def _markdown_block(block: _Block) -> str:
    if block.kind == "heading":
        hashes = "##" if block.level <= 2 else "###"
        return f"{hashes} {' '.join(block.text.split())}"
    if block.kind == "code":
        return _fenced(block.text)
    if block.kind == "item":
        return f"{block.marker} {_escape_line(' '.join(block.text.split()))}"
    if block.kind == "quote":
        return "\n".join(f"> {line}" for line in _escape_lines(block.text))
    return "\n".join(_escape_lines(block.text))


def _markdown(meta: _PageMeta, blocks: list[_Block]) -> str:
    parts = [f"# {meta.title}"]
    if meta.byline:
        parts.append(_escape_line(f"By {meta.byline}"))
    previous: _Block | None = None
    for block in blocks:
        rendered = _markdown_block(block)
        if previous is not None and previous.kind == block.kind == "item":
            parts[-1] = f"{parts[-1]}\n{rendered}"
        else:
            parts.append(rendered)
        previous = block
    return "\n\n".join(parts) + "\n"


def _assemble(meta: _PageMeta, blocks: list[_Block]) -> Article:
    body = _without_title_heading(blocks, meta.title)
    text = "\n\n".join(_plain(block) for block in body)
    word_count = len(text.split())
    if word_count < MIN_ARTICLE_WORDS:
        raise _no_content(meta.paywall_hint)
    return Article(
        title=meta.title,
        byline=meta.byline,
        site_name=meta.site_name,
        language=meta.language,
        text=text,
        markdown=_markdown(meta, body),
        word_count=word_count,
    )
