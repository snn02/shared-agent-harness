import base64
import io
import sys
import tempfile
import unittest
from pathlib import Path
from PIL import Image

SCRIPTS = Path(__file__).resolve().parents[2] / "distribution/windows/payload/skills/document-ingest/scripts"
sys.path.insert(0, str(SCRIPTS))
from extract_fb2 import extract_fb2

SCRATCH = Path(__file__).resolve().parents[2] / "dist" / "test-scratch"
SCRATCH.mkdir(parents=True, exist_ok=True)


class Fb2Tests(unittest.TestCase):
    def test_sections_notes_and_table(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            path = Path(root) / "book.fb2"
            path.write_text('''<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
              <body><section id="one"><title><p>First</p></title><p>Text</p>
              <section id="nested"><title><p>Nested</p></title><p>Inside</p></section>
              <table><tr><td>A</td><td>B</td></tr></table></section></body>
              <body name="notes"><section id="n1"><p>Note text</p></section></body></FictionBook>''', encoding="utf-8")
            result = extract_fb2(path)
            text = "\n".join(s.markdown for s in result.sections)
            self.assertIn("Nested", text)
            self.assertIn("Note text", text)
            self.assertIn("A | B", text)
            self.assertTrue(any("one/nested" in s.locator for s in result.sections))

    def test_rejects_entities_and_bad_image(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            path = Path(root) / "bad.fb2"
            path.write_text('<!DOCTYPE x [<!ENTITY a "evil">]><FictionBook>&a;</FictionBook>', encoding="utf-8")
            with self.assertRaises(Exception):
                extract_fb2(path)
            path.write_text('<FictionBook><binary id="x" content-type="image/png">%%%</binary></FictionBook>', encoding="utf-8")
            with self.assertRaises(ValueError):
                extract_fb2(path)

    def test_image_nested_in_paragraph_is_retained(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            picture = io.BytesIO()
            Image.new("RGB", (4, 4), "blue").save(picture, "PNG")
            encoded = base64.b64encode(picture.getvalue()).decode("ascii")
            path = Path(root) / "image.fb2"
            path.write_text(f'''<FictionBook xmlns:xlink="http://www.w3.org/1999/xlink">
              <body><section id="a"><p>Before <image xlink:href="#img"/> after</p></section></body>
              <binary id="img" content-type="image/png">{encoded}</binary></FictionBook>''', encoding="utf-8")
            result = extract_fb2(path)
            self.assertEqual(len(result.figures), 1)
            self.assertEqual(result.figures[0].locator, "main/a")

    def test_annotation_body_title_and_empty_lines_are_preserved_without_noise(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            path = Path(root) / "intro.fb2"
            path.write_text('''<FictionBook><description><title-info><annotation><p>Summary paragraph</p></annotation></title-info></description>
              <body><title><p>Book title</p></title><empty-line/><section id="one"><p>Chapter text</p><empty-line/></section></body>
              </FictionBook>''', encoding="utf-8")
            result = extract_fb2(path)
            content = "\n".join(section.markdown for section in result.sections)
            self.assertIn("Summary paragraph", content)
            self.assertIn("Book title", content)
            self.assertFalse(any("empty-line" in warning for warning in result.warnings))

    def test_cover_image_is_part_of_extracted_images(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            picture = io.BytesIO()
            Image.new("RGB", (5, 5), "green").save(picture, "PNG")
            encoded = base64.b64encode(picture.getvalue()).decode("ascii")
            path = Path(root) / "cover.fb2"
            path.write_text(f'''<FictionBook xmlns:xlink="http://www.w3.org/1999/xlink">
              <description><title-info><coverpage><image xlink:href="#cover"/></coverpage></title-info></description>
              <body><section><p>Text</p></section></body><binary id="cover" content-type="image/png">{encoded}</binary>
              </FictionBook>''', encoding="utf-8")
            result = extract_fb2(path)
            self.assertEqual(len(result.figures), 1)
            self.assertEqual(result.figures[0].locator, "metadata/coverpage")


if __name__ == "__main__":
    unittest.main()
