"""Safely extract FictionBook sections, notes, tables and embedded images."""

import base64
import binascii
import hashlib
import io
from pathlib import Path

from defusedxml import ElementTree as ET
from PIL import Image

from ingest_model import ExtractedSource, Figure, Section


MAX_XML = 250 * 1024 * 1024
MAX_IMAGE = 25 * 1024 * 1024


def _name(element) -> str:
    return element.tag.rsplit("}", 1)[-1]


def _text(element) -> str:
    return " ".join("".join(element.itertext()).split())


def extract_fb2(path: Path) -> ExtractedSource:
    path = Path(path)
    if path.stat().st_size > MAX_XML:
        raise ValueError("FB2 exceeds size limit")
    root = ET.parse(path).getroot()
    if _name(root) != "FictionBook":
        raise ValueError("Not an FB2 document")
    images: dict[str, bytes] = {}
    for element in root:
        if _name(element) != "binary":
            continue
        identifier = element.get("id", "")
        encoded = "".join((element.text or "").split())
        if len(encoded) > MAX_IMAGE * 4 // 3 + 8:
            raise ValueError("Embedded image exceeds size limit")
        try:
            raw = base64.b64decode(encoded, validate=True)
            if len(raw) > MAX_IMAGE:
                raise ValueError("Embedded image exceeds size limit")
            with Image.open(io.BytesIO(raw)) as image:
                image.verify()
            images[identifier] = raw
        except (binascii.Error, OSError) as exc:
            raise ValueError(f"Invalid embedded image: {identifier}") from exc
    sections: list[Section] = []
    figures: list[Figure] = []
    warnings: list[str] = []
    seen: set[str] = set()

    def add_image(element, locator: str) -> None:
        href = element.get("{http://www.w3.org/1999/xlink}href", "").lstrip("#")
        if href not in images:
            warnings.append(f"Unresolved image at {locator}: {href}")
            return
        raw = images[href]
        digest = hashlib.sha256(raw).hexdigest()
        if digest in seen:
            return
        seen.add(digest)
        buffer = io.BytesIO()
        with Image.open(io.BytesIO(raw)) as image:
            image.convert("RGB").save(buffer, "PNG")
        figures.append(Figure(f"figure-{len(figures)+1:04}", locator, buffer.getvalue()))

    def visit(section, path_parts: list[str]) -> None:
        identifier = section.get("id") or f"section-{len(sections)+1}"
        locator = "/".join(path_parts + [identifier])
        title = next((_text(child) for child in section if _name(child) == "title"), identifier)
        lines: list[str] = []
        for child in section:
            kind = _name(child)
            if kind == "section":
                continue
            for descendant in child.iter():
                if _name(descendant) == "image":
                    add_image(descendant, locator)
            if kind == "empty-line":
                lines.append("")
            elif kind == "title":
                lines.append("# " + _text(child))
            elif kind in ("p", "subtitle", "epigraph", "poem", "cite"):
                lines.append(_text(child))
            elif kind == "table":
                for row in child:
                    if _name(row) == "tr":
                        lines.append("| " + " | ".join(_text(cell).replace("|", "\\|") for cell in row) + " |")
            elif kind == "image":
                pass
            else:
                value = _text(child)
                if value:
                    lines.append(value)
                warnings.append(f"FB2 element requires review at {locator}: {kind}")
        sections.append(Section(f"section-{len(sections)+1:04}", title, locator,
                                "\n\n".join(lines), "fb2"))
        for child in section:
            if _name(child) == "section":
                visit(child, path_parts + [identifier])

    for description in root:
        if _name(description) != "description":
            continue
        for info in description:
            if _name(info) != "title-info":
                continue
            metadata = []
            for field in info:
                if _name(field) == "coverpage":
                    for element in field.iter():
                        if _name(element) == "image":
                            add_image(element, "metadata/coverpage")
                if _name(field) == "annotation":
                    for paragraph in field.iter():
                        if _name(paragraph) == "p" and _text(paragraph):
                            metadata.append(_text(paragraph))
            if metadata:
                sections.append(Section("metadata-annotation", "Annotation", "metadata/annotation",
                                        "\n\n".join(metadata), "fb2"))

    for body_no, body in enumerate(root, 1):
        if _name(body) != "body":
            continue
        prefix = [body.get("name") or "main"]
        intro = []
        for child in body:
            kind = _name(child)
            if kind == "section":
                continue
            if kind == "empty-line":
                intro.append("")
            else:
                value = _text(child)
                if value:
                    intro.append(value)
                for descendant in child.iter():
                    if _name(descendant) == "image":
                        add_image(descendant, "/".join(prefix) + "/intro")
        if any(part.strip() for part in intro):
            sections.append(Section(f"body-intro-{body_no:04}", "Body introduction",
                                    "/".join(prefix) + "/intro", "\n\n".join(intro), "fb2"))
        for child in body:
            if _name(child) == "section":
                visit(child, prefix)
    if not sections:
        warnings.append("No FB2 sections found")
    return ExtractedSource(sections, figures, len(sections), warnings)
