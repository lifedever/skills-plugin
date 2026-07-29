#!/usr/bin/env bash
#
# render.sh — export a diagram-pro HTML page to PNG at 2x via headless Chrome.
#
# This exists for the verification loop: you cannot check a hand-written SVG by
# re-reading its source. Render it, then actually look at the image.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  render.sh <html-file> <width> <height> <out.png> [--crop L,T,R,B]

  <width> <height>  Canvas size in diagram coordinates — the {{W}} {{H}} values
                    you put in the template.
  --crop L,T,R,B    Also write <out>-crop.png containing just that box.
                    Coordinates are in DIAGRAM space; the 2x scale factor is
                    applied for you.

Examples:
  render.sh arch.html 1560 1070 arch.png
  render.sh arch.html 1560 1070 arch.png --crop 780,320,1010,560
EOF
}

if [ $# -lt 4 ]; then usage >&2; exit 1; fi

HTML="$1"; W="$2"; H="$3"; OUT="$4"; shift 4
CROP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --crop) CROP="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "render.sh: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

[ -f "$HTML" ] || { echo "render.sh: no such file: $HTML" >&2; exit 1; }

# --- locate a Chromium-family browser -----------------------------------------
CHROME=""
for candidate in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
do
  [ -x "$candidate" ] && { CHROME="$candidate"; break; }
done
if [ -z "$CHROME" ]; then
  for name in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge; do
    if command -v "$name" >/dev/null 2>&1; then CHROME="$(command -v "$name")"; break; fi
  done
fi
if [ -z "$CHROME" ]; then
  cat >&2 <<'EOF'
render.sh: no Chromium-family browser found.

The diagram HTML itself works in any browser — this script is only needed for
the headless render-and-inspect verification pass.

  macOS:  brew install --cask google-chrome
  Linux:  install chromium via your package manager

Or set CHROME_BIN to a browser binary and re-run.
EOF
  exit 2
fi
CHROME="${CHROME_BIN:-$CHROME}"

# --- absolute file:// URL (spaces must be encoded) -----------------------------
case "$HTML" in
  /*) ABS="$HTML" ;;
   *) ABS="$PWD/$HTML" ;;
esac
URL="file://$(printf '%s' "$ABS" | sed 's/ /%20/g')?export=1"

mkdir -p "$(dirname "$OUT")"

"$CHROME" --headless --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 \
  --window-size="${W},${H}" \
  --screenshot="$OUT" \
  "$URL" >/dev/null 2>&1 || true

[ -s "$OUT" ] || { echo "render.sh: render produced no output — check the HTML for a syntax error" >&2; exit 1; }
echo "rendered: $OUT (${W}x${H} @2x)"

# --- optional crop -------------------------------------------------------------
[ -n "$CROP" ] || exit 0

IFS=',' read -r CL CT CR CB <<EOF
$CROP
EOF
if [ -z "${CB:-}" ]; then
  echo "render.sh: --crop needs four comma-separated numbers: L,T,R,B" >&2; exit 1
fi

CROP_OUT="${OUT%.png}-crop.png"

if python3 -c "import PIL" >/dev/null 2>&1; then
  python3 - "$OUT" "$CROP_OUT" "$CL" "$CT" "$CR" "$CB" <<'PY'
import sys
from PIL import Image
src, dst, l, t, r, b = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:7])
im = Image.open(src)
# diagram coords -> rendered pixels (rendered at 2x)
box = tuple(int(v * 2) for v in (l, t, r, b))
box = (max(0, box[0]), max(0, box[1]), min(im.width, box[2]), min(im.height, box[3]))
if box[2] <= box[0] or box[3] <= box[1]:
    sys.exit("render.sh: crop box is empty after clamping to the image")
im.crop(box).save(dst)
PY
elif command -v sips >/dev/null 2>&1; then
  CW=$(( (CR - CL) * 2 )); CH=$(( (CB - CT) * 2 ))
  sips -c "$CH" "$CW" --cropOffset $(( CT * 2 )) $(( CL * 2 )) "$OUT" --out "$CROP_OUT" >/dev/null 2>&1 \
    || { echo "render.sh: crop failed (sips). Read the full PNG instead." >&2; exit 0; }
else
  echo "render.sh: no cropper available (install Pillow: pip3 install Pillow). Read the full PNG instead." >&2
  exit 0
fi

echo "cropped:  $CROP_OUT (diagram box ${CL},${CT} → ${CR},${CB})"
