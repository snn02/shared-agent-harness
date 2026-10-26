import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import pymupdf

SCRIPTS = Path(__file__).resolve().parents[2] / "distribution/windows/payload/skills/document-ingest/scripts"
sys.path.insert(0, str(SCRIPTS))
from extract_pdf import extract_pdf

SCRATCH = Path(__file__).resolve().parents[2] / "dist" / "test-scratch"
SCRATCH.mkdir(parents=True, exist_ok=True)


class PdfOcrTests(unittest.TestCase):
    def test_ocr_only_blank_page(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            source = Path(root) / "mixed.pdf"
            doc = pymupdf.open()
            doc.new_page().insert_text((72, 72), "Text layer present")
            doc.new_page().draw_rect(pymupdf.Rect(20, 20, 90, 90))
            doc.save(source)
            doc.close()
            with patch("extract_pdf._ocr", return_value="Recognized scan") as ocr:
                result = extract_pdf(source, "fake-tesseract", "eng")
            self.assertEqual(ocr.call_count, 1)
            self.assertEqual([s.method for s in result.sections], ["text", "ocr"])
            self.assertIn("Recognized scan", result.sections[1].markdown)
            missing = extract_pdf(source)
            self.assertEqual(missing.sections[1].method, "missing")
            self.assertTrue(any("page 2" in warning and "OCR unavailable" in warning for warning in missing.warnings))

    def test_short_real_text_layer_is_not_replaced_by_ocr(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            source = Path(root) / "short.pdf"
            doc = pymupdf.open()
            doc.new_page().insert_text((72, 72), "Hi")
            doc.save(source)
            doc.close()
            with patch("extract_pdf._ocr", return_value="wrong") as ocr:
                result = extract_pdf(source, "fake-tesseract", "eng")
            ocr.assert_not_called()
            self.assertEqual(result.sections[0].method, "text")


if __name__ == "__main__":
    unittest.main()
