"""EPUB 2 and EPUB 3 reading for audiobook import."""

from __future__ import annotations

import posixpath
import zipfile
import zlib
from collections.abc import Iterator
from dataclasses import dataclass
from urllib.parse import unquote, urlsplit

from lxml import etree

from app.core.config import settings
from app.core.logging import get_logger
from app.services.import_limits import (
    ImportLimitError,
    is_safe_member_name,
    validate_epub_archive,
)
from app.services.markup_text import (
    BlockCollector,
    Heading,
    MarkupDocument,
    chapter_headings,
    collapse,
    decode_markup,
    inline_text,
    parse_html,
    semantics,
    tag_name,
)

log = get_logger(__name__)

DAMAGED = "This EPUB is damaged and cannot be opened."
DRM_PROTECTED = (
    "This EPUB is protected by DRM. Voqora can only read DRM-free books. "
    "Remove the protection with the store's own tools or choose another copy."
)
MEMBER_TOO_LARGE = "This EPUB has a file that is too large to open safely."

_CONTAINER = "META-INF/container.xml"
_ENCRYPTION = "META-INF/encryption.xml"
_PACKAGE_MEDIA = "application/oebps-package+xml"
_NCX_MEDIA = "application/x-dtbncx+xml"
_CONTENT_MEDIA = frozenset({"application/xhtml+xml", "text/html"})
_COVER_MEDIA = frozenset({"image/jpeg", "image/png", "image/gif", "image/webp"})
_ZIP_ENCRYPTED_FLAG = 0x1
_MAX_TOC_ENTRIES = 5000
_MAX_TOC_DEPTH = 6
_MAX_CREATORS = 3
_MAX_LABEL_CHARS = 300


@dataclass(frozen=True)
class _ManifestItem:
    path: str
    media_type: str
    properties: frozenset[str]


@dataclass(frozen=True)
class _Package:
    title: str | None
    author: str | None
    spine: tuple[str, ...]
    nav_path: str | None
    ncx_path: str | None
    cover_path: str | None


@dataclass(frozen=True)
class _TocEntry:
    path: str
    fragment: str
    title: str
    level: int


def read_epub_document(path: str) -> MarkupDocument:
    validate_epub_archive(path)
    try:
        with zipfile.ZipFile(path) as archive:
            return _read_book(archive)
    except (zipfile.BadZipFile, zlib.error, EOFError) as exc:
        raise ImportLimitError(DAMAGED) from exc


def read_epub_member(path: str, member: str, limit: int) -> bytes:
    try:
        with zipfile.ZipFile(path) as archive:
            return _read_member(archive, member, limit)
    except (zipfile.BadZipFile, zlib.error, EOFError) as exc:
        raise ImportLimitError(DAMAGED) from exc


def _read_book(archive: zipfile.ZipFile) -> MarkupDocument:
    names = frozenset(archive.namelist())
    package = _read_package(archive, _package_path(archive))
    encrypted = _encrypted_paths(archive, names)
    if encrypted.intersection(package.spine):
        raise ImportLimitError(DRM_PROTECTED)

    collector = BlockCollector(settings.MAX_EXTRACTED_TEXT_CHARS)
    for document in package.spine:
        if document not in names:
            log.warning(
                "epub.spine_item_missing",
                extra={"failure_code": "epub_spine_item_missing"},
            )
            continue
        data = _read_member(archive, document, settings.MAX_EPUB_MEMBER_BYTES)
        collector.add_document(parse_html(decode_markup(data)), document)

    toc = _toc_entries(archive, package, names)
    cover = package.cover_path
    if cover is not None and (cover not in names or cover in encrypted):
        cover = None
    return MarkupDocument(
        blocks=tuple(collector.blocks),
        chapters=_chapters(toc, collector),
        title=package.title,
        author=package.author,
        cover_member=cover,
    )


def _read_member(archive: zipfile.ZipFile, name: str, limit: int) -> bytes:
    try:
        info = archive.getinfo(name)
    except KeyError as exc:
        raise ImportLimitError(DAMAGED) from exc
    if info.flag_bits & _ZIP_ENCRYPTED_FLAG:
        raise ImportLimitError(DRM_PROTECTED)
    if info.file_size > limit:
        raise ImportLimitError(MEMBER_TOO_LARGE)
    with archive.open(info) as member:
        data = member.read(limit + 1)
    if len(data) > limit:
        raise ImportLimitError(MEMBER_TOO_LARGE)
    return data


def _parse_xml(data: bytes) -> etree._Element:
    parser = etree.XMLParser(
        resolve_entities=False,
        no_network=True,
        load_dtd=False,
        huge_tree=False,
        remove_comments=True,
        remove_pis=True,
    )
    try:
        root = etree.fromstring(data, parser)
    except etree.XMLSyntaxError as exc:
        raise ImportLimitError(DAMAGED) from exc
    if root is None:
        raise ImportLimitError(DAMAGED)
    return root


def _local(element: etree._Element) -> str:
    tag = element.tag
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def _descendants(root: etree._Element, name: str) -> Iterator[etree._Element]:
    return (element for element in root.iter() if _local(element) == name)


def _children(parent: etree._Element, name: str) -> Iterator[etree._Element]:
    return (element for element in parent if _local(element) == name)


def _first(root: etree._Element, name: str) -> etree._Element | None:
    return next(_descendants(root, name), None)


def resolve_href(base_dir: str, href: str | None) -> tuple[str, str] | None:
    if not href:
        return None
    parts = urlsplit(href.strip())
    if parts.scheme or parts.netloc or not parts.path:
        return None
    joined = posixpath.normpath(posixpath.join(base_dir, unquote(parts.path)))
    if joined == "." or not is_safe_member_name(joined):
        return None
    return joined, unquote(parts.fragment)


def _package_path(archive: zipfile.ZipFile) -> str:
    root = _parse_xml(_read_member(archive, _CONTAINER, settings.MAX_EPUB_MEMBER_BYTES))
    for rootfile in _descendants(root, "rootfile"):
        media_type = rootfile.get("media-type") or _PACKAGE_MEDIA
        resolved = resolve_href("", rootfile.get("full-path"))
        if media_type == _PACKAGE_MEDIA and resolved is not None:
            return resolved[0]
    raise ImportLimitError(DAMAGED)


def _read_package(archive: zipfile.ZipFile, package_path: str) -> _Package:
    root = _parse_xml(
        _read_member(archive, package_path, settings.MAX_EPUB_MEMBER_BYTES)
    )
    base_dir = posixpath.dirname(package_path)
    manifest = _manifest(root, base_dir)
    spine = _first(root, "spine")
    skipped = _guide_toc_paths(root, base_dir)
    return _Package(
        title=_metadata_title(root),
        author=_metadata_author(root),
        spine=_spine_paths(spine, manifest, skipped),
        nav_path=next(
            (item.path for item in manifest.values() if "nav" in item.properties),
            None,
        ),
        ncx_path=_ncx_path(spine, manifest),
        cover_path=_cover_path(root, manifest),
    )


def _manifest(root: etree._Element, base_dir: str) -> dict[str, _ManifestItem]:
    items: dict[str, _ManifestItem] = {}
    manifest = _first(root, "manifest")
    if manifest is None:
        raise ImportLimitError(DAMAGED)
    for item in _children(manifest, "item"):
        ident = item.get("id")
        resolved = resolve_href(base_dir, item.get("href"))
        if not ident or resolved is None or ident in items:
            continue
        items[ident] = _ManifestItem(
            path=resolved[0],
            media_type=(item.get("media-type") or "").strip().lower(),
            properties=frozenset((item.get("properties") or "").split()),
        )
    return items


def _guide_toc_paths(root: etree._Element, base_dir: str) -> frozenset[str]:
    guide = _first(root, "guide")
    if guide is None:
        return frozenset()
    paths = set()
    for reference in _children(guide, "reference"):
        resolved = resolve_href(base_dir, reference.get("href"))
        if (reference.get("type") or "").lower() == "toc" and resolved is not None:
            paths.add(resolved[0])
    return frozenset(paths)


def _spine_paths(
    spine: etree._Element | None,
    manifest: dict[str, _ManifestItem],
    skipped: frozenset[str],
) -> tuple[str, ...]:
    if spine is None:
        raise ImportLimitError(DAMAGED)
    paths: list[str] = []
    for itemref in _children(spine, "itemref"):
        item = manifest.get(itemref.get("idref") or "")
        if (
            item is None
            or (itemref.get("linear") or "").strip().lower() == "no"
            or item.media_type not in _CONTENT_MEDIA
            or "nav" in item.properties
            or item.path in skipped
            or item.path in paths
        ):
            continue
        paths.append(item.path)
    return tuple(paths)


def _ncx_path(
    spine: etree._Element | None, manifest: dict[str, _ManifestItem]
) -> str | None:
    declared = manifest.get(spine.get("toc") or "") if spine is not None else None
    if declared is not None:
        return declared.path
    return next(
        (item.path for item in manifest.values() if item.media_type == _NCX_MEDIA),
        None,
    )


def _cover_path(root: etree._Element, manifest: dict[str, _ManifestItem]) -> str | None:
    images = {
        ident: item
        for ident, item in manifest.items()
        if item.media_type in _COVER_MEDIA
    }
    for item in images.values():
        if "cover-image" in item.properties:
            return item.path
    for meta in _descendants(root, "meta"):
        if (meta.get("name") or "").lower() == "cover":
            item = images.get(meta.get("content") or "")
            if item is not None:
                return item.path
    for ident in ("cover-image", "cover"):
        if ident in images:
            return images[ident].path
    return None


def _metadata(root: etree._Element) -> etree._Element:
    metadata = _first(root, "metadata")
    return root if metadata is None else metadata


def _metadata_title(root: etree._Element) -> str | None:
    for title in _descendants(_metadata(root), "title"):
        text = collapse("".join(title.itertext()), _MAX_LABEL_CHARS)
        if text:
            return text
    return None


def _metadata_author(root: etree._Element) -> str | None:
    names: list[str] = []
    for creator in _descendants(_metadata(root), "creator"):
        role = next(
            (
                value
                for key, value in creator.attrib.items()
                if _local_attr(key) == "role"
            ),
            "aut",
        )
        name = collapse("".join(creator.itertext()), _MAX_LABEL_CHARS)
        if name and role.strip().lower() == "aut" and name not in names:
            names.append(name)
        if len(names) == _MAX_CREATORS:
            break
    return ", ".join(names) or None


def _local_attr(name: str) -> str:
    return name.rsplit("}", 1)[-1]


def _encrypted_paths(archive: zipfile.ZipFile, names: frozenset[str]) -> frozenset[str]:
    if _ENCRYPTION not in names:
        return frozenset()
    root = _parse_xml(
        _read_member(archive, _ENCRYPTION, settings.MAX_EPUB_MEMBER_BYTES)
    )
    paths = set()
    for reference in _descendants(root, "CipherReference"):
        resolved = resolve_href("", (reference.get("URI") or "").lstrip("/"))
        if resolved is not None:
            paths.add(resolved[0])
    return frozenset(paths)


def _toc_entries(
    archive: zipfile.ZipFile, package: _Package, names: frozenset[str]
) -> list[_TocEntry]:
    readers = (
        (package.nav_path, _nav_entries),
        (package.ncx_path, _ncx_entries),
    )
    for toc_path, reader in readers:
        if toc_path is None or toc_path not in names:
            continue
        try:
            data = _read_member(archive, toc_path, settings.MAX_EPUB_MEMBER_BYTES)
            entries = reader(data, posixpath.dirname(toc_path))
        except ImportLimitError:
            log.warning(
                "epub.toc_unreadable", extra={"failure_code": "epub_toc_unreadable"}
            )
            continue
        if entries:
            return entries
    return []


def _nav_entries(data: bytes, base_dir: str) -> list[_TocEntry]:
    root = parse_html(decode_markup(data))
    if root is None:
        return []
    navs = [element for element in root.iter() if tag_name(element) == "nav"]
    toc = next((nav for nav in navs if semantics(nav) & {"toc", "doc-toc"}), None)
    if toc is None and navs:
        toc = navs[0]
    entries: list[_TocEntry] = []
    if toc is not None:
        for top in (child for child in toc if tag_name(child) == "ol"):
            _visit_nav_list(top, base_dir, 1, entries)
    return entries


def _visit_nav_list(
    ordered: etree._Element, base_dir: str, level: int, entries: list[_TocEntry]
) -> None:
    for item in (child for child in ordered if tag_name(child) == "li"):
        if len(entries) >= _MAX_TOC_ENTRIES:
            return
        link = next((child for child in item if tag_name(child) == "a"), None)
        if link is not None:
            _add_entry(
                entries,
                resolve_href(base_dir, link.get("href")),
                inline_text(link, _MAX_LABEL_CHARS),
                level,
            )
        if level < _MAX_TOC_DEPTH:
            for nested in (child for child in item if tag_name(child) == "ol"):
                _visit_nav_list(nested, base_dir, level + 1, entries)


def _ncx_entries(data: bytes, base_dir: str) -> list[_TocEntry]:
    nav_map = _first(_parse_xml(data), "navMap")
    entries: list[_TocEntry] = []
    if nav_map is not None:
        _visit_nav_points(nav_map, base_dir, 1, entries)
    return entries


def _visit_nav_points(
    parent: etree._Element, base_dir: str, level: int, entries: list[_TocEntry]
) -> None:
    for point in _children(parent, "navPoint"):
        if len(entries) >= _MAX_TOC_ENTRIES:
            return
        content = next(_children(point, "content"), None)
        _add_entry(
            entries,
            resolve_href(base_dir, content.get("src") if content is not None else None),
            _nav_point_label(point),
            level,
        )
        if level < _MAX_TOC_DEPTH:
            _visit_nav_points(point, base_dir, level + 1, entries)


def _nav_point_label(point: etree._Element) -> str:
    label = next(_children(point, "navLabel"), None)
    text = next(_children(label, "text"), None) if label is not None else None
    return (
        collapse("".join(text.itertext()), _MAX_LABEL_CHARS) if text is not None else ""
    )


def _add_entry(
    entries: list[_TocEntry],
    target: tuple[str, str] | None,
    title: str,
    level: int,
) -> None:
    if target is not None and title:
        entries.append(_TocEntry(target[0], target[1], title, level))


def _chapters(toc: list[_TocEntry], collector: BlockCollector) -> tuple[Heading, ...]:
    resolved: list[Heading] = []
    for entry in toc:
        key = f"{entry.path}#{entry.fragment}" if entry.fragment else entry.path
        index = collector.anchors.get(key, collector.anchors.get(entry.path))
        if index is not None:
            resolved.append(Heading(index, entry.title, entry.level))
    headings = chapter_headings(collector.headings)
    if len(resolved) >= 2 or (resolved and not headings):
        return tuple(resolved)
    return headings
