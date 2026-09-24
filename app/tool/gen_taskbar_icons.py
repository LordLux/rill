"""Generate the taskbar thumbnail-toolbar icons in `app/assets/taskbar/`.

Run from the repository root with Pillow installed:

    python app/tool/gen_taskbar_icons.py

The glyphs come from the Material Icons font the pinned Flutter SDK ships, at
the codepoints *Flutter's* `icons.dart` maps them to — which are not Google's
public codepoints, so they are read from the SDK rather than looked up online.
Regenerate after an SDK bump only if the font changed.

**Why multi-size, white-with-outline `.ico` files.** `windows_taskbar` loads
each icon with `LoadImage` at `SM_CXSMICON`, which is 16 px at 100 % scaling
and larger above it, so every size Windows might ask for is present rather than
scaled. The thumbnail flyout is dark on a dark taskbar and light on a light one,
and a plain white glyph vanishes on the light one; the soft outline keeps it
legible on both without keeping two icon sets in step with the system theme.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

SDK_FONT = os.path.expandvars(
    r"%USERPROFILE%\fvm\versions\3.44.9\bin\cache\artifacts\material_fonts\materialicons-regular.otf"
)
OUT_DIR = os.path.join("app", "assets", "taskbar")
SIZES = [16, 20, 24, 32, 40, 48]

# Flutter's `Icons.*` codepoints for the pinned SDK (3.44.9).
GLYPHS = {
    "previous": 0xE5BE,  # Icons.skip_previous
    "play": 0xE4CB,  # Icons.play_arrow
    "pause": 0xE47C,  # Icons.pause
    "next": 0xE5BD,  # Icons.skip_next
    "like": 0xF440,  # Icons.thumb_up_outlined
    "liked": 0xE65B,  # Icons.thumb_up
}


def render(codepoint: int, size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype(SDK_FONT, size)
    glyph = chr(codepoint)
    left, top, right, bottom = font.getbbox(glyph)
    x = (size - (right - left)) / 2 - left
    y = (size - (bottom - top)) / 2 - top
    # The outline: the glyph drawn dark and slightly offset in every direction,
    # under the white one. One pixel at the small sizes, where more would fill
    # the counters in; scaled with the icon above that.
    radius = max(1, size // 20)
    for dx in range(-radius, radius + 1):
        for dy in range(-radius, radius + 1):
            if dx or dy:
                draw.text((x + dx, y + dy), glyph, font=font, fill=(0, 0, 0, 150))
    draw.text((x, y), glyph, font=font, fill=(255, 255, 255, 255))
    return image


def main() -> int:
    if not os.path.isfile(SDK_FONT):
        print(f"font not found: {SDK_FONT}", file=sys.stderr)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, codepoint in GLYPHS.items():
        frames = [render(codepoint, size) for size in SIZES]
        path = os.path.join(OUT_DIR, f"{name}.ico")
        frames[-1].save(
            path,
            format="ICO",
            sizes=[(s, s) for s in SIZES],
            append_images=frames[:-1],
        )
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
