#!/usr/bin/env python3
"""Generate logo-only native launch artwork from the existing Shifter glyph.

Run with Pillow 11.3.0 and CairoSVG 2.8.2. On Homebrew macOS, set
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib for CairoSVG. Generated assets
are committed; normal app builds do not need these tools.
The centered 72 x 72 composition matches _Splash in lib/ui/shell/app_root.dart.
"""

import io
from pathlib import Path

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def artwork(scale):
    # Render large, then downsample, so the glyph edges remain antialiased.
    s = 4
    image = Image.new("RGBA", (72 * s, 72 * s))
    glyph_width = round(72 * 115 / 145 * s)
    glyph = Image.open(io.BytesIO(cairosvg.svg2png(
        url=str(ROOT / "assets/brand/shifter-glyph.svg"),
        output_width=glyph_width, output_height=72 * s,
    ))).convert("RGBA")
    image.alpha_composite(glyph, ((image.width - glyph.width) // 2, 0))
    return image.resize((round(72 * scale), round(72 * scale)), Image.Resampling.LANCZOS)


def main():
    ios = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
    for scale in (1, 2, 3):
        suffix = "" if scale == 1 else f"@{scale}x"
        artwork(scale).save(ios / f"LaunchImage{suffix}.png", optimize=True)

    res = ROOT / "android/app/src/main/res"
    for density, scale in (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2),
                           ("xxhdpi", 3), ("xxxhdpi", 4)):
        folder = res / f"drawable-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        launch = artwork(scale)
        launch.save(folder / "launch_image.png", optimize=True)
        # Android 12 masks a 192dp circle inside a 288dp square. Bake the
        # padding into the bitmap so the OS cannot rescale the inner drawable.
        icon = Image.new("RGBA", (round(288 * scale), round(288 * scale)))
        icon.alpha_composite(launch, (round(108 * scale), round(108 * scale)))
        icon.save(folder / "launch_icon.png", optimize=True)
    print("Generated iOS and Android launch artwork.")


if __name__ == "__main__":
    main()
