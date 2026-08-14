# assets

`hawtcher.webp` — source artwork (751×2048, alpha).

`icon.png` — the README title icon: a 450×450 crop of the head, scaled to 128px.
Displayed at 30px, so it stays sharp on high-DPI screens. Regenerate with:

```bash
sips -s format png --cropToHeightWidth 450 450 --cropOffset 0 206 \
  assets/hawtcher.webp --out /tmp/head.png
sips -Z 128 /tmp/head.png --out assets/icon.png
```

Kept as PNG rather than WebP: GitHub renders WebP inconsistently in markdown, and
PNG alpha means the icon works on both light and dark themes.
