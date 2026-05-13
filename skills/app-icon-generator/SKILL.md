---
name: app-icon-generator
description: >
  Generate professional app icons for macOS, Windows, iOS, Tauri, and Electron projects.
  Use when the user asks to: create an app icon, generate app icons, make a logo for their app,
  design an application icon, convert SVG to app icons, generate .icns/.ico files,
  or needs icons for Tauri/Electron/desktop apps.
  Handles the full pipeline: SVG design → multi-size PNG → .icns (macOS) → .ico (Windows).
---

# App Icon Generator

Generate a production-ready app icon from concept to all required platform formats.

## Workflow

### 1. Design the SVG (1024x1024)

Create `logo.svg` with these specs:

- **Canvas**: `viewBox="0 0 1024 1024"` width/height 1024
- **Safe area**: 824x824 effective area, 100px padding on each side
- **Background**: Rounded rect at `x=100 y=100 width=824 height=824 rx=185 ry=185`
- **Content**: Centered within the 824x824 area
- Use `linearGradient` for depth, `feDropShadow` for polish
- Keep shapes simple — icons render at 16x16 too

Example skeleton:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#COLOR1"/>
      <stop offset="100%" stop-color="#COLOR2"/>
    </linearGradient>
  </defs>
  <rect x="100" y="100" width="824" height="824" rx="185" ry="185" fill="url(#bg)"/>
  <!-- Icon content here, centered around cx=512 cy=512 -->
</svg>
```

### 2. Convert to All Formats

Run the bundled conversion script:

```bash
bash SKILL_DIR/scripts/convert_icons.sh logo.svg ./icons/
```

This generates all files in one step:

| File | Purpose |
|------|---------|
| `32x32.png`, `128x128.png`, `128x128@2x.png` | Desktop standard |
| `icon.png` (512x512) | General use |
| `icon.icns` | macOS app bundle |
| `icon.ico` | Windows executable |
| `Square*Logo.png` | Windows UWP/Store |
| `StoreLogo.png` | Windows Store |

### 3. Dependencies

- `rsvg-convert`: `brew install librsvg`
- `iconutil`: built-in on macOS
- `Pillow` (for .ico): `pip3 install Pillow`

If Pillow is missing, .ico is skipped with a warning — all other formats still generate.

### 4. Framework Integration

**Tauri**: Save SVG as `src-tauri/icons/logo.svg`, output to `src-tauri/icons/`. Config:
```json
"icon": ["icons/32x32.png", "icons/128x128.png", "icons/128x128@2x.png", "icons/icon.icns", "icons/icon.ico"]
```

**Electron**: Output to `build/icons/`. Reference in electron-builder config.

## Design Guidelines

- **Contrast**: Ensure recognizable on both light and dark backgrounds
- **Simplicity**: Max 2-3 visual elements — must read at 16x16
- **No text** unless a single letter/symbol (too small at icon sizes)
- **Rounded corners** (`rx=185`): macOS/iOS convention; Windows ignores them
- **Gradients > flat color**: Adds depth and polish
