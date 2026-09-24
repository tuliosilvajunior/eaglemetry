#!/usr/bin/env python3
"""Cut a 3x3 mascot expression sheet into one transparent asset per face.

The sheets arrive as one square PNG with nine faces laid out on a near-white
paper background. Two things have to happen before a face can be drawn in the
app:

* the paper has to become alpha. A face sits on a themed card, and a white
  square around it would read as a sticker on the wrong background. The paper
  is cleared by a flood fill from the border, never by replacing a colour
  everywhere: the teeth and the eye highlights are white too, and a global
  replace would punch holes through the face.
* every face has to be cut on its own artwork, not on an arithmetic third of
  the sheet. Two faces set close leave no empty line between them, so a third
  falls through the chin of the row above and carries a crescent of it into
  the next file. The sleeping face also carries its `Zzz` clear of its body,
  above where any grid line would fall.

So the sheet is read as artwork rather than as a grid. Every connected run of
ink is found once, over the whole sheet; the nine largest are the nine bodies,
and each smaller mark joins the body it is nearest to. A file is then the ink
of one body and of the marks that belong to it, and nothing else — a crescent
of the neighbour cannot enter, because it is part of the neighbour's own body.

Usage:

    slice_mascot_sheet.py SHEET.png OUT_DIR --suffix front
"""

from __future__ import annotations

import argparse
import pathlib
import sys
from collections import deque

from PIL import Image

# The nine expressions, in reading order. The sheet is authored in this order;
# a sheet that is not must be re-ordered before it is cut, because the file
# name is what every screen asks for.
MOODS = [
    "happy",
    "delighted",
    "surprised",
    "sad",
    "angry",
    "worried",
    "sleeping",
    "winking",
    "determined",
]


def paper_alpha(image: Image.Image, tolerance: int) -> Image.Image:
    """Alpha for the sheet: opaque art, transparent paper.

    The fill starts from every border pixel and spreads through pixels within
    [tolerance] of the paper colour, so only paper the art does not enclose is
    cleared.
    """
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    paper = pixels[0, 0]

    def is_paper(x: int, y: int) -> bool:
        r, g, b = pixels[x, y]
        return (
            abs(r - paper[0]) <= tolerance
            and abs(g - paper[1]) <= tolerance
            and abs(b - paper[2]) <= tolerance
        )

    seen = bytearray(width * height)
    queue: deque[tuple[int, int]] = deque()

    def push(x: int, y: int) -> None:
        if not seen[y * width + x] and is_paper(x, y):
            seen[y * width + x] = 1
            queue.append((x, y))

    for x in range(width):
        push(x, 0)
        push(x, height - 1)
    for y in range(height):
        push(0, y)
        push(width - 1, y)

    while queue:
        x, y = queue.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < width and 0 <= ny < height:
                push(nx, ny)

    alpha = Image.new("L", (width, height), 255)
    alpha.putdata([0 if flag else 255 for flag in seen])
    return alpha


class Blob:
    """One connected run of ink, and where it sits."""

    __slots__ = ("label", "size", "left", "top", "right", "bottom")

    def __init__(self, label: int, x: int, y: int) -> None:
        self.label = label
        self.size = 0
        self.left = self.right = x
        self.top = self.bottom = y

    def add(self, x: int, y: int) -> None:
        self.size += 1
        self.left = min(self.left, x)
        self.right = max(self.right, x)
        self.top = min(self.top, y)
        self.bottom = max(self.bottom, y)

    @property
    def centre(self) -> tuple[float, float]:
        return ((self.left + self.right) / 2, (self.top + self.bottom) / 2)


def find_blobs(alpha: Image.Image) -> tuple[list[int], list[Blob]]:
    """Label every connected run of ink in the sheet."""
    width, height = alpha.size
    data = alpha.load()
    labels = [0] * (width * height)
    blobs: list[Blob] = []
    for start_y in range(height):
        for start_x in range(width):
            if data[start_x, start_y] == 0 or labels[start_y * width + start_x]:
                continue
            blob = Blob(len(blobs) + 1, start_x, start_y)
            blobs.append(blob)
            labels[start_y * width + start_x] = blob.label
            queue = deque([(start_x, start_y)])
            while queue:
                x, y = queue.popleft()
                blob.add(x, y)
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < width and 0 <= ny < height:
                        index = ny * width + nx
                        if not labels[index] and data[nx, ny] > 0:
                            labels[index] = blob.label
                            queue.append((nx, ny))
    return labels, blobs


def in_reading_order(bodies: list[Blob]) -> list[Blob]:
    """Sort the nine bodies into rows, then into columns inside each row."""
    by_row = sorted(bodies, key=lambda blob: blob.centre[1])
    ordered: list[Blob] = []
    for start in range(0, 9, 3):
        row = by_row[start : start + 3]
        ordered.extend(sorted(row, key=lambda blob: blob.centre[0]))
    return ordered


def cut(sheet: pathlib.Path, out_dir: pathlib.Path, suffix: str, size: int,
        tolerance: int, margin: int, quality: int) -> None:
    image = Image.open(sheet)
    alpha = paper_alpha(image, tolerance)
    art = image.convert("RGB")
    art.putalpha(alpha)

    labels, blobs = find_blobs(alpha)
    if len(blobs) < 9:
        raise SystemExit(f"{sheet}: found {len(blobs)} marks, expected 9 faces")
    bodies = in_reading_order(
        sorted(blobs, key=lambda blob: blob.size, reverse=True)[:9]
    )
    body_labels = {blob.label for blob in bodies}

    # Every smaller mark joins the body it is nearest to. On these sheets that
    # is the three `Z` glyphs of the sleeping face, which sit clear of it.
    owner = {blob.label: index for index, blob in enumerate(bodies)}
    for blob in blobs:
        if blob.label in body_labels:
            continue
        x, y = blob.centre
        nearest = min(
            range(9),
            key=lambda index: (x - bodies[index].centre[0]) ** 2
            + (y - bodies[index].centre[1]) ** 2,
        )
        owner[blob.label] = nearest

    width = alpha.width
    out_dir.mkdir(parents=True, exist_ok=True)
    for index, body in enumerate(bodies):
        mine = {label for label, cell in owner.items() if cell == index}
        left = min(blob.left for blob in blobs if blob.label in mine)
        right = max(blob.right for blob in blobs if blob.label in mine)
        top = min(blob.top for blob in blobs if blob.label in mine)
        bottom = max(blob.bottom for blob in blobs if blob.label in mine)

        tile = art.crop((left, top, right + 1, bottom + 1))
        # Anything inside the crop that belongs to another face is cleared, so
        # a mark of a neighbour cannot ride along in the corner.
        kept = tile.getchannel("A").copy()
        kept.putdata([
            value
            if labels[(top + i // tile.width) * width + left + i % tile.width]
            in mine
            else 0
            for i, value in enumerate(kept.getdata())
        ])
        tile.putalpha(kept)

        # A square canvas. Every face then has the same geometry, so a widget
        # can swap one for another without the head moving.
        side = max(tile.size) + margin * 2
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        canvas.paste(tile, ((side - tile.width) // 2, (side - tile.height) // 2))
        canvas = canvas.resize((size, size), Image.LANCZOS)
        # Lossy, because lossless holds a flat-colour face at about four times
        # the size for a difference nobody sees on a phone. Alpha is exact
        # either way.
        name = f"capy_{MOODS[index]}_{suffix}.webp"
        canvas.save(out_dir / name, "WEBP", quality=quality, method=6)
    print(f"9 faces written to {out_dir}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sheet", type=pathlib.Path)
    parser.add_argument("out_dir", type=pathlib.Path)
    parser.add_argument("--suffix", required=True, help="front, right, ...")
    parser.add_argument("--size", type=int, default=512)
    parser.add_argument("--quality", type=int, default=88)
    parser.add_argument("--tolerance", type=int, default=14)
    parser.add_argument("--margin", type=int, default=8)
    args = parser.parse_args()
    cut(args.sheet, args.out_dir, args.suffix, args.size, args.tolerance,
        args.margin, args.quality)
    return 0


if __name__ == "__main__":
    sys.exit(main())
