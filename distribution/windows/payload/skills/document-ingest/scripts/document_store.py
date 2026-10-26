"""Write an ingest result in one explicitly selected document directory."""

import hashlib
import json
import os
import re
import shutil
import tempfile
import uuid
from pathlib import Path

from ingest_model import ExtractedSource, validate_coverage


_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")


def _safe_id(value: str) -> str:
    if not _ID.fullmatch(value) or value in (".", "..") or ".." in value:
        raise ValueError(f"Unsafe identifier: {value!r}")
    return value


def _reject_links(path: Path) -> None:
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError(f"Linked path is not allowed: {item}")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_document(output_dir: Path, expected_id: str | None = None) -> dict:
    output_dir = Path(output_dir).absolute()
    _reject_links(output_dir)
    marker = output_dir / "manifest.json"
    if not marker.is_file() or marker.is_symlink():
        raise ValueError("Ingest manifest is missing or linked")
    manifest = json.loads(marker.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or not _ID.fullmatch(manifest.get("document_id", "")):
        raise ValueError("Ingest manifest is invalid")
    if expected_id is not None and manifest["document_id"] != expected_id:
        raise ValueError("Output belongs to another document")
    paths = [manifest.get("original", ""), "index.md"]
    for row in manifest.get("sections", []):
        paths.append(row["path"])
    for row in manifest.get("figures", []):
        paths.extend((row["path"], row["description"]))
    for relative in paths:
        path = Path(relative)
        if path.is_absolute() or not path.parts or any(part in (".", "..") for part in path.parts):
            raise ValueError("Ingest manifest has an unsafe path")
        full = output_dir / path
        if not full.is_file() or full.is_symlink():
            raise ValueError(f"Ingest file is missing or linked: {relative}")
    if _sha256(output_dir / manifest["original"]) != manifest.get("sha256"):
        raise ValueError("Stored original checksum mismatch")
    return manifest


def finalize_document(output_dir: Path, expected_id: str | None = None) -> str:
    """Reconcile manifest status after a human/agent reviews image descriptions."""
    output_dir = Path(output_dir).absolute()
    manifest = verify_document(output_dir, expected_id)
    pending = []
    for row in manifest.get("figures", []):
        content = (output_dir / row["description"]).read_text(encoding="utf-8")
        first = content.splitlines()[0].strip() if content.splitlines() else ""
        if first not in ("Status: described", "Status: decorative"):
            pending.append(row["id"])
    manifest["status"] = "partial" if manifest.get("gaps") or pending else "complete"
    marker = output_dir / "manifest.json"
    temporary = marker.with_name("manifest-" + uuid.uuid4().hex + ".tmp")
    try:
        temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, marker)
    finally:
        if temporary.exists():
            temporary.unlink()
    return manifest["status"]


def write_document(source: Path, document_id: str, extracted: ExtractedSource,
                   output_dir: Path, update: bool) -> Path:
    source, output_dir = Path(source).absolute(), Path(output_dir).absolute()
    _safe_id(document_id)
    _reject_links(source)
    _reject_links(output_dir)
    if not source.is_file():
        raise ValueError("Source must be a regular file")
    if output_dir.exists() and not output_dir.is_dir():
        raise ValueError("Output must be a directory")
    previous = None
    prior_descriptions: dict[str, str] = {}
    prior_sections: dict[str, tuple[str, str]] = {}
    if output_dir.exists() and any(output_dir.iterdir()):
        marker = output_dir / "manifest.json"
        if not marker.is_file():
            raise ValueError("Output contains foreign files")
        previous = verify_document(output_dir, document_id)
        if previous.get("schema") != 1 or previous.get("document_id") != document_id:
            raise ValueError("Output belongs to another document")
        if not update:
            raise ValueError("Existing result requires --update")
        for row in previous.get("figures", []):
            description = output_dir / row["description"]
            if not description.is_file() or description.is_symlink():
                raise ValueError("Existing image description is missing or linked")
            prior_descriptions[row["sha256"]] = description.read_text(encoding="utf-8")
        for row in previous.get("sections", []):
            old = output_dir / row["path"]
            if not old.is_file() or old.is_symlink():
                raise ValueError("Existing section is missing or linked")
            prior_sections[row["id"]] = (row["locator"], hashlib.sha256(old.read_bytes()).hexdigest())
    if source == output_dir or output_dir in source.parents or source in output_dir.parents:
        raise ValueError("Source and output must not contain one another")
    for item in output_dir.rglob("*") if output_dir.exists() else ():
        if item.is_symlink():
            raise ValueError("Output contains a link")

    ids = [_safe_id(s.id) for s in extracted.sections]
    fig_ids = [_safe_id(f.id) for f in extracted.figures]
    if len(ids) != len(set(ids)) or len(fig_ids) != len(set(fig_ids)):
        raise ValueError("Duplicate section or figure ID")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".ingest-", dir=output_dir.parent))
    backup = None
    try:
        (stage / "sections").mkdir()
        (stage / "images").mkdir()
        original = "original" + source.suffix.lower()
        shutil.copyfile(source, stage / original)
        source_hash = _sha256(source)
        if _sha256(stage / original) != source_hash:
            raise OSError("Original copy failed verification")
        index = [f"# {document_id}", "", f"Original: [{original}]({original})", "", "## Sections", ""]
        section_rows = []
        for section in extracted.sections:
            rel = f"sections/{section.id}.md"
            (stage / rel).write_text(section.markdown.rstrip() + "\n", encoding="utf-8")
            index.append(f"- [{section.title or section.id}]({rel}) — {section.locator}")
            section_rows.append({"id": section.id, "title": section.title, "locator": section.locator,
                                 "method": section.method, "path": rel})
        index.extend(["", "## Images", ""])
        figure_rows = []
        for figure in extracted.figures:
            rel = f"images/{figure.id}.png"
            (stage / rel).write_bytes(figure.png)
            image_hash = hashlib.sha256(figure.png).hexdigest()
            description = f"Status: requires-description\nLocator: {figure.locator}\nCaption: {figure.caption}\nDescription:\n"
            if image_hash in prior_descriptions:
                description = prior_descriptions[image_hash]
                locator_line = f"Locator: {figure.locator}"
                if re.search(r"(?m)^Locator:.*$", description):
                    description = re.sub(r"(?m)^Locator:.*$", lambda _: locator_line, description, count=1)
                else:
                    description = locator_line + "\n" + description
            (stage / (rel + ".md")).write_text(description, encoding="utf-8")
            index.append(f"- [{figure.id}]({rel}) · [description]({rel}.md) — {figure.locator}")
            figure_rows.append({"id": figure.id, "locator": figure.locator, "path": rel,
                                "description": rel + ".md", "sha256": image_hash})
        gaps = validate_coverage(extracted)
        changed = []
        if previous:
            current = {row["id"]: (row["locator"], hashlib.sha256((stage / row["path"]).read_bytes()).hexdigest())
                       for row in section_rows}
            changed = sorted(identifier for identifier in set(prior_sections) | set(current)
                             if prior_sections.get(identifier) != current.get(identifier))
            old_figures = {row["id"]: (row["locator"], row["sha256"]) for row in previous.get("figures", [])}
            new_figures = {row["id"]: (row["locator"], row["sha256"]) for row in figure_rows}
            changed.extend("image:" + identifier for identifier in sorted(set(old_figures) | set(new_figures))
                           if old_figures.get(identifier) != new_figures.get(identifier))
        manifest = {"schema": 1, "document_id": document_id, "sha256": source_hash,
                    "original": original, "status": "partial" if gaps or figure_rows else "complete",
                    "total_units": extracted.total_units, "sections": section_rows,
                    "figures": figure_rows, "gaps": gaps, "changed_references": changed}
        (stage / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (stage / "index.md").write_text("\n".join(index).rstrip() + "\n", encoding="utf-8")
        for row in section_rows + figure_rows:
            if not (stage / row["path"]).is_file():
                raise OSError("Missing indexed file")
        if output_dir.exists():
            backup = output_dir.with_name(output_dir.name + ".backup-" + uuid.uuid4().hex)
            output_dir.rename(backup)
        try:
            stage.rename(output_dir)
        except Exception:
            if backup is not None:
                backup.rename(output_dir)
            raise
        if backup is not None:
            shutil.rmtree(backup)
        return output_dir
    finally:
        if stage.exists():
            shutil.rmtree(stage)
