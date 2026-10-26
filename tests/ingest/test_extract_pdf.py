import sys
import tempfile
import unittest
from pathlib import Path

import pymupdf

SCRIPTS = Path(__file__).resolve().parents[2] / "distribution/windows/payload/skills/document-ingest/scripts"
sys.path.insert(0, str(SCRIPTS))
from extract_pdf import extract_pdf

SCRATCH = Path(__file__).resolve().parents[2] / "dist" / "test-scratch"
SCRATCH.mkdir(parents=True, exist_ok=True)


class PdfTests(unittest.TestCase):
    def test_page_locators_and_vector_warning(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            path = Path(root) / "sample.pdf"
            doc = pymupdf.open()
            first = doc.new_page()
            first.insert_text((72, 72), "First page text")
            second = doc.new_page()
            second.insert_text((72, 72), "Second page text")
            second.draw_rect(pymupdf.Rect(80, 100, 160, 140), color=(0, 0, 0))
            doc.save(path)
            doc.close()
            result = extract_pdf(path)
            self.assertEqual([s.locator for s in result.sections], ["page 1", "page 2"])
            self.assertIn("First page text", result.sections[0].markdown)
            self.assertTrue(any("page 2" in w for w in result.warnings))

    def test_two_columns_require_reading_order_review(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            path = Path(root) / "columns.pdf"
            doc = pymupdf.open()
            page = doc.new_page()
            for i in range(3):
                page.insert_text((60, 80 + 25*i), f"Left passage {i}")
                page.insert_text((330, 80 + 25*i), f"Right passage {i}")
            doc.save(path)
            doc.close()
            result = extract_pdf(path)
            self.assertTrue(any("reading order" in warning for warning in result.warnings))


if __name__ == "__main__":
    unittest.main()
