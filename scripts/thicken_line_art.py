#!/usr/bin/env python3
"""Thicken the line art of a tintable WebP so it survives the downscale.

`TiltGauge` draws the vehicle at about 156 logical pixels wide (side) and 80
(front). The master art is 1200 pixels wide, so the drawing is reduced about
8 to 15 times. A 2-pixel line in the master therefore lands under a third of a
pixel on screen. Because the line lives in the alpha channel, it does not get
thinner there — it goes translucent, and the vehicle reads as a grey ghost
beside the solid ground line. Rotation makes the same sub-pixel line shimmer.

This script fixes the cause: it makes the master line wide enough that the
reduction leaves a solid line. It also separates the two kinds of line, because
they do not want the same weight:

* the **outer contour** is the shape of the vehicle. It carries the reading and
  is made the heaviest;
* the **interior lines** are panel gaps, glass and wheels. They are detail, and
  a detail line as heavy as the contour turns the drawing into a blob.

The contour is found by flooding the transparent background inwards from the
border: whatever the flood does not reach is the vehicle body, and the edge of
that body is the contour. This works because the art is a closed outline.

Widths are given in master pixels, so they are independent of `--width`.
Multiply the wanted on-screen width by the reduction to get them: an on-screen
2.5 px contour at a 7.7x reduction asks for about 19 master pixels.

The shipped weights are an on-screen 2.5 px contour and 0.7 px interior:

    thicken_line_art.py art/car_side.webp  packages/capy_ui/assets/images/car_side.webp \
        --outer 19.2 --inner 4.5 --width 600
    thicken_line_art.py art/car_front.webp packages/capy_ui/assets/images/car_front.webp \
        --outer 37.3 --inner 7 --width 400

The front view is drawn half as wide as the side view, so it is reduced twice
as hard and asks for twice the master weight for the same on-screen line. It
also ships at a smaller `--width` for the same reason: an asset far larger than
the size it is drawn at only costs bytes.

The output is re-cropped to the ink, because thickening grows the drawing past
the master's box, and the aspect ratio is printed. `CarSilhouette.aspectRatio`
in `lib/ui/components/tilt_gauge.dart` must be updated to match, or the gauge
will distort the drawing.

Requires Pillow and NumPy (not project dependencies — use a throwaway venv):

    python3 -m venv /tmp/lineart && /tmp/lineart/bin/pip install pillow numpy
    /tmp/lineart/bin/python scripts/thicken_line_art.py ...
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


def _dilate(alpha: Image.Image, width: float) -> Image.Image:
    """Grow the ink by ``width`` master pixels, total, across the line.

    A line is grown from both sides at once, so a filter radius of ``r`` adds
    ``2 * r`` to the width. Radii are whole pixels; a fractional remainder is
    applied as one more pass at the next radius down, blended by the fraction,
    which keeps the weight adjustable in steps finer than 2 pixels.
    """
    radius = max(0.0, width) / 2
    whole = int(radius)
    fraction = radius - whole

    grown = alpha
    for _ in range(whole):
        grown = grown.filter(ImageFilter.MaxFilter(3))
    if fraction > 0:
        further = grown.filter(ImageFilter.MaxFilter(3))
        grown = Image.blend(grown, further, fraction)
    return grown


def _body(alpha: np.ndarray, threshold: int) -> Image.Image:
    """The filled vehicle: everything the outside background cannot reach.

    The flood runs on a 1-pixel transparent border added around the art, so it
    starts outside the drawing even when the ink touches an edge — which it
    does, the master is cropped to the ink.
    """
    height, width = alpha.shape
    canvas = Image.new("L", (width + 2, height + 2), 0)
    canvas.paste(Image.fromarray((alpha >= threshold).astype(np.uint8) * 255), (1, 1))
    ImageDraw.floodfill(canvas, (0, 0), 128)

    flooded = np.array(canvas)[1:-1, 1:-1]
    return Image.fromarray(np.where(flooded == 128, 0, 255).astype(np.uint8))


def _contour(body: Image.Image) -> Image.Image:
    """The one-pixel edge of the filled body."""
    inside = body.filter(ImageFilter.MinFilter(3))
    return Image.fromarray(
        np.clip(np.array(body).astype(np.int16) - np.array(inside), 0, 255).astype(
            np.uint8
        )
    )


def _crop_box(alpha: np.ndarray, threshold: int) -> tuple[int, int, int, int]:
    rows = np.where(alpha.max(axis=1) >= threshold)[0]
    cols = np.where(alpha.max(axis=0) >= threshold)[0]
    return int(cols[0]), int(rows[0]), int(cols[-1]) + 1, int(rows[-1]) + 1


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="master WebP from art/")
    parser.add_argument("output", type=Path, help="asset WebP to write")
    parser.add_argument(
        "--outer",
        type=float,
        required=True,
        help="width of the outer contour, in master pixels",
    )
    parser.add_argument(
        "--inner",
        type=float,
        required=True,
        help="width of the interior lines, in master pixels",
    )
    parser.add_argument(
        "--width",
        type=int,
        default=600,
        help="output width in pixels (default: 600)",
    )
    parser.add_argument(
        "--threshold",
        type=int,
        default=32,
        help="alpha at or above which a pixel counts as ink (default: 32)",
    )
    args = parser.parse_args()

    source = Image.open(args.source).convert("RGBA")
    alpha = source.getchannel("A")
    original = np.array(alpha)

    # The drawing grows outwards, so give it room before it is grown and crop
    # back to the ink afterwards.
    pad = int(max(args.outer, args.inner)) + 2
    padded = Image.new("L", (alpha.width + 2 * pad, alpha.height + 2 * pad), 0)
    padded.paste(alpha, (pad, pad))

    # The existing line already has weight; grow it by the difference only.
    have = _existing_width(original, args.threshold)
    interior = _dilate(padded, args.inner - have)
    contour = _dilate(
        _contour(_body(np.array(padded), args.threshold)), args.outer - 1
    )

    grown = np.maximum(np.array(interior), np.array(contour))
    grown = grown[*[slice(*p) for p in _pairs(_crop_box(grown, args.threshold))]]

    height = round(grown.shape[0] * args.width / grown.shape[1])
    resized = Image.fromarray(grown).resize((args.width, height), Image.LANCZOS)
    black = Image.new("L", resized.size, 0)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    Image.merge("RGBA", (black, black, black, resized)).save(
        args.output, "WEBP", lossless=True, quality=100, method=6
    )

    print(f"{args.output}: {args.width}x{height}, {args.output.stat().st_size} bytes")
    print(f"aspect ratio: {args.width / height:.4f}")


def _pairs(box: tuple[int, int, int, int]) -> list[tuple[int, int]]:
    left, top, right, bottom = box
    return [(top, bottom), (left, right)]


def _existing_width(alpha: np.ndarray, threshold: int) -> float:
    """Mean width of the lines already in the master, in pixels.

    Ink area divided by line length. The length is estimated as the ink area of
    the skeleton-free approximation: the area that survives one erosion is the
    part of a line more than one pixel from its edge, so the difference between
    the two areas is the perimeter, and area over half-perimeter is the width.
    """
    ink = Image.fromarray((alpha >= threshold).astype(np.uint8) * 255)
    eroded = np.array(ink.filter(ImageFilter.MinFilter(3))) > 0
    area = float((np.array(ink) > 0).sum())
    perimeter = area - float(eroded.sum())
    return 2 * area / perimeter if perimeter > 0 else 1.0


if __name__ == "__main__":
    main()
