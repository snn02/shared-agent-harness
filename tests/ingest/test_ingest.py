import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "distribution/windows/payload/skills/document-ingest/scripts"
SCRATCH = Path(__file__).resolve().parents[2] / "dist" / "test-scratch"
SCRATCH.mkdir(parents=True, exist_ok=True)


class IngestCliTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPTS / "ingest.py"), *map(str, args)],
                              capture_output=True, text=True)

    def test_explicit_project_output_and_updates(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            root = Path(root)
            source = root / "book.fb2"
            source.write_text("<FictionBook><body><section id='a'><p>First version</p></section></body></FictionBook>", encoding="utf-8")
            output = root / "project" / "ingested"
            self.assertNotEqual(self.run_cli("--source", source, "--document-id", "book").returncode, 0)
            result = self.run_cli("--source", source, "--output", output, "--document-id", "book")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "library").exists())
            self.assertEqual(self.run_cli("--source", source, "--output", output, "--document-id", "book").returncode, 0)
            source.write_text("<FictionBook><body><section id='a'><p>Second version</p></section></body></FictionBook>", encoding="utf-8")
            self.assertNotEqual(self.run_cli("--source", source, "--output", output, "--document-id", "book").returncode, 0)
            updated = self.run_cli("--source", source, "--output", output, "--document-id", "book", "--update")
            self.assertEqual(updated.returncode, 0, updated.stderr)
            self.assertIn("Second version", (output / "sections" / "section-0001.md").read_text(encoding="utf-8"))
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertIn("changed_references", manifest)

    def test_rejects_directory_and_unknown_format(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            root = Path(root)
            self.assertNotEqual(self.run_cli("--source", root, "--output", root / "out", "--document-id", "x").returncode, 0)
            source = root / "x.txt"
            source.write_text("hello")
            self.assertNotEqual(self.run_cli("--source", source, "--output", root / "out", "--document-id", "x").returncode, 0)

    def test_corrupt_existing_result_is_not_accepted_as_noop(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            root = Path(root)
            source = root / "book.fb2"
            source.write_text("<FictionBook><body><section><p>Source</p></section></body></FictionBook>", encoding="utf-8")
            output = root / "result"
            self.assertEqual(self.run_cli("--source", source, "--output", output, "--document-id", "book").returncode, 0)
            (output / "sections" / "section-0001.md").unlink()
            self.assertNotEqual(self.run_cli("--source", source, "--output", output, "--document-id", "book").returncode, 0)

    def test_explicit_update_reextracts_unchanged_source(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            root = Path(root)
            source = root / "book.fb2"
            source.write_text("<FictionBook><body><section><p>Original text</p></section></body></FictionBook>", encoding="utf-8")
            output = root / "result"
            self.assertEqual(self.run_cli("--source", source, "--output", output, "--document-id", "book").returncode, 0)
            section = output / "sections" / "section-0001.md"
            section.write_text("stale extraction", encoding="utf-8")
            self.assertEqual(self.run_cli("--source", source, "--output", output, "--document-id", "book", "--update").returncode, 0)
            self.assertIn("Original text", section.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
