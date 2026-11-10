# Terminal UI architecture: a DOM-like tree rendered to terminal cells

Status: proposed design.

## 1. Context

This repository is a Zig 0.17 port of VS Code editor internals. The model,
commands and contributions are ported; `src/tui/` contains a hand-written
terminal frontend that paints directly from the model (`src/tui/render.zig`).
The next step is to port the browser-facing editor UI (`viewParts`, cursors,
selections, scrollbar) while keeping the code close to upstream.

The obstacle is that upstream browser code is written against a browser DOM and
CSS. This design introduces a small, standalone, DOM-like UI library that
provides the node tree, direct styles, layout and terminal rendering, so the
ported editor code can keep its upstream shape without a browser engine and
without CSS.

The long-term shape is:

```
src/vs/editor/browser/...   ported upstream UI code (view parts, controllers)
        |
src/tui/...                 TUI host: config, view model bridge, input, status
        |
ui/                         standalone UI library: tree, layout, cell renderer
        |
terminal cells (ANSI)
```

## 2. Decisions

1. **Separate library, outside `src/`.** The UI library is a standalone Zig
   package at the repository root:

   ```
   ui/
     build.zig
     build.zig.zon
     ui.zig              # public root module, re-exports the pieces below
     dom.zig             # Node/Element/Text/Document, tree operations
     style.zig           # Color, Style, Dimension
     layout.zig          # layout pass
     cell.zig            # CellGrid, attributes, color, grapheme interning
     paint.zig           # paint primitives (drawText/drawRect/setCell)
     frame.zig           # double buffer, damage bands, cell diff
     ansi.zig            # ANSI writer / style-diff encoder
     surface.zig         # Document + Frame + viewport + render()
     test/               # library unit tests
   ```

   The package/module name `ui` is provisional and easy to rename. The library
   must not import anything from `src/`.

2. **No CSS and no HTML.** Every node carries a typed `Style` value. Class
   names may be kept as logical identifiers where upstream toggles them, but
   they never select visual rules. `innerHTML` is not implemented.

3. **Direct style fields, not stylesheet lookups.** Colors, alignment,
   visibility, positioning and text attributes are written directly by the code
   that builds the node.

4. **Terminal cells are the unit.** `1` style unit = `1` terminal cell. The
   editor configures `lineHeight = 1`, `charWidth = 1`,
   `typicalHalfwidthCharacterWidth = 1`, `spaceWidth = 1`; fractional layout
   results are rounded to whole cells.

5. **The renderer is a double-buffered cell grid with a frame diff.** Painting
   writes cells; presenting compares the frame with the previous one and emits
   only what changed. This follows TermDOM's architecture (see §5) instead of a
   per-cell sink or a full-screen redraw.

6. **The DOM tree is modeled on Lightpanda's Zig DOM.** Parent/child/sibling
   links, the last-child invariant and the explicit factory/ownership model are
   taken from it as a reference. We implement the small subset we need: no JS
   interop, no WebIDL, no shadow DOM, no full HTML element zoo, no HTML parser
   (see §4).

7. **Terminal first, TUI integration stays in `src/tui/`.** Portable editor
   logic stays under `src/vs/...`. A future native/GUI backend can reuse the
   tree/layout and provide another renderer; it is not designed now.

8. **POC before the full port.** The first integration is a read-only
   text + gutter preview. The existing editable TUI remains the default until
   the ported view stack replaces it.

9. **Editing is not regressed.** During the POC and the first view-stack
   milestone, `src/tui/editor.zig` keeps the model/command/input path; only
   painting moves to the library/view stack.

## 3. Prior art

| Project | What it is | Takeaway |
|---|---|---|
| [TermDOM](https://github.com/bikeshaving/termdom) (TS, MIT) | DOM + CSS + flex/grid in terminal cells; runs CodeMirror | The renderer is the closest match: cell grid, frame diff, ANSI encoder, scroll shift. See §5. |
| [Lightpanda](https://github.com/lightpanda-io/browser) (Zig, AGPL-3.0) | Zig headless browser with a DOM/CSS/layout stack | The Zig DOM tree, linking and ownership patterns are worth referencing. Reference only, no code copied. See §4. |
| [rdom](https://github.com/miskun/rdom) (Rust, MIT) | "A DOM for terminal applications": arena nodes, CSS cascade, flex/grid, events, ranges, hit testing | Most complete reference for the DOM contract; its feature list shows why this design drops CSS. |
| [RTXUI](https://github.com/ArthurSonzogni/RTXUI) (C++, MIT) | HTML + real CSS browser engine for the terminal | Maximum-fidelity approach; confirms a CSS engine is a project of its own. |
| [Textual](https://textual.textualize.io/guide/CSS/) (Python) | DOM + TCSS + widgets + compositor | Mature architecture reference for a retained tree and compositor. |
| [OpenTUI](https://github.com/anomalyco/opentui) (Zig, MIT) | Retained scene + Yoga layout + cell framebuffer + ANSI diffing | Closest Zig implementation of the rendering half, but a flexbox scene with no DOM measurement/events; not a drop-in. |
| [FTXUI](https://github.com/ArthurSonzogni/FTXUI) (C++) | Element tree with direct decorators/styles | Closest to the direct-style node model chosen here. |
| [iocraft](https://github.com/ccbrown/iocraft) (Rust) | Declarative element tree + taffy flexbox | Alternative declarative model. |
| [Consolonia](https://github.com/tomlm/Consolonia) (.NET) | Avalonia visual tree rendered to a console | Precedent for a UI tree over a terminal backend. |

Decision: build the small library in-repo. Follow TermDOM's rendering process,
borrow Lightpanda's tree/linking invariants, and keep our own direct styles and
absolute editor layout. Do not add a dependency for the POC.

License note: TermDOM is MIT; we reimplement its ideas in Zig and attribute it.
Lightpanda is **AGPL-3.0**; it is used only as an architectural reference and no
code, tables or comments are copied.

## 4. DOM tree

### 4.1 What we borrow from Lightpanda

Reference files:
[`Node.zig`](https://github.com/lightpanda-io/browser/blob/main/src/browser/webapi/Node.zig),
[`Element.zig`](https://github.com/lightpanda-io/browser/blob/main/src/browser/webapi/Element.zig),
[`Document.zig`](https://github.com/lightpanda-io/browser/blob/main/src/browser/webapi/Document.zig),
[`Factory.zig`](https://github.com/lightpanda-io/browser/blob/main/src/browser/Factory.zig),
[`element/Html.zig`](https://github.com/lightpanda-io/browser/blob/main/src/browser/webapi/element/Html.zig).

- **Node links.** `_parent`, `_first_child`, `_next`, `_prev`, with the trick
  that the first child's `_prev` points at the **last** child. `lastChild` is
  O(1), `nextSibling` is O(1), and a detached node has null links.
- **Splice primitives.** `linkLast`, `linkBefore`, `linkAfter`, `unlink` only
  maintain the link invariants; higher-level insert/remove owns validation,
  notifications and re-parenting. We keep that split.
- **Tree navigation.** `parentNode`, `firstChild`, `lastChild`, `nextSibling`,
  `previousSibling` (special-cased for the first child), a `childrenIterator`,
  and `contains`/root walks.
- **Explicit factory and owner.** Nodes are created by a document-owned factory
  and carry a document reference (`_owner` in Lightpanda; `*Document` here).
  There is no global registry and no GC.
- **Element shape.** An element has a tag/namespace, attributes, classes, and
  (in our case) a direct `Style`; a text node is its own node kind.
- **Validation as a separate step.** DOM's "ensure pre-insert validity" checks
  (cycle, parent type, node type) are separate from the link splicing.

### 4.2 What we deliberately do not take

- The contiguous prototype chain (`EventTarget` -> `Node` -> `Element` ->
  `Html` -> subtype) and its pointer arithmetic. It exists to give JS/WebIDL
  inheritance without stored parent pointers; we have no JS interop, so a
  tagged union is simpler and safer.
- `JsApi` / `js.Bridge`, WebIDL reflection, and the ~100 per-tag `Html.*`
  types. We use one `Element` with a small tag enum and a generic fallback.
- Shadow DOM, slots, custom elements, `ElementInternals`, mutation observers,
  live collections, `Range`/`Selection`, CSSOM/StyleManager, `Frame`/`Page`/
  realm/document registry, HTML parsing.
- The AGPL implementation itself. Only the structural ideas above are used.

### 4.3 Our node model

```zig
pub const Node = struct {
    kind: union(enum) {
        element: Element,
        text: Text,
    },
    parent: ?*Node = null,
    first_child: ?*Node = null, // first_child.?.prev == last child
    next: ?*Node = null,
    prev: ?*Node = null,
    document: *Document,
};

pub const Element = struct {
    tag: Tag, // .div, .span, .document, ...
    attributes: AttributeMap,
    classes: ClassList,
    style: Style,
    rect: Rect = .{}, // layout result
    // measurement/layout cache fields later
};

pub const Text = struct {
    data: []u8, // owned
};
```

- **Tags are enum values**, not Zig types: only the tags the UI actually uses
  (`div`, `span`, ...) plus `.generic`; no per-tag behavior.
- **Attributes** are a small string map with fast paths for `id`, `class` and
  `style`-related use. Classes are a small list; class names remain logical
  identifiers, never style rules.
- **Node identity is the pointer.** No JS wrappers, handles or realms.
- **Navigation** keeps Lightpanda's invariants: `first_child.?.prev` is the last
  child; `next` of the last child is null; detached nodes have null links.
- **Ownership:** a `Document` owns its node allocation. `createElement` /
  `createText` allocate; `remove`/`removeChild` detach; `destroy` (or a
  document-level sweep) recycles a subtree's nodes and strings. `Document.deinit`
  frees everything. Allocators are explicit, no globals.
- **API subset for the POC:** `createElement`, `createText`, `appendChild`,
  `insertBefore`, `removeChild`, `remove`, `firstChild`, `nextSibling`,
  `parentNode`, `root`, `textContent` (read/write), `setAttribute`,
  `getAttribute`, `removeAttribute`, `classList` (`contains/add/remove/toggle`).
- **Not implemented until a port needs them:** `querySelector*`,
  `MutationObserver`, `Range`/`Selection`, `shadowRoot`, forms, HTML parsing,
  and the full DOM exception taxonomy. Checks we do keep: no cycles, a node has
  one parent, a document has one root element.
- **Events:** not in the POC. The node gets a small listener list later
  (capture/bubble as needed by the view parts); no full `Event` class hierarchy
  and no per-type `on*` properties.

## 5. Renderer: CellGrid + frame diff

This is the process we take from TermDOM
([`framebuffer.ts`](https://github.com/bikeshaving/termdom/blob/main/src/internal/framebuffer.ts),
[`painter.ts`](https://github.com/bikeshaving/termdom/blob/main/src/internal/painter.ts),
[`02-rendering.md`](https://github.com/bikeshaving/termdom/blob/main/docs/guides/02-rendering.md)).
We use the fullscreen/alternate-screen subset only: no flow mode, no scrollback
re-anchoring.

### 5.1 Cell grid

One `CellGrid` per frame, as parallel typed arrays:

| plane | type | meaning |
|---|---|---|
| `cluster` | `u32` | `0` = empty; printable ASCII stored directly; other graphemes interned in an append-only table as `0x8000_0000 \| id` |
| `fg` | `u32` | packed RGB; `0` = terminal default |
| `bg` | `u32` | packed RGB; `0` = terminal default |
| `attrs` | `u16` | bold, dim, italic, underline/double, strikethrough, overline, inverse, blink, plus glyph width |
| `border` | `u32` | optional box-drawing edge encoding; empty for the editor POC |

- Wide glyphs set their width and leave the continuation cell `cluster = 0`.
- Grapheme interning keeps a cell 32 bits even for multi-codepoint clusters.
- The POC uses one codepoint per cell and the host's width callback; grapheme
  segmentation and mode-2027 width negotiation are follow-ups.

### 5.2 Painting

`PaintContext` carries the target grid, viewport offset, the active clip rect
(from `overflow: hidden` ancestors), and the damage bands. All writes go through
clipped primitives:

- `drawRect(x, y, w, h, color)` — background fills.
- `drawText(x, y, text, style)` — skips control characters and zero-width
  clusters, stops at the right edge, writes wide glyphs and clears continuation
  cells.
- `setCell(x, y, grapheme, style)` — the single clipped write path.

The document's paint pass walks the tree in DOM order, applies the direct
`Style` values (position, size, clip, colors, attributes), and paints
backgrounds before text. The POC paints all rows; row-level damage bands are
part of the API so the view can later name only changed lines.

### 5.3 Frame diff

`Frame` keeps three grids: `next` (painted), `prev` (last presented), and
`spare` (reused). Presenting:

1. Paint into `next`.
2. Compare `next` with `prev`: `cluster`, `fg`, `bg`, `attrs` style bits and
   `border`.
3. For cells that had content and now have none, seed a blank so the terminal
   erases them instead of keeping the old glyph.
4. Encode the diff as ANSI; swap `next`/`prev`.
5. `spare` is cleared and reused, so steady-state frames allocate no grids.

The POC paints every row each frame; the diff still sends only changed cells.
A later optimization lets the view report damaged rows and copy the rest of
`prev` into `next`.

### 5.4 ANSI encoding

The encoder follows TermDOM's `generateANSI`:

- Walk the diff grid row-major and never move the cursor up or left.
- Choose the cheapest forward cursor move: `\r`, `\n`, CUD, CUF, or CUP.
- Batch printable ASCII into one run; emit non-ASCII and wide glyphs
  individually.
- Emit the minimal SGR diff against the previously emitted cell, with an
  escape-sequence cache keyed by `(fg, bg, attrs, previous attrs)`.
- Reset style at the end of a row that used any.
- The first time a row has content, emit `\r` + erase-to-line-end (`EL`) before
  painting, so a shortened line does not leave a stale tail.
- Wrap each frame in synchronized-output markers (`CSI ?2026h` / `CSI ?2026l`).
- Color depth is configurable (`rgb`, `256`, `ansi`) with the same quantization
  fallback as TermDOM.
- Park the cursor at the end of the frame (at the caret once editing exists).

### 5.5 Scroll shift (design hook, deferred)

Because every editor view line is exactly one terminal row, a viewport scroll is
a whole-row shift. The later optimization mirrors TermDOM's `shiftPrevious`:

- Shift the previous grid's rows and mark the exposed rows damaged.
- Emit `DECSTBM` + `IL`/`DL` so the terminal moves the rows itself, then paint
  only the exposed rows.
- Keep the cost check: only if the shift is cheaper than repainting, and never
  if it would put content into scrollback.

The POC does not implement this, but `Frame` keeps `prev` and the row origin so
it can be added without changing the API.

### 5.6 Caret

TermDOM parks the **real terminal cursor** at the caret for IME and draws
secondary cursors into cells. The POC has no caret. When cursors are ported, the
primary caret should use the hardware cursor (DECSCUSR shape/color where
supported) and secondary cursors should be cell runs; this keeps IME viable.

### 5.7 Width and capability contract

The host passes `measure_width: fn (u21) u2` so the renderer agrees with the
editor's `CursorColumns.nextVisibleColumn` for CJK and emoji. Color depth and
synchronized-output support are `Surface` options; probing the terminal (mode
2027, DECRQSS, cell pixel size) is a later addition. The POC assumes truecolor
and a terminal that accepts synchronized output (both are ignored safely if
not).

## 6. Library API (POC slice)

```zig
const ui = @import("ui");

var surface = try ui.Surface.init(allocator, .{
    .cols = 80,
    .rows = 24,
    .tab_size = 4,
    .color_depth = .rgb,
    .measure_width = measureCodepoint, // fn (u21) u2; wide chars return 2
});
defer surface.deinit();

const doc = surface.document();
const root = try doc.createElement(.div);
try root.setStyle(.{
    .position = .absolute,
    .width = .{ .percent = 100 },
    .height = .{ .percent = 100 },
});
try doc.setRoot(root);

const line = try doc.createElement(.div);
try line.setStyle(.{
    .position = .absolute,
    .top = .{ .cells = 0 },
    .height = .{ .cells = 1 },
});
const run = try doc.createText("pub fn main() void {}");
try run.setStyle(.{ .color = .{ .r = 197, .g = 134, .b = 192 } });
try line.appendChild(run);
try root.appendChild(line);

try surface.render(&writer, .{ .synchronized = true });

const cells = surface.grid(); // read-only CellGrid for tests
```

Public surface for the POC:

- `Surface`: allocator, `Document`, viewport, color depth, tab size, width
  callback, `render(writer, options)`.
- `Document`: root, viewport, tab size, node creation/ownership.
- `Style`: `position` (static/relative/absolute/fixed), `top/right/bottom/left`,
  `width/height` (`auto | cells | percent`), `display`
  (block/inline/inline-block/none), `overflow` (visible/hidden/clip),
  `text_align`, `white_space`, `color`, `background`, `bold`, `italic`,
  `underline`, `strikethrough`, `dim`, `reverse`, `visibility`, `z_index`,
  `translate_x/y`, plus padding/margin placeholders for later widgets.
- Measurement: `offsetWidth`, `offsetHeight`, `getBoundingClientRect`,
  `getClientArea`; `Range.getClientRects` is a follow-up (needed by
  cursors/selections, not by the POC).
- Layout: absolute positioning against the nearest positioned ancestor; inline
  text flow; shrink-to-fit auto sizes; percentage sizes; `text_align`;
  clipping; `display:none`; visibility. No flexbox/grid in the POC.
- Rendering: `Surface.render` = layout -> paint into the next grid -> diff against
  the previous grid -> ANSI to the writer. Tests read `Surface.grid()` instead of
  parsing ANSI.
- Ownership: the document owns all nodes; text/attribute buffers are
  document-allocated; `remove()` detaches and queues recycle; `Document.deinit`
  frees everything. The allocator is always explicit, no globals.
- No events/scheduler in the POC. They are added with the view parts; the
  library contract will be extended, not replaced.

Library constraints:

- Zero imports from `src/`.
- No CSS parser, no HTML parser, no hidden globals.
- Unit tests run with `std.testing.allocator`; the library exposes its own
  `zig build test`.

## 7. Editor integration (POC)

- Root `build.zig.zon` adds the library as a path dependency
  (`.ui = .{ .path = "ui" }`); the TUI executable and tests import the `ui`
  module. `ui/build.zig` exposes the `ui` module and its tests.
- The editor-specific token-to-style work stays in the editor:
  - `src/vs/editor/common/viewLayout/viewLineRenderer.zig` gets a **partial
    port** for the POC: `RenderLineInput`-style input, token splitting, tab
    expansion, and a flat `RenderedLine` of parts
    `{ text, class_name, inline_style, metadata }` instead of HTML.
  - `src/tui/theme.zig` / a small adapter resolves token metadata to
    `ui.Style` colors and attributes (using the existing token color palette).
- `src/tui/preview.zig` builds the POC view:
  - Uses the existing `Editor`, `ProjectedViewModelLines`, and `viewLineData`
    to iterate visible view lines.
  - Creates a gutter column (right-aligned line numbers) and a text column; one
    line element per view line, one text node per rendered part.
  - Builds the whole screen (editor area plus the status row) as one tree, so a
    single `Surface.render` diff covers it.
- `src/tui/app.zig` gains a `--preview` flag (or a separate
  `zig build preview` run step): read-only preview of the top of the file,
  `Ctrl-Q` quits, resize re-renders. Default TUI behavior is unchanged.
- Gutter width follows the existing `gutterWidthFor` logic; line numbers are
  right-aligned with `text_align = .right`.
- Long lines are clipped (no horizontal scrolling); wrapping uses the existing
  projection/wrapping column.
- The existing `src/tui/screen.zig`/its ANSI path stay for the old editor until
  the preview replaces the painter.

## 8. POC acceptance

- `zig build` and `zig build test --summary all` pass with no leaks.
- A preview of a fixture file at 80x24 shows: text, syntax colors,
  right-aligned line numbers, empty lines, tabs, CJK/emoji wide characters,
  wrapped lines, long-line clipping, gutters for lines past 9 and 99.
- Snapshot tests in `src/tui/` assert text rows and per-cell styles for ASCII,
  CJK, tabs, wrapping and long-line clipping.
- Library unit tests cover: tree linking/invariants, absolute/percent/auto
  layout, clipping, right alignment, wide characters, tabs, cell painting,
  frame diff (changed cell, vanished cell, unchanged frame), first-row erase and
  a small ANSI golden.
- No cursor, selection, scrollbar, mouse, view model or view-part ports in this
  POC.

## 9. Roadmap after the POC

1. Full `viewLineRenderer` port + `CharacterMapping` and the upstream
   `viewLineRenderer.test.ts` cases (canonical part comparison).
2. `ViewLayout`/`Scrollable` + `IViewModel`/`IViewLayout` interfaces + a
   temporary `TuiViewModel` adapter + view-event bridge.
3. `viewLayer`, `viewPart`, `renderingContext`, `viewOverlays`,
   `viewLines`/`viewLine`, margin/lineNumbers/currentLineHighlight/selections/
   viewCursors; `TerminalView` orchestrator; replace `render.zig`.
4. Scroll, scrollbar, mouse input, cursor blink/timers; row damage bands and
   the `DECSTBM` + `IL`/`DL` scroll shift; hardware-cursor caret.
5. Replace the adapter with a port of `viewModelImpl.ts` +
   `CursorsController`; port edit context/controllers; then widgets and
   contributions (find, hover, suggest, quick pick).

## 10. Testing strategy

- Library: unit tests with `std.testing.allocator`, run by `ui/build.zig`; also
  linked into the root test build so `zig build test` covers them.
- Renderer tests compare cell grids (`cluster`/`fg`/`bg`/`attrs`) and a few
  full ANSI strings; they do not parse ANSI to assert behavior.
- Editor POC: snapshot tests at 80x24/120x40/200x60 in `src/tui/`; no terminal
  required.
- Upstream tests: ported where the behavior is portable (`viewLineRenderer`,
  layout helpers); adapted only where HTML/string output becomes structured
  parts.
- No source-tree test duplication: library tests live under `ui/test/`; editor
  tests mirror upstream paths under `src/vs/.../test/...`.

## 11. Deferred / explicit limitations

- No CSS, HTML, `innerHTML`, flexbox/grid, transitions, opacity compositing,
  borders/radii.
- No RTL/bidi visual reordering, grapheme segmentation, combining-mark cell
  composition, ligatures, or terminal width negotiation (mode 2027) in the POC.
- No events, scheduler, ranges, focus, mouse in the POC.
- No cursors, selections, scrollbar/viewport scrolling, decorations, minimap,
  glyph margin, view zones, widgets, IME.
- No row damage bands or terminal scroll shift in the POC; full grid diff only.
- No JS interop, WebIDL, shadow DOM, custom elements, HTML parsing, or the full
  DOM API; only the node/tree/attribute subset above.
- The `ui/` name, module name and exact style field set are provisional;
  renaming before the first commit is cheap.

## 12. Open questions

- Final library name/location (`ui/` is a placeholder).
- Whether the same tree should later get a native/window backend or remain
  terminal-only.
- Whether to enable mode 2027 / terminal width negotiation once the renderer
  handles grapheme clusters.
