#!/usr/bin/env python3
"""Make the Connector's AppIcon.icns from the iPhone app icon, on the macOS icon grid:
1024 canvas, 824 rounded-rect body centered, corner radius 185, soft drop shadow.

Scaled below 128 px the seven bars blur into a grey shape, so 16, 32 and 64 px are drawn
for their own pixel grid: fewer, thicker bars with whole-pixel widths and gaps."""
from pathlib import Path
import subprocess
import sys
import tempfile
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
OUTPUT = ROOT / 'mac/VoxtConnector/Resources/AppIcon.icns'
CANVAS, BODY, RADIUS = 1024, 824, 185
SIZES = [16, 32, 128, 256, 512]
FILL, BAR = (23, 23, 23), (248, 246, 242)  # measured from the iPhone icon
# pixels: (body, bar width, gap, bar heights), all in whole pixels. Heights follow the
# iPhone icon's middle bars (tallest in the middle, the right side a little shorter).
SMALL = {
    16: (14, 2, 2, [6, 10, 6]),
    32: (26, 2, 2, [8, 12, 16, 10, 6]),
    64: (52, 4, 2, [8, 14, 24, 30, 20, 12, 6]),
}


def rounded_mask(size, radius, scale=4):
    # Drawn 4x larger and reduced, so the edge is antialiased.
    big = Image.new('L', (size * scale, size * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, size * scale - 1, size * scale - 1), radius * scale, fill=255)
    return big.resize((size, size), Image.LANCZOS)


def master():
    # The iPhone icon is full-bleed: scaling it to the body scales the waveform with it.
    body = Image.open(SOURCE).convert('RGBA').resize((BODY, BODY), Image.LANCZOS)
    mask = rounded_mask(BODY, RADIUS)
    body.putalpha(mask)
    offset = (CANVAS - BODY) // 2
    shadow_alpha = Image.new('L', (CANVAS, CANVAS), 0)
    shadow_alpha.paste(mask, (offset, offset + 12))
    shadow_alpha = shadow_alpha.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.3))
    shadow = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.putalpha(shadow_alpha)
    icon = Image.alpha_composite(Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0)), shadow)
    icon.alpha_composite(body, (offset, offset))
    return icon


def small(pixels, scale=8):
    """Drawn 8x larger on whole-pixel edges and reduced by averaging, so bar sides stay sharp
    and only the rounded ends and corners are smoothed."""
    body, width, gap, heights = SMALL[pixels]
    size, unit = pixels * scale, scale
    offset = (pixels - body) // 2
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((offset * unit, offset * unit, (offset + body) * unit - 1,
                                            (offset + body) * unit - 1), round(RADIUS / BODY * body * unit), fill=255)
    art = Image.new('RGBA', (size, size), FILL + (255,))
    draw = ImageDraw.Draw(art)
    span = len(heights) * width + (len(heights) - 1) * gap
    left, middle = offset + (body - span) // 2, offset + body // 2
    for index, height in enumerate(heights):
        x = left + index * (width + gap)
        top = middle - height // 2
        draw.rounded_rectangle((x * unit, top * unit, (x + width) * unit - 1, (top + height) * unit - 1),
                               width * unit // 2, fill=BAR + (255,))
    art.putalpha(mask)
    shadow_alpha = Image.new('L', (size, size), 0)
    shadow_alpha.paste(mask, (0, round(12 / CANVAS * size)))
    shadow_alpha = shadow_alpha.filter(ImageFilter.GaussianBlur(14 / CANVAS * size)).point(lambda v: int(v * 0.3))
    icon = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    icon.putalpha(shadow_alpha)
    icon.alpha_composite(art)
    return icon.reduce(scale)


def render(pixels, large=None):
    if pixels in SMALL:
        return small(pixels)
    return (large or master()).resize((pixels, pixels), Image.LANCZOS)


def main(output=OUTPUT):
    large = master()
    with tempfile.TemporaryDirectory(dir=ROOT / 'build') as folder:
        iconset = Path(folder) / 'AppIcon.iconset'
        iconset.mkdir()
        for size in SIZES:
            render(size, large).save(iconset / f'icon_{size}x{size}.png')
            render(size * 2, large).save(iconset / f'icon_{size}x{size}@2x.png')
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(output)], check=True, timeout=60)
    print('wrote', output.relative_to(ROOT))


if __name__ == '__main__':
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else OUTPUT)
