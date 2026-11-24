#!/usr/bin/env python3
"""Render sharp flag PNGs for assets/flags/ from the flag-icons SVG set.

The app shows flags up to 26 pt wide, which is 78 px on a 3x screen, so the
flags are rendered at 96 x 72 px (4:3; the Flag widget crops to its own shape).
Source: https://github.com/lipis/flag-icons (MIT), flags/4x3/*.svg.

    git clone --depth 1 https://github.com/lipis/flag-icons.git /tmp/flag-icons
    python3 tool/generate_flags.py /tmp/flag-icons

Run with CairoSVG 2.8.2. On Homebrew macOS, set DYLD_FALLBACK_LIBRARY_PATH to
Homebrew's lib folder for CairoSVG. File names stay the same, so no code changes.
Flags with no flag-icons source (an, cs, fam) keep their existing images.
"""

import sys
from pathlib import Path

import cairosvg

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 96, 72
# Our file names that differ from flag-icons names.
ALIASES = {
    "catalonia": "es-ct",
    "england": "gb-eng",
    "scotland": "gb-sct",
    "wales": "gb-wls",
    "europeanunion": "eu",
}


def main():
    source = Path(sys.argv[1]) / "flags" / "4x3"
    flags = ROOT / "assets" / "flags"
    kept = []
    for png in sorted(flags.glob("*.png")):
        svg = source / f"{ALIASES.get(png.stem, png.stem)}.svg"
        if not svg.exists():
            kept.append(png.stem)
            continue
        cairosvg.svg2png(url=str(svg), write_to=str(png), output_width=WIDTH, output_height=HEIGHT)
    print(f"Rendered flags; kept existing images for: {', '.join(kept) or 'none'}")


if __name__ == "__main__":
    main()
