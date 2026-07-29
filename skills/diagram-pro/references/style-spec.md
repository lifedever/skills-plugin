# Style Spec

The visual grammar that makes a hand-written SVG read as a professional diagram rather than an auto-generated one. Read this before writing markup.

---

## 1. Palette

The draw.io standard palette. Each entry is a fill plus its matching 1px stroke — always use them as a pair.

| Role | Fill | Stroke | Text on fill |
|---|---|---|---|
| Blue | `#DAE8FC` | `#6C8EBF` | `#3E6396` |
| Green | `#D5E8D4` | `#82B366` | `#4E7A38` |
| Purple | `#E1D5E7` | `#9673A6` | `#7A5E90` |
| Yellow | `#FFF2CC` | `#D6B656` | `#8A6100` |
| Orange | `#FFE6CC` | `#D79B00` | `#8A6100` |
| Red | `#F8CECC` | `#B85450` | `#9E4B48` |

Neutrals:

| Role | Value |
|---|---|
| Canvas | `#FFFFFF` |
| Container tint (very light wash of a region colour) | `#FBFCFE` blue · `#FBFDFB` green · `#FDF3F2` red · `#FFFDF5` yellow |
| Connector stroke | `#8593A6` |
| Divider / note border | `#DCE1E8` |
| Note background | `#FAFBFC` |
| Body text | `#1A2230` |
| Secondary text | `#5C6675` |
| Muted label | `#8A93A3` |

**Cap yourself at five semantic colours plus neutrals.** Six is already hard to hold in your head while reading.

Colour encodes exactly **one** dimension — pick it explicitly (ownership? layer? risk level?) and stay consistent across the whole diagram. A second dimension goes on badges, shape, or border style.

### Forbidden

- Gradients of any kind
- Border width > 1px on nodes (2px is reserved for a boundary/wall container)
- Drop shadows on nodes (the page-level shadow on the SVG element is fine — it's chrome, not content)
- Saturated brand colours as fills
- More than one accent colour per node

---

## 2. Shape vocabulary

Shape carries meaning. Never pick a shape for visual variety.

| Meaning | Shape | Notes |
|---|---|---|
| Start / end | Capsule (`rx` = half the height) | Only at genuine entry and exit points |
| Process / service / component | Plain rectangle, no `rx` | The default |
| Decision | Diamond | Branches must be exhaustive and labelled |
| Storage / database | Cylinder | Don't add a database icon too — the shape is the icon |
| Grouping / swimlane / zone | Dashed or solid container with a solid title strip | |
| Boundary / hard constraint | 2px dashed container | Reserve for one thing per diagram |
| Note / caveat | Rectangle with a 4px coloured accent bar on the left | Neutral fill, never a palette colour |
| Funnel stage | Trapezoid path | For conversion funnels only |

### Snippets

**Rectangle with icon and two-line text**

```xml
<rect x="246" y="196" width="146" height="100" fill="#DAE8FC" stroke="#6C8EBF"/>
<use href="#i-lock" x="311" y="206" width="16" height="16" style="color:#3E6396"/>
<foreignObject x="250" y="226" width="138" height="62">
  <div xmlns="http://www.w3.org/1999/xhtml" class="n ctr sm">
    <div class="t">Title</div>
    <div class="d">Supporting line</div>
  </div>
</foreignObject>
```

**Capsule** — `rx` equals half the height:

```xml
<rect x="470" y="126" width="300" height="52" rx="26" fill="#DAE8FC" stroke="#6C8EBF"/>
```

**Cylinder** — body path plus a separate top-ellipse arc. With `rx = width/2` and `ry ≈ 10–12`:

```xml
<path d="M66 206 A73 10 0 0 1 212 206 L212 286 A73 10 0 0 1 66 286 Z"
      fill="#DAE8FC" stroke="#6C8EBF"/>
<path d="M66 206 A73 10 0 0 0 212 206" fill="none" stroke="#6C8EBF"/>
```

Start the text `foreignObject` ~12px below the top arc so it clears the ellipse.

**Diamond** — plain path through the four points:

```xml
<path d="M620 288 L780 350 L620 412 L460 350 Z" fill="#FFF2CC" stroke="#D6B656"/>
```

Text sizing is constrained — see the inscribed-box formula in SKILL.md step 2.

**Swimlane** — container plus a solid title strip sharing the top edge:

```xml
<rect x="48" y="158" width="722" height="158" fill="#FBFCFE" stroke="#6C8EBF"/>
<rect x="48" y="158" width="722" height="26" fill="#DAE8FC" stroke="#6C8EBF"/>
<text class="lanehd" x="60" y="176" fill="#3E6396">Lane title</text>
```

**Boundary / wall** — 2px dashed, light tint, with "doors" (nodes) sitting inside it:

```xml
<rect x="790" y="158" width="200" height="524" fill="#FDF3F2"
      stroke="#B85450" stroke-width="2" stroke-dasharray="7 5"/>
```

**Note with accent bar**

```xml
<rect x="48" y="870" width="480" height="104" fill="#FAFBFC" stroke="#DCE1E8"/>
<rect x="48" y="870" width="4" height="104" fill="#B85450"/>
```

**Badge** — a small pill for a second meaning dimension, top-right inside a node:

```xml
<rect x="346" y="326" width="52" height="16" rx="8" fill="#D5E8D4" stroke="#82B366"/>
<text class="bdg" x="372" y="337" fill="#3E6329">强匹配</text>
```

---

## 3. Typography

Text lives inside `foreignObject` (for wrapping) or as `<text>` (for single-line labels). The template ships these classes:

| Class | Size | Weight | Use |
|---|---|---|---|
| `.ttl` | 21px | 600 | Diagram title |
| `.sub` | 12px | 400 | The one-line question the diagram answers |
| `.eyebrow` | 10.5px | 400 | Project / context line above the title, `letter-spacing:.7px` |
| `.colhd` | 12.5px | 600 | Region header bar |
| `.lanehd` | 11.8px | 600 | Swimlane title |
| `.n .t` | 12.4px | 600 | Node title |
| `.n .d` | 10.2px | 400 | Node description |
| `.n.sm .t` / `.n.sm .d` | 11.6 / 9.7px | | Compact nodes (< 160px wide) |
| `.n.dia .t` | 11.4px | 600 | Diamond text |
| `.edgetxt` | 10px | 400 | Connector labels |
| `.brtxt` | 10.5px | 600 | Branch labels (是 / 否 / yes / no) |
| `.legtxt` | 10.5px | 400 | Legend |
| `.bdg` | 9px | 700 | Badge pills |

Add `.ctr` for centred node content. Font stack is `"PingFang SC","Hiragino Sans GB","Microsoft YaHei",-apple-system,sans-serif`.

**Rough width budget:** a CJK glyph occupies about its font-size in pixels; Latin about 0.55×. Use this to predict wrapping before you render — a title that wraps to two lines inside a one-line slot is the most common cosmetic defect.

---

## 4. Icons

24×24 line icons, defined once as `<symbol>` and placed with `<use>`. Every component node gets one; storage cylinders don't (the shape already reads).

Rules: `fill="none"`, `stroke="currentColor"`, `stroke-width="1.7"`, round caps and joins. Colour comes from the `<use>` site via `style="color:…"`, using the palette's *text* colour. Render at 16–18px.

```xml
<use href="#i-lock" x="311" y="206" width="16" height="16" style="color:#3E6396"/>
```

### Starter library

```xml
<symbol id="i-lock" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <rect x="4.5" y="10.5" width="15" height="10.5" rx="1.6"/><path d="M8 10.5V7.4a4 4 0 0 1 8 0v3.1"/><circle cx="12" cy="15.6" r="1.3"/>
</symbol>
<symbol id="i-key" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <circle cx="7.6" cy="15.4" r="4.1"/><path d="M10.6 12.4 20.4 2.6"/><path d="M17.2 5.8l2.6 2.6"/><path d="M14.6 8.4l2.6 2.6"/>
</symbol>
<symbol id="i-ban" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
  <circle cx="12" cy="12" r="8.8"/><line x1="5.8" y1="5.8" x2="18.2" y2="18.2"/>
</symbol>
<symbol id="i-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
  <circle cx="12" cy="12" r="8.8"/><path d="M7.8 12.2l2.9 2.9 5.5-5.9"/>
</symbol>
<symbol id="i-alert" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M12 3.4 21.6 20H2.4z"/><line x1="12" y1="9.4" x2="12" y2="14"/><circle cx="12" cy="17" r=".9" fill="currentColor" stroke="none"/>
</symbol>
<symbol id="i-help" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <circle cx="12" cy="12" r="8.8"/><path d="M9.6 9.6a2.6 2.6 0 1 1 3.2 2.6v1.4"/><circle cx="12.4" cy="16.6" r=".9" fill="currentColor" stroke="none"/>
</symbol>
<symbol id="i-users" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <circle cx="9.2" cy="8.2" r="3.6"/><path d="M2.8 20.4a6.4 6.4 0 0 1 12.8 0"/><path d="M16.4 5a3.6 3.6 0 0 1 0 6.6"/><path d="M17.6 14.6a6.4 6.4 0 0 1 3.6 5.8"/>
</symbol>
<symbol id="i-link" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M10 13.6a4.4 4.4 0 0 0 6.4.3l2.6-2.6a4.4 4.4 0 0 0-6.2-6.2l-1.5 1.5"/>
  <path d="M14 10.4a4.4 4.4 0 0 0-6.4-.3L5 12.7a4.4 4.4 0 0 0 6.2 6.2l1.5-1.5"/>
</symbol>
<symbol id="i-cluster" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <circle cx="12" cy="5" r="2.6"/><circle cx="5" cy="18" r="2.6"/><circle cx="19" cy="18" r="2.6"/>
  <path d="M10.2 7.2 6.4 15.6"/><path d="M13.8 7.2l3.8 8.4"/><path d="M7.6 18h8.8"/>
</symbol>
<symbol id="i-layers" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M12 2.8 21.6 8 12 13.2 2.4 8z"/><path d="M2.4 12.6 12 17.8l9.6-5.2"/><path d="M2.4 17 12 22.2l9.6-5.2"/>
</symbol>
<symbol id="i-chart" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M3 20.5h18"/><rect x="5" y="11" width="3.6" height="7"/><rect x="10.2" y="6" width="3.6" height="12"/><rect x="15.4" y="13.5" width="3.6" height="4.5"/>
</symbol>
<symbol id="i-doc" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M6 2.8h8l4 4v14.4H6z"/><path d="M14 2.8v4h4"/><path d="M9 13.5v4M12 11v6.5M15 14.5v3"/>
</symbol>
<symbol id="i-cycle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M20.4 12a8.4 8.4 0 1 1-2.6-6.1"/><path d="M20.5 3.6v4.8h-4.8"/>
</symbol>
<symbol id="i-target" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <circle cx="12" cy="12" r="8.7"/><circle cx="12" cy="12" r="4.8"/><circle cx="12" cy="12" r="1.2"/>
</symbol>
<symbol id="i-tag" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M11.2 2.8H21v9.8l-9.4 9.4-9.8-9.8z"/><circle cx="16.6" cy="7.4" r="1.5"/>
</symbol>
<symbol id="i-pin" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M12 21.4s7-6.6 7-11.4a7 7 0 1 0-14 0c0 4.8 7 11.4 7 11.4z"/><circle cx="12" cy="9.8" r="2.6"/>
</symbol>
<symbol id="i-print" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M7 9V3.2h10V9"/><rect x="3.2" y="9" width="17.6" height="7.6" rx="1.6"/><rect x="7" y="14" width="10" height="6.8"/>
</symbol>
<symbol id="i-card" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <rect x="2.6" y="4.8" width="18.8" height="14.4" rx="2"/><line x1="2.6" y1="9.6" x2="21.4" y2="9.6"/><line x1="6.4" y1="14.4" x2="11.6" y2="14.4"/>
</symbol>
<symbol id="i-chat" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M3.5 5.5h17v10.5h-9l-5 4v-4h-3z"/><line x1="7.5" y1="9.5" x2="16.5" y2="9.5"/><line x1="7.5" y1="12.5" x2="13" y2="12.5"/>
</symbol>
<symbol id="i-merge" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <path d="M5 3.2v5.2c0 3 2.4 5.4 5.4 5.4h8.4"/><path d="M5 20.8v-5.2c0-3 2.4-5.4 5.4-5.4"/><path d="M15.6 9.8l3.6 3.8-3.6 3.8"/>
</symbol>
```

Need something not in the list? Draw it in the same idiom: 24×24 box, ~2px inset margin, no fills, no more than four or five strokes.

---

## 5. Connectors

Stroke `#8593A6`, `stroke-width="1.3"`, `marker-end="url(#ar)"`. The template defines `#ar`; add a coloured variant per accent when a flow needs to stand out:

```xml
<marker id="arY" markerWidth="10" markerHeight="8" refX="8.5" refY="4" orient="auto">
  <path d="M0,0.5 L8.5,4 L0,7.5 z" fill="#C3982F"/>
</marker>
```

**Orthogonal only.** Horizontal and vertical segments; no diagonals except inside an explicit funnel or fan.

**Where the marker goes.** Only the final segment of a multi-segment route carries `marker-end`. Draw the intermediate legs as a plain `<g>` with no marker, then the last leg separately with it:

```xml
<g stroke="#8593A6" stroke-width="1.3" fill="none">
  <line x1="974" y1="532" x2="998" y2="532"/>
  <line x1="998" y1="532" x2="998" y2="228"/>
</g>
<line x1="998" y1="228" x2="1032" y2="228" stroke="#8593A6" stroke-width="1.3" marker-end="url(#ar)"/>
```

**Fan-out from one source to N targets:** one stub down, one horizontal spreader bar, then N short arrows down from the bar. Keep the arrows ≥16px.

**Merge from N sources:** N stubs into a shared channel, one vertical spine, one arrow out.

**Labels on lines** always need a background plate matching whatever is behind them, placed *before* the text in document order:

```xml
<rect x="626" y="418" width="22" height="13" fill="#FFFFFF"/>
<text class="brtxt" x="637" y="428">否</text>
```

Size the plate to the text — an oversized plate punches a visible hole in the line.

---

## 6. Legend

Mandatory. Bottom of the canvas, above the outer margin, under a `#DCE1E8` divider.

- Swatches are 26×15 rects using the exact fill + stroke pair from the diagram
- Line styles get a 32px sample line with its real marker
- Shape meanings that aren't obvious (capsule = terminal, dashed = grouping) get an entry too
- Every colour and line style used in the diagram appears exactly once
- Lead the row with a muted `图例` / `Legend` label in `#8A93A3`

Lay it out arithmetically like everything else: swatch, 6px, text, ~20px, next swatch. Budget ~11px per CJK glyph and verify the last item clears the right margin.

---

## 7. Copy rules

The fastest tell of a machine-made diagram is its wording, not its shapes.

**Do**

- Anchor to the source document's own terminology
- Write neutral, specific, checkable statements ("解密接口仅履约场景可调，有配额与审计")
- Let node descriptions carry the caveat that makes the box honest
- Keep node titles under ~12 CJK glyphs so they hold one line

**Don't**

- Stack marketing abstractions — 赋能 / 沉淀 / 反哺 / 闭环 / 抓手 / 心智 in the same diagram
- Chain adjectives — "高效精准的智能化匹配引擎"
- Invent benefit claims the source never made
- Use "AI 腔" connective tissue — "从而实现…", "进一步提升…", "有效降低…"
- Title a node with a full sentence

If a box needs a full sentence to be understood, the box is doing too much — split it, or move the sentence into a note.

---

## 8. Rendering traps

These have all bitten before. Check each one on the rendered PNG, not in the source.

| Trap | Symptom | Fix |
|---|---|---|
| Segment shorter than the marker | A triangle floating with no line | Make every marker-bearing segment ≥16px |
| Rounded `rx` on a container-hugging node | Visible gap at the corner | Inner-edge nodes use square corners |
| Label sitting on a stroke | Line strikes through the text | Add a background plate sized to the text |
| Plate colour ≠ backdrop | Visible white patch inside a tinted container | Match the plate to the container fill |
| Text overflowing `foreignObject` | Clipped descender or hidden last line | Give the box ~4px more than the computed text height |
| Title wrapping by one character | Reads as broken | Shorten the title or move detail to the description line |
| Cylinder text over the top arc | Text collides with the ellipse | Start the text box ~12px below the arc |
| Diamond text too wide | Text pokes out of the rhombus | Apply `w ≤ a*(1-h/b)` |
| Two routes sharing a channel | Lines merge into one ambiguous stroke | ≥10px apart, minimal overlap on the other axis |
| Zoom implemented via `width` | Layout reflows and jumps while zooming | Use `transform: scale()` with an anchor — the template already does |

---

## 9. Multi-diagram sets

When a topic needs more than one diagram, ship an `index.html` alongside them: title, one sentence on what the set covers, and one card per diagram (name, one-line description, canvas dimensions, link). Plain cards with a 1px border — it's a table of contents, not a landing page.

Keep the cards accurate when diagrams change. A stale index that describes a diagram that no longer matches is worse than no index.
