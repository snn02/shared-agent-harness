import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[2] / "distribution/windows/payload/skills/document-ingest/scripts"
SCRATCH = Path(__file__).resolve().parents[2] / "dist" / "test-scratch"
SCRATCH.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(SCRIPTS))
from ingest_model import ExtractedSource, Figure, Section
from document_store import finalize_document, write_document


class DocumentStoreTests(unittest.TestCase):
    def test_writes_self_contained_result_and_marks_gaps(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            root = Path(root)
            source = root / "book.fb2"
            source.write_bytes(b"source bytes")
            extracted = ExtractedSource(
                sections=[Section("s1", "One", "chapter 1", "Full text", "xml"),
                          Section("s2", "Two", "chapter 2", "", "xml")],
                figures=[Figure("f1", "chapter 1", b"png bytes", "Caption")],
                total_units=2,
                warnings=[],
            )
            output = root / "project" / "document"
            write_document(source, "my-book-v1", extracted, output, False)
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["sha256"], hashlib.sha256(b"source bytes").hexdigest())
            self.assertEqual(manifest["document_id"], "my-book-v1")
            self.assertEqual(manifest["status"], "partial")
            self.assertEqual((output / "original.fb2").read_bytes(), b"source bytes")
            index = (output / "index.md").read_text(encoding="utf-8")
            self.assertIn("sections/s1.md", index)
            self.assertIn("images/f1.png.md", index)
            self.assertFalse((root / "library").exists())

    def test_rejects_unsafe_ids_and_foreign_output(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            root = Path(root)
            source = root / "a.fb2"
            source.write_bytes(b"x")
            extracted = ExtractedSource([Section("s", "", "1", "x", "xml")], [], 1, [])
            for document_id in ("../x", "a/b", "a\\b", ".."):
                with self.assertRaises(ValueError):
                    write_document(source, document_id, extracted, root / "out", False)
            output = root / "foreign"
            output.mkdir()
            (output / "note.txt").write_text("keep")
            with self.assertRaises(ValueError):
                write_document(source, "valid", extracted, output, False)
            self.assertEqual((output / "note.txt").read_text(), "keep")

    def test_update_preserves_matching_description_and_reports_changed_section(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            root = Path(root)
            source = root / "book.fb2"
            source.write_bytes(b"one")
            output = root / "result"
            first = ExtractedSource([Section("s1", "One", "chapter 1", "Old", "fb2")],
                                    [Figure("f1", "chapter 1", b"same picture")], 1, [])
            write_document(source, "book", first, output, False)
            description = output / "images" / "f1.png.md"
            description.write_text("Status: described\nLocator: chapter 1\nDescription: verified picture\n", encoding="utf-8")
            source.write_bytes(b"two")
            second = ExtractedSource([Section("s1", "One", "chapter 1", "New", "fb2")],
                                     [Figure("f2", "chapter 2", b"same picture")], 1, [])
            write_document(source, "book", second, output, True)
            updated_description = (output / "images" / "f2.png.md").read_text(encoding="utf-8")
            self.assertIn("verified picture", updated_description)
            self.assertIn("Locator: chapter 2", updated_description)
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertIn("s1", manifest["changed_references"])
            self.assertIn("image:f1", manifest["changed_references"])
            self.assertIn("image:f2", manifest["changed_references"])

    def test_finalization_requires_all_descriptions_and_no_gaps(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            root = Path(root)
            source = root / "book.fb2"
            source.write_bytes(b"book")
            output = root / "result"
            extracted = ExtractedSource([Section("s1", "One", "chapter", "Text", "fb2")],
                                        [Figure("f1", "chapter", b"image")], 1, [])
            write_document(source, "book", extracted, output, False)
            self.assertEqual(finalize_document(output), "partial")
            (output / "images" / "f1.png.md").write_text("Status: described\nDescription: diagram\n", encoding="utf-8")
            self.assertEqual(finalize_document(output), "complete")
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["status"], "complete")


if __name__ == "__main__":
    unittest.main()
