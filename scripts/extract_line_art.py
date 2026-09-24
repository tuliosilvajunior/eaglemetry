#!/usr/bin/env python3
"""Turn a line-art PNG into a small, tintable WebP asset.

The vehicle silhouettes arrive as large PNGs with the transparency checkerboard
*baked in* as pixels: the background is real white and grey squares, not alpha.
That pattern is what makes the file huge (5.1 MB for `imgs/side.png`) and it
makes the art unusable on a themed surface.

This script rebuilds the alpha channel from luminance, so the drawing becomes
ink-on-nothing:

    alpha = clamp((BG - luminance) / BG)

Every background level (white 255 and checker grey ~211) sits above ``--bg`` and
maps to fully transparent. The lines keep their anti-aliasing as partial alpha.
The RGB channels are then set to black, because the app never shows them: the
widget tints the asset with the theme ink through ``BlendMode.srcIn``, which
keeps only the alpha. That also makes the colour planes compress to almost
nothing.

The output is cropped to the ink, so the asset's bottom edge is the tyre contact
line and its box is the vehicle. `TiltGauge` relies on that: it puts the bottom
edge on the ground line and needs the exact aspect ratio, which this script
prints.

Requires Pillow (not a project dependency — install it in a throwaway venv):

    python3 -m venv /tmp/lineart && /tmp/lineart/bin/pip install pillow
    /tmp/lineart/bin/python scripts/extract_line_art.py \
        imgs/side.png packages/capy_ui/assets/images/car_side.webp
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover - developer tool
    sys.exit("Pillow is required. See the module docstring for a venv recipe.")


def build_alpha(source: Path, bg: int) -> Image.Image:
    """Return the drawing as an 8-bit alpha mask."""
    grey = Image.open(source).convert("L")
    lut = [max(0, min(255, round((bg - level) * 255 / bg))) for level in range(256)]
    return grey.point(lut)


def crop_to_ink(alpha: Image.Image, threshold: int, pad: int) -> Image.Image:
    """Crop to the solid part of the drawing, plus a small margin.

    The threshold ignores the faint compression noise that the source carries
    across its whole canvas; without it the box is the canvas, not the vehicle.
    """
    box = alpha.point(lambda level: 255 if level > threshold else 0).getbbox()
    if box is None:
        sys.exit("No ink found. Check --bg and --threshold against the source.")
    left, top, right, bottom = box
    return alpha.crop(
        (
            max(0, left - pad),
            max(0, top - pad),
            min(alpha.width, right + pad),
            min(alpha.height, bottom + pad),
        )
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--width",
        type=int,
        default=1200,
        help="output width in pixels (default: 1200)",
    )
    parser.add_argument(
        "--bg",
        type=int,
        default=208,
        help="luminance at and above which a pixel is background (default: 208, "
        "just under the checkerboard grey)",
    )
    parser.add_argument(
        "--threshold",
        type=int,
        default=24,
        help="alpha above which a pixel counts as ink for the crop (default: 24)",
    )
    parser.add_argument(
        "--pad",
        type=int,
        default=2,
        help="pixels kept around the ink box (default: 2)",
    )
    args = parser.parse_args()

    alpha = crop_to_ink(build_alpha(args.source, args.bg), args.threshold, args.pad)
    height = round(alpha.height * args.width / alpha.width)
    alpha = alpha.resize((args.width, height), Image.LANCZOS)

    black = Image.new("L", alpha.size, 0)
    Image.merge("RGBA", (black, black, black, alpha)).save(
        args.output,
        format="WEBP",
        lossless=True,
        quality=100,
        method=6,
        exact=True,
    )

    print(f"{args.output}: {args.width}x{height}, {args.output.stat().st_size} bytes")
    print(f"aspect ratio: {args.width / height:.4f}")


if __name__ == "__main__":
    main()
