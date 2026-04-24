#!/usr/bin/env python3
"""Generate Argon app icons at all required macOS sizes."""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ICON_DIR = (
    Path(__file__).resolve().parent.parent
    / "apps"
    / "macos"
    / "Resources"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
)

MASTER_SIZE = 1024
OVERSAMPLE = 4
MASTER_WORK_SIZE = MASTER_SIZE * OVERSAMPLE

SIZES = [
    (16, 1),
    (16, 2),
    (32, 1),
    (32, 2),
    (128, 1),
    (128, 2),
    (256, 1),
    (256, 2),
    (512, 1),
    (512, 2),
]

RESAMPLE_LANCZOS = Image.Resampling.LANCZOS if hasattr(Image, "Resampling") else Image.LANCZOS


def rgba(hex_color: str, alpha: int = 255) -> tuple[int, int, int, int]:
    value = hex_color.removeprefix("#")
    return tuple(int(value[index : index + 2], 16) for index in (0, 2, 4)) + (alpha,)


def rounded_mask(size: int, inset: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (inset, inset, size - inset - 1, size - inset - 1),
        radius=radius,
        fill=255,
    )
    return mask


def alpha_composite(base: Image.Image, overlay: Image.Image) -> Image.Image:
    return Image.alpha_composite(base, overlay)


def make_overlay(size: int) -> tuple[Image.Image, ImageDraw.ImageDraw]:
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    return overlay, ImageDraw.Draw(overlay)


def vertical_gradient(
    size: int,
    top: tuple[int, int, int, int],
    bottom: tuple[int, int, int, int],
) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    height = max(1, size - 1)
    for y in range(size):
        t = y / height
        color = tuple(
            int(round(top[index] * (1.0 - t) + bottom[index] * t)) for index in range(4)
        )
        draw.line((0, y, size, y), fill=color)
    return image


def add_glow(
    base: Image.Image,
    box: tuple[int, int, int, int],
    color: tuple[int, int, int, int],
    blur_radius: int,
) -> Image.Image:
    overlay, draw = make_overlay(base.size[0])
    draw.ellipse(box, fill=color)
    return alpha_composite(base, overlay.filter(ImageFilter.GaussianBlur(blur_radius)))


def create_background(size: int) -> Image.Image:
    inset = int(size * 0.02)
    radius = int(size * 0.22)

    background = vertical_gradient(size, rgba("#0A1233"), rgba("#0A1030"))
    background = add_glow(
        background,
        (
            int(size * 0.48),
            int(size * 0.05),
            int(size * 1.02),
            int(size * 0.62),
        ),
        rgba("#3E86FF", 70),
        int(size * 0.08),
    )
    background = add_glow(
        background,
        (
            int(size * -0.08),
            int(size * -0.04),
            int(size * 0.45),
            int(size * 0.42),
        ),
        rgba("#1C2B66", 72),
        int(size * 0.06),
    )

    sheen_overlay, sheen_draw = make_overlay(size)
    sheen_draw.polygon(
        [
            (inset, inset),
            (int(size * 0.28), inset),
            (inset, int(size * 0.28)),
        ],
        fill=rgba("#1B2F6C", 80),
    )
    sheen_draw.polygon(
        [
            (size - inset, size - inset),
            (int(size * 0.74), size - inset),
            (size - inset, int(size * 0.74)),
        ],
        fill=rgba("#09102D", 120),
    )
    background = alpha_composite(background, sheen_overlay)

    border_overlay, border_draw = make_overlay(size)
    border_draw.rounded_rectangle(
        (inset, inset, size - inset - 1, size - inset - 1),
        radius=radius,
        outline=rgba("#6F86D9", 128),
        width=max(3, size // 280),
    )
    background = alpha_composite(background, border_overlay)
    background.putalpha(rounded_mask(size, inset, radius))
    return background


def stroke_mask(size: int, points: list[tuple[float, float]], width: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.line(points, fill=255, width=width, joint="curve")
    radius = width // 2
    for x, y in (points[0], points[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=255)
    return mask


def create_mark_mask(size: int) -> Image.Image:
    stroke_width = int(size * 0.09)
    points = [
        (size * 0.26, size * 0.70),
        (size * 0.50, size * 0.32),
        (size * 0.74, size * 0.70),
        (size * 0.54, size * 0.70),
    ]
    return stroke_mask(size, points, stroke_width)


def create_mark_gradient(size: int) -> Image.Image:
    return vertical_gradient(size, rgba("#61DCFF"), rgba("#7744FF"))


def create_mark_outline(size: int) -> Image.Image:
    mask = create_mark_mask(size)
    dilated = mask.filter(ImageFilter.MaxFilter(size=max(3, int(size * 0.014) | 1)))
    outline_mask = ImageChops.subtract(dilated, mask)
    outline = Image.new("RGBA", (size, size), rgba("#A7D4FF", 0))
    outline.putalpha(outline_mask.point(lambda value: int(value * 0.55)))
    return outline.filter(ImageFilter.GaussianBlur(max(1, size // 240)))


def create_mark_shadow(size: int) -> Image.Image:
    mask = create_mark_mask(size)
    shadow = Image.new("RGBA", (size, size), rgba("#000000", 0))
    shadow.putalpha(mask.point(lambda value: int(value * 0.26)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(1, size // 90)))
    shifted = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shifted.alpha_composite(shadow, (0, int(size * 0.012)))
    return shifted


def sparkle_points(size: int) -> list[tuple[float, float]]:
    cx = size * 0.50
    cy = size * 0.565
    outer = size * 0.108
    inner = outer * 0.34
    return [
        (cx, cy - outer),
        (cx + inner, cy - inner),
        (cx + outer, cy),
        (cx + inner, cy + inner),
        (cx, cy + outer),
        (cx - inner, cy + inner),
        (cx - outer, cy),
        (cx - inner, cy - inner),
    ]


def create_sparkle(size: int) -> Image.Image:
    sparkle, draw = make_overlay(size)
    points = sparkle_points(size)
    draw.polygon(points, fill=rgba("#F4FBFF"))
    glow, glow_draw = make_overlay(size)
    glow_draw.polygon(points, fill=rgba("#B9E8FF", 180))
    sparkle = alpha_composite(
        glow.filter(ImageFilter.GaussianBlur(max(2, size // 120))),
        sparkle,
    )
    return sparkle


def render_master() -> Image.Image:
    image = create_background(MASTER_WORK_SIZE)
    image = alpha_composite(image, create_mark_shadow(MASTER_WORK_SIZE))

    mark_gradient = create_mark_gradient(MASTER_WORK_SIZE)
    mark_mask = create_mark_mask(MASTER_WORK_SIZE)
    mark_gradient.putalpha(mark_mask)
    image = alpha_composite(image, create_mark_outline(MASTER_WORK_SIZE))
    image = alpha_composite(image, mark_gradient)
    image = alpha_composite(image, create_sparkle(MASTER_WORK_SIZE))
    return image.resize((MASTER_SIZE, MASTER_SIZE), RESAMPLE_LANCZOS)


def resize_for_slot(master: Image.Image, px: int) -> Image.Image:
    return master.resize((px, px), RESAMPLE_LANCZOS)


def main() -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)

    master = render_master()
    master.save(ICON_DIR / "icon-master-1024.png", "PNG")

    images: list[dict[str, str]] = []
    for points, scale in SIZES:
        px = points * scale
        filename = f"icon_{points}x{points}@{scale}x.png"
        filepath = ICON_DIR / filename
        resize_for_slot(master, px).save(filepath, "PNG")
        images.append(
            {
                "idiom": "mac",
                "size": f"{points}x{points}",
                "scale": f"{scale}x",
                "filename": filename,
            }
        )
        print(f"  {filename} ({px}x{px})")

    contents = {
        "images": images,
        "info": {"author": "xcode", "version": 1},
    }
    (ICON_DIR / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")
    print(f"\nGenerated {len(images)} icons in {ICON_DIR}")


if __name__ == "__main__":
    main()
