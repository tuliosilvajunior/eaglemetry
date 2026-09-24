#!/usr/bin/env python3
"""Generate Android and iOS launcher icons from the mascot asset.

Usage:
    python3 scripts/generate_launcher_icons.py
"""

from __future__ import annotations

import json
import pathlib
import sys

from PIL import Image

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
MASCOT_PATH = REPO_ROOT / "packages/capy_ui/assets/images/mascot/capy_happy_front.webp"
BG_COLOR = (220, 240, 210, 255)  # #DCF0D2 (AppColors.energyGainSubtle)


def create_adaptive_foreground(mascot: Image.Image, size: int) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # Android safe zone is the central 66-72dp out of 108dp (~67%)
    mascot_size = int(size * 0.67)
    scaled = mascot.resize((mascot_size, mascot_size), Image.Resampling.LANCZOS)
    offset = (size - mascot_size) // 2
    canvas.paste(scaled, (offset, offset), scaled)
    return canvas


def create_adaptive_background(size: int) -> Image.Image:
    return Image.new("RGBA", (size, size), BG_COLOR)


def create_adaptive_monochrome(mascot: Image.Image, size: int) -> Image.Image:
    fg = create_adaptive_foreground(mascot, size)
    _, _, _, a = fg.split()
    dark_ink = Image.new("L", (size, size), 38)
    return Image.merge("RGBA", (dark_ink, dark_ink, dark_ink, a))


def create_full_icon(mascot: Image.Image, size: int) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), BG_COLOR)
    # Full icon: mascot scaled to ~76% centered
    mascot_size = int(size * 0.76)
    scaled = mascot.resize((mascot_size, mascot_size), Image.Resampling.LANCZOS)
    offset = (size - mascot_size) // 2
    canvas.paste(scaled, (offset, offset), scaled)
    return canvas


def main() -> int:
    if not MASCOT_PATH.exists():
        sys.stderr.write(f"Mascot not found at {MASCOT_PATH}\n")
        return 1

    mascot = Image.open(MASCOT_PATH).convert("RGBA")

    # 1. Android densities
    android_densities = {
        "mipmap-mdpi": {"legacy": 48, "adaptive": 108},
        "mipmap-hdpi": {"legacy": 72, "adaptive": 162},
        "mipmap-xhdpi": {"legacy": 96, "adaptive": 216},
        "mipmap-xxhdpi": {"legacy": 144, "adaptive": 324},
        "mipmap-xxxhdpi": {"legacy": 192, "adaptive": 432},
    }

    android_roots = [
        REPO_ROOT / "android/app/src/main/res",
        REPO_ROOT / "apps/companion/android/app/src/main/res",
    ]

    for res_dir in android_roots:
        anydpi_dir = res_dir / "mipmap-anydpi-v26"
        anydpi_dir.mkdir(parents=True, exist_ok=True)
        xml_path = anydpi_dir / "ic_launcher.xml"
        xml_content = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
"""
        xml_path.write_text(xml_content)

        for density, sizes in android_densities.items():
            d_dir = res_dir / density
            d_dir.mkdir(parents=True, exist_ok=True)

            legacy_icon = create_full_icon(mascot, sizes["legacy"])
            legacy_icon.save(d_dir / "ic_launcher.png", "PNG")

            bg_icon = create_adaptive_background(sizes["adaptive"])
            bg_icon.save(d_dir / "ic_launcher_background.png", "PNG")

            fg_icon = create_adaptive_foreground(mascot, sizes["adaptive"])
            fg_icon.save(d_dir / "ic_launcher_foreground.png", "PNG")

            mono_icon = create_adaptive_monochrome(mascot, sizes["adaptive"])
            mono_icon.save(d_dir / "ic_launcher_monochrome.png", "PNG")

        print(f"Generated Android icons in {res_dir}")

    # 2. iOS Icons
    ios_iconset_dir = (
        REPO_ROOT
        / "apps/companion/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    )
    contents_path = ios_iconset_dir / "Contents.json"

    if contents_path.exists():
        contents = json.loads(contents_path.read_text())
        for item in contents.get("images", []):
            filename = item.get("filename")
            if not filename:
                continue
            size_str = item.get("size", "0x0")
            scale_str = item.get("scale", "1x")
            base_w, base_h = [float(x) for x in size_str.split("x")]
            scale = float(scale_str.replace("x", ""))
            w = int(round(base_w * scale))
            h = int(round(base_h * scale))

            icon = create_full_icon(mascot, w)
            icon.save(ios_iconset_dir / filename, "PNG")
            print(f"Generated iOS icon {filename} ({w}x{h})")

    print("All launcher icons successfully generated!")
    return 0


if __name__ == "__main__":
    sys.exit(main())
