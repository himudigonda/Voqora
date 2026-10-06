import threading

from PIL import Image

from app.services.pdf_extractor import PDFExtractor


def _image_pdf(path, pages=40):
    frames = [Image.new("RGB", (400, 520), (255, 255, 255)) for _ in range(pages)]
    frames[0].save(path, save_all=True, append_images=frames[1:])
    return str(path)


def test_concurrent_pdf_reads_do_not_corrupt_pdfium(tmp_path):
    pdf = _image_pdf(tmp_path / "doc.pdf")
    errors: list[str] = []

    def work(fn):
        for _ in range(15):
            try:
                fn(pdf)
            except Exception as exc:
                errors.append(repr(exc))

    threads = [
        threading.Thread(target=work, args=(fn,))
        for fn in (
            PDFExtractor.read_page_texts,
            PDFExtractor.sample_word_count,
            PDFExtractor.is_image_only,
            PDFExtractor.read_outline,
            lambda p: PDFExtractor.render_page_image(p, 1, resolution=72),
        )
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=60)

    assert not any(t.is_alive() for t in threads)
    assert errors == []
