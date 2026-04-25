#!/usr/bin/env python3

"""Apply a clean rounded-window alpha mask to website screenshots.

The website screenshots are captured as PNGs with an alpha channel, but some
captures include baked-in desktop pixels at the rounded macOS window corners.
This script makes the outer rounded corners transparent so the website frame
shows through cleanly.

The implementation intentionally uses only the Python standard library so it
can run in CI or on a fresh macOS checkout without Pillow/ImageMagick.
"""

from __future__ import annotations

import argparse
import math
import struct
import zlib
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
DEFAULT_SCREENSHOTS = (
    "workspace-window.png",
    "feature-worktrees.png",
    "feature-terminals.png",
    "feature-review.png",
    "review-agents.png",
    "review-window.png",
)
DEFAULT_ASSET_DIRS = (
    Path("website/assets"),
    Path("website/draft/assets"),
)


def read_rgba_png(path: Path) -> tuple[int, int, list[bytearray]]:
    data = path.read_bytes()
    if data[:8] != PNG_SIGNATURE:
        raise ValueError(f"{path}: not a PNG file")

    position = 8
    ihdr = None
    idat = bytearray()

    while position < len(data):
        length = struct.unpack(">I", data[position : position + 4])[0]
        chunk_type = data[position + 4 : position + 8]
        chunk = data[position + 8 : position + 8 + length]
        position += 12 + length

        if chunk_type == b"IHDR":
            ihdr = chunk
        elif chunk_type == b"IDAT":
            idat.extend(chunk)
        elif chunk_type == b"IEND":
            break

    if ihdr is None:
        raise ValueError(f"{path}: missing IHDR chunk")

    width, height, bit_depth, color_type, compression, filter_method, interlace = (
        struct.unpack(">IIBBBBB", ihdr)
    )
    if (bit_depth, color_type, compression, filter_method, interlace) != (8, 6, 0, 0, 0):
        raise ValueError(
            f"{path}: expected non-interlaced 8-bit RGBA PNG, got "
            f"bit_depth={bit_depth} color_type={color_type} interlace={interlace}"
        )

    raw = zlib.decompress(bytes(idat))
    bytes_per_pixel = 4
    stride = width * bytes_per_pixel
    rows: list[bytearray] = []
    index = 0
    previous = bytearray(stride)

    for _ in range(height):
        filter_type = raw[index]
        index += 1
        scanline = bytearray(raw[index : index + stride])
        index += stride
        row = bytearray(stride)

        for byte_index, encoded in enumerate(scanline):
            left = row[byte_index - bytes_per_pixel] if byte_index >= bytes_per_pixel else 0
            up = previous[byte_index]
            up_left = previous[byte_index - bytes_per_pixel] if byte_index >= bytes_per_pixel else 0

            if filter_type == 0:
                decoded = encoded
            elif filter_type == 1:
                decoded = (encoded + left) & 0xFF
            elif filter_type == 2:
                decoded = (encoded + up) & 0xFF
            elif filter_type == 3:
                decoded = (encoded + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                decoded = (encoded + paeth_predictor(left, up, up_left)) & 0xFF
            else:
                raise ValueError(f"{path}: unsupported PNG filter {filter_type}")

            row[byte_index] = decoded

        rows.append(row)
        previous = row

    return width, height, rows


def paeth_predictor(left: int, up: int, up_left: int) -> int:
    estimate = left + up - up_left
    left_distance = abs(estimate - left)
    up_distance = abs(estimate - up)
    up_left_distance = abs(estimate - up_left)

    if left_distance <= up_distance and left_distance <= up_left_distance:
        return left
    if up_distance <= up_left_distance:
        return up
    return up_left


def write_rgba_png(path: Path, width: int, height: int, rows: list[bytearray]) -> None:
    raw = bytearray()
    for row in rows:
        raw.append(0)
        raw.extend(row)

    def chunk(chunk_type: bytes, payload: bytes) -> bytes:
        checksum = zlib.crc32(chunk_type + payload) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + chunk_type + payload + struct.pack(">I", checksum)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(
        PNG_SIGNATURE
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), level=9))
        + chunk(b"IEND", b"")
    )


def rounded_corner_alpha_factor(
    x: int,
    y: int,
    width: int,
    height: int,
    radius: int,
    antialias_width: float,
) -> float:
    centers: list[tuple[int, int]] = []
    if x < radius and y < radius:
        centers.append((radius, radius))
    if x >= width - radius and y < radius:
        centers.append((width - radius - 1, radius))
    if x < radius and y >= height - radius:
        centers.append((radius, height - radius - 1))
    if x >= width - radius and y >= height - radius:
        centers.append((width - radius - 1, height - radius - 1))

    if not centers:
        return 1.0

    factor = 1.0
    for center_x, center_y in centers:
        distance_from_edge = math.hypot(x - center_x, y - center_y) - radius
        if distance_from_edge >= antialias_width:
            factor = min(factor, 0.0)
        elif distance_from_edge > -antialias_width:
            factor = min(
                factor,
                max(0.0, min(1.0, (antialias_width - distance_from_edge) / (2 * antialias_width))),
            )

    return factor


def mask_screenshot(path: Path, radius_ratio: float, antialias_width: float) -> None:
    width, height, rows = read_rgba_png(path)
    radius = max(64, round(min(width, height) * radius_ratio))

    for y, row in enumerate(rows):
        for x in range(width):
            factor = rounded_corner_alpha_factor(x, y, width, height, radius, antialias_width)
            if factor < 1.0:
                alpha_index = x * 4 + 3
                # Use min() instead of multiplication so repeated runs are idempotent.
                row[alpha_index] = min(row[alpha_index], round(255 * factor))

    write_rgba_png(path, width, height, rows)
    print(f"processed {path} radius={radius}")


def default_paths() -> list[Path]:
    paths: list[Path] = []
    for asset_dir in DEFAULT_ASSET_DIRS:
        for filename in DEFAULT_SCREENSHOTS:
            path = asset_dir / filename
            if path.exists():
                paths.append(path)
    return paths


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply transparent rounded corners to Argon website screenshots."
    )
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        help="PNG screenshots to process. Defaults to website screenshot assets.",
    )
    parser.add_argument(
        "--radius-ratio",
        type=float,
        default=0.065,
        help="Corner radius as a fraction of the smaller image dimension.",
    )
    parser.add_argument(
        "--antialias-width",
        type=float,
        default=2.0,
        help="Width in pixels for the alpha falloff at the rounded edge.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    paths = args.paths or default_paths()
    if not paths:
        raise SystemExit("no screenshots found")

    for path in paths:
        mask_screenshot(path, args.radius_ratio, args.antialias_width)


if __name__ == "__main__":
    main()
