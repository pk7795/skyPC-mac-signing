"""Run with Mac-signing/.venv/bin/python -m unittest discover -s Mac-signing/tests -p test_dmg_layout.py -v."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dmg_layout import verify_image

SOURCE = Path(__file__).resolve().parents[2] / 'skypc-app/assets/background.jpg'


class BackgroundImageTests(unittest.TestCase):
    def test_original_jpeg_is_rejected_for_half_size_canvas(self):
        with self.assertRaisesRegex(ValueError, 'logical size'):
            verify_image(SOURCE, 900, 351)

    def test_original_jpeg_matches_full_size_canvas(self):
        verify_image(SOURCE, 1800, 702)

    def test_tiff_preserves_retina_density_and_rejects_wrong_canvas(self):
        with tempfile.TemporaryDirectory() as directory:
            tiff = Path(directory) / 'background.tiff'
            subprocess.run(['/usr/bin/sips', '-s', 'format', 'tiff', str(SOURCE), '--out', str(tiff)],
                           check=True, capture_output=True)
            subprocess.run(['/usr/bin/sips', '-s', 'dpiWidth', '144', '-s', 'dpiHeight', '144', str(tiff)],
                           check=True, capture_output=True)
            verify_image(tiff, 900, 351)
            with self.assertRaisesRegex(ValueError, 'logical size'):
                verify_image(tiff, 900, 350)

    def test_missing_image_does_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                verify_image(Path(directory) / 'missing.tiff', 900, 351)


if __name__ == '__main__':
    unittest.main(verbosity=2)
