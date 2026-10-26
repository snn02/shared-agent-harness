"""Page-addressed PDF extraction with selective OCR and visible coverage gaps."""

import io
import subprocess
from pathlib import Path

import pdfplumber

from ingest_model import ExtractedSource, Figure, Section


def _render(page) -> bytes:
    buffer = io.BytesIO()
    page.to_image(resolution=150).original.convert("RGB").save(buffer, format="PNG")
    return buffer.getvalue()


def _ocr(png: bytes, executable: str, languages: str) -> str:
    listed = subprocess.run([executable, "--list-langs"], capture_output=True, text=True, check=True)
    available = set(listed.stdout.splitlines() + listed.stderr.splitlines())
    missing = [language for language in languages.split("+") if language not in available]
    if missing:
        raise RuntimeError("Missing Tesseract language models: " + ", ".join(missing))
    result = subprocess.run([executable, "stdin", "stdout", "-l", languages],
                            input=png, capture_output=True, check=True)
    return result.stdout.decode("utf-8", errors="replace").strip()


def _possibly_multicolumn(page) -> bool:
    lines: dict[int, list[dict]] = {}
    for word in page.extract_words() or []:
        lines.setdefault(round(word["top"] / 3), []).append(word)
    split_lines = 0
    for words in lines.values():
        words.sort(key=lambda word: word["x0"])
        if any(right["x0"] - left["x1"] > page.width * 0.16
               for left, right in zip(words, words[1:])):
            split_lines += 1
    return split_lines >= 2


def extract_pdf(path: Path, ocr_executable: str | None = None,
                ocr_languages: str = "rus+eng") -> ExtractedSource:
    sections: list[Section] = []
    figures: list[Figure] = []
    warnings: list[str] = []
    with pdfplumber.open(path) as pdf:
        total = len(pdf.pages)
        for number, page in enumerate(pdf.pages, 1):
            locator = f"page {number}"
            text = (page.extract_text(layout=False) or "").strip()
            method = "text"
            if _possibly_multicolumn(page):
                warnings.append(f"{locator}: possible columns; reading order requires review")
            graphical = bool(page.images or page.rects or page.curves or page.lines)
            if graphical:
                try:
                    figures.append(Figure(f"page-{number:04}-visual", locator, _render(page)))
                    warnings.append(f"{locator}: graphics or table layout requires visual review")
                except Exception as exc:
                    warnings.append(f"{locator}: graphics could not be rendered: {exc}")
            if sum(character.isalpha() for character in text) < 2:
                if ocr_executable:
                    try:
                        text = _ocr(_render(page), ocr_executable, ocr_languages)
                        method = "ocr"
                    except Exception as exc:
                        warnings.append(f"{locator}: OCR failed: {exc}")
                        method = "missing"
                else:
                    warnings.append(f"{locator}: no usable text layer; OCR unavailable")
                    method = "missing"
            if not text:
                warnings.append(f"{locator}: no text extracted")
            tables = page.extract_tables() or []
            if tables:
                table_lines = []
                for table in tables:
                    for row in table:
                        table_lines.append("| " + " | ".join((cell or "").replace("|", "\\|") for cell in row) + " |")
                text += "\n\nTables (verify against page image):\n" + "\n".join(table_lines)
                warnings.append(f"{locator}: table reading order requires review")
            sections.append(Section(f"page-{number:04}", locator, locator, text, method))
    return ExtractedSource(sections, figures, total, warnings)
