"""Build the taskbar thumbnail-toolbar icons in `app/assets/taskbar/`.

Run from the repository root, with Pillow installed and ImageMagick on PATH:

    python app/tool/gen_taskbar_icons.py

**The sources are the SVGs in `app/assets/icons/taskbar/`** — edit those, then
run this. Every `<name>.svg` there becomes `app/assets/taskbar/<name>.ico`, and
`taskbar_controller.dart` asks for icons by that name, so a new state is a new
SVG plus the line that names it. The PNGs beside the SVGs are exports for
editing in a raster tool and are not read: they are cropped to each icon's
bounds, so they have lost where the icon sits in its square, which the SVG's
1024x1024 box keeps.

ImageMagick renders the SVG (through librsvg, which reads the `<style>` classes
Illustrator exports), at 2048 px; Pillow scales that down to each frame with
premultiplied alpha, so the soft outline does not pick up a halo of the
transparent pixels' colour.

**Why multi-size `.ico` files.** `windows_taskbar` loads each icon with
`LoadImage` at `SM_CXSMICON`, which is 16 px at 100 % scaling and larger above
it, so every size Windows might ask for is present rather than scaled.
"""

import glob
import io
import os
import shutil
import subprocess
import sys

from PIL import Image

SOURCE_DIR = os.path.join("app", "assets", "icons", "taskbar")
OUT_DIR = os.path.join("app", "assets", "taskbar")
SIZES = [16, 20, 24, 32, 40, 48]
RENDER_DENSITY = "192"  # a 1024-unit box at 192 dpi is 2048 px


def render(svg_path: str) -> Image.Image:
    png = subprocess.run(
        ["magick", "-background", "none", "-density", RENDER_DENSITY, svg_path, "png32:-"],
        check=True,
        capture_output=True,
    ).stdout
    image = Image.open(io.BytesIO(png)).convert("RGBA")
    if image.width != image.height:
        raise ValueError(f"{svg_path}: renders {image.width}x{image.height}, not square")
    return image


def main() -> int:
    if shutil.which("magick") is None:
        print("ImageMagick (`magick`) not found on PATH", file=sys.stderr)
        return 1
    sources = sorted(glob.glob(os.path.join(SOURCE_DIR, "*.svg")))
    if not sources:
        print(f"no SVGs in {SOURCE_DIR}", file=sys.stderr)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)
    for source in sources:
        name = os.path.splitext(os.path.basename(source))[0]
        premultiplied = render(source).convert("RGBa")
        frames = [
            premultiplied.resize((size, size), Image.LANCZOS).convert("RGBA")
            for size in SIZES
        ]
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
