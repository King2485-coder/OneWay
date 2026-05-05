# Assets

Drop these PNGs in here before the first build (Expo expects them at the paths in `app.json`):

- `icon.png` — 1024×1024
- `adaptive-icon.png` — 1024×1024 (Android foreground)
- `splash.png` — 1284×2778 (or any portrait, `resizeMode: contain` will handle it)
- `favicon.png` — 48×48

Until then, `expo start` will warn but still launch on a simulator.
