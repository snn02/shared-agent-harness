import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "distribution/windows/payload/skills/document-ingest/scripts"
sys.path.insert(0, str(SCRIPTS))
from ingest_model import ExtractedSource, Section, validate_coverage


class CoverageTests(unittest.TestCase):
    def test_empty_page_and_missing_units_are_explicit(self):
        result = ExtractedSource([Section("p1", "", "page 1", "", "missing")], [], 2, [])
        gaps = validate_coverage(result)
        self.assertTrue(any("page 1" in gap for gap in gaps))
        self.assertTrue(any("1 of 2" in gap for gap in gaps))


if __name__ == "__main__":
    unittest.main()
