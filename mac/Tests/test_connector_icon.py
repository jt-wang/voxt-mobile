"""Small Connector icon sizes are drawn for their pixel grid; scaled down, the seven bars blur."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load():
    spec = importlib.util.spec_from_file_location("connector_icon", ROOT / "tools/make-connector-icon.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def bars_in_middle_row(image):
    """The number of light runs across the middle row, and the row's red values."""
    y = image.height // 2
    values = [image.getpixel((x, y))[0] for x in range(image.width)]
    runs, inside = 0, False
    for v in values:
        light = v > 128
        runs += light and not inside
        inside = light
    return runs, values


class ConnectorIconTests(unittest.TestCase):
    def test_small_sizes_have_fewer_pixel_aligned_bars(self):
        icon = load()
        for pixels, expected in [(16, 3), (32, 5), (64, 7)]:
            image = icon.render(pixels)
            self.assertEqual(image.size, (pixels, pixels))
            runs, values = bars_in_middle_row(image)
            self.assertEqual(runs, expected, f"{pixels} px")
            # Inside the body every pixel of the middle row is either bar or fill: no grey edges.
            body = [v for x, v in enumerate(values) if image.getpixel((x, pixels // 2))[3] == 255]
            self.assertTrue(all(v > 220 or v < 60 for v in body), f"{pixels} px has blurred bar edges: {body}")

    def test_large_sizes_keep_the_iphone_artwork(self):
        image = load().render(1024)
        runs, _ = bars_in_middle_row(image)
        self.assertEqual(runs, 7)


if __name__ == "__main__": unittest.main()
