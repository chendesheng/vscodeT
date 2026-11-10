# Terminal UI architecture: a DOM-like tree rendered to terminal cells

Status: proposed design.

## 1. Context

This repository is a Zig 0.17 port of VS Code editor internals. The model,
commands and contributions are ported; `src/tui/` contains the terminal
frontend. The editor is now rendered through the standalone `ui` library
(`src/tui/view.zig`); the read-only `--preview` mode shares the same renderer.
The next step is to port the browser-facing editor UI (`viewParts`, widgets,
and the contributions in `src/vs/editor/contrib`) while keeping the code close
to upstream.

The obstacle is that upstream browser code is written against a browser DOM and
CSS. This design introduces a small, standalone, DOM-like UI library that
provides the node tree, direct styles, layout and terminal rendering, so the
ported editor code can keep its upstream shape without a browser engine and
without CSS.

The long-term shape is:

```
src/vs/editor/browser/...   ported upstream UI code (view parts, controllers)
        |
src/tui/...                 TUI host: config, view model bridge, raw mode, status
        |
ui/                         standalone UI library: tree, events, layout, renderer
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
     box.zig             # derived layout box tree + node→box mapping
     layout.zig          # formatting contexts over the box tree
     paint.zig           # paints the box tree
     cell.zig            # CellGrid, attributes, color, grapheme interning
     frame.zig           # double buffer, damage bands, cell diff
     ansi.zig            # ANSI writer / style-diff encoder
     surface.zig         # Document + Frame + viewport + render()
     tests.zig           # library unit tests
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
   only what changed. This follows TermDOM's architecture (see §6) instead of a
   per-cell sink or a full-screen redraw.

6. **The DOM tree is modeled on Lightpanda's Zig DOM.** Parent/child/sibling
   links, the last-child invariant and the explicit factory/ownership model are
   taken from it as a reference. We implement the small subset we need: no JS
   interop, no WebIDL, no shadow DOM, no full HTML element zoo, no HTML parser
   (see §4).

7. **A separate layout tree.** Layout runs on a derived `LayoutBox` tree
   (viewport root, principal boxes, anonymous inline/flex boxes, text boxes),
   not on DOM nodes. It follows WebKit's `Layout::Box` tree and TermDOM's box
   derivation; sizing is in cells (see §5).

8. **Terminal first, TUI integration stays in `src/tui/`.** Portable editor
   logic stays under `src/vs/...`. A future native/GUI backend can reuse the
   tree/layout and provide another renderer; it is not designed now.

9. **POC before the full port.** The first integration is a read-only
   text + gutter preview. The existing editable TUI remains the default until
   the ported view stack replaces it.

10. **Editing is not regressed.** During the POC and the first view-stack
   milestone, `src/tui/editor.zig` keeps the model/command/input path; only
   painting moves to the library/view stack.

## 3. Prior art

| Project | What it is | Takeaway |
|---|---|---|
| [TermDOM](https://github.com/bikeshaving/termdom) (TS, MIT) | DOM + CSS + flex/grid in terminal cells; runs CodeMirror | Closest renderer: cell grid, frame diff, ANSI encoder, scroll shift. Also a derived box tree plus a `LayoutNode` solver. See §6. |
| [WebKit](https://github.com/WebKit/WebKit) (C++, LGPL-2.1/BSD) | Real browser: render tree plus a `Layout::Box` layout tree with block/flex/grid/inline formatting contexts | Reference for the separate layout tree and layout pass shape. No code copied. See §5. |
| [Lightpanda](https://github.com/lightpanda-io/browser) (Zig, AGPL-3.0) | Zig headless browser; DOM and computed styles, but only a faux width/position model for geometry | The Zig DOM tree, linking and ownership patterns are worth referencing. It has no layout tree or layout engine. Reference only, no code copied. See §4. |
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
    listeners: []Listener = &.{}, // arena-owned, registration order
};

pub const Element = struct {
    tag: Tag, // .div, .span, .document, ...
    attributes: AttributeMap,
    classes: ClassList,
    style: Style,
    rect: Rect = .{}, // layout result
    focusable: bool = false,
    tab_index: i32 = 0, // positive first, then 0; negative is Tab-skipped
    // measurement/layout cache fields later
};

// Document also holds `active_element: ?*Node`, exposed as `activeElement()`
// with the root as the body-like fallback.

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
  `Range`/`Selection`, `shadowRoot`, forms, HTML parsing, and the full DOM
  exception taxonomy. Checks we do keep: no cycles, a node has one parent, a
  document has one root element.
- **Events and focus:** see §4.4. A node has a listener list; key events run
  capture/target/bubble; `Document.activeElement` and `focus`/`blur` drive
  keyboard delivery. There is no `Event` class hierarchy and no per-type `on*`
  properties.

### 4.4 Events and focus

Event delivery is DOM-shaped but typed, and follows the same split as
Lightpanda's `EventTarget`/`EventManager` and TermDOM's browser layer:

- Every node has a listener list (`addEventListener` / `removeEventListener`).
  A listener is a struct of optional callbacks (`key_down`, `focus`, `blur`,
  `focus_in`, `focus_out`) plus an optional context. There is no `Event` base
  class and no per-type `on*` property.
- Key events run capture (root → parent), target, then bubble (parent → root).
  `stopPropagation`, `stopImmediatePropagation` and `preventDefault` have the
  usual meanings. Only `key_down` exists: a terminal reports bytes, not releases
  or repeats. There is no `keyup`/`keypress`.
- `Document.activeElement` is the focused element, falling back to the root when
  nothing is focused (the browser's `body` fallback), so a root listener still
  receives keys before any widget takes focus.
- `Element.focusable` opts a node into focus. `Element.tab_index` follows HTML:
  positive values come first in ascending order, `0` keeps tree order, and
  negative values are programmatically focusable but skipped by Tab. Tab is the
  default action of a non-prevented key event. Focus requires a connected,
  rendered (no `display: none` ancestor), visible element.
- A focus move dispatches `blur` then `focusout` on the old element and `focus`
  then `focusin` on the new one, with `related_target` pointing at the other
  element. `focus`/`blur` do not bubble; `focusin`/`focusout` do. Removing a
  focused subtree clears `activeElement` silently, as the references do.
- `ui/input.zig` decodes terminal bytes into key events: printable runs,
  control bytes, cursor/editing keys (including modifier parameters), and
  bracketed paste. Text runs borrow the input buffer. Extended keyboard
  protocols (CSI u, kitty), key release/repeat, mouse and terminal focus
  reporting are not decoded yet.

## 5. Layout tree

Layout does not walk the DOM. A derived box tree is built from the DOM and the
direct `Style` values; the solver and painter operate on it. WebKit and TermDOM
separate the same way: WebKit keeps a `RenderObject` render tree and a
`Layout::Box` layout tree, and TermDOM keeps a box derivation over the DOM plus a
`LayoutNode` solver tree.

We collapse the two into one because our DOM nodes already carry the styles and
are the paint scene; there is no separate style/paint/compositing tree:

```
DOM + Style (dom.zig)
   ↓ mutation notifications
BoxTree (box.zig)
   ↓ layoutTree
formatting contexts (layout.zig): block, absolute, flex (next)
   ↓
paint (paint.zig) + geometry copied back to DOM rects
```

### 5.1 Box kinds

`ui/box.zig` defines `LayoutBox`:

| kind | owner | meaning |
|---|---|---|
| `initial_containing_block` | null | viewport root; WebKit's `Layout::InitialContainingBlock` |
| `element` | `*Node` | principal box for an element |
| `anonymous_inline` | null | contiguous inline/text run in a block container |
| `anonymous_flex_item` | null | bare text run in a flex container |
| `text` | `*Node` | text content box; WebKit's `Layout::InlineTextBox` |

Each box has `parent`, `children`, `style`, `needs_layout`, and three rects:
`rect` (border box), `padding_rect` (border box inset by the border) and
`content_rect` (padding box inset by the padding). Text boxes also hold their
content. `node_boxes` maps DOM nodes to principal/text boxes. `display: none`
nodes have no box; `display: contents` elements have no box of their own, and
their children are promoted into the parent's formatting context.

### 5.2 Build and solve

`BoxTree.rebuild(doc)` resets the tree arena and derives the boxes:

- the viewport root, then the document element as its child;
- a principal box per element that generates one;
- contiguous inline content wrapped in an `anonymous_inline` box;
- under a flex container, element children are flex items and bare text runs
  become `anonymous_flex_item` boxes;
- `display: none` is skipped; `display: contents` is promoted.

`layoutTree(tree, doc)` sets the viewport, solves the box tree, and copies the
rects back to DOM `Element.rect`/`Text.rect` for the measurement boundary. The
current solver handles block flow, absolute positioning, the
margin/padding/border box model and one line of inline text per anonymous inline
box. Flex is the next formatting context; the box tree
already produces its items.

The box tree owns invalidation. DOM mutation APIs notify the attached
`MutationObserver`. Structural, style and text changes all set `needs_rebuild`
(and `needs_layout`): boxes copy the direct `Style` and text data when they are
built, and a `display` change can alter the box shape, so the POC rebuilds the
derived tree from the DOM before solving. There is no document-level dirty flag
or revision. Per-box `needs_layout` is kept for the future incremental pass,
which can update copied values in place instead of rebuilding. Direct writes to
public `Element.style`/`Text.style` fields bypass the observer; use
`Node.setStyle`.

### 5.3 Why the tree

The separate tree is what makes the following representable without polluting
the DOM:

- anonymous boxes (inline runs, future table wrappers, bare flex text);
- a text box whose geometry is not stored on the text node;
- `display: contents`;
- a formatting-context root per block/flex container;
- one geometry boundary for `getBoundingClientRect` and ranges.

WebKit's LayoutFormattingContext is the reference for this shape:
`layout/layouttree` (`Layout::Box`, `ElementBox`, `InlineTextBox`,
`InitialContainingBlock`), `layout/formattingContexts/{block,flex,grid,inline}`,
and `layout/integration` (`BoxTreeUpdater`, `layoutWithFormattingContextForBox`).
Lightpanda is not: it has no layout tree, only a faux width/position model
(`layout.zig`, and a `calculateDocumentPosition` that counts preceding nodes at
5px each) plus a text-flow renderer for screenshots. TermDOM's derived `Box`
list and `LayoutNode` solver are the closer non-browser reference.

## 6. Renderer: CellGrid + frame diff

This is the process we take from TermDOM
([`framebuffer.ts`](https://github.com/bikeshaving/termdom/blob/main/src/internal/framebuffer.ts),
[`painter.ts`](https://github.com/bikeshaving/termdom/blob/main/src/internal/painter.ts),
[`02-rendering.md`](https://github.com/bikeshaving/termdom/blob/main/docs/guides/02-rendering.md)).
We use the fullscreen/alternate-screen subset only: no flow mode, no scrollback
re-anchoring.

### 6.1 Cell grid

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

### 6.2 Painting

The paint pass carries the target grid, the viewport, and the active clip rect
(from `overflow: hidden` ancestors). All writes go through clipped primitives:

- `drawRect(x, y, w, h, color)` — background fills.
- `drawText(x, y, text, style)` — skips control characters and zero-width
  clusters, stops at the right edge, writes wide glyphs and clears continuation
  cells.
- `setCell(x, y, grapheme, style)` — the single clipped write path.

The box tree's paint pass walks boxes in order, applies the direct `Style`
values (position, size, clip, colors, attributes), and paints backgrounds before
text. Backgrounds are not inherited: a text run with no background of its own
keeps the background already in the cell, following TermDOM's `setCell` rule, so
a transparent label over a filled panel shows the panel instead of punching a
hole to the root color. Borders use the same rule. The POC paints all rows;
row-level damage bands are part of the API so the view can later name only
changed lines.

### 6.3 Frame diff

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

### 6.4 ANSI encoding

The encoder follows TermDOM's `generateANSI`:

- Walk the diff grid row-major and never move the cursor up or left.
- Choose the cheapest forward cursor move: `\r`, `\n`, CUD, CUF, or CUP.
- Batch printable ASCII into one run; emit non-ASCII and wide glyphs
  individually.
- Emit a style reset plus the needed SGR attributes when the style changes
  (the escape cache and truly minimal diffs are a later optimization).
- Reset style at the end of a row that used any.
- The first time a row has content, emit `\r` + erase-to-line-end (`EL`) before
  painting, so a shortened line does not leave a stale tail.
- Wrap each frame in synchronized-output markers (`CSI ?2026h` / `CSI ?2026l`).
- Color depth is configurable (`rgb`, `256`, `ansi`) with the same quantization
  fallback as TermDOM.
- Park the cursor at the end of the frame (at the caret once editing exists).

### 6.5 Scroll shift (design hook, deferred)

Because every editor view line is exactly one terminal row, a viewport scroll is
a whole-row shift. The later optimization mirrors TermDOM's `shiftPrevious`:

- Shift the previous grid's rows and mark the exposed rows damaged.
- Emit `DECSTBM` + `IL`/`DL` so the terminal moves the rows itself, then paint
  only the exposed rows.
- Keep the cost check: only if the shift is cheaper than repainting, and never
  if it would put content into scrollback.

The POC does not implement this, but `Frame` keeps `prev` and the row origin so
it can be added without changing the API.

### 6.6 Caret

TermDOM parks the **real terminal cursor** at the caret for IME and draws
secondary cursors into cells. The POC has no caret. When cursors are ported, the
primary caret should use the hardware cursor (DECSCUSR shape/color where
supported) and secondary cursors should be cell runs; this keeps IME viable.

### 6.7 Width and capability contract

The host passes `measure_width: fn (u21) u2` so the renderer agrees with the
editor's `CursorColumns.nextVisibleColumn` for CJK and emoji. Color depth and
synchronized-output support are `Surface` options; probing the terminal (mode
2027, DECRQSS, cell pixel size) is a later addition. The POC assumes truecolor
and a terminal that accepts synchronized output (both are ignored safely if
not).

## 7. Library API (POC slice)

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
- `Document`: root, viewport, tab size, node creation/ownership,
  `activeElement`, `focus`, `blur`, `moveFocus`, `dispatchKey`.
- `Node`: tree navigation/mutation, direct styles, `addEventListener` /
  `removeEventListener`, `focus`, `blur`, `isFocusable`.
- `Style`: `position` (static/relative/absolute/fixed), `top/right/bottom/left`,
  `width/height` (`auto | cells | percent`), `display`
  (block/inline/inline-block/none), `overflow` (visible/hidden/clip),
  `text_align`, `white_space`, `color`, `background`, `bold`, `italic`,
  `underline`, `strikethrough`, `dim`, `reverse`, `visibility`, `z_index`,
  `translate_x/y`, plus `margin`, `padding`, `border`, `border_style` and
  `border_color`. `width`/`height` are content-box sizes; padding, border and
  margin expand outward.
- Measurement: not implemented yet; tests read `Surface.grid()` directly. The
  `getBoundingClientRect`/`offsetWidth` boundary comes with the view parts.
- Layout: absolute positioning against the nearest positioned ancestor using
  `left`/`top`, with the margin box anchored there (right/bottom anchoring and
  auto margins are not implemented); inline text flow; percentage sizes
  resolved against the containing content box; `text_align`; clipping to the
  padding box; `display:none`; backgrounds paint the border box. Auto width
  fills the containing block. No flexbox/grid or margin collapsing in the POC.
- Rendering: `Surface.render` = layout -> paint into the next grid -> diff against
  the previous grid -> ANSI to the writer. Tests read `Surface.grid()` instead of
  parsing ANSI.
- Ownership: the document owns all nodes; text/attribute buffers are
  document-allocated; `remove()` detaches and queues recycle; `Document.deinit`
  frees everything. The allocator is always explicit, no globals.
- Events: `ui/event.zig` (keys, focus, listener dispatch) and
  `ui/input.zig` (terminal byte decoder). The preview also handles Up/Down,
  PageUp/PageDown, Home and End for scrolling and Ctrl-Q to quit.

Library constraints:

- Zero imports from `src/`.
- No CSS parser, no HTML parser, no hidden globals.
- Unit tests run with `std.testing.allocator`; the library exposes its own
  `zig build test`.

## 8. Editor integration (POC)

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
- `src/tui/view.zig` builds the editor view on the library:
  - Uses the existing `Editor`, `ProjectedViewModelLines`, and `viewLineData`
    to iterate visible view lines.
  - Creates a gutter column (right-aligned line numbers) and a text column; one
    line element per view line, one text node per rendered part.
  - Paints selections as inverted cells and the cursor line with a background;
    the hardware cursor is moved to the caret cell after layout.
  - Builds the whole screen (editor area plus the status row) as one tree, so a
    single `Surface.render` diff covers it. `Document.clear` rebuilds the tree
    between frames while keeping the previous grid for the diff.
- `src/tui/preview.zig` remains the read-only `--preview` variant, adding
  Up/Down and PageUp/PageDown scrolling.
- Overlay widgets use the terminal adaptation of upstream `IOverlayWidget`
  in `src/vs/editor/browser/editorBrowser.zig`. A widget reports its size in
  cells, builds a `ui` subtree each frame and is anchored to a corner
  (`top_right_corner`, `bottom_right_corner`, `top_center`); the view restores
  focus after every rebuild. `View.dispatchKey` forwards decoded keys through
  the widget document first, so a focused widget owns the keyboard.
- `ui/inputbox.zig` is the terminal single-line input: UTF-8 buffer, byte
  caret, block caret cell, placeholder, editing keys and `on_change` /
  `on_enter` / `on_escape` callbacks. It is the base for the find bar.
- `src/vs/editor/contrib/find/browser/replacePattern.zig` and
  `src/vs/base/common/search.zig` port the replace-string parser and
  case-preserving replacement, with the upstream test cases.
- The find contribution is ported end-to-end on this layer: `findState.zig`
  (state/events/overrides), `findDecorations.zig` (ranges instead of model
  decorations), `findModel.zig` (incremental research, next/previous with wrap,
  replace, replace all, select all matches), `replaceAllCommand.zig` and
  `findWidget.zig` (the terminal bar). `findController.zig` owns the state,
  model and widget and forwards decoration ranges to the view. The app treats
  Ctrl-F/Ctrl-R as global find keys, and `View.dispatchKey` routes everything
  else to the focused widget first.
- Key map for the terminal find bar (TUI-specific, documented in `README.md`):
  Enter/Shift-Enter next/previous, Tab switches inputs, Escape closes,
  Ctrl-R toggles the replace row (Ctrl-H is Backspace in a terminal),
  Alt-C/W/R options, Alt-P preserve case, Alt-L find in selection,
  Alt-Enter select all matches, Ctrl-Alt-Enter replace all.
- Model fixes the port needed: `TextModel.findNextMatch` no longer runs a
  second discarded search (which leaked its capture array), and the
  word-separator cache owns its keys instead of borrowing editor slices.
- `src/tui/app.zig` dispatches keys to the editor, refreshes the view and syncs
  the hardware cursor after each frame; resize recreates the surface.
- Gutter width follows the existing `gutterWidthFor` logic; line numbers are
  right-aligned with `text_align = .right`.
- Long lines are clipped (no horizontal scrolling); wrapping uses the existing
  projection/wrapping column.
- The old `src/tui/screen.zig`/`render.zig` path is gone.

## 9. POC acceptance

- `zig build` and `zig build test --summary all` pass with no leaks.
- A preview of a fixture file at 80x24 shows: text, syntax colors,
  right-aligned line numbers, empty lines, tabs, CJK/emoji wide characters,
  wrapped lines, long-line clipping, gutters for lines past 9 and 99.
- Snapshot tests in `src/tui/` assert text rows and per-cell styles for ASCII,
  CJK, tabs, wrapping and long-line clipping; selection inversion; the hardware
  cursor cell; an unchanged refresh writing no bytes; plus keyboard scrolling and
  Ctrl-Q through the library dispatcher.
- Library unit tests cover: tree linking/invariants, box-tree derivation
  (viewport root, principal/text boxes, anonymous inline/flex items,
  `display: contents`/`none`, mutation invalidation), absolute/percent/auto layout,
  clipping, right alignment, wide characters, tabs, cell painting, frame diff
  (changed cell, vanished cell, unchanged frame), first-row erase and a small
  ANSI golden. Event tests cover capture/target/bubble order, propagation and
  default prevention, focus event order and `related_target`, tabindex
  traversal, hidden/focusability checks, silent focus clearing on removal, and
  the terminal decoder (control keys, modifiers, paste, lone Escape).
- No cursor, selection, scrollbar, mouse, view model or view-part ports in this
  POC.

## 10. Roadmap after the POC

1. Full `viewLineRenderer` port + `CharacterMapping` and the upstream
   `viewLineRenderer.test.ts` cases (canonical part comparison).
2. Flex formatting context over the box tree: direction, wrap, grow/shrink/basis,
   justify/align, gap, order and auto margins; then an anonymous-flex-item pass.
3. `ViewLayout`/`Scrollable` + `IViewModel`/`IViewLayout` interfaces + a
   temporary `TuiViewModel` adapter + view-event bridge.
4. `viewLayer`, `viewPart`, `renderingContext`, `viewOverlays`,
   `viewLines`/`viewLine`, margin/lineNumbers/currentLineHighlight/selections/
   viewCursors; `TerminalView` orchestrator. The terminal editor view
   (`src/tui/view.zig`) already covers gutter, tokens, selection, cursor and
   status; the split into upstream-shaped view parts is still open.
5. Scrollable viewport/scrollbar, mouse input, cursor blink/timers; row
   damage bands and
   the `DECSTBM` + `IL`/`DL` scroll shift; hardware-cursor caret.
6. Replace the adapter with a port of `viewModelImpl.ts` +
   `CursorsController`; port edit context/controllers; then widgets and
   contributions (find, hover, suggest, quick pick).

## 11. Testing strategy

- Library: unit tests with `std.testing.allocator`, run by `ui/build.zig`; also
  linked into the root test build so `zig build test` covers them.
- Renderer tests compare cell grids (`cluster`/`fg`/`bg`/`attrs`) and a few
  full ANSI strings; they do not parse ANSI to assert behavior.
- Editor POC: snapshot tests at 80x24/120x40/200x60 in `src/tui/`; no terminal
  required.
- Upstream tests: ported where the behavior is portable (`viewLineRenderer`,
  layout helpers); adapted only where HTML/string output becomes structured
  parts.
- No source-tree test duplication: library tests live under `ui/tests.zig`; editor
  tests mirror upstream paths under `src/vs/.../test/...`.

## 12. Deferred / explicit limitations

- No CSS, HTML, `innerHTML`, flexbox/grid, transitions, opacity compositing,
  borders/radii.
- No RTL/bidi visual reordering, grapheme segmentation, combining-mark cell
  composition, ligatures, or terminal width negotiation (mode 2027) in the POC.
- No mouse, IME, scheduler or `Range`/`Selection` in the POC. Keyboard events
  and focus are in; key release/repeat, CSI u/kitty reports and terminal focus
  reporting are not. Focus events have no capture pass and there are no
  `:focus`-style selectors; focus is explicit state plus listeners.
- No cursors, selections, scrollbar or scrollable viewport (the preview
  page-scrolls by rebuilding), minimap, glyph margin, view zones, IME. The
  editor view paints the current line, selections, hardware cursor and find
  ranges; overlay widget hosting and the find bar are in, other contributions
  are not.
- No row damage bands or terminal scroll shift in the POC; full grid diff only.
- No margin collapsing, auto margins, right/bottom anchoring, multi-cell/rounded
  border styles, background-clip or z-index paint ordering yet. Borders are
  repeated single-line box-drawing glyphs.
- No flex/grid formatting contexts, table boxes or incremental box reuse yet;
  the box tree is rebuilt from the DOM when mutations invalidate it, then solved whole.
- No JS interop, WebIDL, shadow DOM, custom elements, HTML parsing, or the full
  DOM API; only the node/tree/attribute subset above.
- The `ui/` name, module name and exact style field set are provisional;
  renaming before the first commit is cheap.

## 13. Open questions

- Final library name/location (`ui/` is a placeholder).
- Whether the same tree should later get a native/window backend or remain
  terminal-only.
- Whether to enable mode 2027 / terminal width negotiation once the renderer
  handles grapheme clusters.
