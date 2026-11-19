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
  A listener is a struct of optional callbacks (`key_down`, `mouse_down`,
  `mouse_move`, `mouse_up`, `click`, `wheel`, `focus`, `blur`, `focus_in`,
  `focus_out`) plus an optional context. There is no `Event` base class and no
  per-type `on*` property.
- Key and mouse events run capture (root → parent), target, then bubble
  (parent → root). `stopPropagation`, `stopImmediatePropagation` and
  `preventDefault` have the usual meanings. Only `key_down` exists: a terminal
  reports bytes, not releases or repeats. There is no `keyup`/`keypress`.
- `Document.activeElement` is the focused element, falling back to the root when
  nothing is focused (the browser's `body` fallback), so a root listener still
  receives keys before any widget takes focus.
- Mouse events carry zero-based terminal-cell coordinates. `Surface.elementFromPoint`
  solves pending layout, walks the box tree in reverse paint order and clips to
  `overflow: hidden`/`clip`; a text hit reports its parent element, like the DOM
  API. A non-canceled press focuses the nearest focusable ancestor, or blurs.
  Click synthesis, drag state and the wheel's effect stay in the host, as
  TermDOM keeps them in `Input`: the TUI view tracks the press cell, drags a
  selection, clicks the press/release common ancestor, and scrolls three view
  lines per notch. Motion is the all-motion report of mode 1003: button-held
  motion drives drags, and idle motion lets widgets derive their hover state
  from the hit-tested target. There is no CSS `:hover` and no implicit
  enter/leave synthesis in the library; hover is host/widget state.
- `Element.focusable` opts a node into focus. `Element.tab_index` follows HTML:
  positive values come first in ascending order, `0` keeps tree order, and
  negative values are programmatically focusable but skipped by Tab. Tab is the
  default action of a non-prevented key event. Focus requires a connected,
  rendered (no `display: none` ancestor), visible element.
- A focus move dispatches `blur` then `focusout` on the old element and `focus`
  then `focusin` on the new one, with `related_target` pointing at the other
  element. `focus`/`blur` do not bubble; `focusin`/`focusout` do. Removing a
  focused subtree clears `activeElement` silently, as the references do.
- `ui/input.zig` decodes terminal bytes into key and mouse events: printable
  runs, control bytes, cursor/editing keys (including modifier parameters),
  bracketed paste, and SGR mouse reports (`CSI < b ; x ; y M/m`). Text runs
  borrow the input buffer. Extended keyboard protocols (CSI u, kitty), key
  release/repeat, legacy X10 mouse reports and terminal focus reporting are not
  decoded yet.

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
formatting contexts (layout.zig): block, inline, flex, absolute
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
solver is a two-pass whole-tree layout: in-flow block, inline and flex boxes are
solved first, then every out-of-flow box is placed once its containing block has
final geometry.

The block pass stacks children, supports horizontal auto margins, and derives
auto content height from the children. Inline flow is a line-breaking pass:
`ui/text_layout.zig` collects text and atomic inline leaves, renders CSS white
space, finds UAX #14 breaks (`ui/linebreak.zig`), builds line boxes and writes
line fragments back to the text boxes. Non-atomic `display: inline_` boxes are
flattened into start/end edges and their text joins the outer run; their border
boxes fragment per line. `inline-block`/`inline-flex` boxes remain atomic inline
items and lay out their own content. The flex pass follows css-flexbox-1 §9 and TermDOM's `layoutsolver` shape:
it resolves a flex basis per item (border-box main size), breaks lines for a
definite main axis, runs the grow/shrink freeze loop, measures item cross sizes,
computes line and container sizes, and positions items with `justify-content`,
`align-content`, `align-items`/`align-self`, gaps and auto margins. Reverse
directions mirror margin boxes, and `wrap-reverse` mirrors lines. Items are
re-laid at their final origins so descendants and absolute children get final
absolute coordinates. `order` is applied once by stable-sorting the flex
container's derived children, so layout, paint order and hit testing agree.

The solver uses a per-solve scratch arena on the box tree for flex items, lines,
processed text and fragments; `layoutTree` is therefore fallible. Fragments stay
valid through paint and hit testing until the next solve. `min_width` and
`max_width` clamp content-box widths in block, inline-level and flex layout,
including flex base/target sizes and stretched column cross sizes; percentages
resolve against the containing block content width and `min_width` wins when
both apply. There is no `min-height`/`max-height` or automatic min-content
floor, so a shrunken item can overflow its neighbour unless `overflow` clips it.

### 5.2.1 Text flow

`ui/text_layout.zig` is the CSS text pipeline: `renderLeaf`/`processWhitespace`
implement the `white-space` family (collapse/trim boundaries, hanging spaces,
tabs, preserving newlines), `findBreaks` wraps UAX #14 opportunities with
`word-break`/`overflow-wrap` and `nowrap`-leaf filtering, and `buildLines` is a
port of TermDOM's binary-search line builder. The full UAX #14 rule set and
Unicode 17 tables live in `ui/linebreak.zig`/`ui/linebreak_tables.zig`; the
checker includes the upstream conformance subset and VS Code-derived cases for
tabs, wide cells, CJK/Kinsoku, punctuation and `keepAll`.

VS Code's `MonospaceLineBreaksComputer` remains the editor reference for the
editor-only wrapping features (injected text, continuation indent, incremental
break reuse); the TUI editor keeps using the ported view-model wrapping and its
line boxes are `pre`, so edge text is not wrapped twice. Single-line chrome in
the TUI and ported widgets is `pre` as well, preserving literal spacing. The
generic `ui` engine follows CSS/TermDOM instead.

Ported widgets use flex where upstream does: the find bar is a flex column with
one row per input, the suggest widget is a flex column with flex rows and a
flex list/detail split, and the hover status bar is a flex row. The
terminal-specific list windowing, hit targets and hover scrolling remain
manual; the generic `ui.ScrollView` covers arbitrary overflowing content.

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
| `border` | `u16` | interned cell-border set id; `0` = none. The id points into a table shared by the frame's two grids. |

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
- Before a cell whose border set changed, emit the cell-border pen: clear the
  old segments and set the new groups. SGR 0 clears the pen, so a style reset
  re-emits it; every changed row starts with SGR 0 before `EL`, which makes the
  erase clear the row's borders.
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
synchronized-output support are `Surface` options. Cell-border support is the
one probed capability: `src/tui/cellBorders.zig` sends the DCS query followed
by DA1 and returns the answer, and the host calls `Surface.setCellBorders`.
Mode 2027, DECRQSS and cell pixel size remain later additions. The POC assumes
truecolor and a terminal that accepts synchronized output (both are ignored
safely if not).

### 6.8 Cell borders

The renderer implements the draft cell-border protocol
(`DCS 1 + b cell-border`, version 1) behind a capability probe. On the wire the
`b` final byte is followed immediately by the payload: `ESC P 1 + b` then
`cell-border;...`, with no separator space. The model is in
`ui/cell_border.zig`: twelve segment bits, a stroke (width in 1/256 cell,
colour, placement, layer, line style, priority), disjoint segment groups, and
an interned set table. `ui/cell.zig` adds a parallel `u16` id plane to
`CellGrid`; `Frame` owns one table shared by both buffers so ids compare across
the diff.

When support is present, box derivation copies the requested border widths to
`LayoutBox.cell_border` and zeroes `style.border`. Layout therefore does not
reserve cells, and the painter puts centred strokes on the box's outer-edge
cells instead of writing `┌ ─ ┐` glyphs. Two adjacent boxes set their own side
of a shared edge; the terminal merges the centred strokes. Paint order still
decides which box owns a cell's glyph and background, but border segments from
different boxes combine in the cell's set. Text and background writes preserve
the border attribute (the terminal semantics), so an overlay that covers a
bordered cell calls `CellGrid.clearBordersRect` for its rectangle; the quick
pick does this over split dividers.

Without support, nothing changes: border widths take part in layout, `drawBorder`
writes single-line box-drawing glyphs into the reserved cells, and the border
plane stays empty. This is still the default, so a terminal or multiplexer that
discards the query keeps the old rendering. Widgets that size themselves with
`border_width * 2` (the hover and suggest content widgets) have not opted into
the cell-border path yet; the workbench does.

The workbench uses the article's pane chrome. Each editor pane's border box
(tab row plus editor content) gets a full outline on its own cells, so no gutter
is reserved; adjacent panes set opposite cells of the shared boundary and the
terminal merges them. The active pane's stroke carries `priority=1` and the
focus colour, so a supporting terminal preserves its whole outline on shared
edges no matter which neighbour was painted first; with priority unsupported it
falls back to the protocol's width/position tie-break. The pane divider is also
the sash hit zone: a left-button drag updates the split ratio (clamped to a
10-column/3-row minimum), and closing the last tab in a pane removes the group
from the split tree and promotes its sibling, mirroring Grid branch demotion.
Dragging a tab moves it between groups: dropping in a pane's middle moves it
there, and dropping on an edge splits that pane in that direction and moves the
tab into the new group. While dragging, the target pane gets a bright outline
(with cell borders; the glyph fallback has no drag indicator).
The full N-ary `Grid` branch model is not ported; the terminal keeps a binary
oriented split tree, which represents the same guillotine tilings.

### Editor tab strip and breadcrumb row

Each editor pane spends one cell row on the tab strip and, when
`breadcrumbs.enabled` is on (the upstream default), a second row on the
breadcrumb bar. The editor content starts below both rows; the pane's outline
still surrounds the whole chrome+content rectangle, and the cursor/mouse
coordinate translation subtracts the same chrome height.

The tab strip is the cell adaptation of `editorTabsControl.ts`/
`multiEditorTabsControl.ts`: the file icon theme is a two-cell language badge
(`JS`, `TS`, `ZG`, …), preview tabs are italic, the active tab uses the active
background and bold text, and every tab reserves action space. The active or
hovered tab paints `×`; a modified tab paints `●` in the same cell (hovering it
paints `×`). Clicking that cell or middle-clicking the tab closes it; a dirty
tab first opens the modal save confirmation and `Ctrl-W` takes the same close
path. Double-clicking a preview tab pins it; double-clicking a pinned tab
toggles the group's expanded state (default
`doubleClickTabToToggleEditorGroupSizes: 'expand'`). An expanded
group is laid out over the whole editor area and its siblings are not painted;
toggling it off restores the split from the existing grid rects. Sash resizing
and tab dragging are disabled while a group is expanded. There is no 1px
active-tab top border, horizontal scrollbar, editor actions toolbar, Add Tab
control, tab context menu or tab drag reordering; overflow clips leading tabs
behind an ellipsis and reveals the active tab. Preview editors come from
Explorer single clicks; Enter/quick open/CLI/session opens stay pinned, and an
edit pins a preview.

### Editor close confirmation dialog

`ui/dialog.zig` is the reusable modal message widget. The editor close path
feeds it the VS Code save confirmation built by
`src/vs/platform/dialogs/common/dialogs.zig`. It follows the native macOS save
sheet from VS Code: a warning glyph above the bold, wrapped
"Do you want to save the changes you made to …?" message, the
"Your changes will be lost if you don't save them." detail, and full-width
buttons stacked vertically. A terminal shorter than the stacked layout turns
the buttons into one row and drops the icon and blank separators; the dialog is
centered, bordered and dims every cell outside its rectangle.

The close path is upstream's `EditorGroupView.doHandleCloseConfirmation`.
Clicking a tab's close cell, middle-clicking, `Ctrl-W` or the
`workbench.action.closeActiveEditor` command all go through the same
`closeTab`: a custom `IEditorCloseHandler` can veto, otherwise a dirty editor
that is not opened in another group asks; `Save` writes and then closes only
when the buffer is clean, `Don't Save` attempts the revert and closes, and
`Cancel` vetoes. The dialog is modal and workbench-level: it consumes every key
and mouse event (a press only focuses; the matching release activates), focuses
`Save` when it opens, cycles with Tab/Left/Right/Up/Down, activates with
Enter/Space and cancels with Escape. The hardware caret is hidden while it is
open. The browser dialog's action-bar close button, custom body/footer,
checkbox, inputs, dropdown and shadow are not ported.

The breadcrumb row is the cell adaptation of `breadcrumbsWidget.ts` and
`breadcrumbsControl.ts`. Items are painted left to right with a dim `>` between
them; focused/selected items are underlined and white, hovered items brighten,
and long paths drop leading items behind `…`. A directory/file click opens the
terminal quick pick for the item's sibling directory (the browser tree picker is
replaced by the existing quick pick); a symbol click/space calls
`IOutline.reveal`. Focus navigation is `Left`/`Right`, `Enter`/`Down` picks,
`Space` reveals and `Escape` returns to the editor. `Ctrl+Shift+.` and
`Ctrl+Shift+;` focus the bar; some terminals do not deliver those combinations.

Symbol segments require an `IOutlineCreator` registered with the ported
`OutlineService`. The tree's only creator source is the future extension host /
language-service layer, so the stock TUI shows the file path alone; the
breadcrumb model/widget tests register fake creators to cover the symbol path.
The browser editor-type dropdown, hover tooltips, drag data, symbol-kind filters
and the tree picker are not ported. Creating a short-lived control to paint an
inactive group's breadcrumbs is a terminal adaptation of the browser's one
widget per group; it keeps the visible content correct without a per-group DOM
lifetime.

Limitations of the current wire encoder: it emits solid strokes only, with
square joints, `placement=1` and `layer=0`. `Set` carries joint flags and the
wire encoder carries the line-style and priority fields, but the painter never
sets joints and rounded joints, the `outside` fill, double/dashed/dotted
strokes and shared-edge `priority` are not emitted yet.
Between cells the encoder clears only the segments whose stroke disappears and
then sets the changed groups, so moving along a rectangle edge emits one small
command per cell rather than a full set. Joints are always square, so no joint
state needs clearing.

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
  callback, `render(writer, options)`, and `resize(cols, rows)`. Resize
  reallocates the double buffer, updates the document viewport, invalidates the
  box tree and forces the next frame to clear. The host owns terminal resize
  detection (`SIGWINCH`; the examples relay it through a self-pipe) and rebuilds
  any tree that captured the old size.
- `Document`: root, viewport, tab size, node creation/ownership,
  `activeElement`, `focus`, `blur`, `moveFocus`, `dispatchKey`.
- `Node`: tree navigation/mutation, direct styles, `addEventListener` /
  `removeEventListener`, `focus`, `blur`, `isFocusable`.
- `Style`: `position` (static/relative/absolute/fixed), `top/right/bottom/left`,
  `width/height` and `min_width/max_width` (`auto | cells | percent`), `display`
  (block/inline/inline-block/flex/inline-flex/contents/none), `overflow`
  (visible/hidden/clip), `text_align`, `white_space`
  (normal/nowrap/pre/pre_wrap/pre_line/break_spaces), `word_break`,
  `overflow_wrap`, `visibility`, `color`, `background`,
  `bold`, `italic`, `underline`, `strikethrough`, `dim`, `reverse`, `z_index`,
  `translate_x/y`, plus `margin` (`Margin` with per-side auto), `padding`,
  `border`, `border_style` and `border_color`. Flex adds `flex_direction`,
  `flex_wrap`, `justify_content`, `align_items`, `align_self`, `align_content`,
  `flex_grow`, `flex_shrink`, `flex_basis`, `order` and `gap` (`Gap.all`).
  `width`/`height`/`min_width`/`max_width` are content-box sizes; padding,
  border and margin expand outward.
- `ScrollView`: a manual scroll view built from those primitives. `init`
  creates a clipped viewport, a translated content box and a proportional
  scrollbar; the caller appends cells to `contentNode()` and passes explicit
  viewport/content heights. The wheel scrolls it. There is no CSS
  `overflow: scroll`/`auto`; list windowing and editor/hover scrolling keep
  their own view-model state. A layout-level `overflow: scroll`/`auto` for
  every box is future work; it would move scroll state into the box tree.
- Measurement: not implemented yet; tests read `Surface.grid()` directly. The
  `getBoundingClientRect`/`offsetWidth` boundary comes with the view parts.
- Layout: absolute positioning against the nearest positioned ancestor using
  `left`/`top`, with the margin box anchored there (right/bottom anchoring and
  absolute auto margins are not implemented); block flow with content-derived
  auto height and horizontal auto margins; UAX #14 inline flow with
  `white-space`, `word-break`/`overflow-wrap`, per-line `text_align`, hanging
  spaces, tabs and wide cells; percentage sizes resolved against the containing
  content box; clipping to the padding box; `display:none`; backgrounds paint
  the border box. Auto width fills the containing block for a block-level box
  and shrink-wraps for an inline-level box. Text and non-atomic inline elements
  store per-line fragments for paint and hit testing. Flex containers cover
  row/column direction, wrap, grow/shrink/basis, justify/align, gap, order and
  auto margins; text wraps at each item's resolved content width. No grid,
  table layout or margin collapsing in the POC.
- Rendering: `Surface.render` = layout -> paint into the next grid -> diff against
  the previous grid -> ANSI to the writer. Tests read `Surface.grid()` instead of
  parsing ANSI.
- Ownership: the document owns all nodes; text/attribute buffers are
  document-allocated; `remove()` detaches and queues recycle; `Document.deinit`
  frees everything. The allocator is always explicit, no globals.
- Events: `ui/event.zig` (keys, mouse, focus, listener dispatch),
  `ui/box.zig`/`ui/surface.zig` (`elementFromPoint`) and `ui/input.zig` (the
  terminal byte decoder, including SGR mouse reports). The preview also handles
  Up/Down, PageUp/PageDown, Home/End and mouse-wheel scrolling, and Ctrl-Q to
  quit.

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
  - Turns the cached bracket-matching data into model decorations and paints
    them through `LineDecoration.filter`/`extractWrapped`, the same per-wrapped-
    line route as find ranges. Highlights are hidden while a widget owns focus
    and update on typing or cursor movement.
  - Builds the editor tree as one surface; `Document.clear` rebuilds the tree
    between frames while keeping the previous grid for the diff.
- The workbench status bar is a separate one-row `ui.Surface` owned by the
  ported `StatusbarPart`. `StatusbarPart.render` rebuilds a flex document
  (root row, left `flex_grow` container, right `row_reverse` container with a
  fixed content width, item containers and label containers), paints it, and
  blits the resulting
  grid into the workbench frame's bottom row. The row spans the full window
  (including under the sidebar) and the activity/sidebar/editor part
  rectangles end above it. The ported `StatusbarModel` owns order, priority,
  visibility, overrides and focus; `StatusbarItem` owns the label, kind colors,
  progress/beak prefix and truncation; `StatusbarPart` owns hit testing,
  hover/tooltip and command activation. The item max width is the cell
  equivalent of upstream's `40vw`. Upstream wraps the right group; the terminal
  keeps it on one line and clips at the row edge. Standard values open the
  corresponding quick picker; the file path stays in the tab/title, matching
  upstream's status bar. `Ctrl-Alt-S` is a TUI-specific
  focus toggle, and `Focus Status Bar` is available from the command palette.
  Not ported: DOM context menus, extension management, window-focus/inactive
  backgrounds, auxiliary/scoped status bars, storage persistence of hidden
  entries and codicon rendering.
- `src/tui/preview.zig` remains the read-only `--preview` variant, adding
  Up/Down, PageUp/PageDown, Home/End and mouse-wheel scrolling.
- Overlay widgets use the terminal adaptation of upstream `IOverlayWidget`
  in `src/vs/editor/browser/editorBrowser.zig`. A widget reports its size in
  cells, builds a `ui` subtree each frame and is anchored to a corner
  (`top_right_corner`, `bottom_right_corner`, `top_center`); the view restores
  focus after every rebuild. `View.dispatchKey` forwards decoded keys through
  the widget document first, so a focused widget owns the keyboard.
- Quick open is a workbench-level overlay, not an editor overlay. The
  controller (`src/vs/platform/quickinput/browser/quickAccess.zig`) owns one
  persistent `QuickPick` model and selects a provider from
  `src/vs/platform/quickinput/common/quickAccess.zig`; the terminal view
  (`src/tui/quickInput.zig`) renders the input row with a one-row `ui.Surface`
  and paints the list rows directly into the workbench grid. The workbench
  composites it after every pane and the tab strip, and hides the hardware
  cursor while it is open. `Ctrl-P` opens Go to File, `>` switches to the
  command provider, and `Alt-P` opens the command provider directly because a
  terminal cannot distinguish `Ctrl-Shift-P`. The workspace file index is a
  TUI adapter (`src/tui/fileIndex.zig`) that walks the workspace instead of
  calling the search process, but it honors `.gitignore`/`.ignore` through the
  same ported `IgnoreFile`. Icons, buttons, keybinding labels,
  virtualized lists, symbol/go-to-line/link providers and the browser
  `fuzzyScorer.ts` path-aware scorer are not ported.
- Content widgets use the terminal adaptation of upstream `IContentWidget`: the
  widget reports a model position plus an `above`/`below` preference, and
  `View.buildContentWidgets` converts it with the view model
  (`Editor.viewPositionOfModelPosition`), maps the column to a cell (tabs, wide
  characters and wrapping indent included), and places the box inside the text
  area. This is the hover anchor route; the browser's pixel `ResizableContentWidget`
  geometry becomes cell sizing and clamping. Mouse hit testing reports
  `CONTENT_TEXT`, `CONTENT_EMPTY` (with `isAfterLines` and a cell distance),
  `GUTTER_LINE_NUMBERS`, `GUTTER_LINE_DECORATIONS`, `STATUS`,
  `CONTENT_WIDGET` and `OVERLAY_WIDGET` through `View.mouseTargetAt`, which the
  hover controller consumes instead of the browser's `onMouseMove` target.
- Folding is applied at the view-model boundary:
  `src/vs/editor/contrib/folding/browser/folding.zig` computes indentation
  ranges, keeps collapse state and produces hidden model-line ranges;
  `ProjectedViewModelLines.setHiddenAreas` marks those projections invisible
  and updates the prefix sums, and the converter maps positions on hidden
  lines to the preceding visible line. `src/tui/view.zig` paints the last
  gutter cell as `▾`/`▸` and makes it a `GUTTER_LINE_DECORATIONS` hit target;
  clicking it toggles the region. The first visible line of a collapsed region
  gets the upstream `…` suffix. The editor binds `Ctrl-Shift-[`/`]`,
  `Ctrl-K Ctrl-L`, `Ctrl-K Ctrl-0` and `Ctrl-K Ctrl-J` and registers the
  corresponding `editor.fold*`/`editor.unfold*` commands in the workbench.
  Syntax providers, folding decorations/CSS, sticky scroll and folding view
  state are not ported. Fold state survives edits on the folded line; line
  insertions or deletions above a collapsed region re-expand it because there
  are no tracked folding decorations to shift the range.
- Indentation guides are painted by `View.rebuild` from the ported
  `src/vs/editor/common/model/guidesTextModelPart.zig` indentation subset. The
  model computes a guide count per visible model line, including the upstream
  blank-line rule that inherits from the surrounding content, and the view
  overlays a dim `│` at each `(level - 1) * indentSize` column inside the
  leading whitespace. This follows Flow's whitespace-indent glyph. Vertical
  bracket-pair guides come from
  `src/vs/editor/browser/viewParts/indentGuides/indentGuides.zig`, which reads
  the existing bracket-pairs model and colors each guide by nesting level. The
  active indentation scope around the caret and the bracket pair containing
  the caret are painted with brighter guide colors. A guide is only painted
  in a leading-whitespace or blank cell, because one terminal cell cannot show
  both a guide and a text glyph; horizontal bracket guide segments are
  therefore not painted. Wrapped continuation lines do not get guides.
- Find, bracket and word ranges are stored in the model as `TextModel`
  decorations (`findMatch`, `currentFindMatch`, `bracket-match`,
  `wordHighlight*`). `View.ModelDecorationSink` replaces each contribution's
  owner ID directly against the model; the view's bracket pass does the same.
  The rebuild reads the model's inline and overview-ruler decorations back
  through `getLineDecorations` / `getOverviewRulerDecorations`. This gives all
  contributions one range tracking and z-order path.
- The suggest contribution (`src/vs/editor/contrib/suggest`) is the first
  end-to-end completion UI. `SuggestModel` schedules quick suggestions 10 ms
  after a typed word character, opens immediately for provider trigger
  characters, and exposes `Ctrl-Space` as an explicit alternative. It supports
  synchronous providers and deferred `CompletionRequest`s that are polled from
  the app loop. `CompletionModel` uses the ported fuzzy subsequence scorer and
  orders by preselect, score, `sortText` and label. `SuggestWidget` is a content
  widget anchored below or above the caret; it windows at most eight rows,
  draws a one-cell scrollbar, handles row click/wheel listeners, and shows a
  plain-text documentation/details pane for the selected or resolved item.
  Acceptance applies additional text edits atomically, supports multiple
  cursors, honors commit characters, and uses the snippet session for
  `InsertAsSnippet` items. The app routes suggest keys before the editor,
  forwards the poll deadline and refilters after edits. The default provider
  suggests document words.
  Snippet parsing uses the upstream marker AST: text, placeholders, choices,
  variables/defaults, escaped characters, nested placeholders, regex
  transforms (variables and empty placeholders) with regex options, format
  conditionals and case shorthands. `snippetSession` ports `OneSnippet`
  placeholder decorations and groups, transform re-runs, nested merge, choice
  completion, per-edit templates and snippet variable resolvers. Placeholder
  decorations render through the generic model-decoration path with
  `snippet-placeholder` / `finish-snippet-placeholder` cell backgrounds.
  Remaining host limits: clipboard text comes from the caller, workspace
  variables use the edited file's parent directory, time variables use UTC,
  and Unicode case transforms are ASCII-only. Deliberately unported:
  `SnippetController2` actions/context keys, asynchronous resolve,
  incomplete-list retries, suggest memory, inline completions,
  configuration/context keys, markdown rendering in the details pane and
  accessibility announcements.

- **Diagnostics.** Marker decorations use the upstream `squiggly-*` class
  names. Cells have no wavy underline or glyph margin, so the view paints the
  range as an underline in the severity color (hint/unnecessary dimmed) and the
  existing overview-ruler lane carries the marker color. The workbench
  `Problems` status entry shows the active resource's error/warning counts. The
  minimap metadata produced by the marker decorator is ignored.

- Word-occurrence highlighting is the third decoration consumer:
  `src/vs/editor/contrib/wordHighlighter` tracks the caret/selection, waits
  `max(50 ms, editor.occurrencesHighlightDelay)`, asks the textual provider for
  whole-word matches, and sends `wordHighlightText`/`wordHighlight`/
  `wordHighlightStrong` ranges to `View.setWordHighlights`. The view stores
  them as `TextModel` decorations with the corresponding class names and
  paints them through the same `LineDecoration.filter`/`extractWrapped` path
  as find, bracket and hover highlights, using the dark-theme colors
  composited to cells. The controller replaces the upstream cursor/content/focus listeners
  with `onEditorChanged`/`onTick`, which the app calls after each input batch
  and from the nearest-deadline poll timeout.
- The hover contribution is the second end-to-end widget consumer: the
  controller schedules a delayed computation with two deadline timers (the TUI
  event loop polls with the nearest deadline and calls `onTick`), the wrapper
  picks range anchors, `contentHoverRendered.zig` builds participant rows and
  the `hoverHighlight` decoration, and `contentHoverWidget.zig` renders the
  bordered, scrollable box as a content widget. Markdown is parsed by the
  pinned `taggon/markdown-zig` CommonMark + GFM package (commit `85bcc67`,
  MIT) and rendered to styled cells by `hoverMarkdownRenderer.zig`; there is
  no HTML/CSS engine, so links show their URL in dim text, images show their
  alt text, tables render as width-capped box-drawing grids, and raw HTML is
  ignored. Nested/task lists, setext/indented code, autolinks and reference
  links are supported; wide table rows are clipped to the hover width. Fenced
  code blocks use the editor's TextMate tokenizer: the fence info string is
  resolved through common aliases, a missing language falls back to the editor
  model language, and unknown languages render plain.
- `ui/inputbox.zig` is the terminal single-line input: UTF-8 buffer,
  `(anchor, cursor)` selection with keyboard/mouse extension and selection
  paint, shell-like word movement/deletion, Ctrl+A, clipboard hooks
  (`on_copy`/`on_paste`; the library does no clipboard IO), snapshot
  undo/redo, caret-follow horizontal scrolling with wheel and drag-edge
  scrolling, enable/disable, and the upstream
  `select`/`getSelection`/`isSelectionAtEnd`/`insertAtCursor` shape.
  Placeholder, `on_change`/`on_enter`/`on_escape` and the block caret are
  unchanged. Up/Down and Tab stay host-owned; history, validation messages and
  action bars remain host concerns. Terminal limits: no double-click word
  selection (reports carry no click counts) and no grapheme/IME segmentation.
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
- `src/tui/app.zig` dispatches keys and mouse events to the editor, refreshes
  the view and syncs the hardware cursor after each frame; resize recreates the
  surface. The terminal runs in mouse mode 1003 with SGR coordinates (1006), so
  press, release, idle/button-held motion and wheel arrive as `ui.MouseEvent`s.
  `View.dispatchMouse` hit-tests, applies press-to-focus, places the caret
  (Shift extends), drag-selects, synthesizes the release click on the common
  ancestor and scrolls three view lines per wheel notch. Clicking a find input
  focuses it and places the byte caret; the option toggles (`Aa`, `ab`, `.*`,
  `Sel`) and `All` highlight on idle hover and run their action on click while
  keeping input focus. Clicking the editor blurs the bar without closing it.
- The right edge reserves one text cell shared by the overview ruler and the
  scrollbar. `decorationsOverviewRuler.zig` ports the upstream scaled
  `y1`/`y2` projection and z-order paint rules, but writes cell rows instead of
  canvas pixels: a row represents a range of document lines when the document
  is taller than the track, and lanes collapse onto the cell. The view
  supplies markers from find, the current find match, bracket matches with the
  overview-ruler option, word occurrences and cursor positions. The thumb is
  painted afterwards in the same cell as a foreground block glyph, so it
  covers the markers on its rows. This follows Flow's vertical-scrollbar
  rendering technique: a one-column plane erased to the editor background and
  then a single glyph, with no background run at the terminal edge (the
  terminal equivalent of the browser's overlapping slider and ruler layers). `ScrollbarState` is ported from `base/browser/ui/scrollbar` and
  drives a one-cell-wide slider with a one-row minimum; click, thumb drag and
  wheel use the upstream offset/delta math at row resolution. Cells have no alpha, so
  the marker colors are composited over the dark editor background. There is
  no minimap, horizontal scrollbar, pixel-lane width, border or smooth
  scrolling.
- Gutter width follows the existing `gutterWidthFor` logic; line numbers are
  right-aligned with `text_align = .right`.
- Long lines are clipped (no horizontal scrolling); wrapping uses the existing
  projection/wrapping column.
- The old `src/tui/screen.zig`/`render.zig` path is gone.
- Multi-file editing keeps one `View` per tab and composites the active view's
  cell grid below a one-row tab strip in `src/tui/workbench.zig`. The portable
  editor-part layers live at their upstream paths:
  `src/vs/workbench/browser/parts/editor/editorPart.zig` owns the group
  registry, grid and sash resize; `editorGroupView.zig` maps model editors to
  tab views and drives the active pane; `editorPanes.zig` keeps the active pane
  and page position. `src/tui/workbench.zig` keeps the terminal rendering and
  input adaptation. `EditorGroupModel` owns
  tab order/MRU/preview/pinned/sticky state, `FileEditorInput` exposes each
  editor's path/dirty/save state, and `Tab` keeps one persistent
  view/contribution set per file. `ui.Surface.paintFrame` paints without
  encoding ANSI and `ui.CellGrid.blit` copies the pane grid into the shell
  frame, so switching tabs reuses the one double-buffered frame diff instead of
  clearing the screen. Each tab keeps its scroll position and decorations.
  Groups form a binary split tree; every pane gets its own tab row and active
  view, and all panes are composited into one frame. Group state is serialized
  through the workbench editor serializer registry; the JSON session stores
  the group list and active group and restores splits as equal horizontal
  splits. Dirty working copies are not persisted.
- Workspace roots come from the portable `Workspace` /
  `WorkspaceContextService` models (`src/vs/platform/workspace/common/` and
  `src/vs/workbench/services/workspaces/common/`). The CLI classifies directory
  arguments as workspace folders and file arguments as initial editors;
  `ExplorerModel` creates one root per workspace folder. The workbench starts
  with an empty editor group when only a folder is opened.
- The Explorer sidebar is a terminal tree view
  (`src/tui/explorerTreeSidebar.zig`) over `ExplorerModel`/`ExplorerItem` from
  `src/vs/workbench/contrib/files/common/explorerModel.zig`: lazy directory
  resolution, directories-first ordering, expand/collapse, selection and
  scroll. A single-folder workspace uses the folder as the tree input, so its
  children are top-level rows; multi-root workspaces show roots and expand the
  first five by default. Filtering runs through the upstream-shaped
  `FilesFilter`
  (`src/vs/workbench/contrib/files/browser/views/explorerViewer.zig`): it
  evaluates `files.exclude` per root, applies `!` exceptions, keeps folders
  that lead to an exception visible, and hides entries matched by
  `.gitignore`/`.ignore` through the ported `IgnoreFile`, including nested
  files and `!` negations. Ignore files themselves stay visible.
  `explorer.excludeGitIgnore` controls the ignore-file filtering; the TUI
  default for that setting is on rather than upstream's off, because the
  Explorer hid ignored entries before the configuration service existed; a
  workspace setting can disable it. An open editor keeps an otherwise excluded
  file and its parent folders visible.
  The workbench reserves a fixed left activity column
  and sidebar column and offsets the editor split root; a click or Enter on a
  file calls `Workbench.openPath`. Directory resolution is synchronous. The
  Explorer now renders through the ported list/tree view layer
  (`rangeMap` + `ListView`/`ListWidget` + `IndexTreeModel`/`ObjectTreeModel` +
  `CompressedObjectTreeModel` + `AbstractTree`), including virtualization,
  wheel scrolling, collapse state and `explorer.compactFolders`. The
  `CompressibleObjectTree` adapter renders a compressed path as one
  `a/b/c` row, and object/index/synchronous-data tree view adapters are ported
  too. The async data tree/loading placeholders, identity-provider diffing
  through the object models, drag/drop, sticky scroll and the compressed-label
  navigation controller (per-segment focus/hover) are not ported.
  The activity bar is split into the ported model
  (`src/vs/workbench/browser/parts/activitybar/activitybarPart.zig`), the
  activity service model
  (`src/vs/workbench/services/activity/browser/activityService.zig`) and the
  terminal view (`src/tui/activityBar.zig`). The Search activity shows a badge
  dot while matches are present (the exact count is in the panel); the service
  also supports view and global badges. It
  switches fixed Explorer,
  Search and Settings containers; Settings remains a placeholder. The model
  owns activity order, visibility, the active container and compact width.
  There is still no registered view-container contribution registry; live
  file-change refresh, resizing and context menus are not ported.
- The Search panel is split into a portable search service/tree and a terminal
  view. `searchService.zig` walks workspace folders in bounded steps, reads
  open-editor content through a host callback, applies the ported regex/word
  matcher and streams owned file matches. `ignoreFile.zig` ports upstream's
  `IgnoreFile`, and the search walk plus the quick-open index build a
  per-directory ignore chain from `.gitignore`/`.ignore`, including nested
  files, directory-only patterns and `!` negations. `glob.zig` grew the
  pattern language that port needs: `**`, `?`, `{}` groups, `[...]` character
  classes, `trimForExclusions` and `ignoreCase`. `searchTreeModel` ports the result
  hierarchy, replacement pattern and change events. `queryBuilder.zig` builds
  the text query and `searchService.zig` applies `files.exclude`/
  `search.exclude` through the ported glob expression, including `false`
  entries, `!` exceptions and `{ when: ... }` sibling clauses.
  `src/vs/workbench/contrib/search/browser/searchView.zig` is the portable view
  controller (query lifecycle, focus state, counts/messages and replace-all
  request/execute); `searchResultsView.zig` owns the data source, ordering,
  row labels and accessibility labels; `searchCompare.zig` and
  `searchActions*.zig` port the comparers and action helpers.
  `src/tui/searchWidget.zig` renders the input/replace/details rows on a
  `ui.Surface`; `src/tui/searchView.zig` is the terminal adapter that owns
  focus, mouse routing, flattened row painting and the replace/open callbacks.
  Completed match selections write a `rangeHighlight` model decoration through
  `View.setSearchHighlights`. Remaining gaps are the browser tree's
  compression/virtualization, multi-selection, drag/drop, context menus,
  clipboard/history storage, AI/notebook/search-editor results, compressed
  folder chains, search-path expansion and Settings view.
- Configuration lives in
  `src/vs/workbench/services/configuration/browser/configurationService.zig`,
  over the platform `configuration.zig`, `configurationModels.zig` and
  `configurationRegistry.zig` ports. It reads defaults, a user settings file,
  the workspace file's `settings` object and each folder's
  `.vscode/settings.json`, with folder > workspace > user > defaults precedence.
  Settings JSON accepts comments and trailing commas. The service exposes
  `getValue`, `inspect`, `keys`, `reload` and a change emitter.
  Native watching uses inotify on Linux, kqueue on macOS and overlapped
  `ReadDirectoryChangesW` on Windows; the `@parcel/watcher` FSEvents backend is
  not ported because it requires the CoreServices SDK and a CFRunLoop thread.
  Not ported in this configuration-service port:
  - `updateValue` and settings editing; these need the JSONC-preserving
    configuration-editing service, which is not ported;
  - language override blocks (`[typescript]`); `ConfigurationModel` keeps the
    blocks but does not resolve override identifiers;
  - policy, application, remote and profile scopes; the corresponding
    services do not exist in the terminal workbench;
  - trusted-workspace filtering and restricted settings; there is no
    workspace-trust service;
  - the browser Settings editor/view; the activity-bar Settings container
    remains a placeholder.

## 9. POC acceptance

- `zig build` and `zig build test --summary all` pass with no leaks.
- A preview of a fixture file at 80x24 shows: text, syntax colors,
  right-aligned line numbers, empty lines, tabs, CJK/emoji wide characters,
  wrapped lines, long-line clipping, gutters for lines past 9 and 99.
- Snapshot tests in `src/tui/` assert text rows and per-cell styles for ASCII,
  CJK, tabs, wrapping and long-line clipping; selection inversion; the hardware
  cursor cell; an unchanged refresh writing no bytes; mouse click/shift-click/
  drag/wheel caret and viewport effects; find-control hover highlighting and
  click activation; input click-to-caret; plus keyboard scrolling and Ctrl-Q
  through the library dispatcher. Content-widget tests cover model-position
  anchoring, wrapped anchors, above/below flipping and cell clamping; the hover
  contribution tests cover the upstream `contentHover.test.ts` placement cases,
  markdown/decoration participants, rendering the box and highlight, focus with
  Escape, and wheel scrolling of long hover content without moving the
  editor viewport. Word-highlighter tests cover the textual provider, the
  delayed run, keeping/updating occurrences, stopping on edits, multi-line
  selections and focus loss, and next/previous navigation. Scrollbar tests
  cover the reserved column, marker colors and rows, the thumb covering a
  marker row, cursor markers, the no-thumb short-document case, thumb geometry,
  click/drag scrolling, narrow terminals and the per-decoration overview-ruler
  flag. The ported
  `ScrollbarState` tests include the upstream cases and a one-row minimum.
- Library unit tests cover: tree linking/invariants, box-tree derivation
  (viewport root, principal/text boxes, anonymous inline/flex items,
  `display: contents`/`none`, order sorting, mutation invalidation),
  absolute/percent/auto layout, flex direction/reverse, justify-content, wrap and
  align-content, grow/shrink/basis, gaps, align-items/align-self/baseline, auto
  margins, order stability, content-derived auto sizes, nested flex,
  out-of-flow children, inline-flex and flex painting, a set of cases ported
  from Taffy's flexbox fixtures (basis/grow/shrink, reverse directions,
  justify/align, gap and align-content wrapping), clipping, right
  alignment, wide characters, tabs, cell painting, frame diff (changed cell,
  vanished cell, unchanged frame), first-row erase and a small ANSI golden.
  Text-flow tests cover UAX #14 conformance (>2500 Unicode cases), white-space
  modes and boundary trimming, hanging spaces, tabs and wide cells,
  word-break/overflow-wrap, per-line alignment, long-word overflow, per-leaf
  overrides, inline-element fragmentation, and multi-line paint/hit testing.
  Event tests cover capture/target/bubble order, propagation and default
  prevention, focus event order and `related_target`, tabindex
  traversal, hidden/focusability checks, silent focus clearing on removal,
  mouse hit-testing, press-to-focus, wheel cancellation, and the terminal
  decoder (control keys, modifiers, paste, lone Escape, SGR mouse).
- No view model or view-part architecture ports in this POC; the editor view
  remains the collapsed `src/tui/view.zig`. Cursor, selection and a two-cell
  scrollbar/overview ruler are painted, but there is no generic scrollable
  viewport.

## 10. Roadmap after the POC

1. Full `viewLineRenderer` port + `CharacterMapping` and the upstream
   `viewLineRenderer.test.ts` cases (canonical part comparison).
2. Flex follow-ups: `min-height`/`max-height` and the automatic min-content
   floor for shrinking items.
3. `ViewLayout`/`Scrollable` + `IViewModel`/`IViewLayout` interfaces + a
   temporary `TuiViewModel` adapter + view-event bridge.
4. `viewLayer`, `viewPart`, `renderingContext`, `viewOverlays`,
   `viewLines`/`viewLine`, margin/lineNumbers/currentLineHighlight/selections/
   viewCursors; `TerminalView` orchestrator. The terminal editor view
   (`src/tui/view.zig`) already covers gutter, tokens, selection, cursor and
   status; the split into upstream-shaped view parts is still open.
5. Generic scrollable viewport (`overflow: auto` boxes) and CSS-style
   `:hover`; cursor blink/timers; row damage bands and the `DECSTBM` +
   `IL`/`DL` scroll shift; hardware-cursor caret. The editor scrollbar and
   overview ruler are in as a shared one-column terminal adaptation with
   `ScrollbarState`, including click, thumb drag and wheel scrolling; the
   generic scroll and selector machinery is not.
6. Replace the adapter with a port of `viewModelImpl.ts` +
   `CursorsController`; port edit context/controllers; then the remaining
   widgets and contributions (marker/glyph hover, and the quick-pick list's
   icons/buttons/virtualization). The workbench quick-open overlay, file and
   command providers, and their terminal view are in.

Since this list was written, the editor view model (`ViewModelLines`,
`ViewModelDecorations`, `CoordinatesConverter`) has landed. The remaining
editor-view work is the view/controller/widget split, not the view model.
The file-by-file mapping of `src/tui/` to these upstream modules, including
the current UI/view code map (§7.1), the P1-P5 sequencing and upstream test
map, is tracked in the [TUI porting inventory](porting-inventory.md).

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

- No CSS, HTML, `innerHTML`, grid or table layout, transitions, opacity
  compositing, borders/radii.
- No RTL/bidi visual reordering, grapheme segmentation, combining-mark cell
  composition, ligatures, or terminal width negotiation (mode 2027) in the POC.
- Mouse press/release, click, idle and button-held motion and wheel are in.
  Hover is widget state derived from idle motion: find toggles/`All` highlight,
  and the input box maps clicks/drags to its byte selection. CSS-style
  `:hover`, enter/leave events, double/triple click counts, context menus,
  middle-click paste, legacy X10 reports, terminal focus reporting, editor
  drag auto-scroll and generic `overflow: auto` scrolling are not. IME,
  scheduler and `Range`/`Selection` are still absent. Keyboard events and
  focus are in; key release/repeat, CSI u/kitty reports are not. Focus events
  have no capture pass and there are no `:focus`-style selectors; focus is
  explicit state plus listeners.
- The one-line input has no system clipboard (host hooks only), no
  double-click word selection, no horizontal scrollbar and no validation
  message/context view; history (`HistoryInputBox`) stays host-owned. Its
  selection and editing are codepoint based, so combining marks/graphemes are
  not grouped.
- The editor scrollbar/overview ruler is a right-aligned 1.5-cell strip with
  three half-cell marker lanes; the 1.5-cell thumb covers markers on its rows
  and resolves its top/bottom edges to half-cell quadrants. It has no pixel
  lanes, minimap, horizontal scrollbar, rounded/smooth slider, translucent
  marker alpha or diagnostics markers; a marker row can represent many
  document lines. There is no generic scrollable
  viewport (the editor scrolls its top view line; the preview rebuilds), glyph
  margin, view zones or IME. The editor view paints the current line,
  selections, hardware cursor, find ranges and overview markers; overlay widget
  hosting and the find bar are in, other contributions are not.
- No row damage bands or terminal scroll shift in the POC; full grid diff only.
- The in-place-replace decoration is rendered as an underline in the
  bracket-match color; terminal cells cannot draw the browser's 2 px outline.
- No margin collapsing, right/bottom anchoring, auto margins on absolute boxes,
  background-clip or z-index paint ordering yet. Without cell-border support,
  borders are repeated single-line box-drawing glyphs; with support they are
  solid centred strokes (rounded joints, double/dashed/dotted styles and the
  outside fill are not painted yet).
- Flex is in, with content-box `min-width`/`max-width`, but without
  `min-height`/`max-height`, an automatic min-content floor, percentage gaps or
  `justify-content: stretch`.
  Baseline alignment is approximated by the first text row and falls back to
  flex-start under `wrap-reverse`. `position: fixed` still resolves like
  `absolute`.
- Text flow covers UAX #14 line breaking, the `white-space` family,
  `word-break`/`overflow-wrap`, hanging spaces and non-atomic inline
  fragmentation. It has no bidi reordering, grapheme-cluster segmentation, CSS
  `line-height`/`text-indent`/`vertical-align`, `<br>` elements, or font-aware
  shaping; forced breaks come from newlines under preserving white-space
  modes.
- No grid formatting contexts, table boxes or incremental box reuse yet; the
  box tree is rebuilt from the DOM when mutations invalidate it, then solved whole.
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
