"""EPUB and HTML import: reading order, chapters, metadata, covers, hardening."""

from __future__ import annotations

import io
import os
import shutil
import tempfile
import threading
import zipfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.core.config import settings
from app.services import epub_reader, text_extractor
from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.epub_reader import (
    DAMAGED,
    read_epub_document,
    read_epub_member,
    resolve_href,
)
from app.services.import_limits import (
    ImportLimitError,
    is_safe_member_name,
    validate_docx_archive,
    validate_epub_archive,
    validate_magic,
)
from app.services.markup_text import (
    TOO_MUCH_TEXT,
    BlockCollector,
    decode_markup,
    parse_html,
    read_html_document,
)
from app.services.text_extractor import TextExtractor

XHTML = "application/xhtml+xml"
OPF_NS = "http://www.idpf.org/2007/opf"
DC_NS = "http://purl.org/dc/elements/1.1/"
FONT_OBFUSCATION = "http://www.idpf.org/2008/embedding"
AES = "http://www.w3.org/2001/04/xmlenc#aes128-cbc"
NON_LINEAR = ' linear="no"'


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="ss_ebook_test_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    text_extractor._load_markup_document.cache_clear()
    yield tmp
    text_extractor._load_markup_document.cache_clear()
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


def open_bytes(path) -> bytes:
    return Path(path).read_bytes()


def words(marker: str, count: int) -> str:
    return " ".join(f"{marker}{i}" for i in range(count))


def xhtml(body: str, encoding: str = "utf-8") -> str:
    return (
        f'<?xml version="1.0" encoding="{encoding}"?>\n<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops">'
        "<head><title>Ignored head title</title>"
        "<style>p { color: red }</style><script>var hidden = 1;</script></head>"
        f"<body>{body}</body></html>"
    )


@dataclass
class Chapter:
    body: str
    label: str | None = None
    fragment: str | None = None
    children: list[Chapter] = field(default_factory=list)
    linear: bool = True


def nav_document(chapters: list[Chapter]) -> str:
    def items(entries: list[tuple[int, Chapter]]) -> str:
        out = []
        for index, chapter in entries:
            href = f"text/ch{index}.xhtml" + (
                f"#{chapter.fragment}" if chapter.fragment else ""
            )
            nested = ""
            if chapter.children:
                nested = (
                    "<ol>"
                    + "".join(
                        f'<li><a href="text/ch{index}.xhtml#{child.fragment}">'
                        f"{child.label}</a></li>"
                        for child in chapter.children
                    )
                    + "</ol>"
                )
            out.append(f'<li><a href="{href}">{chapter.label}</a>{nested}</li>')
        return "".join(out)

    labelled = [(i, c) for i, c in enumerate(chapters) if c.label]
    return xhtml(
        '<nav epub:type="landmarks"><ol><li><a href="text/ch0.xhtml">Start</a>'
        "</li></ol></nav>"
        f'<nav epub:type="toc"><h1>Contents</h1><ol>{items(labelled)}</ol></nav>'
    )


def ncx_document(chapters: list[Chapter]) -> str:
    points = []
    for order, (index, chapter) in enumerate(
        (i, c) for i, c in enumerate(chapters) if c.label
    ):
        src = f"text/ch{index}.xhtml" + (
            f"#{chapter.fragment}" if chapter.fragment else ""
        )
        children = "".join(
            f'<navPoint id="c{index}-{n}"><navLabel><text>{child.label}</text>'
            f'</navLabel><content src="text/ch{index}.xhtml#{child.fragment}"/>'
            "</navPoint>"
            for n, child in enumerate(chapter.children)
        )
        points.append(
            f'<navPoint id="p{order}" playOrder="{order + 1}"><navLabel><text>'
            f'{chapter.label}</text></navLabel><content src="{src}"/>{children}'
            "</navPoint>"
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
        f'<head/><docTitle><text>Book</text></docTitle><navMap>{"".join(points)}'
        "</navMap></ncx>"
    )


def png_bytes(color=(200, 30, 30, 255), size=(60, 90)) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGBA", size, color=color).save(buffer, format="PNG")
    return buffer.getvalue()


def write_epub(
    path,
    chapters: list[Chapter],
    *,
    version: int = 3,
    toc: str | None = "nav",
    cover: bytes | None = None,
    title: str = "The Test Book",
    authors: tuple[str, ...] = ("Ada Writer",),
    encrypted: dict[str, str] | None = None,
    extra: dict[str, bytes] | None = None,
    package_override: str | None = None,
    container_override: str | None = None,
) -> str:
    manifest = [
        f'<item id="ch{i}" href="text/ch{i}.xhtml" media-type="{XHTML}"/>'
        for i in reversed(range(len(chapters)))
    ]
    spine = [
        f'<itemref idref="ch{i}"{"" if c.linear else NON_LINEAR}/>'
        for i, c in enumerate(chapters)
    ]
    metadata_extra = ""
    if toc == "nav":
        manifest.append(
            f'<item id="nav" href="nav.xhtml" media-type="{XHTML}" properties="nav"/>'
        )
        spine.insert(0, '<itemref idref="nav"/>')
    spine_toc = ""
    if toc == "ncx":
        manifest.append(
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
        )
        spine_toc = ' toc="ncx"'
    if cover is not None:
        if version == 3:
            manifest.append(
                '<item id="img" href="images/cover.png" media-type="image/png" '
                'properties="cover-image"/>'
            )
        else:
            manifest.append(
                '<item id="img" href="images/cover.png" media-type="image/png"/>'
            )
            metadata_extra = '<meta name="cover" content="img"/>'
    creators = "".join(
        f'<dc:creator opf:role="aut">{name}</dc:creator>' for name in authors
    )
    package = package_override or (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f'<package xmlns="{OPF_NS}" xmlns:opf="{OPF_NS}" version="{version}.0" '
        'unique-identifier="id">'
        f'<metadata xmlns:dc="{DC_NS}"><dc:title>{title}</dc:title>{creators}'
        f"{metadata_extra}</metadata>"
        f'<manifest>{"".join(manifest)}</manifest>'
        f'<spine{spine_toc}>{"".join(spine)}</spine></package>'
    )
    container = container_override or (
        '<?xml version="1.0"?><container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
        '<rootfile full-path="OEBPS/content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>'
    )
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            zipfile.ZipInfo("mimetype"), "application/epub+zip", zipfile.ZIP_STORED
        )
        archive.writestr("META-INF/container.xml", container)
        archive.writestr("OEBPS/content.opf", package)
        for index, chapter in enumerate(chapters):
            archive.writestr(f"OEBPS/text/ch{index}.xhtml", xhtml(chapter.body))
        if toc == "nav":
            archive.writestr("OEBPS/nav.xhtml", nav_document(chapters))
        if toc == "ncx":
            archive.writestr("OEBPS/toc.ncx", ncx_document(chapters))
        if cover is not None:
            archive.writestr("OEBPS/images/cover.png", cover)
        if encrypted:
            entries = "".join(
                '<enc:EncryptedData><enc:EncryptionMethod Algorithm="'
                f'{algorithm}"/><enc:CipherData><enc:CipherReference URI="{uri}"/>'
                "</enc:CipherData></enc:EncryptedData>"
                for uri, algorithm in encrypted.items()
            )
            archive.writestr(
                "META-INF/encryption.xml",
                '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"'
                f' xmlns:enc="http://www.w3.org/2001/04/xmlenc#">{entries}</encryption>',
            )
        for name, data in (extra or {}).items():
            archive.writestr(name, data)
    return str(path)


def three_chapters() -> list[Chapter]:
    return [
        Chapter(f"<h1>One</h1><p>{words('alpha', 300)}</p>", label="Chapter One"),
        Chapter(f"<h1>Two</h1><p>{words('beta', 300)}</p>", label="Chapter Two"),
        Chapter(f"<h1>Three</h1><p>{words('gamma', 300)}</p>", label="Chapter Three"),
    ]


def page_of(pages: list[str], token: str) -> int:
    return next(i for i, page in enumerate(pages, start=1) if token in page)


# ---------- EPUB reading ----------


def test_epub3_text_follows_spine_order_and_metadata_is_read(tmp_path):
    path = write_epub(
        tmp_path / "book.epub", three_chapters(), authors=("Ada Writer", "Bo Coauthor")
    )

    text = TextExtractor.read_text(path)

    assert text.index("alpha0") < text.index("beta0") < text.index("gamma0")
    assert "Contents" not in text and "Start" not in text
    assert "hidden" not in text and "color" not in text
    assert "Ignored head title" not in text
    assert TextExtractor.read_metadata(path) == (
        "The Test Book",
        "Ada Writer, Bo Coauthor",
    )


def test_epub3_nav_chapters_map_to_the_pages_they_start_on(tmp_path):
    path = write_epub(tmp_path / "book.epub", three_chapters())
    pages = TextExtractor.split_pages(TextExtractor.read_text(path))

    outline = TextExtractor.read_outline(path)

    assert [entry["title"] for entry in outline] == [
        "Chapter One",
        "Chapter Two",
        "Chapter Three",
    ]
    assert [entry["start_page"] for entry in outline] == [
        page_of(pages, "One"),
        page_of(pages, "Two"),
        page_of(pages, "Three"),
    ]
    assert outline[2]["start_page"] > outline[0]["start_page"]
    assert all(entry["level"] == 1 for entry in outline)


def test_epub3_nested_nav_entries_resolve_fragments_and_levels(tmp_path):
    body = (
        f'<h1>Part</h1><p>{words("intro", 50)}</p>'
        f'<h2 id="s1">First</h2><p>{words("first", 420)}</p>'
        f'<section id="s2"><h2>Second</h2><p>{words("second", 420)}</p></section>'
    )
    chapter = Chapter(
        body,
        label="Part One",
        children=[
            Chapter("", label="First Section", fragment="s1"),
            Chapter("", label="Second Section", fragment="s2"),
        ],
    )
    path = write_epub(tmp_path / "nested.epub", [chapter])
    pages = TextExtractor.split_pages(TextExtractor.read_text(path))

    outline = TextExtractor.read_outline(path)

    assert [(entry["title"], entry["level"]) for entry in outline] == [
        ("Part One", 1),
        ("First Section", 2),
        ("Second Section", 2),
    ]
    assert outline[1]["start_page"] == page_of(pages, "First")
    assert outline[2]["start_page"] == page_of(pages, "Second")
    assert outline[2]["start_page"] > outline[1]["start_page"]


def test_epub2_ncx_toc_and_meta_cover_are_used(tmp_path):
    path = write_epub(
        tmp_path / "book2.epub",
        three_chapters(),
        version=2,
        toc="ncx",
        cover=png_bytes(),
    )

    document = read_epub_document(path)
    outline = TextExtractor.read_outline(path)

    assert [entry["title"] for entry in outline] == [
        "Chapter One",
        "Chapter Two",
        "Chapter Three",
    ]
    assert document.cover_member == "OEBPS/images/cover.png"
    assert document.title == "The Test Book"


def test_epub_without_toc_falls_back_to_h1_and_h2_headings(tmp_path):
    chapters = [
        Chapter(f"<h1>Opening</h1><p>{words('a', 300)}</p><h3>Minor</h3>"),
        Chapter(f"<h2>Middle</h2><p>{words('b', 300)}</p>"),
    ]
    path = write_epub(tmp_path / "plain.epub", chapters, toc=None)

    outline = TextExtractor.read_outline(path)

    assert [(entry["title"], entry["level"]) for entry in outline] == [
        ("Opening", 1),
        ("Middle", 2),
    ]


def test_epub_single_entry_toc_prefers_richer_headings(tmp_path):
    chapters = [
        Chapter(f"<h1>Cover</h1><p>{words('c', 20)}</p>", label="Cover"),
        Chapter(f"<h1>Real One</h1><p>{words('r', 300)}</p>"),
        Chapter(f"<h1>Real Two</h1><p>{words('s', 300)}</p>"),
    ]
    path = write_epub(tmp_path / "thin.epub", chapters)

    titles = [entry["title"] for entry in TextExtractor.read_outline(path)]

    assert titles == ["Cover", "Real One", "Real Two"]


def test_epub_without_toc_or_headings_has_no_outline(tmp_path):
    path = write_epub(
        tmp_path / "flat.epub", [Chapter(f"<p>{words('x', 30)}</p>")], toc=None
    )

    assert TextExtractor.read_outline(path) is None


def test_epub_skips_note_markers_backlinks_and_page_breaks(tmp_path):
    body = (
        "<p>Main text<sup><a href='#n1' id='r1'>1</a></sup> continues"
        "<a epub:type='noteref' href='#n2'>2</a> here.</p>"
        "<span epub:type='pagebreak' id='p7' title='7'>7</span>"
        "<p>See chapter <a href='#c4'>4</a> for more.</p>"
        "<aside epub:type='footnote' id='n1'><p>The note body."
        "<a href='#r1'>↩︎</a> <a role='doc-backlink' href='#r1'>Back</a></p></aside>"
        "<p hidden>Secret</p><nav><p>Inline nav</p></nav>"
    )
    path = write_epub(tmp_path / "notes.epub", [Chapter(body)], toc=None)

    text = TextExtractor.read_text(path)

    assert "Main text continues here." in text
    assert "See chapter 4 for more." in text
    assert "The note body." in text
    for noise in ("↩", "Back", "Secret", "Inline nav", "7"):
        assert noise not in text


def test_epub_preserves_preformatted_lines_breaks_and_tables(tmp_path):
    body = (
        "<p>Line one<br/>Line two</p>"
        "<pre>  keep\n    indent</pre>"
        "<table><tr><th>Name</th><th>Age</th></tr>"
        "<tr><td>Ann</td><td>30</td></tr><tr><td></td><td></td></tr></table>"
        "<p>soft\u00adhy\u200bphen and   spaced\n words</p>"
    )
    path = write_epub(tmp_path / "layout.epub", [Chapter(body)], toc=None)

    blocks = read_epub_document(path).blocks

    assert blocks[0] == "Line one\nLine two"
    assert blocks[1] == "  keep\n    indent"
    assert blocks[2] == "| Name | Age |\n| --- | --- |\n| Ann | 30 |"
    assert blocks[3] == "softhyphen and spaced words"


def test_epub_skips_non_linear_and_guide_toc_documents(tmp_path):
    chapters = [
        Chapter(f"<p>{words('kept', 10)}</p>"),
        Chapter("<p>Endnotes popup</p>", linear=False),
        Chapter("<p>Printed contents page</p>"),
    ]
    path = write_epub(tmp_path / "guide.epub", chapters, toc=None)
    with zipfile.ZipFile(path) as archive:
        package = archive.read("OEBPS/content.opf").decode()
    package = package.replace(
        "</package>",
        '<guide><reference type="toc" href="text/ch2.xhtml"/></guide></package>',
    )
    path = write_epub(
        tmp_path / "guide2.epub", chapters, toc=None, package_override=package
    )

    text = TextExtractor.read_text(path)

    assert "kept0" in text
    assert "Endnotes popup" not in text
    assert "Printed contents page" not in text


def test_epub_missing_spine_document_is_skipped(tmp_path):
    chapters = three_chapters()
    path = write_epub(tmp_path / "gap.epub", chapters)
    rebuilt = tmp_path / "gap2.epub"
    with zipfile.ZipFile(path) as source, zipfile.ZipFile(rebuilt, "w") as target:
        for info in source.infolist():
            if info.filename != "OEBPS/text/ch1.xhtml":
                target.writestr(info, source.read(info))

    text = TextExtractor.read_text(str(rebuilt))

    assert "alpha0" in text and "gamma0" in text and "beta0" not in text


def test_epub_decodes_declared_legacy_encoding(tmp_path):
    path = tmp_path / "latin.epub"
    write_epub(path, [Chapter("<p>placeholder</p>")], toc=None)
    rebuilt = tmp_path / "latin2.epub"
    with zipfile.ZipFile(path) as source, zipfile.ZipFile(rebuilt, "w") as target:
        for info in source.infolist():
            data = source.read(info)
            if info.filename == "OEBPS/text/ch0.xhtml":
                data = xhtml("<p>Café déjà vu</p>", "iso-8859-1").encode("latin-1")
            target.writestr(info, data)

    assert TextExtractor.read_text(str(rebuilt)) == "Café déjà vu"


def test_epub_with_no_readable_text_yields_one_empty_page(tmp_path):
    path = write_epub(
        tmp_path / "images.epub",
        [Chapter("<img src='a.png' alt='A picture'/>")],
        toc=None,
    )

    assert TextExtractor.split_pages(TextExtractor.read_text(path)) == [""]


def test_epub_text_limit_is_enforced(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "MAX_EXTRACTED_TEXT_CHARS", 500)
    path = write_epub(tmp_path / "long.epub", three_chapters())

    with pytest.raises(ImportLimitError, match="more text"):
        read_epub_document(path)
    assert TOO_MUCH_TEXT.startswith("This book")


def test_epub_parse_is_cached_until_the_file_changes(tmp_path, monkeypatch):
    path = write_epub(tmp_path / "cached.epub", three_chapters())
    calls = []
    original = text_extractor.read_epub_document

    def counting(source):
        calls.append(source)
        return original(source)

    monkeypatch.setattr(text_extractor, "read_epub_document", counting)

    TextExtractor.page_count(path)
    TextExtractor.sample_word_count(path)
    TextExtractor.read_outline(path)
    assert len(calls) == 1

    write_epub(tmp_path / "cached.epub", three_chapters()[:1])
    os.utime(path, ns=(1, 1))
    assert "beta0" not in TextExtractor.read_text(path)
    assert len(calls) == 2


def test_concurrent_epub_reads_agree(tmp_path):
    path = write_epub(tmp_path / "shared.epub", three_chapters())
    barrier = threading.Barrier(8)

    def read() -> str:
        barrier.wait()
        return TextExtractor.read_text(path)

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: read(), range(8)))

    assert len(set(results)) == 1 and "gamma299" in results[0]


def test_resolve_href_rejects_escapes_and_external_links():
    assert resolve_href("OEBPS", "text/a%20b.xhtml#x") == ("OEBPS/text/a b.xhtml", "x")
    assert resolve_href("OEBPS/text", "../img/c.png") == ("OEBPS/img/c.png", "")
    for href in (
        "../../etc/passwd",
        "/etc/passwd",
        "https://example.com/a.xhtml",
        "file:///etc/passwd",
        "#only-fragment",
        "",
        None,
        "a\\..\\b",
    ):
        assert resolve_href("OEBPS", href) is None


# ---------- EPUB failure modes ----------


def test_drm_encrypted_content_is_rejected_with_a_clear_message(tmp_path):
    path = write_epub(
        tmp_path / "drm.epub",
        three_chapters(),
        encrypted={"OEBPS/text/ch1.xhtml": AES},
    )

    with pytest.raises(ImportLimitError, match="DRM"):
        read_epub_document(path)


def test_drm_reference_with_a_leading_slash_is_still_rejected(tmp_path):
    path = write_epub(
        tmp_path / "drm-root.epub",
        three_chapters(),
        encrypted={"/OEBPS/text/ch1.xhtml": AES},
    )

    with pytest.raises(ImportLimitError, match="DRM"):
        read_epub_document(path)


def test_obfuscated_fonts_alone_are_not_treated_as_drm(tmp_path):
    path = write_epub(
        tmp_path / "fonts.epub",
        three_chapters(),
        encrypted={"OEBPS/fonts/a.otf": FONT_OBFUSCATION},
        extra={"OEBPS/fonts/a.otf": b"\x00\x01font"},
    )

    assert "alpha0" in TextExtractor.read_text(path)


def _set_central_flag(path, member: str, flag: int) -> None:
    data = bytearray(open_bytes(path))
    position = data.find(b"PK\x01\x02")
    while position != -1:
        name_length = int.from_bytes(data[position + 28 : position + 30], "little")
        name = bytes(data[position + 46 : position + 46 + name_length])
        if name == member.encode():
            flags = int.from_bytes(data[position + 8 : position + 10], "little")
            data[position + 8 : position + 10] = (flags | flag).to_bytes(2, "little")
        position = data.find(b"PK\x01\x02", position + 4)
    Path(path).write_bytes(bytes(data))


def test_zip_level_encrypted_entry_is_reported_as_drm(tmp_path):
    path = write_epub(tmp_path / "zipcrypt.epub", three_chapters())
    _set_central_flag(path, "OEBPS/text/ch1.xhtml", 0x1)

    with pytest.raises(ImportLimitError, match="DRM"):
        read_epub_document(path)


@pytest.mark.parametrize(
    "package",
    [
        "<package><manifest><item",
        "<package xmlns='http://www.idpf.org/2007/opf'><spine/></package>",
        "<package xmlns='http://www.idpf.org/2007/opf'><manifest/></package>",
    ],
)
def test_malformed_or_incomplete_package_is_a_clear_error(tmp_path, package):
    path = write_epub(tmp_path / "bad.epub", three_chapters(), package_override=package)

    with pytest.raises(ImportLimitError) as raised:
        read_epub_document(path)
    assert str(raised.value) == DAMAGED


@pytest.mark.parametrize(
    "container",
    [
        "<container><rootfiles>",
        "<container><rootfiles><rootfile full-path='../escape.opf'/></rootfiles>"
        "</container>",
        "<container><rootfiles/></container>",
        "<container><rootfiles><rootfile full-path='missing.opf'/></rootfiles>"
        "</container>",
    ],
)
def test_bad_container_is_a_clear_error(tmp_path, container):
    path = write_epub(
        tmp_path / "bad.epub", three_chapters(), container_override=container
    )

    with pytest.raises(ImportLimitError) as raised:
        read_epub_document(path)
    assert str(raised.value) == DAMAGED


def test_malformed_encryption_manifest_is_a_clear_error(tmp_path):
    path = write_epub(
        tmp_path / "enc.epub",
        three_chapters(),
        extra={"META-INF/encryption.xml": b"<encryption><broken"},
    )

    with pytest.raises(ImportLimitError, match="damaged"):
        read_epub_document(path)


def test_malformed_ncx_falls_back_to_headings(tmp_path):
    path = write_epub(tmp_path / "ncx.epub", three_chapters(), toc="ncx")
    rebuilt = tmp_path / "ncx2.epub"
    with zipfile.ZipFile(path) as source, zipfile.ZipFile(rebuilt, "w") as target:
        for info in source.infolist():
            data = source.read(info)
            if info.filename == "OEBPS/toc.ncx":
                data = b"<ncx><navMap><navPoint>"
            target.writestr(info, data)

    titles = [entry["title"] for entry in TextExtractor.read_outline(str(rebuilt))]

    assert titles == ["One", "Two", "Three"]


def test_external_entities_are_never_resolved(tmp_path):
    secret = tmp_path / "secret.txt"
    secret.write_text("TOPSECRET")
    package = (
        '<?xml version="1.0"?><!DOCTYPE package [<!ENTITY leak SYSTEM '
        f'"file://{secret}"><!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;'
        '&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]>'
        f'<package xmlns="{OPF_NS}" version="3.0"><metadata xmlns:dc="{DC_NS}">'
        "<dc:title>T &leak; &c;</dc:title></metadata><manifest>"
        f'<item id="ch0" href="text/ch0.xhtml" media-type="{XHTML}"/></manifest>'
        '<spine><itemref idref="ch0"/></spine></package>'
    )
    path = write_epub(
        tmp_path / "xxe.epub",
        [Chapter("<p>Body</p>")],
        toc=None,
        package_override=package,
    )

    document = read_epub_document(path)

    assert "TOPSECRET" not in (document.title or "")
    assert len(document.title or "") < 300


def test_read_epub_member_bounds_size(tmp_path):
    path = write_epub(tmp_path / "cover.epub", three_chapters(), cover=png_bytes())

    with pytest.raises(ImportLimitError, match="too large"):
        read_epub_member(path, "OEBPS/images/cover.png", 10)
    with pytest.raises(ImportLimitError, match="damaged"):
        read_epub_member(path, "OEBPS/images/absent.png", 10_000)


def test_unreadable_epub_outline_is_none_not_an_exception(tmp_path):
    path = tmp_path / "broken.epub"
    path.write_bytes(b"PK\x03\x04 not really")

    assert TextExtractor.read_outline(str(path)) is None


# ---------- archive validation ----------


def test_epub_archive_validator_accepts_a_normal_book(tmp_path):
    path = write_epub(tmp_path / "ok.epub", three_chapters(), cover=png_bytes())

    validate_magic(path, "epub")
    validate_epub_archive(path)


def test_epub_magic_rejects_renamed_file(tmp_path):
    path = tmp_path / "fake.epub"
    path.write_bytes(b"%PDF-1.4 not a zip")

    with pytest.raises(ImportLimitError, match="not a valid EPUB"):
        validate_magic(str(path), "epub")


@pytest.mark.parametrize(
    "name", ["../evil.xhtml", "/etc/evil.xhtml", "OEBPS\\..\\evil", "C:/evil"]
)
def test_epub_validator_rejects_traversal_names(tmp_path, name):
    path = write_epub(tmp_path / "trav.epub", three_chapters(), extra={name: b"x"})

    with pytest.raises(ImportLimitError, match="unsafe"):
        validate_epub_archive(path)
    with pytest.raises(ImportLimitError, match="unsafe"):
        read_epub_document(path)


@pytest.mark.parametrize("name", [".", "./", ""])
def test_member_names_without_parts_are_unsafe_not_a_crash(tmp_path, name):
    assert not is_safe_member_name(name)
    if not name:
        return
    path = write_epub(tmp_path / "dot.epub", three_chapters(), extra={name: b"x"})
    with pytest.raises(ImportLimitError, match="unsafe"):
        validate_epub_archive(path)
    docx = tmp_path / "dot.docx"
    with zipfile.ZipFile(docx, "w") as archive:
        archive.writestr("word/document.xml", "<w:document/>")
        archive.writestr(name, b"x")
    with pytest.raises(ImportLimitError, match="unsafe"):
        validate_docx_archive(str(docx))


def test_epub_validator_rejects_symlinks(tmp_path):
    path = write_epub(tmp_path / "link.epub", three_chapters())
    with zipfile.ZipFile(path, "a") as archive:
        info = zipfile.ZipInfo("OEBPS/link")
        info.external_attr = (0o120777 << 16) | 0
        archive.writestr(info, "/etc/passwd")

    with pytest.raises(ImportLimitError, match="link"):
        validate_epub_archive(path)


def test_epub_validator_rejects_zip_bomb(tmp_path):
    path = write_epub(
        tmp_path / "bomb.epub",
        three_chapters(),
        extra={"OEBPS/text/bomb.xhtml": b"a" * 5_000_000},
    )

    with pytest.raises(ImportLimitError, match="compressed"):
        validate_epub_archive(path)


def test_epub_validator_rejects_whole_archive_ratio(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "MAX_EPUB_COMPRESSION_RATIO", 2)
    monkeypatch.setattr(settings, "DOCX_RATIO_CHECK_MIN_BYTES", 10**9)
    path = write_epub(tmp_path / "ratio.epub", three_chapters())

    with pytest.raises(ImportLimitError, match="compressed"):
        validate_epub_archive(path)


def test_epub_validator_bounds_member_count_and_expansion(tmp_path, monkeypatch):
    path = write_epub(tmp_path / "many.epub", three_chapters())

    monkeypatch.setattr(settings, "MAX_EPUB_MEMBERS", 3)
    with pytest.raises(ImportLimitError, match="too many"):
        validate_epub_archive(path)
    monkeypatch.setattr(settings, "MAX_EPUB_MEMBERS", 5000)

    monkeypatch.setattr(settings, "MAX_EPUB_EXPANDED_BYTES", 1000)
    with pytest.raises(ImportLimitError, match="expands"):
        validate_epub_archive(path)
    monkeypatch.setattr(settings, "MAX_EPUB_EXPANDED_BYTES", 300 * 1024 * 1024)

    monkeypatch.setattr(settings, "MAX_EPUB_MEMBER_BYTES", 1000)
    with pytest.raises(ImportLimitError, match="too large"):
        validate_epub_archive(path)


def test_epub_validator_requires_container_and_zip(tmp_path):
    no_container = tmp_path / "nocontainer.epub"
    with zipfile.ZipFile(no_container, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip")
    not_zip = tmp_path / "notzip.epub"
    not_zip.write_bytes(b"PK\x03\x04garbage")

    for path in (no_container, not_zip):
        with pytest.raises(ImportLimitError, match="not a readable EPUB"):
            validate_epub_archive(str(path))


# ---------- covers ----------


def _epub_book(tmp_path, chapters: list[Chapter] | None = None, **kwargs) -> str:
    book_id = AudiobookStore.create_book("book.epub")
    source = AudiobookStore.source_file_path(book_id, "epub")
    write_epub(source, chapters or three_chapters(), **kwargs)
    meta = AudiobookStore.initial_meta(
        book_id, "The Test Book", 3, "kokoro", "af_bella", 1.0, {}
    )
    meta["file_ext"] = "epub"
    AudiobookStore.write_meta(book_id, meta)
    return book_id


def test_epub_cover_image_becomes_the_book_cover(tmp_path):
    book_id = _epub_book(tmp_path, cover=png_bytes(size=(300, 450)))

    TextExtractor.render_cover(book_id)

    path = AudiobookStore.cover_path(book_id)
    assert TextExtractor.cover_is_current(path)
    with Image.open(path) as cover:
        assert cover.format == "JPEG"
        assert cover.size == (300, 450)
        red, green, blue = cover.getpixel((150, 225))
        assert red > 150 and green < 80 and blue < 80


def test_large_epub_cover_is_downscaled_and_transparency_flattened(tmp_path):
    book_id = _epub_book(tmp_path, cover=png_bytes((0, 0, 0, 0), size=(2400, 3000)))

    TextExtractor.render_cover(book_id)

    with Image.open(AudiobookStore.cover_path(book_id)) as cover:
        assert cover.width <= 1200 and cover.height <= 1680
        assert min(cover.getpixel((10, 10))) > 240


@pytest.mark.parametrize("problem", ["corrupt", "too_many_pixels", "none"])
def test_epub_cover_problems_fall_back_to_the_text_cover(
    tmp_path, monkeypatch, problem
):
    cover = {"corrupt": b"not an image", "too_many_pixels": png_bytes()}.get(problem)
    if problem == "too_many_pixels":
        monkeypatch.setattr(settings, "MAX_COVER_IMAGE_PIXELS", 100)
    book_id = _epub_book(tmp_path, cover=cover)

    TextExtractor.render_cover(book_id)

    with Image.open(AudiobookStore.cover_path(book_id)) as rendered:
        assert rendered.size == (600, 840)
        assert min(rendered.getpixel((5, 5))) > 230


# ---------- HTML ----------


def test_html_headings_become_chapters_and_noise_is_skipped(tmp_path):
    path = tmp_path / "page.html"
    path.write_text(
        "<!doctype html><html><head><title>Site | Page</title>"
        "<script>alert(1)</script><style>body{}</style></head><body>"
        "<nav><a href='/'>Home</a></nav>"
        f"<h1>Intro</h1><p>{words('intro', 300)}</p><h3>Detail</h3>"
        f"<h2>Next</h2><p>{words('next', 300)}</p>"
        "<form><button>Subscribe</button></form></body></html>",
        encoding="utf-8",
    )
    source = str(path)
    pages = TextExtractor.split_pages(TextExtractor.read_text(source))

    outline = TextExtractor.read_outline(source)
    text = TextExtractor.read_text(source)

    assert [(entry["title"], entry["level"]) for entry in outline] == [
        ("Intro", 1),
        ("Next", 2),
    ]
    assert outline[1]["start_page"] == page_of(pages, "Next")
    assert "Detail" in text
    for noise in ("alert", "Home", "Subscribe", "Site | Page", "body{}"):
        assert noise not in text
    assert TextExtractor.read_metadata(source) == (None, None)


def test_htm_without_headings_has_no_outline_and_reads_legacy_bytes(tmp_path):
    path = tmp_path / "old.htm"
    path.write_bytes("<p>Na\u00efve r\u00e9sum\u00e9</p>".encode("cp1252"))

    assert TextExtractor.read_text(str(path)) == "Naïve résumé"
    assert TextExtractor.read_outline(str(path)) is None


def test_block_anchors_point_at_their_own_block_even_on_skipped_elements():
    markup = xhtml(
        '<div>loose intro<h2 id="c2">Two</h2><p>body '
        '<span epub:type="pagebreak" id="p7" title="7"/>rest</p></div>'
    )
    root = parse_html(decode_markup(markup.encode()))
    collector = BlockCollector(10_000)

    collector.add_document(root, "ch.xhtml")

    assert collector.blocks == ["loose intro", "Two", "body rest"]
    assert collector.blocks[collector.anchors["ch.xhtml#c2"]] == "Two"
    assert collector.blocks[collector.anchors["ch.xhtml#p7"]] == "body rest"


def test_html_binary_and_oversized_files_are_rejected(tmp_path, monkeypatch):
    binary = tmp_path / "binary.html"
    binary.write_bytes(b"\x89PNG\r\n\x1a\n\x00\x00\x00" + os.urandom(64))
    with pytest.raises(ImportLimitError, match="readable web page"):
        read_html_document(str(binary))

    big = tmp_path / "big.html"
    big.write_text("<p>" + "x" * 200 + "</p>")
    monkeypatch.setattr(settings, "MAX_HTML_SOURCE_BYTES", 100)
    with pytest.raises(ImportLimitError, match="too large"):
        read_html_document(str(big))


def test_html_utf16_with_bom_is_decoded(tmp_path):
    path = tmp_path / "wide.html"
    path.write_bytes("<p>Wide text</p>".encode("utf-16"))

    assert TextExtractor.read_text(str(path)) == "Wide text"


def test_decode_markup_honours_meta_charset_and_unknown_labels():
    latin = "<meta charset='iso-8859-1'><p>caf\u00e9</p>".encode("latin-1")
    unknown = '<?xml version="1.0" encoding="x-unknown"?><p>ok</p>'.encode()

    assert "café" in decode_markup(latin)
    assert decode_markup(unknown) == "<p>ok</p>"
    assert parse_html("") is None


# ---------- pipeline and API ----------


@pytest.mark.asyncio
async def test_local_section_phase_uses_the_epub_table_of_contents(tmp_path):
    chapters = [
        Chapter(f"<h1>{n}</h1><p>{words(n, 700)}</p>", label=f"Chapter {n}")
        for n in ("One", "Two", "Three")
    ]
    book_id = _epub_book(tmp_path, chapters)
    page_count = TextExtractor.page_count(
        AudiobookStore.source_file_path(book_id, "epub")
    )
    await AudiobookStore.update_meta(book_id, page_count=page_count)

    await AudiobookService._phase_section(
        book_id, None, AudiobookStore.read_meta(book_id)
    )

    sections = AudiobookStore.read_meta(book_id)["sections"]
    assert [section["title"] for section in sections] == [
        "Chapter One",
        "Chapter Two",
        "Chapter Three",
    ]


def _upload(filename: str, content: bytes, content_type: str = "application/epub+zip"):
    from app.main import app

    return TestClient(app).post(
        "/audiobook", files={"file": (filename, content, content_type)}
    )


@pytest.fixture
def no_cover_render(monkeypatch):
    rendered: list[str] = []
    monkeypatch.setattr(
        TextExtractor, "render_cover", classmethod(lambda cls, b: rendered.append(b))
    )
    return rendered


def test_upload_epub_uses_package_title_and_author(tmp_path, no_cover_render):
    path = write_epub(tmp_path / "file-name.epub", three_chapters())

    response = _upload("file-name.epub", open_bytes(path))

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["title"] == "The Test Book"
    assert body["author"] == "Ada Writer"
    assert body["page_count"] >= 2
    assert body["is_image_only"] is False
    meta = AudiobookStore.read_meta(body["book_id"])
    assert meta["file_ext"] == "epub"
    assert meta["author"] == "Ada Writer"
    assert meta["title"] == "The Test Book"


def test_upload_epub_without_title_keeps_the_file_name(tmp_path, no_cover_render):
    path = write_epub(tmp_path / "x.epub", three_chapters(), title="", authors=())

    body = _upload("Untitled Draft.epub", open_bytes(path)).json()

    assert body["title"] == "Untitled Draft.epub"
    assert body["author"] is None
    assert "author" not in AudiobookStore.read_meta(body["book_id"])


@pytest.mark.parametrize(
    ("filename", "content_type"),
    [("page.html", "text/html"), ("page.htm", "text/html")],
)
def test_upload_html_is_accepted(no_cover_render, filename, content_type):
    content = f"<h1>Title</h1><p>{words('w', 50)}</p>".encode()

    response = _upload(filename, content, content_type)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["title"] == filename
    assert body["author"] is None
    assert AudiobookStore.read_meta(body["book_id"])["file_ext"] == filename[
        -4:
    ].lstrip(".")


def _assert_rejected(response, status: int, fragment: str) -> None:
    assert response.status_code == status, response.text
    assert fragment in response.json()["detail"]
    assert AudiobookStore.list_books() == []
    leftovers = [
        name
        for name in os.listdir(AudiobookStore.root_dir())
        if name not in {"audiobooks.db", "audiobooks.db-wal", "audiobooks.db-shm"}
    ]
    assert leftovers == []


def test_upload_drm_epub_is_rejected_with_the_drm_message(tmp_path, no_cover_render):
    path = write_epub(
        tmp_path / "drm.epub",
        three_chapters(),
        encrypted={"OEBPS/text/ch0.xhtml": AES},
    )

    _assert_rejected(_upload("drm.epub", open_bytes(path)), 400, "DRM")


def test_upload_zip_bomb_epub_is_rejected(tmp_path, no_cover_render):
    path = write_epub(
        tmp_path / "bomb.epub",
        three_chapters(),
        extra={"OEBPS/bomb.bin": b"\x00" * 5_000_000},
    )

    _assert_rejected(_upload("bomb.epub", open_bytes(path)), 400, "compressed")


def test_upload_traversal_epub_is_rejected(tmp_path, no_cover_render):
    path = write_epub(
        tmp_path / "trav.epub", three_chapters(), extra={"../../escape": b"x"}
    )

    _assert_rejected(_upload("trav.epub", open_bytes(path)), 400, "unsafe")


def test_upload_malformed_epub_is_rejected_with_a_clear_message(
    tmp_path, no_cover_render
):
    path = write_epub(tmp_path / "bad.epub", three_chapters(), package_override="<p")

    _assert_rejected(_upload("bad.epub", open_bytes(path)), 400, DAMAGED)


def test_upload_renamed_file_as_epub_is_rejected(no_cover_render):
    _assert_rejected(_upload("fake.epub", b"plain text"), 400, "not a valid EPUB")


def test_upload_epub_without_text_is_rejected(tmp_path, no_cover_render):
    path = write_epub(tmp_path / "pics.epub", [Chapter("<img src='a.png'/>")], toc=None)

    _assert_rejected(
        _upload("pics.epub", open_bytes(path)), 400, "no extractable content"
    )


def test_upload_unsupported_extension_lists_new_formats(no_cover_render):
    response = _upload("book.mobi", b"data", "application/octet-stream")

    assert response.status_code == 400
    assert "EPUB" in response.json()["detail"] and "HTML" in response.json()["detail"]


def test_epub_reader_logs_without_user_text(tmp_path, caplog):
    chapters = three_chapters()
    path = write_epub(tmp_path / "gap.epub", chapters)
    rebuilt = tmp_path / "gap2.epub"
    with zipfile.ZipFile(path) as source, zipfile.ZipFile(rebuilt, "w") as target:
        for info in source.infolist():
            if info.filename != "OEBPS/text/ch2.xhtml":
                target.writestr(info, source.read(info))

    with caplog.at_level("WARNING", logger=epub_reader.log.name):
        read_epub_document(str(rebuilt))

    records = [r for r in caplog.records if r.getMessage() == "epub.spine_item_missing"]
    assert records and records[0].failure_code == "epub_spine_item_missing"
    assert all("alpha" not in r.getMessage() for r in caplog.records)
