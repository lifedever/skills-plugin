#!/usr/bin/env bash
# Convert an SVG icon to all required app icon formats.
# Usage: convert_icons.sh <source.svg> <output_dir>
#
# Dependencies:
#   - rsvg-convert (librsvg): brew install librsvg
#   - iconutil (macOS built-in)
#   - Python3 + Pillow: pip3 install Pillow

set -euo pipefail

SVG="${1:?Usage: convert_icons.sh <source.svg> <output_dir>}"
OUT="${2:?Usage: convert_icons.sh <source.svg> <output_dir>}"

if ! command -v rsvg-convert &>/dev/null; then
  echo "Error: rsvg-convert not found. Install with: brew install librsvg" >&2
  exit 1
fi

mkdir -p "$OUT"

echo "==> Generating PNGs..."

# Standard sizes (Tauri / Electron / general desktop)
for SIZE in 32 128 256 512 1024; do
  rsvg-convert -w "$SIZE" -h "$SIZE" "$SVG" > "$OUT/${SIZE}x${SIZE}.png"
  echo "    ${SIZE}x${SIZE}.png"
done

# Retina @2x
rsvg-convert -w 256 -h 256 "$SVG" > "$OUT/128x128@2x.png"
echo "    128x128@2x.png"

# icon.png (512x512 standard)
cp "$OUT/512x512.png" "$OUT/icon.png"
echo "    icon.png"

# Windows Square logos (UWP)
for SIZE in 30 44 71 89 107 142 150 284 310; do
  rsvg-convert -w "$SIZE" -h "$SIZE" "$SVG" > "$OUT/Square${SIZE}x${SIZE}Logo.png"
  echo "    Square${SIZE}x${SIZE}Logo.png"
done

# StoreLogo (50x50)
rsvg-convert -w 50 -h 50 "$SVG" > "$OUT/StoreLogo.png"
echo "    StoreLogo.png"

# macOS .icns
echo "==> Generating icon.icns..."
ICONSET=$(mktemp -d)/icon.iconset
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  rsvg-convert -w "$SIZE" -h "$SIZE" "$SVG" > "$ICONSET/icon_${SIZE}x${SIZE}.png"
  DOUBLE=$((SIZE * 2))
  rsvg-convert -w "$DOUBLE" -h "$DOUBLE" "$SVG" > "$ICONSET/icon_${SIZE}x${SIZE}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$OUT/icon.icns"
rm -rf "$(dirname "$ICONSET")"
echo "    icon.icns"

# Windows .ico
echo "==> Generating icon.ico..."
python3 -c "
from PIL import Image
sizes = [16, 24, 32, 48, 64, 128, 256]
imgs = []
for s in sizes:
    img = Image.open('$OUT/{0}x{0}.png'.format(s) if s in [32, 128, 256] else '$OUT/icon.png')
    imgs.append(img.resize((s, s), Image.LANCZOS))
imgs[0].save('$OUT/icon.ico', format='ICO', sizes=[(s, s) for s in sizes], append_images=imgs[1:])
print('    icon.ico')
" 2>/dev/null || {
  echo "    Skipped icon.ico (Pillow not installed: pip3 install Pillow)" >&2
}

# Clean up intermediate sizes not needed by most frameworks
rm -f "$OUT/256x256.png" "$OUT/512x512.png" "$OUT/1024x1024.png"

echo ""
echo "Done! Icons saved to: $OUT"
