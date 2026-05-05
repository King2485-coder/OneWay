#!/usr/bin/env python3
"""
Create a purple-themed 1024x1024 OneWay icon master from an OG 1024 icon.

This keeps the original composition (paper plane + bubble) but pushes the
background/theme toward deep purple/indigo with subtle neon-violet highlights.
"""

from __future__ import annotations

import argparse
import random
from pathlib import Path

from PIL import Image, ImageChops, ImageEnhance, ImageFilter


def hex_to_rgb(hex_value: str) -> tuple[int, int, int]:
    hex_value = hex_value.strip().lstrip("#")
    if len(hex_value) != 6:
        raise ValueError(f"Invalid hex color: {hex_value}")
    return tuple(int(hex_value[i : i + 2], 16) for i in (0, 2, 4))


def vertical_gradient(size: tuple[int, int], stops: list[tuple[float, str]]) -> Image.Image:
    width, height = size
    img = Image.new("RGB", size)
    px = img.load()

    parsed = [(pos, hex_to_rgb(color)) for pos, color in stops]
    parsed.sort(key=lambda x: x[0])

    for y in range(height):
        t = y / max(1, height - 1)

        left = parsed[0]
        right = parsed[-1]
        for i in range(len(parsed) - 1):
            if parsed[i][0] <= t <= parsed[i + 1][0]:
                left = parsed[i]
                right = parsed[i + 1]
                break

        if right[0] == left[0]:
            local_t = 0.0
        else:
            local_t = (t - left[0]) / (right[0] - left[0])

        r = int(left[1][0] + (right[1][0] - left[1][0]) * local_t)
        g = int(left[1][1] + (right[1][1] - left[1][1]) * local_t)
        b = int(left[1][2] + (right[1][2] - left[1][2]) * local_t)

        for x in range(width):
            px[x, y] = (r, g, b)

    return img


def add_subtle_noise(img: Image.Image, amount: int = 10, opacity: float = 0.06) -> Image.Image:
    width, height = img.size
    noise = Image.new("L", (width, height))
    noise_px = noise.load()

    for y in range(height):
        for x in range(width):
            base = 128
            jitter = random.randint(-amount, amount)
            noise_px[x, y] = max(0, min(255, base + jitter))

    noise_rgb = Image.merge("RGB", (noise, noise, noise))
    return Image.blend(img, noise_rgb, opacity)


def preserve_highlights(original: Image.Image, themed: Image.Image) -> Image.Image:
    # Preserve bright whites (paper plane highlights) so they remain crisp ice-white.
    lum = original.convert("L")
    mask = lum.point(lambda p: 255 if p > 220 else 0).filter(ImageFilter.GaussianBlur(1.5))
    return Image.composite(original, themed, mask)


def build_purple_variant(src_path: Path, dst_path: Path) -> None:
    base = Image.open(src_path).convert("RGBA")
    if base.size != (1024, 1024):
        base = base.resize((1024, 1024), Image.Resampling.LANCZOS)

    # Target theme stops from requirement.
    grad = vertical_gradient(
        (1024, 1024),
        [
            (0.00, "#0B0720"),
            (0.35, "#1A0B3D"),
            (0.72, "#3B1A73"),
            (1.00, "#2A145C"),
        ],
    ).convert("RGBA")

    # Soft neon-violet bloom (sparingly).
    glow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    glow_core = Image.new("RGBA", (420, 420), (*hex_to_rgb("#6C3BD6"), 110))
    glow.alpha_composite(glow_core, dest=(510, 80))
    glow = glow.filter(ImageFilter.GaussianBlur(65))

    # Theme blend: keep source composition, push palette toward purple.
    tinted = ImageChops.soft_light(base, grad)
    tinted = Image.blend(base, tinted, 0.70)
    tinted = Image.alpha_composite(tinted, glow)

    # Slight vibrance and contrast polish.
    rgb = tinted.convert("RGB")
    rgb = ImageEnhance.Color(rgb).enhance(1.10)
    rgb = ImageEnhance.Contrast(rgb).enhance(1.06)
    rgb = add_subtle_noise(rgb, amount=8, opacity=0.05)

    # Preserve bright highlights for paper plane + dots.
    rgb = preserve_highlights(base.convert("RGB"), rgb)

    # Keep alpha from source master and export.
    out = rgb.convert("RGBA")
    out.putalpha(base.split()[-1])
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    out.save(dst_path, format="PNG", optimize=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create purple themed OneWay master icon (1024).")
    parser.add_argument("--src", required=True, help="Path to OG 1024 PNG")
    parser.add_argument(
        "--out",
        default="OneWay_AppIcon_Purple_1024.png",
        help="Output path for purple master (default: OneWay_AppIcon_Purple_1024.png)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    src = Path(args.src).expanduser().resolve()
    out = Path(args.out).expanduser().resolve()

    if not src.exists():
        raise SystemExit(f"Source image not found: {src}")

    build_purple_variant(src, out)
    print(f"Created: {out}")


if __name__ == "__main__":
    main()
