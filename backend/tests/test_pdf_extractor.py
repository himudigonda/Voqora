from __future__ import annotations

import io
import os

from app.services.pdf_extractor import PDFExtractor


def _pdf_with_outline(page_count: int, outline: list[dict]) -> bytes:
    objects: dict[int, bytes] = {}
    page_ids = [4 + i for i in range(page_count)]
    next_id = 4 + page_count

    def alloc() -> int:
        nonlocal next_id
        next_id += 1
        return next_id - 1

    def build(items: list[dict], parent: int) -> tuple[int, int, int]:
        ids = [alloc() for _ in items]
        total = 0
        for index, (item, item_id) in enumerate(zip(items, ids, strict=True)):
            parts = [
                f"/Title ({item['title']})",
                f"/Parent {parent} 0 R",
                f"/Dest [{page_ids[item['page']]} 0 R /Fit]",
            ]
            if index > 0:
                parts.append(f"/Prev {ids[index - 1]} 0 R")
            if index + 1 < len(ids):
                parts.append(f"/Next {ids[index + 1]} 0 R")
            descendants = 0
            if item.get("children"):
                first, last, descendants = build(item["children"], item_id)
                parts.append(
                    f"/First {first} 0 R /Last {last} 0 R /Count {descendants}"
                )
            objects[item_id] = f"<< {' '.join(parts)} >>".encode()
            total += 1 + descendants
        return ids[0], ids[-1], total

    first, last, count = build(outline, 3)
    objects[1] = b"<< /Type /Catalog /Pages 2 0 R /Outlines 3 0 R >>"
    kids = " ".join(f"{i} 0 R" for i in page_ids)
    objects[2] = f"<< /Type /Pages /Kids [{kids}] /Count {page_count} >>".encode()
    objects[3] = (
        f"<< /Type /Outlines /First {first} 0 R /Last {last} 0 R /Count {count} >>"
    ).encode()
    for page_id in page_ids:
        objects[page_id] = b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>"

    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets: dict[int, int] = {}
    for object_id in sorted(objects):
        offsets[object_id] = out.tell()
        out.write(f"{object_id} 0 obj\n".encode() + objects[object_id] + b"\nendobj\n")
    xref_at = out.tell()
    size = max(objects) + 1
    out.write(f"xref\n0 {size}\n".encode())
    out.write(b"0000000000 65535 f \n")
    for object_id in range(1, size):
        out.write(f"{offsets[object_id]:010d} 00000 n \n".encode())
    out.write(
        f"trailer\n<< /Size {size} /Root 1 0 R >>\nstartxref\n{xref_at}\n%%EOF\n".encode()
    )
    return out.getvalue()


def _write(tmp_path, page_count: int, outline: list[dict]) -> str:
    path = os.path.join(tmp_path, "outlined.pdf")
    with open(path, "wb") as f:
        f.write(_pdf_with_outline(page_count, outline))
    return path


def test_read_outline_reports_titles_pages_and_nesting_level(tmp_path):
    path = _write(
        tmp_path,
        5,
        [
            {
                "title": "Part One",
                "page": 0,
                "children": [
                    {"title": "Chapter One", "page": 1},
                    {"title": "Chapter Two", "page": 2},
                ],
            },
            {"title": "Part Two", "page": 3},
        ],
    )

    assert PDFExtractor.read_outline(path) == [
        {"title": "Part One", "start_page": 1, "level": 0},
        {"title": "Chapter One", "start_page": 2, "level": 1},
        {"title": "Chapter Two", "start_page": 3, "level": 1},
        {"title": "Part Two", "start_page": 4, "level": 0},
    ]


def test_read_outline_skips_blank_titles(tmp_path):
    path = _write(
        tmp_path,
        3,
        [
            {"title": "   ", "page": 0},
            {"title": "Real Chapter", "page": 1},
        ],
    )

    assert PDFExtractor.read_outline(path) == [
        {"title": "Real Chapter", "start_page": 2, "level": 0}
    ]


def test_read_outline_returns_none_without_an_outline(tmp_path):
    from PIL import Image

    path = str(tmp_path / "plain.pdf")
    Image.new("RGB", (200, 200), (255, 255, 255)).save(path)

    assert PDFExtractor.read_outline(path) is None


def test_outline_fixture_is_a_valid_pdf(tmp_path):
    path = _write(tmp_path, 3, [{"title": "Only", "page": 0}])

    assert PDFExtractor.page_count(path) == 3


def test_read_outline_returns_none_for_unreadable_file(tmp_path):
    path = str(tmp_path / "broken.pdf")
    with open(path, "wb") as f:
        f.write(b"not a pdf")

    assert PDFExtractor.read_outline(path) is None


def test_atomic_write_leaves_no_tmp_files(tmp_path):
    out = str(tmp_path / "pages" / "001.txt")

    PDFExtractor._atomic_write(out, "hello")

    assert os.listdir(tmp_path / "pages") == ["001.txt"]
    with open(out, encoding="utf-8") as f:
        assert f.read() == "hello"
