#!/usr/bin/env python3
"""Generate Argon app icons at all required macOS sizes."""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ICON_DIR = (
    Path(__file__).resolve().parent.parent
    / "apps"
    / "macos"
    / "Resources"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
)

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

OVERSAMPLE = 4
RESAMPLE_LANCZOS = Image.Resampling.LANCZOS if hasattr(Image, "Resampling") else Image.LANCZOS

FONT_CANDIDATES = [
    "/System/Library/Fonts/SFNSRounded.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Supplemental/Avenir Next Demi Bold.ttf",
]


def lerp(start: float, end: float, t: float) -> float:
    return start + (end - start) * t


def blend(c1: tuple[int, int, int], c2: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(lerp(a, b, t)) for a, b in zip(c1, c2, strict=True))


def alpha_composite(base: Image.Image, overlay: Image.Image) -> Image.Image:
    return Image.alpha_composite(base, overlay)


def make_overlay(size: int) -> tuple[Image.Image, ImageDraw.ImageDraw]:
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    return overlay, ImageDraw.Draw(overlay)


def add_glow_ellipse(
    base: Image.Image,
    box: tuple[int, int, int, int],
    color: tuple[int, int, int, int],
    blur_radius: int,
) -> Image.Image:
    overlay, draw = make_overlay(base.size[0])
    draw.ellipse(box, fill=color)
    return alpha_composite(base, overlay.filter(ImageFilter.GaussianBlur(blur_radius)))


def add_glow_line(
    base: Image.Image,
    points: list[tuple[float, float]],
    glow_color: tuple[int, int, int, int],
    core_color: tuple[int, int, int, int],
    glow_width: int,
    core_width: int,
    blur_radius: int,
) -> Image.Image:
    glow_overlay, glow_draw = make_overlay(base.size[0])
    glow_draw.line(points, fill=glow_color, width=glow_width)
    base = alpha_composite(base, glow_overlay.filter(ImageFilter.GaussianBlur(blur_radius)))

    core_overlay, core_draw = make_overlay(base.size[0])
    core_draw.line(points, fill=core_color, width=core_width)
    return alpha_composite(base, core_overlay)


def add_glow_dot(
    base: Image.Image,
    center: tuple[float, float],
    radius: int,
    fill: tuple[int, int, int, int],
    glow: tuple[int, int, int, int],
    blur_radius: int,
) -> Image.Image:
    cx, cy = center
    glow_box = (
        int(cx - radius * 3),
        int(cy - radius * 3),
        int(cx + radius * 3),
        int(cy + radius * 3),
    )
    base = add_glow_ellipse(base, glow_box, glow, blur_radius)

    overlay, draw = make_overlay(base.size[0])
    dot_box = (int(cx - radius), int(cy - radius), int(cx + radius), int(cy + radius))
    draw.ellipse(dot_box, fill=fill)
    return alpha_composite(base, overlay)


def quadratic_curve(
    start: tuple[float, float],
    control: tuple[float, float],
    end: tuple[float, float],
    steps: int = 80,
) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for index in range(steps + 1):
        t = index / steps
        omt = 1 - t
        x = omt * omt * start[0] + 2 * omt * t * control[0] + t * t * end[0]
        y = omt * omt * start[1] + 2 * omt * t * control[1] + t * t * end[1]
        points.append((x, y))
    return points


def load_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for candidate in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default()


def text_bbox(text: str, font: ImageFont.ImageFont | ImageFont.FreeTypeFont) -> tuple[int, int, int, int]:
    image = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    return draw.textbbox((0, 0), text, font=font)


def rounded_mask(px: int, margin: int, radius: int) -> Image.Image:
    mask = Image.new("L", (px, px), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((margin, margin, px - margin - 1, px - margin - 1), radius=radius, fill=255)
    return mask


def draw_background(px: int, margin: int, radius: int) -> Image.Image:
    image = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    top = (10, 22, 50)
    bottom = (4, 10, 24)
    accent = (24, 67, 156)
    for y in range(margin, px - margin):
        t = (y - margin) / max(1, px - margin * 2 - 1)
        base = blend(top, bottom, t)
        highlight = blend(base, accent, max(0.0, 0.55 - abs(t - 0.38) * 1.9))
        draw.line((margin, y, px - margin - 1, y), fill=(*highlight, 255))

    image = add_glow_ellipse(
        image,
        (
            int(px * 0.06),
            int(px * 0.12),
            int(px * 0.82),
            int(px * 0.90),
        ),
        (38, 108, 255, 72),
        max(2, px // 14),
    )
    image = add_glow_ellipse(
        image,
        (
            int(px * 0.34),
            int(px * 0.02),
            int(px * 0.96),
            int(px * 0.56),
        ),
        (114, 244, 255, 38),
        max(2, px // 18),
    )
    image = add_glow_ellipse(
        image,
        (
            int(px * 0.02),
            int(px * 0.54),
            int(px * 0.62),
            int(px * 1.02),
        ),
        (72, 126, 255, 28),
        max(2, px // 12),
    )

    detail_overlay, detail_draw = make_overlay(px)
    panel_box = (
        int(px * 0.17),
        int(px * 0.18),
        int(px * 0.84),
        int(px * 0.83),
    )
    detail_draw.rounded_rectangle(
        panel_box,
        radius=int(px * 0.18),
        fill=(255, 255, 255, 12),
        outline=(180, 230, 255, 24),
        width=max(1, px // 192),
    )
    image = alpha_composite(image, detail_overlay.filter(ImageFilter.GaussianBlur(max(1, px // 64))))

    border_overlay, border_draw = make_overlay(px)
    border_draw.rounded_rectangle(
        (margin, margin, px - margin - 1, px - margin - 1),
        radius=radius,
        outline=(255, 255, 255, 48),
        width=max(1, px // 160),
    )
    image = alpha_composite(image, border_overlay)

    image.putalpha(rounded_mask(px, margin, radius))
    return image


def draw_rendezvous_motif(base: Image.Image, px: int) -> Image.Image:
    target = (px * 0.71, px * 0.31)
    left_start = (px * 0.19, px * 0.73)
    left_control = (px * 0.12, px * 0.27)
    right_start = (px * 0.82, px * 0.79)
    right_control = (px * 0.90, px * 0.50)

    left_curve = quadratic_curve(left_start, left_control, target)
    right_curve = quadratic_curve(right_start, right_control, target)

    base = add_glow_line(
        base,
        left_curve,
        glow_color=(88, 229, 255, 92),
        core_color=(140, 247, 255, 148),
        glow_width=max(4, px // 18),
        core_width=max(1, px // 110),
        blur_radius=max(2, px // 30),
    )
    base = add_glow_line(
        base,
        right_curve,
        glow_color=(120, 170, 255, 88),
        core_color=(170, 210, 255, 132),
        glow_width=max(4, px // 20),
        core_width=max(1, px // 120),
        blur_radius=max(2, px // 32),
    )

    base = add_glow_dot(
        base,
        left_start,
        radius=max(3, px // 44),
        fill=(170, 248, 255, 255),
        glow=(78, 231, 255, 118),
        blur_radius=max(2, px // 26),
    )
    base = add_glow_dot(
        base,
        right_start,
        radius=max(3, px // 48),
        fill=(190, 220, 255, 255),
        glow=(118, 170, 255, 112),
        blur_radius=max(2, px // 28),
    )
    base = add_glow_dot(
        base,
        target,
        radius=max(4, px // 36),
        fill=(245, 252, 255, 255),
        glow=(140, 244, 255, 140),
        blur_radius=max(3, px // 22),
    )

    ring_overlay, ring_draw = make_overlay(px)
    ring_box = (
        int(px * 0.24),
        int(px * 0.20),
        int(px * 0.80),
        int(px * 0.76),
    )
    ring_draw.ellipse(
        ring_box,
        outline=(170, 226, 255, 42),
        width=max(1, px // 120),
    )
    return alpha_composite(base, ring_overlay)


def draw_small_halo(base: Image.Image, px: int) -> Image.Image:
    halo_overlay, halo_draw = make_overlay(px)
    halo_draw.ellipse(
        (
            int(px * 0.24),
            int(px * 0.22),
            int(px * 0.82),
            int(px * 0.80),
        ),
        outline=(180, 230, 255, 56),
        width=max(1, px // 96),
    )
    return alpha_composite(base, halo_overlay)


def draw_monogram(base: Image.Image, px: int) -> Image.Image:
    a_font = load_font(int(px * 0.54))
    r_font = load_font(int(px * 0.27))

    a_bbox = text_bbox("A", a_font)
    r_bbox = text_bbox("r", r_font)
    a_width = a_bbox[2] - a_bbox[0]
    a_height = a_bbox[3] - a_bbox[1]
    r_width = r_bbox[2] - r_bbox[0]

    a_x = int(px * 0.27)
    a_y = int(px * 0.23)
    r_x = a_x + a_width - int(px * 0.03)
    r_y = a_y + int(a_height * 0.18)

    shadow = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_offset = max(1, px // 160)
    shadow_draw.text((a_x + shadow_offset, a_y + shadow_offset), "A", font=a_font, fill=(0, 0, 0, 105))
    shadow_draw.text((r_x + shadow_offset, r_y + shadow_offset), "r", font=r_font, fill=(0, 0, 0, 92))
    base = alpha_composite(base, shadow.filter(ImageFilter.GaussianBlur(max(1, px // 64))))

    monogram = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    monogram_draw = ImageDraw.Draw(monogram)
    monogram_draw.text((a_x, a_y), "A", font=a_font, fill=(248, 250, 255, 255))
    monogram_draw.text((r_x, r_y), "r", font=r_font, fill=(155, 244, 255, 255))

    if px >= 64:
        glow = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        glow_draw = ImageDraw.Draw(glow)
        glow_draw.text((r_x, r_y), "r", font=r_font, fill=(88, 230, 255, 130))
        base = alpha_composite(base, glow.filter(ImageFilter.GaussianBlur(max(2, px // 44))))

    return alpha_composite(base, monogram)


def render_icon(px: int) -> Image.Image:
    work_px = px * OVERSAMPLE
    margin = max(1, int(work_px * 0.035))
    radius = int(work_px * 0.22)

    image = draw_background(work_px, margin, radius)
    if px >= 64:
        image = draw_rendezvous_motif(image, work_px)
    else:
        image = draw_small_halo(image, work_px)
    image = draw_monogram(image, work_px)
    return image.resize((px, px), RESAMPLE_LANCZOS)


def main() -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)

    images: list[dict[str, str]] = []
    for points, scale in SIZES:
        px = points * scale
        filename = f"icon_{points}x{points}@{scale}x.png"
        filepath = ICON_DIR / filename

        render_icon(px).save(filepath, "PNG")
        images.append(
            {
                "size": f"{points}x{points}",
                "scale": f"{scale}x",
                "filename": filename,
            }
        )
        print(f"  {filename} ({px}x{px})")

    contents = {
        "images": [
            {
                "idiom": "mac",
                "size": image["size"],
                "scale": image["scale"],
                "filename": image["filename"],
            }
            for image in images
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (ICON_DIR / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")
    print(f"\nGenerated {len(images)} icons in {ICON_DIR}")


if __name__ == "__main__":
    main()
