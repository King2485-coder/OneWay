#!/usr/bin/env python3
"""
Generate iOS AppIcon.appiconset from 1024 masters (OG + Purple), and zip output.

Outputs:
- OneWay_AppIcon_OG_1024.png (copied/normalized)
- OneWay_AppIcon_Purple_1024.png (copied/normalized)
- Assets.xcassets/AppIcon_OG.appiconset/*
- Assets.xcassets/AppIcon_Purple.appiconset/*
- OneWay_AppIcons.zip
"""

from __future__ import annotations

import argparse
import json
import shutil
import zipfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image


@dataclass(frozen=True)
class IconSpec:
    idiom: str
    size_points: float
    scale: int

    @property
    def pixel_size(self) -> int:
        return int(round(self.size_points * self.scale))

    @property
    def size_string(self) -> str:
        if self.size_points.is_integer():
            left = str(int(self.size_points))
        else:
            left = str(self.size_points)
        return f"{left}x{left}"

    @property
    def scale_string(self) -> str:
        return f"{self.scale}x"

    @property
    def filename(self) -> str:
        size_label = str(self.size_points).replace(".0", "")
        return f"icon-{self.idiom}-{size_label}@{self.scale}x.png"


ICON_SPECS: list[IconSpec] = [
    # iPhone
    IconSpec("iphone", 20.0, 2),
    IconSpec("iphone", 20.0, 3),
    IconSpec("iphone", 29.0, 2),
    IconSpec("iphone", 29.0, 3),
    IconSpec("iphone", 40.0, 2),
    IconSpec("iphone", 40.0, 3),
    IconSpec("iphone", 60.0, 2),
    IconSpec("iphone", 60.0, 3),
    # iPad
    IconSpec("ipad", 20.0, 1),
    IconSpec("ipad", 20.0, 2),
    IconSpec("ipad", 29.0, 1),
    IconSpec("ipad", 29.0, 2),
    IconSpec("ipad", 40.0, 1),
    IconSpec("ipad", 40.0, 2),
    IconSpec("ipad", 76.0, 1),
    IconSpec("ipad", 76.0, 2),
    IconSpec("ipad", 83.5, 2),
    # App Store
    IconSpec("ios-marketing", 1024.0, 1),
]


def ensure_1024(img_path: Path, out_path: Path) -> Path:
    img = Image.open(img_path).convert("RGBA")
    if img.size != (1024, 1024):
        img = img.resize((1024, 1024), Image.Resampling.LANCZOS)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, format="PNG", optimize=True)
    return out_path


def flatten_to_opaque(img: Image.Image) -> Image.Image:
    if img.mode != "RGBA":
        img = img.convert("RGBA")

    # Fill with average of edge pixels to avoid halos.
    px = img.load()
    w, h = img.size
    samples = [
        px[0, 0][:3],
        px[w - 1, 0][:3],
        px[0, h - 1][:3],
        px[w - 1, h - 1][:3],
        px[w // 2, 0][:3],
        px[w // 2, h - 1][:3],
        px[0, h // 2][:3],
        px[w - 1, h // 2][:3],
    ]
    r = sum(c[0] for c in samples) // len(samples)
    g = sum(c[1] for c in samples) // len(samples)
    b = sum(c[2] for c in samples) // len(samples)

    bg = Image.new("RGBA", img.size, (r, g, b, 255))
    bg.alpha_composite(img)
    return bg.convert("RGB")


def write_appiconset(master_1024: Path, appiconset_dir: Path) -> None:
    appiconset_dir.mkdir(parents=True, exist_ok=True)

    src = Image.open(master_1024).convert("RGBA")
    images_entries: list[dict] = []

    for spec in ICON_SPECS:
        resized = src.resize((spec.pixel_size, spec.pixel_size), Image.Resampling.LANCZOS)
        flattened = flatten_to_opaque(resized)
        out_file = appiconset_dir / spec.filename
        flattened.save(out_file, format="PNG", optimize=True)

        images_entries.append(
            {
                "idiom": spec.idiom,
                "size": spec.size_string,
                "scale": spec.scale_string,
                "filename": spec.filename,
            }
        )

    contents = {
        "images": images_entries,
        "info": {
            "version": 1,
            "author": "xcode",
        },
    }

    (appiconset_dir / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


def zip_dir(source_dir: Path, zip_path: Path) -> None:
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in source_dir.rglob("*"):
            zf.write(path, path.relative_to(source_dir))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export iOS AppIcon sets for OneWay")
    parser.add_argument("--og", required=True, help="Path to OG master 1024 PNG")
    parser.add_argument("--purple", required=True, help="Path to Purple master 1024 PNG")
    parser.add_argument(
        "--out-dir",
        default="/Users/king/Documents/OneWay/AppIconBuild",
        help="Output directory (default: /Users/king/Documents/OneWay/AppIconBuild)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    og_src = Path(args.og).expanduser().resolve()
    purple_src = Path(args.purple).expanduser().resolve()
    out_dir = Path(args.out_dir).expanduser().resolve()

    if not og_src.exists():
        raise SystemExit(f"Missing OG master: {og_src}")
    if not purple_src.exists():
        raise SystemExit(f"Missing Purple master: {purple_src}")

    assets_dir = out_dir / "Assets.xcassets"
    og_set = assets_dir / "AppIcon_OG.appiconset"
    purple_set = assets_dir / "AppIcon_Purple.appiconset"

    out_dir.mkdir(parents=True, exist_ok=True)

    og_master = ensure_1024(og_src, out_dir / "OneWay_AppIcon_OG_1024.png")
    purple_master = ensure_1024(purple_src, out_dir / "OneWay_AppIcon_Purple_1024.png")

    write_appiconset(og_master, og_set)
    write_appiconset(purple_master, purple_set)

    # Also provide a drop-in default AppIcon.appiconset from purple theme.
    default_appicon = assets_dir / "AppIcon.appiconset"
    if default_appicon.exists():
        shutil.rmtree(default_appicon)
    shutil.copytree(purple_set, default_appicon)

    zip_path = out_dir / "OneWay_AppIcons.zip"
    zip_dir(out_dir, zip_path)

    print(f"Created OG master: {og_master}")
    print(f"Created Purple master: {purple_master}")
    print(f"Created app icon sets: {og_set} and {purple_set}")
    print(f"Created default drop-in set: {default_appicon}")
    print(f"Created zip: {zip_path}")


if __name__ == "__main__":
    main()
