"""Single-file, explicit-output entry point for universal document ingest."""

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

from document_store import finalize_document, verify_document, write_document


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="Ingest one local DOCX, PDF or FB2 into an explicit directory")
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--document-id", required=True)
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--finalize", action="store_true", help="Recheck image descriptions after visual review")
    parser.add_argument("--ocr-langs", default="rus+eng")
    args = parser.parse_args()
    source = args.source.absolute()
    output = args.output.absolute()
    if not source.is_file() or source.is_symlink():
        parser.error("--source must be an existing regular file")
    suffix = source.suffix.lower()
    if suffix not in (".docx", ".pdf", ".fb2"):
        parser.error("Supported formats: DOCX, PDF, FB2")
    if args.finalize:
        prior = verify_document(output, args.document_id)
        if prior.get("sha256") != sha256(source):
            parser.error("Source changed; ingest the new edition before finalization")
        print(finalize_document(output, args.document_id))
        return 0
    if output.is_dir() and (output / "manifest.json").is_file():
        previous = verify_document(output, args.document_id)
        if not args.update and previous.get("document_id") == args.document_id and previous.get("sha256") == sha256(source):
            print(str(output))
            return 0
        if not args.update:
            parser.error("Source changed; rerun with --update after review")
    if suffix == ".docx":
        from extract_docx import extract_docx
        extracted = extract_docx(source)
    elif suffix == ".fb2":
        from extract_fb2 import extract_fb2
        extracted = extract_fb2(source)
    else:
        from extract_pdf import extract_pdf
        extracted = extract_pdf(source, shutil.which("tesseract"), args.ocr_langs)
    write_document(source, args.document_id, extracted, output, args.update)
    print(str(output))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, RuntimeError) as exc:
        print(f"Ingest failed: {exc}", file=sys.stderr)
        sys.exit(1)
