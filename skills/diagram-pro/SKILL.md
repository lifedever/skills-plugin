---
name: diagram-pro
description: >
  Produce deliverable-grade business flowcharts and technical architecture
  diagrams as hand-written SVG inside a self-contained HTML page — draw.io
  visual grammar (standard shapes, line icons, mandatory legend), a preview
  toolbar (zoom / grid / PNG@2x / clean export mode), and a required
  render-and-inspect verification pass before handing anything over.
  Use when the diagram is a deliverable: a bid, a deck, a design doc, a README,
  a client-facing explainer.
  Use when user says: "diagram-pro", "画个流程图", "画个架构图", "画张图",
  "出个图", "画个示意图", "业务流程图", "技术架构图", "流程图", "架构图",
  "系统架构图", "投标用的图", "汇报用的图", "文档配图",
  "draw a flowchart", "draw an architecture diagram", "make me a diagram",
  "system diagram", "produce a professional diagram", "diagram this",
  "visualize this flow", "chart this out",
  or when a Mermaid sketch has already been judged not presentable enough.
---

# Diagram Pro — Deliverable-Grade Diagrams

Hand-write SVG inside a self-contained HTML page. One file per diagram, no build step, no dependencies, opens in any browser, exports a 2× PNG.

## Use this — or don't

**Use it** when the diagram is a deliverable: a bid document, a slide, a design doc, a README, something a client or a room of people will look at. Also use it the moment a Mermaid render gets rejected as "not presentable enough".

**Skip it** for a throwaway sketch inside the conversation. Mermaid is faster and perfectly fine there. The cost of this skill is real layout work — don't spend it on something nobody keeps.

Signals that you're in deliverable territory: the user names an audience (客户 / 老板 / 评委 / 投标), asks for a file rather than an answer, mentions a document it goes into, or has previously rejected an auto-layout render.

## Workflow

### 1. Pin the content before touching SVG

Do not start drawing until you can state, in plain sentences:

- **What single question does this diagram answer?** Write it down — it becomes the subtitle line under the title. If you can't write it, you don't understand the content well enough to lay it out.
- **What are the top-level regions?** Two or three groupings that carry the argument (e.g. "inside the wall / the wall / outside the wall", or "user journey / data / algorithm"). Regions come before nodes.
- **What is the reading direction?** Left-to-right for boundaries and pipelines; top-to-bottom for decision flows. Pick one and don't mix within a region.

If the content comes from a source document, anchor the wording to that document's own phrasing. Do not invent new terminology, and do not write marketing copy — see the copy rules in the style spec.

When the user's question is conceptual ("how does X actually work"), prefer **two focused diagrams over one crowded one**: typically a structure/boundary diagram plus a step-by-step flow diagram. Two diagrams that each fit on a screen beat one that needs zooming.

### 2. Plan the coordinate grid — on paper, before any markup

This is where diagrams succeed or fail. Compute every coordinate arithmetically first; do not eyeball values and fix them later.

**Canvas frame**

- Outer margin 48px on all sides.
- Title block: eyebrow at `y=34`, title at `y=63`, subtitle at `y=88`. Content starts at `y≥116`.
- Reserve the bottom: a divider line plus one legend row is ~70px. Add ~110px more if you use a note band.

**Row / column arithmetic**

For `n` nodes across a container of width `containerW` with padding `pad`:

```
available = containerW - 2*pad
available = n*nodeW + (n-1)*gap
```

Pick `nodeW` from the longest label, solve for `gap`. If `gap < 20`, shrink `nodeW` — don't let nodes touch. Then write out the explicit x positions and **check the last one**: `lastX + nodeW` must equal `containerX + containerW - pad`. An off-by-one here is the single most common source of a diagram that looks subtly crooked.

**Routing channels**

- Leave a 20–30px gutter between regions and run orthogonal connectors down its centre. Never route a connector through a node.
- Two connectors sharing a gutter must sit ≥10px apart on the shared axis, and should overlap on the other axis by no more than a few pixels.
- To merge N sources into one target: draw N short horizontal stubs into the channel, one vertical spine joining them, and a **single** arrow out of the spine into the target. N crossing diagonals is always the wrong answer.

**Text inside a diamond**

For a diamond with half-diagonals `a` (horizontal) and `b` (vertical), a centred text box of half-height `h` fits only if its half-width `w` satisfies:

```
w ≤ a * (1 - h/b)
```

Worked example: `a=160`, `b=62`, text box `176×56` → `h=28` → `w ≤ 160*(1-28/62) ≈ 88` → 176 wide total. Fits exactly.

**Arrow length**

Every segment carrying `marker-end` must be **≥16px** long. Shorter and the marker renders as an orphan triangle floating in space with no visible line. If two nodes end up 10px apart, move a node — don't shorten the arrow.

### 3. Fill the template

Copy [references/template.html](references/template.html) and replace the placeholders:

| Placeholder | What goes in |
|---|---|
| `{{TITLE}}` | Page `<title>` |
| `{{W}}` / `{{H}}` | Canvas width / height (appears in the SVG attrs *and* the JS — replace all occurrences) |
| `{{PNG_NAME}}` | Filename used by the "download PNG" button |
| `{{ICONS}}` | The `<symbol>` defs you actually use |
| `{{BODY}}` | The diagram markup |

The template already ships the toolbar, zoom/pan JS, `localStorage` view persistence, `?export=1` clean mode, grid patterns, and arrow markers. Don't reimplement any of that.

Everything about palette, shape vocabulary, typography, the icon starter library, legend rules, and the specific rendering traps lives in [references/style-spec.md](references/style-spec.md). **Read it before writing markup** — it is the part that makes the output not look auto-generated.

### 4. Render and inspect — not optional

```bash
${CLAUDE_SKILL_DIR}/scripts/render.sh <html-file> <W> <H> <out.png>
```

Then **actually read the PNG back**. You cannot verify a hand-written SVG by re-reading its source; layout bugs only exist in the render.

Scan specifically for:

- Titles wrapping mid-phrase (a one-character overflow reads as broken)
- Text overflowing or colliding with its shape's border
- Orphan arrowheads (segment shorter than the marker)
- Connectors crossing nodes or other connectors at a shallow angle
- Line labels sitting directly on a stroke without a background plate
- The last node in a row not aligning with its container's inner edge

For anything subtle, crop the region and look closely — coordinates are in **diagram space**, the script handles the 2× scaling:

```bash
${CLAUDE_SKILL_DIR}/scripts/render.sh diagram.html 1560 1070 check.png --crop 780,320,1010,560
```

Fix with precise string replacement (`Edit`), re-render, re-read. Iterate until clean. Two or three passes is normal; shipping without looking is not.

### 5. Deliver

- Write the file(s) to the directory the user asked for, or `~/Downloads/<topic>图/` when unspecified.
- Export a 2× PNG alongside each HTML.
- More than one diagram? Add a small `index.html` with one card per diagram (title, one-line description, canvas dimensions, link). Keep it plain — it's a table of contents, not a landing page.
- `open` the index (or the single HTML) so the user sees it immediately.
- In your reply, walk through what each diagram shows — the user should understand the diagram from your text without having to reverse-engineer it from the picture.

## Hard rules

1. **Never ship without rendering and looking at it.** Non-negotiable. See step 4.
2. **No gradients, no wide coloured borders, no drop shadows on nodes.** These read as machine-generated on sight. Flat draw.io fills with 1px matching strokes.
3. **Legend is mandatory.** Every colour and line style used must appear in it. If a colour isn't worth a legend entry, don't use the colour.
4. **Colour carries exactly one dimension of meaning.** Pick what it encodes (ownership, layer, risk) and stay consistent. Need a second dimension? Use badges, shape, or border style — never a second colour scheme.
5. **Shape carries meaning too** — capsule = start/end, rectangle = process, diamond = decision, cylinder = storage, dashed container = grouping. Don't pick shapes for variety.
6. **Every decision diamond's branches must be exhaustive and labelled**, with the label tight against the diamond.
7. **No marketing voice.** No "赋能 / 沉淀 / 反哺 / 闭环" stacking, no adjective chains, no invented benefit claims. Neutral, specific, verifiable statements only.
8. **Match the source vocabulary.** If the brief calls it 旅程节点, the diagram says 旅程节点.

## When the user annotates a revision

If they come back with markup on an exported PNG, do **not** batch-apply your reading of it. Restate what you think each annotation asks for, confirm, then apply one at a time. Revise by precise string replacement against the SVG source (assert on a unique anchor), re-render, and diff the crop. Silent bulk rewrites of a diagram the user has already reviewed are the fastest way to lose their trust in it.

## References

- [references/style-spec.md](references/style-spec.md) — palette, shape vocabulary with SVG snippets, typography scale, icon starter library, connector patterns, legend rules, copy rules, and the rendering-trap checklist
- [references/template.html](references/template.html) — the HTML scaffold: toolbar, zoom/pan, PNG export, `?export=1` mode
- `scripts/render.sh` — headless-Chrome render with optional crop, for the verification loop
