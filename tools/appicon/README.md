# OneWay App Icon Workflow

This workflow gives you both requested icon versions and a full iOS `AppIcon.appiconset` export.

## Prerequisites

- Python 3.9+
- Pillow:

```bash
python3 -m pip install pillow
```

## 1) Prepare 1024 masters

Place your polished original icon master at:

- `/Users/king/Documents/OneWay/tools/appicon/OneWay_AppIcon_OG_1024.png`

Then generate purple version from OG:

```bash
python3 /Users/king/Documents/OneWay/tools/appicon/make_purple_variant.py \
  --src /Users/king/Documents/OneWay/tools/appicon/OneWay_AppIcon_OG_1024.png \
  --out /Users/king/Documents/OneWay/tools/appicon/OneWay_AppIcon_Purple_1024.png
```

If you already have your own purple master, just place it at:

- `/Users/king/Documents/OneWay/tools/appicon/OneWay_AppIcon_Purple_1024.png`

## 2) Export full iOS AppIcon sets + Contents.json + zip

```bash
python3 /Users/king/Documents/OneWay/tools/appicon/export_appicon_set.py \
  --og /Users/king/Documents/OneWay/tools/appicon/OneWay_AppIcon_OG_1024.png \
  --purple /Users/king/Documents/OneWay/tools/appicon/OneWay_AppIcon_Purple_1024.png \
  --out-dir /Users/king/Documents/OneWay/AppIconBuild
```

## 3) Output files

Generated:

- `/Users/king/Documents/OneWay/AppIconBuild/OneWay_AppIcon_OG_1024.png`
- `/Users/king/Documents/OneWay/AppIconBuild/OneWay_AppIcon_Purple_1024.png`
- `/Users/king/Documents/OneWay/AppIconBuild/Assets.xcassets/AppIcon_OG.appiconset/`
- `/Users/king/Documents/OneWay/AppIconBuild/Assets.xcassets/AppIcon_Purple.appiconset/`
- `/Users/king/Documents/OneWay/AppIconBuild/Assets.xcassets/AppIcon.appiconset/` (drop-in default, purple)
- `/Users/king/Documents/OneWay/AppIconBuild/OneWay_AppIcons.zip`

## 4) Drop into Xcode

Copy the generated `AppIcon.appiconset` into your project assets:

- `/Users/king/Documents/OneWay/OneWay/OneWay/Assets.xcassets/AppIcon.appiconset`

## Notes

- Exports include all requested sizes:
  - iPhone: `20@2x`, `20@3x`, `29@2x`, `29@3x`, `40@2x`, `40@3x`, `60@2x`, `60@3x`
  - iPad: `20@1x`, `20@2x`, `29@1x`, `29@2x`, `40@1x`, `40@2x`, `76@1x`, `76@2x`, `83.5@2x`
  - App Store: `1024x1024`
- PNGs are flattened to opaque during appiconset export to avoid alpha/halo issues.
