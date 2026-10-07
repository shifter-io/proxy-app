#!/usr/bin/env python3
"""Regenerate native icons from Shifter's existing vector glyph (no wordmark).

Run with Python 3, Pillow 11.3.0 and CairoSVG 2.8.2 installed. CairoSVG also
requires libcairo; on Homebrew macOS use DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib.
All generated assets are committed, so normal app builds need no Python tools.
"""

import io
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
BG = "#0B0E17"
BLUE = "#2B7FFF"
PATHS = [p.attrib["d"] for p in ET.parse(
    ROOT / "assets/brand/shifter-glyph.svg"
).getroot().findall("{http://www.w3.org/2000/svg}path")]


def write(path, content):
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content + "\n")


def svg(inset=0, radius=0):
    # Center the visible glyph bounds, including the detached dot. The source
    # glyph viewBox clips its right edge slightly, so use expanded bounds here.
    side = 1024 - 2 * inset
    height = side * 0.68
    width = height * 120 / 136
    paths = "".join(f'<path d="{d}" fill="{BLUE}"/>' for d in PATHS)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            f'viewBox="0 0 1024 1024"><rect x="{inset}" y="{inset}" '
            f'width="{side}" height="{side}" rx="{radius}" fill="{BG}"/>'
            f'<svg x="{(1024-width)/2}" y="{(1024-height)/2}" '
            f'width="{width}" height="{height}" viewBox="-1 5 120 136">'
            f'{paths}</svg></svg>')


def render(source):
    return Image.open(io.BytesIO(cairosvg.svg2png(
        bytestring=source.encode(), output_width=2048, output_height=2048
    ))).convert("RGBA")


def png(source, path, size, opaque=False):
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    result = source.resize((size, size), Image.Resampling.LANCZOS)
    if opaque:
        result = result.convert("RGB")
    result.save(target, optimize=True)


def vector(size, glyph_height, color):
    scale = glyph_height / 136
    # Glyph bounds: x=-1..119, y=5..141; center=(59,73).
    x, y = size / 2 - 59 * scale, size / 2 - 73 * scale
    paths = "\n".join(f'        <path android:fillColor="{color}" '
                      f'android:pathData="{d}" />' for d in PATHS)
    return (f'<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    android:width="{size}dp" android:height="{size}dp"\n'
            f'    android:viewportWidth="{size}" android:viewportHeight="{size}">\n'
            f'    <group android:scaleX="{scale:.8f}" android:scaleY="{scale:.8f}"\n'
            f'        android:translateX="{x:.8f}" android:translateY="{y:.8f}">\n'
            f'{paths}\n    </group>\n</vector>')


def main():
    square_svg = svg()
    write("assets/brand/shifter-app-icon.svg", square_svg)
    square = render(square_svg)
    desktop = render(svg(inset=100, radius=184))
    rounded = render(svg(radius=224))

    for platform, source in [("ios", square), ("macos", desktop)]:
        folder = Path(platform) / "Runner/Assets.xcassets/AppIcon.appiconset"
        catalog = json.loads((ROOT / folder / "Contents.json").read_text())
        for entry in catalog["images"]:
            size = round(float(entry["size"].split("x")[0]) *
                         float(entry["scale"].removesuffix("x")))
            png(source, folder / entry["filename"], size, opaque=platform == "ios")

    res = Path("android/app/src/main/res")
    for density, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                          ("xxhdpi", 144), ("xxxhdpi", 192)]:
        png(rounded, res / f"mipmap-{density}/ic_launcher.png", size)
    write(res / "values/icon_colors.xml",
          f'<resources>\n    <color name="ic_launcher_background">{BG}</color>\n</resources>')
    # 46dp glyph fits wholly inside the 66dp safe circle of a 108dp layer.
    write(res / "drawable/ic_launcher_foreground.xml", vector(108, 46, BLUE))
    write(res / "drawable/ic_launcher_monochrome.xml", vector(108, 46, "#FFFFFF"))
    write(res / "drawable/ic_stat_shifter.xml", vector(24, 21, "#FFFFFF"))
    for version in [26, 33]:
        mono = ('\n    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />'
                if version == 33 else '')
        write(res / f"mipmap-anydpi-v{version}/ic_launcher.xml",
              '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
              '    <background android:drawable="@color/ic_launcher_background" />\n'
              '    <foreground android:drawable="@drawable/ic_launcher_foreground" />'
              f'{mono}\n</adaptive-icon>')

    sizes = [(s, s) for s in [16, 20, 24, 32, 40, 48, 64, 128, 256]]
    rounded.save(ROOT / "windows/runner/resources/app_icon.ico", sizes=sizes)
    png(rounded, "linux/runner/resources/shifter.png", 256)
    write("linux/runner/resources/io.shifter.shifter_app.svg", svg(radius=224))
    print("Generated iPhone/iPad, Mac, Android, Windows and Linux icons.")


if __name__ == "__main__":
    main()
