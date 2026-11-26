# Terminal UI architecture: a DOM-like tree rendered to terminal cells

**Current Workbench architecture:** `src/vs/workbench/browser/workbench.zig` owns the portable Workbench startup, Layout, registered parts, notifications and lifecycle. `src/tui/workbenchWindow.zig` owns the native TerminalWorkbench window and remaining service/feature adapters; `src/tui/workbenchServices.zig` constructs the native service contracts; `src/tui/workbench.zig` owns the terminal event loop, rendering, and input. No production feature imports the portable Workbench or the native window. The old workbench polling methods are replaced by events and I/O readiness/deadline adapters. Outline editor subscriptions follow the view body visibility and active/visible-editor events, without render-time synchronization. ViewsService resolves registered views, active composites and body visibility through the layout and descriptor services. Sidebar title-area events drive the active toolbar. See the [Workbench port audit](workbench-audit.md) for the live boundary, native size budget, and remaining port omissions.

Status: proposed design.

The native host in `src/tui/workbench.zig` preserves partial input sequences
across reads, waits on terminal and worker-completion handles, composites the
editor, sidebar, panel, status bar and overlays, and flushes completed frames.
Terminal cells supply part bounds and pointer input. Browser DOM
font measurement, macOS font smoothing, auxiliary windows, floating panels,
traffic-light title controls, ARIA live regions/accessible view and browser-managed
text selection and IME lack equivalent
host APIs here. Notification center and toast rows use terminal cell bounds,
explicit link and button hit regions, and the status-bar bell in lieu of the
browser title bar. Notification deadlines use the shared window scheduler;
there is no notification-state poll. The terminal routes tab, sash and quick
input hit testing and terminal pixel/capability changes in `src/tui/workbench.zig`.
The editor pane accepts an explicit view factory and an IEditorView handle;
the native renderer remains in src/tui/editorView.zig. No portable source
imports src/tui.
[Workbench port audit](workbench-audit.md)

## 1. Context

This repository is a Zig 0.17 port of VS Code editor internals. The model,
commands and contributions are ported; `src/tui/` contains the terminal
frontend. The editor is now rendered through the standalone `ui` library
(`src/tui/editorView.zig`); the read-only `--preview` mode shares the same renderer.
The next step is to port the browser-facing editor UI (`viewParts`, widgets,
and the contributions in `src/vs/editor/contrib`) while keeping the code close
to upstream.

The obstacle is that upstream browser code is written against a browser DOM and
CSS. This design introduces a small, standalone, DOM-like UI library that
provides the node tree, direct styles, layout and terminal rendering, so the
ported editor code can keep its upstream shape without a browser engine and
without a CSS parser or selector engine.

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
     src/
       ui.zig            # public module
       surface.zig       # document, layout, painting and frame output
       dom/              # node tree, focus and event dispatch
       style/            # declarations, computed styles and class cascade
       layout/           # box tree, layout solver and text wrapping
       render/           # painting, cell grid and frame buffers
       terminal/         # terminal input decoding and output protocols
       widgets/          # controls, scrolling and drag interactions
     tests/              # unit and stress tests, fixtures, test entry point
     examples/           # runnable examples and gallery
     bench/              # benchmark runner and scenarios
   ```

   The package/module name `ui` is provisional and easy to rename. The library
   must not import from the editor’s `src/` directory.

2. **No CSS parser, selector engine or HTML.** Styles are authored as `Style`
   declarations. A box carries `ComputedStyle`: inherited properties come from
   the parent, everything else from its initial value. Classes are integer IDs
   into the document's array-backed stylesheet (`css.StyleTable`); a class
   declaration is merged by list order, not matched by a selector. `innerHTML`
   is not implemented.

3. **Declarations, not a stylesheet lookup engine.** Colors, alignment,
   visibility, positioning and text attributes are still written by the code
   that builds the node, as inline `Style` declarations. A class is only a
   style record registered on the document; the ported widget chooses it by
   enum name. See `docs/css.md`.

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
   milestone, `src/vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig` keeps the model/command/input path; only
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
    listeners: std.ArrayList(ListenerEntry), // stable order, tombstones
    recycled: bool = false,
    serial: u64 = 0,                    // document-assigned identity
};

pub const Element = struct {
    tag: Tag, // .div, .span, .document, ...
    attributes: AttributeMap,
    classes: std.ArrayListUnmanaged(u16), // IDs into Document.class_styles
    style: Style,                          // inline declaration
    rect: Rect = .{}, // layout result
    focusable: bool = false,
    tab_index: i32 = 0, // positive first, then 0; negative is Tab-skipped
    // measurement/layout cache fields later
};

// Document also holds `active_element: ?*Node`, exposed as `activeElement()`
// with the root as the body-like fallback and `focusedElement()` for the raw
// value, plus `focus_start` (the last press position) and `generation` (bumped
// by `clear`, which invalidates node pointers).

pub const Text = struct {
    data: []u8, // owned
};
```

- **Tags are enum values**, not Zig types: only the tags the UI actually uses
  (`div`, `span`, ...) plus `.generic`; no per-tag behavior.
- **Attributes** are a small string map. `class` is not interpreted; classes
  are integer IDs into the document's array-backed style table. The class list
  is cascade order and the inline `style` declaration is applied after it.
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

- Every node has a listener list (`addEventListener` /
  `removeEventListener`). A listener is a struct of optional callbacks
  (`key_down`, `mouse_down`, `mouse_move`, `mouse_up`, `click`, `wheel`,
  `focus`, `blur`, `focus_in`, `focus_out`) plus an optional context. There is
  no `Event` base class and no per-type `on*` property. Entries are stable and
  arena-owned: removing a listener marks it removed, so an in-flight dispatch
  keeps walking a valid list and skips the removed entry. Each node snapshots
  its listener count when the dispatch reaches it, so entries appended to that
  node afterwards are not visited by the current dispatch.
- Key, mouse and `focusin`/`focusout` events run capture (root → parent),
  target, then bubble (parent → root). `stopPropagation`,
  `stopImmediatePropagation` and `preventDefault` have the usual meanings for
  key and mouse events; focus events can be stopped but are not cancelable.
  Only `key_down` exists: a terminal reports bytes, not releases or repeats.
  There is no `keyup`/`keypress`.
- `Document.activeElement` is the focused element, falling back to the root when
  nothing is focused (the browser's `body` fallback), so a root listener still
  receives keys before any widget takes focus. `Document.focusedElement()`
  returns the focused element or null, which distinguishes "nothing focused"
  from "the root is focused".
- Mouse events carry zero-based terminal-cell coordinates. `Surface.elementFromPoint`
  solves pending layout, walks the box tree in reverse paint order and clips to
  `overflow: hidden`/`clip`; a text hit reports its parent element, like the DOM
  API. A non-canceled press focuses the nearest focusable ancestor, or blurs.
  Click synthesis, drag state and the wheel's effect stay in the host, as
  TermDOM keeps them in `Input`: the TUI view tracks the press cell, drags a
  selection, clicks the press/release common ancestor, and scrolls three view
  lines per notch. Motion is the all-motion report of mode 1003: button-held
  motion drives drags, and idle motion updates the library's hover target.
  `Document.hoverTarget` and `Node.isHovered` expose the CSS-like inclusive
  ancestor chain, and `Element.hover_style` (a paint-only `HoverStyle`) is
  applied by the painter. The declaration can also set `visibility`, which the
  painter overlays on the hovered element and its descendants so a
  `.parent:hover .child { opacity: 1 }` rule has a terminal equivalent (the
  folding gutter's expanded icons use it). `Surface.updateHoverAt` is the coordinate entry point
  for hosts that hit-test themselves and keeps its pointer cell across a tree
  rebuild. Declarations cascade through `ComputedStyle`, but there is no
  selector engine, no `mouseenter`/`mouseleave` synthesis and no transition;
  hover never dirties layout.
- `Element.focusable` opts a node into focus. `Element.tab_index` follows HTML:
  positive values come first in ascending order, `0` keeps tree order, and
  negative values are programmatically focusable but skipped by Tab. Tab is the
  default action of a non-prevented key event. Focus requires a connected,
  rendered (no `display: none` ancestor), visible element.
- A focused element outside the sequential order (negative tabindex, or a node
  that is not a tab stop) makes Tab use DOM order: it selects the nearest tab
  stop after/before the element in tree order, as the HTML sequential
  navigation algorithm does. A mouse press records a sequential focus starting
  point, so Tab after a press on non-focusable content continues from that
  position instead of restarting at the first stop.
- A focus move dispatches `blur` then `focusout` on the old element and `focus`
  then `focusin` on the new one, with `related_target` pointing at the other
  element. `focus`/`blur` do not bubble or capture; `focusin`/`focusout` do
  both and honor `stopPropagation`. Focus is cleared before the old element's
  blur, so `activeElement` is the root during `blur`/`focusout`; a blur,
  focusout or focus handler that moves focus aborts the pending move, so the
  requested element does not receive `focus`/`focusin` afterwards. The focusin
  path is captured before the target phase, so reparenting a node in a handler
  does not change the ancestors still notified. Removing a focused subtree
  clears `activeElement` silently, as the references do.
- The decoded editor key path is in `codeEditorWidgetTerminalInput.zig`;
  the terminal view implements `IEditorKeyTarget` for focused widget events.
  The host still owns raw input decoding and quit.
- `ui/src/terminal/input.zig` decodes terminal bytes into key and mouse events: printable
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

`ui/src/layout/box.zig` defines `LayoutBox`:

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
`ui/src/layout/text_layout.zig` collects text and atomic inline leaves, renders CSS white
space, finds UAX #14 breaks (`ui/src/layout/linebreak.zig`), builds line boxes and writes
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

`ui/src/layout/text_layout.zig` is the CSS text pipeline: `renderLeaf`/`processWhitespace`
implement the `white-space` family (collapse/trim boundaries, hanging spaces,
tabs, preserving newlines), `findBreaks` wraps UAX #14 opportunities with
`word-break`/`overflow-wrap` and `nowrap`-leaf filtering, and `buildLines` is a
port of TermDOM's binary-search line builder. The full UAX #14 rule set and
Unicode 17 tables live in `ui/src/layout/linebreak.zig`/`ui/src/layout/linebreak_tables.zig`; the
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

The box tree owns invalidation. By default DOM mutation APIs notify the
attached `MutationObserver`; structural, style and text changes set
`needs_rebuild`/`needs_layout`, and the surface rebuilds the derived tree from
the DOM before solving. There is no document-level dirty flag or revision.
Direct writes to public `Element.style`/`Text.style` fields bypass the
observer; use `Node.setStyle`.

A retained view can turn the automatic path off and drive the tree explicitly,
the way WebKit dirties a layout subtree:

```zig
tree.setAutoInvalidate(false);
_ = try tree.addSubtree(node);       // a newly attached line/part node
_ = tree.translateSubtree(node, 0, dy); // a moved line: shift rects/fragments
_ = try tree.rebuildSubtree(node);   // a line whose text children changed
tree.removeSubtree(node);            // a detached line/part
try layout.layoutSubtree(tree, doc, box); // solve one out-of-flow subtree
```

The editor view uses this mode for its retained, windowed line DOM: only the
visible lines have nodes (`ViewLine.dom_node`), a scroll translates the retained
lines instead of rewriting them, and the layout scratch is not reset by a
targeted solve, so clean lines keep their text fragments. Nodes are recycled
through `Document.destroy`/`Node.clearChildren`; the document arena is reset
only when it crosses a bound. Text runs share interned `PaintStyle` objects
(the CSS-class analogue); `Element.pointer_events` is the hit-testing
`pointer-events` analogue for transparent layout containers.

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
| `attrs` | `u16` | bold, dim, italic, underline style (single/double/curly/dotted/dashed), strikethrough, overline, inverse, blink, plus glyph width |
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

Hover is the one live-DOM style input. When an element's box is painted and
`Node.isHovered()` is true, the painter overlays `Element.hover_style` on the
element's merged paint (colors and attributes; `false` clears an attribute,
`border_color` repaints the edge). A hover background fills only the hovered
element's own box; its color and attributes inherit to text and descendants.
Anonymous inline/flex boxes paint from the inherited value directly, because
their style is a copy of their container's style: re-merging that copy would
re-apply the base paint over the hover override. Hover is paint-only by
construction (no geometry or border-width fields), so the box tree and layout
are untouched.

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
- Underlined cells emit SGR `4` and then the ECMA-48 underline-shape
  subparameter when the style is not single (`4:2` double, `4:3` curly, `4:4`
  dotted, `4:5` dashed). Emitting plain `4` first is the fallback for terminals
  that do not implement underline subparameters. `Style.underline_style`
  selects the shape; `underline = false` ignores it.
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
synchronized-output support are `Surface` options. Two terminal capabilities
are probed: `ui/src/render/cell_border.zig` sends the cell-border DCS query followed by
DA1, and `ui/src/terminal/image.zig` sends the kitty graphics/feature queries followed by
DA1. The host calls `Surface.setCellBorders` and
`ui.image.Runtime.setProtocol`. `TIOCGWINSZ`'s `ws_xpixel`/`ws_ypixel` provide
the cell pixel size used for image row counts (defaults 8x16 when a terminal
reports zeros). Mode 2027 and DECRQSS remain later additions. The POC assumes
truecolor and a terminal that accepts synchronized output (both are ignored
safely if not).

### 6.8 Cell borders

The renderer implements the draft cell-border protocol
(`DCS 1 + b cell-border`, version 1) behind a capability probe. On the wire the
`b` final byte is followed immediately by the payload: `ESC P 1 + b` then
`cell-border;...`, with no separator space. The model is in
`ui/src/render/cell_border.zig`: twelve segment bits, a stroke (width in 1/256 cell,
colour, placement, layer, line style, priority), disjoint segment groups, and
an interned set table. `ui/src/render/cell.zig` adds a parallel `u16` id plane to
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
discards the query keeps the glyph rendering. The suggest widget reserves
layout cells for its border. The editor hover keeps its content inset and
can paint a rounded border on the outer cell edges.

The workbench draws one frame around the editor area, following VS Code's
`editorBorder.css`. The sidebar and panel each have a separate frame.
A single editor keeps its frame when the sidebar is hidden. Straight dividers
between groups use `editorGroup.border` and meet at T-junctions in nested splits. Cell-border
terminals draw the frame and dividers on cell edges. The `round` extension
rounds the outer frame corners. The glyph fallback uses rounded box-drawing
outlines and one-cell dividers with junction glyphs. In compact terminals it
keeps the dividers and uses the outer cells for content.
Dragging a sash with the left button updates the split ratio, clamped to a
10-column/3-row minimum. Closing the last tab in a pane removes the group from
the split tree and promotes its sibling, mirroring Grid branch demotion.
On hover and during resize, the sash fills a row or column of cells with
VS Code's `sash.hoverBorder`, which defaults to `focusBorder`. In cell-border
terminals, the highlight uses cells on one side of the shared edge.
Modal dialogs, the breadcrumb picker, editor hovers, and Source Control
commit hovers use rounded cell edges when the terminal advertises `round`
and rounded glyphs otherwise. The `radius` and `outside` extensions control
the arc radius and fill the area outside each corner.
An editor tab drag transfers the selected editors. Dragging the empty
background of a tab strip transfers its whole group. A center drop moves or
merges into the target group, an edge drop places a split on that side, and a
tab-strip drop inserts at the indicated index. The platform's copy modifier is
Alt on macOS and Ctrl elsewhere. The split toggle is Shift on macOS and Alt
elsewhere. SGR mouse input reports Shift, Ctrl and Alt, so Shift range
selection works on macOS and other platforms. Cmd-click selection requires a
mouse protocol that reports Command. The split commands duplicate the
active editor instead of moving it, like `EditorGroupView.copyEditor`: a shared
`EditorDocument` owns the text model, undo stack, language services and
saved/dirty state, while each pane has its own `Editor` view (wrapping,
cursors, scroll and folding). `workbench.action.splitEditor` uses
`workbench.editor.openSideBySideDirection`, and the Left/Right/Up/Down command
variants choose the side explicitly. The editor-group command family uses the
same split tree: focus first/last/next/previous and directional neighbours, add
an empty group on any side, close a group by merging its editors into the most
recently active group, join two or all groups, move a group by detaching and
reinserting its live leaf, duplicate a group by copying every tab into a new
group, move the active editor into an adjacent/target group, and split the
active editor into it. Directional targets are created on demand, like
`moveCopyEditorsToGroup`.

The standalone UI library owns the drag session. It turns mouse reports into
source and target drag events, holds the local transfer and drag image, and
checks the target again on release. Editor drop targets follow the pinned
VS Code layout and use `editorGroup.dropBackground` to tint the destination
cells while preserving text. The floating tab or group label follows the
pointer on the cell grid. Tab insertion uses `tab.dragAndDropBorder` with a
cell-edge stroke or a `▏` block glyph. The tint and floating label work with
both border modes. Escape and terminal focus loss cancel the session. The
drag image, offsets and overlay transitions use whole cells. The transfer is
local to the workbench window.
The full N-ary `Grid` branch model is not ported; the terminal keeps a binary
oriented split tree, which represents the same guillotine tilings.

### Editor tab strip and breadcrumb row

Each editor pane spends one cell row on the tab strip and, when
`breadcrumbs.enabled` is on (the upstream default), a second row on the
breadcrumb bar. The editor content starts below both rows; the pane's outline
still surrounds the whole chrome+content rectangle, and the cursor/mouse
coordinate translation subtracts the same chrome height.

The tab strip is the cell adaptation of `editorTabsControl.ts`/
`multiEditorTabsControl.ts`: the file icon theme is the Explorer's Nerd Font
file glyph and color (one cell plus a gap), preview tabs are italic, the active
tab uses the active background and bold text, and every tab reserves action
space. The active or hovered tab paints `×`; a modified tab paints `●` in the
same cell (hovering it paints `×`). Clicking that cell or middle-clicking the
tab closes it; a dirty
tab first opens the modal save confirmation and `Ctrl-W` takes the same close
path. Double-clicking a preview tab pins it; double-clicking a pinned tab
toggles the group's expanded state (default
`doubleClickTabToToggleEditorGroupSizes: 'expand'`). An expanded
group is laid out over the whole editor area and its siblings are not painted;
toggling it off restores the split from the existing grid rects. Sash resizing
pauses while a group is expanded. An edge drop restores the grid before
retiling. There is no 1px
active-tab top border, horizontal scrollbar, editor actions toolbar, Add Tab
control; the tab context menu opens at the pointer; duplicate labels
use a dimmed description. MultiEditorTabsControl applies the upstream `shorten`
algorithm to paths with duplicate names when `workbench.editor.labelFormat` is default; overflow clips
leading tabs behind a clickable ellipsis that lists them in an anchored menu, and
reveals the active tab. Preview editors come from Explorer single clicks;
Enter/quick open/CLI/session opens stay pinned, and an edit pins a preview.

### Editor close confirmation dialog

`ui/src/widgets/dialog.zig` is the reusable modal message widget. The editor close path
feeds it the VS Code save confirmation built by
`src/vs/platform/dialogs/common/dialogs.zig` and queued by the Workbench DialogService. It follows the native macOS save
sheet from VS Code: a warning glyph above the bold, wrapped
"Do you want to save the changes you made to …?" message, the
"Your changes will be lost if you don't save them." detail, and full-width
buttons stacked vertically. A terminal shorter than the stacked layout turns
the buttons into one row and drops the icon and blank separators; the dialog is
centered, bordered and dims every cell outside its rectangle. Modal extension
messages share the same queued dialog service, with severity-specific glyphs
and the upstream cancel choice. When more choices fit vertically, they stack;
otherwise keyboard navigation brings the focused button into the visible row.

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

During startup the workbench creates the registered activity bar, sidebar,
editor, panel and status bar in the main document, in VS Code’s part order.
Each container receives its role, classes and cell rectangle from the workbench
and layout. The status bar uses a footer. Each editor group mounts its active
pane and watermark under the editor part’s grid.
The terminal window owns the cell surface and its root element. Workbench startup appends its main container under the root. Closing the workbench removes its subtree and leaves the window document available to its owner.

Workbenches can attach registered stylesheet class IDs to the main container
through `IWorkbenchOptions.extra_classes`. Terminal cells supply font metrics.
The side bar, activity bar, panel and status bar still paint separately. Changing `workbench.sideBar.location` repositions the rail, its sidebar sash and the adjacent editor and panel.

### Native context menus

`ui/src/widgets/contextmenu.zig` is the reusable native context menu. It mirrors the item
and popup model from `src/vs/base/parts/contextmenu/common/contextmenu.ts` and
the `NativeContextMenuService` path, not the browser `Menu` widget:
`label`, `type` (`normal`/`separator`/`submenu`/`checkbox`/`radio`),
`accelerator`, `enabled`, `visible`, `checked`, `click`, `submenu`, plus
`x`/`y`/`positioning_item` popup options. Zig cannot express JavaScript
closures, so `ClickHandler` and `OnHide` carry an explicit context pointer next
to the callback. `popup(allocator, items, options, on_hide)` returns a
`*ContextMenu` because the terminal has no OS menu window for the host to
drive.

Editor tabs, the status bar, activity and tab overflow, and terminal menus share
the platform ContextMenuService. The opening press anchors the menu in screen
cells. The service consumes its matching release and restores input routing
before running the selected action. Outline and Source Control resolve pane
menus through MenuService. Registered group titles appear as disabled rows.
The status bar builds its entry actions from the live StatusbarModel.

The menu is deliberately not part of the DOM: it does not enter
`Document.activeElement`, node listeners or tab order. It paints into a host
`CellGrid` after the normal UI and the host routes every key/mouse event to it
while it is open, like `Dialog`. `Surface.renderWithOverlay` is the standalone
`Surface` hook for that compositing step; the workbench path is the same
`renderWithBorderCapabilities(&frame.next, caps)` call used for dialogs and
other native overlays.

Popup levels use one reserved border cell (rounded glyphs or native cell-border
rounding), a check/radio gutter, a right-aligned accelerator, a submenu arrow,
and a selected-row background. Items are copied at popup time, invisible items
are removed, separators are trimmed/collapsed and empty submenus disappear; an
empty root returns `error.EmptyContextMenu`. Tall menus window their rows and scroll with the wheel; `positioning_item`
shifts the popup so that row sits at `y`, then the menu clamps to the viewport.
Submenus prefer the right of their parent item and flip left when needed.

Keyboard behavior follows the native menu conventions: Up/Down wrap over
enabled non-separator rows, Home/End and PageUp/PageDown move within the
window, Right/Enter opens a submenu, Left/Escape closes one level, Escape at the
root dismisses, and Enter/Space activates. Hover focuses a row and opens
submenus immediately, a press/release on the same row activates, a click
outside dismisses, and every event is swallowed while the menu is open.
Activation closes the popup, fires `on_hide` once, then calls the item's
`click` with the modifier event.

Accelerators are display-only and checked state is not toggled automatically;
`deinit` does not fire `on_hide`, so a host that needs the close callback calls
`close` first.
The OS-native menu window, animations, shadows, accessibility,
mnemonics/type-ahead and the submenu delay timer are omitted; a hover submenu
opens immediately. The standalone `example-context-menu` scene is the reference
host implementation, including gallery overlay routing through
`common.Example.overlay`.

`Ctrl-Q` is the terminal equivalent of the window close button and follows
upstream `AbstractCloseAllAction` plus `doCloseAll`: it collects every dirty
tab, reveals one dirty editor per group, and shows one save confirmation for
the whole set. The message names the files (up to ten, then a summary), the
primary action is `Save All`, and `Don't Save` reverts every dirty editor
before closing. A failed save vetoes the quit and leaves the failing tab
active with its error message. Success closes every tab and lets the host
leave the event loop.

The breadcrumb row is the cell adaptation of `breadcrumbsWidget.ts` and
`breadcrumbsControl.ts`. Items are painted left to right with a dim `>` between
them; a file segment starts with the Explorer's Nerd Font file icon (glyph and
color), while folder segments have no icon, matching upstream's `hideIcon`;
focused/selected items are underlined and white, hovered items brighten,
and long paths drop leading items behind `…`. A directory/file click opens an
anchored cell overlay under the clicked item. The terminal overlay uses a
continuous rounded frame in place of the browser context view's border and
CSS pointer. The overlay hosts the ported `BreadcrumbsFilePicker` /
`BreadcrumbsOutlinePicker` `AsyncDataTree`s, so directories and nested symbols
expand and collapse inline with the Explorer's twistie behavior and lazy
directory loading. `Left`/`Right` collapse/expand the selected node,
`Up`/`Down`/`Home`/`End` navigate, `Enter` activates and `Escape` or a click
outside closes it. A symbol click or `Space` calls `IOutline.reveal`. Focus
navigation in the bar is `Left`/`Right`, `Enter`/`Down` opens the tree,
`Space` reveals and `Escape` returns to the editor. `Ctrl+Shift+.` and
`Ctrl+Shift+;` focus the bar; some terminals do not deliver those combinations.

Breadcrumbs can paint the file path while JSON document symbols are pending.
The Outline pane and breadcrumbs subscribe to the shared outline model for the
current model version and provider list. Sticky Scroll makes its own cancellable
provider request as in VS Code. The JSON reader decodes responses off the UI
thread and the main event loop delivers them to the requesting view. Closing
a view releases its subscription. JSON symbol ranges use a per-response index
to convert UTF-16 columns to terminal UTF-8 byte offsets. The breadcrumb picker
retains its tree input so an asynchronous refresh keeps existing rows selectable.

Symbol segments require an `IOutlineCreator` registered with the ported
`OutlineService`. The built-in TypeScript extension and the JSON language
client register document-symbol providers; other languages show the file path
alone until a provider is registered. The breadcrumb model/widget tests
register fake creators to cover the symbol path. The browser editor-type
dropdown, hover tooltips, drag data and symbol-kind filters are not ported.
Creating a short-lived control to paint an inactive group's breadcrumbs is a
terminal adaptation of the browser's one widget per group; it keeps the visible
content correct without a per-group DOM lifetime.

The Outline side panel is the cell adaptation of
`src/vs/workbench/contrib/outline/browser/outlinePane.ts`. It binds to the
active text editor, creates the outline through `OutlineService`, and renders
the `DocumentSymbolsOutline` tree snapshot with the ported `DataTree`, the same
workbench tree component the Explorer uses: indentation guides and twisties,
fold/unfold from the tree, symbol glyphs, marker counts/rollup bubbles,
selection/hover/focus colors, wheel scrolling and Enter-to-reveal. The title
toolbar shows Collapse All or Expand All and More Actions. More Actions opens
the picker for Follow Cursor, Filter on Type, and the three Sort By commands.
Follow Cursor selects the symbol enclosing the cursor. Model content changes reschedule the outline debounce timer. The completed
outline updates the tree and breadcrumbs through `IOutline.onDidChange`.
The view lives in the Explorer view container, stacked under the file tree with
its own collapsible section header, matching upstream `outline.contribution.ts`;
`outline.focus` expands the section and focuses it. Terminal adaptations: tree
state is not persisted, and the find widget's separate input row is not drawn
(typed filter text is appended to the pane's filter).

Limitations of the current wire encoder: it emits solid strokes only, with
square joints, `placement=1` and `layer=0`. `Set` carries joint flags and the
wire encoder carries the line-style and priority fields, but the painter never
sets joints and rounded joints, the `outside` fill, double/dashed/dotted
strokes and shared-edge `priority` are not emitted yet.
Between cells the encoder clears only the segments whose stroke disappears and
then sets the changed groups, so moving along a rectangle edge emits one small
command per cell rather than a full set. Joints are always square, so no joint
state needs clearing.

### 6.9 Terminal images (kitty Unicode placeholders)

The workbench renders images with the kitty graphics protocol's Unicode
placeholders, implemented in `ui/src/terminal/image.zig`. The image is transmitted once
(PNG `f=100`, or raw RGBA `f=32`), a virtual placement declares its
`columns x rows` grid (`a=p,U=1,i=...,c=...,r=...`), and every cell of that grid
is an ordinary one-cell grapheme: `U+10EEEE` plus a row diacritic and a column
diacritic from the kitty table (297 entries, `rowcolumn_diacritics`). The cell's
foreground RGB is the 24-bit image id; the cell background is the pane
background kitty blends transparent image pixels against. Nothing about the
image is stored in the cell planes beyond that normal cluster and colors, so
scrolling, clipping,
compositing and frame diffing work unchanged: a placeholder scrolled out of the
viewport is simply not painted, and a partially visible image uses the full
grid's row/column indices for the cells that remain.

`ui.image.Runtime` owns the id allocator, the pending escape-code buffer and
the cell pixel size. Hosts flush it before the frame body inside the same
synchronized update (`Workbench.render` opens `CSI ? 2026 h`,
writes image commands and the frame diff, then closes it). A view keeps a
`vs/workbench/contrib/mediaPreview/browser/terminalImage.zig` handle: the encoded payload stays in memory so a resize
or `CSI 2J` can invalidate and re-upload the image; zooming only changes the
virtual placement. Image ids are 24-bit because the foreground color carries
them, and placements are capped to the diacritic table's 297 rows/columns.

The capability probe sends a 1x1 graphics query, the 0.50 feature query
(`e=T,U=1`) and DA1. Unicode placeholders are enabled when the feature reply
contains `U=1`; terminals known to implement them but too old for that query
(kitty before 0.50, Ghostty and Rex) are recognized by `KITTY_WINDOW_ID`,
`TERM_PROGRAM=ghostty|rex` or `TERM=xterm-ghostty|xterm-rex`. Rex answers the
feature query with `EINVAL` but is libghostty-based and accepts virtual
placements, so it takes the hint path. There is no direct-placement fallback,
sixel or iTerm2 path: unsupported terminals keep the caller's text fallback
(Markdown alt text or an image-pane message). Input decoding swallows
`ESC _ G ... ST` replies while keeping a bare `ESC _` (Alt+Shift+-) as a key.

The pane/view split mirrors the Markdown contribution: `mediaPreview/common`
validates the path pattern and LFS pointers, `mediaPreview/common/mediaImage.zig`
decodes with the pinned `zigimg` package (PNG passes through; JPEG/GIF/BMP/TIFF
are converted to RGBA and encoded as PNG for the terminal), `imageViewer.zig`
and `imagePreviewEditor.zig` hold fit/zoom/scroll/load state, and
`src/vs/workbench/contrib/mediaPreview/browser/imagePreviewPane.zig` paints the message chrome through a `Surface` and the
image through placeholder cells. Browser-only behavior (clipboard image copy,
context menus, pinch zoom, CSS scrollbars, pixelated rendering) is omitted as
documented in `README.md`.

### 6.10 Mouse pointer shapes (OSC 22)

The pointer is the terminal counterpart of CSS `cursor`. kitty's
[pointer-shapes protocol](https://sw.kovidgoyal.net/kitty/pointer-shapes/)
defines `OSC 22 ; <name> ST`, where `<name>` is a CSS cursor keyword
(`text`, `pointer`, `ew-resize`, `default`, …); Ghostty, foot and recent xterm
builds implement it too. `ui/src/terminal/pointer.zig` owns the names, the encoder and the
deduplicating `State`; it is separate from `ansi.zig` because the pointer is
terminal-global state, not a cell attribute.

Style model: `Style.pointer: ?Pointer` is inherited like CSS `cursor`. The
derived box tree resolves the computed value while building boxes
(`LayoutBox.pointer`), the same way `TextStyle` resolves inherited text
properties. The viewport root starts at `.default`; `null` inherits and an
explicit `.default` overrides an inherited shape. Text and anonymous boxes carry
the container's computed value, so a text hit reports the right shape without a
DOM walk. There is no `auto`: without a browser user agent there is no distinct
automatic shape, and the terminal default is the fallback.

Hit testing: `BoxTree.pointerAt`/`Surface.pointerAt(col, row)` use the same
reverse-paint-order walk, `overflow` clipping and `pointer-events` rules as
`elementFromPoint`. The result is `null` when no box contains the cell.

Emission: the pointer is written only at the top-level writer. `Surface.render`
keeps a `pointer.State` and writes OSC 22 before the frame when
`Options.pointer_shapes`/`setPointerShapes(true)` is enabled and the shape from
`setPointer` differs from the last emitted shape. In the workbench,
`Workbench` owns the `pointer.State` and writes it at the start of `render`.
The shared editor surface resolves pointer style from its layout tree.
`default` is the initial emitted state, so startup writes nothing, and a host
resets to `default` on exit (the TUI does this before leaving the alternate
screen).

TUI resolution: nodes built on the `ui` tree express their shape in `Style`
(editor content `.text`, input boxes `.text`, links/buttons/list rows/status
entries `.pointer`, sashes `.ew_resize`/`.ns_resize`, editor drags
`.grabbing`, `.copy` or `.no_drop`).
Direct-painted chrome (activity bar, tab strip, panel tabs, status bar, sidebar
title, sashes, dialog buttons, quick-pick rows, terminal tabs) has no style
tree; the workbench maps its existing hit-test results to the same shapes in
its mouse handlers. The sash cursors come from the hand-ported `sash_css.zig`
sheet, which also styles the find widget's resize node. For sidebar and editor
sashes the workbench paints the `sash.hoverBorder` color on the divider when
hovered or grabbed. `app.zig` resets the shape to `default` before routing each
mouse move and calls `Workbench.updateMousePointer` for the pane
under the pointer (`Tab.pointerAt` covers the editor, Markdown preview,
image pane and diff widget). A side preview occupies a regular editor group.
Its divider is painted and hit-tested by the editor grid.

No capability probe is added: OSC 22 is out-of-band, has no layout or cell
payload, and terminals that do not implement it ignore the sequence. The
protocol's push/pop stack, support query and X11 cursor-font aliases are not
implemented; only CSS names are emitted. A child application's OSC 22 inside the
integrated terminal panel is parsed by the emulator but not forwarded to the
host terminal.

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
  `bold`, `italic`, `underline`, `underline_style`, `strikethrough`, `dim`,
  `reverse`, `pointer` (inherited CSS `cursor` shape, see §6.10), `z_index`,
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
- Events: `ui/src/dom/event.zig` (keys, mouse, focus, listener dispatch),
  `ui/src/layout/box.zig`/`ui/src/surface.zig` (`elementFromPoint`, `pointerAt`) and
  `ui/src/terminal/input.zig` (the terminal byte decoder, including SGR mouse reports).
  `ui/src/terminal/pointer.zig` encodes OSC 22 pointer shapes; `Surface.Options.pointer_shapes`
  / `setPointerShapes` and `setPointer` drive emission. The preview also handles
  Up/Down, PageUp/PageDown, Home/End and mouse-wheel scrolling, and Ctrl-Q to
  quit.

Library constraints:

- Zero imports from `src/`.
- No CSS parser or selector engine, no HTML parser, no hidden globals.
  `Style` declarations cascade (`Style`/`ComputedStyle`); classes are integer
  IDs into the document `StyleTable`; editor `.css` files are ported by hand to
  sibling `*_css.zig` files and registered in
  `src/vs/editor/browser/editorCss.zig`.
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
  - `src/vs/editor/common/tokenizationRegistry.zig` / a small adapter resolves token metadata to
    `ui.Style` colors and attributes (using the existing token color palette).
- `src/tui/editorView.zig` builds the editor view on the library:
  - Uses the existing `Editor`, `ProjectedViewModelLines`, and `viewLineData`
    to iterate visible view lines.
  - Creates a gutter column (right-aligned line numbers) and a text column; one
    line element per view line, one text node per rendered part.
  - Paints selections with the theme `editor.selectionBackground` and dims the
    covered glyphs (high-contrast themes use `editor.selectionForeground`): a
    cell cannot alpha-composite the browser's selection layer over the text, so
    the background is explicit and the foreground is blended toward it.
    Indentation guides keep the selection background and their guide color. The
    cursor line uses a background and the hardware cursor is moved to the caret
    cell after layout.
  - Shows hidden whitespace like VS Code: the shared line renderer applies
    `editor.renderWhitespace`, whose upstream default is `selection`, so
    selected spaces become `·` and tabs `→` while the selection is active. The
    other modes (`all`, `boundary`, `trailing`) and `none` are honored when the
    setting is present.
  - Turns the cached bracket-matching data into model decorations and paints
    them through `LineDecoration.filter`/`extractWrapped`, the same per-wrapped-
    line route as find ranges. Highlights are hidden while a widget owns focus
    and update on typing or cursor movement.
  - Builds the editor tree as one surface; `Document.clear` rebuilds the tree
    between frames while keeping the previous grid for the diff.
  - The vertical scroll position is the editor's line-granular port of
    upstream `ViewLayout` (`src/vs/editor/common/viewLayout/viewLayout.zig`),
    built on the ported `LinesLayout` and `Scrollable`. It emits upstream's
    `ViewScrollChanged`; `TerminalViewHost.renderViewport` takes the visible
    range from it, and `ViewLines` re-renders only lines dirtied by view
    events. The wheel is routed to the ported `EditorScrollbar` part, which
    applies `mouseWheelScrollSensitivity`/`fastScrollSensitivity` and keeps a
    sub-line remainder (a terminal cannot paint sub-line offsets, so whole
    view lines are applied).
  - Visible-range tokenization is bounded: an incremental scroll tokenizes the
    new lines, an edit walks from the first invalid line, and a jump tokenizes
    the visible range from a guessed start state instead of every line in
    between. The model version guards the forced interval.
  - TextMate background tokenization runs on a dedicated worker thread, like
    upstream's web worker. The renderer keeps pending edits, applies state
    deltas before token blocks, and polls completed results from its main
    loop; the fallback `DefaultBackgroundTokenizer` still handles tests,
    too-large models and tokenizers without a TextMate grammar.
- The workbench status bar is a separate one-row `ui.Surface` owned by the
  ported `StatusbarPart`. `StatusbarPart.render` rebuilds a flex document
  (root row, left `flex_grow` container, right `row_reverse` container with a
  fixed content width, item containers and label containers), paints it, and
  blits the resulting
  grid into the workbench frame's bottom row. The part hashes the model
  revision, width, theme, focus, hover and no-folder state and re-blits its
  last grid when none changed, so an editor scroll does not relayout it. The
  side-bar title and panel title use the same retained-grid scheme. The row
  spans the full window
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
  Not ported: the extension management UI, window-focus/inactive
  backgrounds, auxiliary/scoped status bars, storage persistence of hidden
  entries and codicon rendering.
- `src/tui/editorView.zig` remains the read-only `--preview` variant, adding
  Up/Down, PageUp/PageDown, Home/End and mouse-wheel scrolling.
- Overlay widgets use the terminal adaptation of upstream `IOverlayWidget`
  in `src/vs/editor/browser/editorBrowser.zig`. A widget reports its size in
  cells, builds a `ui` subtree each frame and is anchored to a corner
  (`top_right_corner`, `bottom_right_corner`, `top_center`, and the terminal
  `top_left_corner` used by sticky scroll); the view restores focus after every
  rebuild. Sticky rows paint after the text lines and before the find widget,
  and the hardware cursor is hidden when its cell is covered by an overlay. `View.dispatchKey` forwards decoded keys through
  the widget document first, so a focused widget owns the keyboard.
- Quick open is a workbench-level overlay, not an editor overlay. The
  controller (`src/vs/platform/quickinput/browser/quickAccess.zig`) owns one
  persistent `QuickPick` model and selects a provider from
  `src/vs/platform/quickinput/common/quickAccess.zig`; the terminal view
  (`src/vs/platform/quickinput/browser/quickInputList.zig`) renders the input row with a one-row `ui.Surface`
  and paints the list rows directly into the workbench grid. The workbench
  composites it after every pane and the tab strip, and hides the hardware
  cursor while it is open. `Ctrl-P` opens Go to File, `>` switches to the
  command provider, and `F1` executes Show All Commands through the workbench
  keybinding service. `Alt-P` also opens the palette on terminals where
  `Ctrl-Shift-P` sends the same bytes as `Ctrl-P`. While a picker is open,
  `Ctrl-N`/`Ctrl-P` select the next/previous item (the terminal form of the
  macOS quick-pick bindings; arrows, pages and Ctrl-Home/End work as well), and
  the chord never reaches the filter input. Go to File uses a dedicated worker
  thread (`src/vs/workbench/services/search/node/fileSearchWorker.zig`) that
  spawns one `rg --files` per picker session and streams the listing into an
  owned path cache. Keystrokes queue a filter; the worker applies the ported
  `isFilePatternMatch` rules and `fuzzyScorer.scoreItemFuzzy`, and publishes at
  most 512 owned results. The event-loop thread only copies a published result
  into the picker arena, so the input, rendering and terminal output keep
  running while a large checkout is listed or scored. `files.exclude`,
  `search.exclude`, the `search.useIgnoreFiles`/`useParentIgnoreFiles`/
  `useGlobalIgnoreFiles` settings and `search.followSymlinks` are read through
  the same query/exclude helpers as text search. `rg` must be on `PATH`; a
  missing binary is reported once through the picker error path. The rounded
  popup uses native cell borders when supported and rounded line glyphs
  otherwise. After 800 ms of continuous work the picker animates a four-second
  progress sweep along the bottom of the input. Plain terminals use a colored
  underline. Overflowing lists reveal a proportional, draggable scrollbar on
  hover and scroll. Inline group labels, shortcut keycaps and row buttons share the
  trailing edge. File rows reuse the Explorer icons. The command gear opens
  the terminal profile's keybindings JSON and searches for the command ID.
  Virtualized lists, symbol/go-to-line/link
  providers and the browser `fuzzyScorer.ts` path-aware scorer are not ported.
  macOS Unicode normalization is not ported. The Search view's text search uses
  the same `rg` prerequisite: open buffers are searched synchronously by the
  editor matcher, workspace folders stream through `rg --json` on a bounded
  worker, and parser context events are stored on `FileMatch` like upstream
  `surroundingContext`.
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
- Block decorations are ported from
  `src/vs/editor/browser/viewParts/blockDecorations/blockDecorations.zig`.
  The view part computes the upstream `blockClassName` ranges and the
  `blockIsAfterEnd`/`blockDoesNotCollapse` branches in scrolled rows; the
  terminal compositor paints each block as an absolute cell layer under the
  text. Upstream's CSS-defined look becomes a terminal style rule:
  `movedOriginal`/`movedModified` use `diffEditor.move.border` and
  `currentMove` uses `diffEditor.moveActive.border`, drawn as a one-cell
  border instead of the browser's 2 px border. Unknown block classes stay
  invisible, just as an upstream class with no CSS rule does.
- `workbench.editor.showTabs` none/single can hide the tab row; the reclaimed
  row becomes editor content.
- The find widget reserves 1-2 top rows as a terminal view zone when
  `editor.find.addExtraSpaceOnTop` is enabled; text/hit testing start below it.
- The scroll decoration is a one-row `scrollbar.shadow` tint on the first text
  row after scrolling (no alpha/blur in a cell grid).
- Configured `editor.rulers` paint one-cell vertical guides in empty cells;
  a cell cannot show both the ruler and a text glyph.
- Glyph-margin decorations are ported through
  `src/vs/editor/browser/viewParts/glyphMargin/glyphMargin.zig`. The terminal
  reserves one cell per compacted `GlyphMarginLanesModel` lane (up to three)
  only while a `glyphMarginClassName` decoration exists, maps the known
  error/warning/info/breakpoint classes to cell glyphs and reports
  `gutter_glyph_margin` hit targets. DOM glyph widgets, CSS icon fonts and the
  hover message is rendered as a one-line content-widget tooltip on hover.
- Folding is applied at the view-model boundary:
  `src/vs/editor/contrib/folding/browser/folding.zig` computes indentation
  ranges, keeps collapse state and produces hidden model-line ranges;
  `ProjectedViewModelLines.setHiddenAreas` marks those projections invisible
  and updates the prefix sums, and the converter maps positions on hidden
  lines to the preceding visible line. `src/tui/editorView.zig` paints the last
  gutter cell as `▾`/`▸` and makes it a `GUTTER_LINE_DECORATIONS` hit target;
  clicking it toggles the region. The first visible line of a collapsed region
  gets the upstream `…` suffix. The editor binds `Ctrl-Shift-[`/`]`,
  `Ctrl-K Ctrl-L`, `Ctrl-K Ctrl-0` and `Ctrl-K Ctrl-J` and registers the
  corresponding `editor.fold*`/`editor.unfold*` commands in the workbench.
  Syntax providers, folding decorations/CSS and folding view state are not
  ported. Fold state survives edits on the folded line; line
  insertions or deletions above a collapsed region re-expand it because there
  are no tracked folding decorations to shift the range.
- Sticky scroll is ported from
  `src/vs/editor/contrib/stickyScroll/browser` and painted as an editor overlay
  (`stickyScrollHost.zig` in that contribution owns the editor/view-model adapter;
  the terminal view supplies paint and focus callbacks). It is not a CSS
  `position: sticky` element: like upstream, the controller computes the
  enclosing outline/folding scopes from the scroll position and the widget
  paints them above the text. Candidate providers are the document-symbol
  outline (largest provider range-sum) and indentation folding; the syntax
  folding provider has no terminal registry. The widget is anchored
  `top_left_corner` (a terminal addition to the overlay preference enum), spans
  the editor width minus the scrollbar, and reports one cell per sticky line.
  It paints line numbers, syntax-colored `ViewLine` content and fold glyphs,
  handles normal click (reveal scope line), Shift-click (reveal the line after
  the scope), fold-icon clicks, hover/shift-hover and focused-row keys
  (Up/Down/Enter/Escape). The 25% viewport cap and `editor.stickyScroll.*`
  settings are read through the terminal configuration; the model rebuild uses
  one 300 ms scheduler ticked by the app and runs synchronously on the UI
  thread (the debounce coalesces edits but does not cancel a provider call). Because terminal scrolling is in
  whole cells, a scope whose header is still the first visible row is not
  duplicated. `stickyScroll.scrollWithEditor` translates the sticky content
  layer by the editor's horizontal offset. No CSS border/shadow, context menu,
  go-to-definition from a sticky row or embedded-editor peek styling is
  ported.
- Indentation guides are owned by the ported `IndentGuidesOverlay` in
  `src/vs/editor/browser/viewParts/indentGuides/indentGuides.zig`, which runs
  upstream's `prepareRender`/`render` overlay lifecycle against the view
  model's `getLinesIndentGuides`, `getBracketGuidesInRangeByLine` and
  `getActiveIndentGuide`. Like upstream it requests `visibleEndLineNumber + 1`,
  so a bracket pair closing just below the viewport still draws its guide on
  the last visible line. The model-side counts come from
  `src/vs/editor/common/model/guidesTextModelPart.zig`, including the upstream
  blank-line rule that inherits from the surrounding content; the view-model
  queries in `viewModelLines.zig` repeat/block those counts across wrapped
  lines. The terminal compositor maps the guide class names to colors and
  paints a dim `│` at each `(level - 1) * indentSize` view column inside the
  leading whitespace. This follows Flow's whitespace-indent glyph. Indent guide
  colors follow upstream's cycled `editorIndentGuide.background1..6` /
  `activeBackground1..6` pools; because the default themes only define level 1,
  the guides are a single gray unless a theme opts into per-level colors.
  Bracket-pair guides use
  `editorBracketPairGuide.background1..6` / `activeBackground1..6` when the
  theme defines them, and otherwise derive from the same-level
  `editorBracketHighlight.foreground1..6` color at 30% opacity (inactive) or
  full opacity (active pair), matching upstream. The indentation scope around
  the caret is painted with the active indent-guide color. A guide is only
  painted in a leading-whitespace or blank cell, because one terminal cell
  cannot show both a guide and a text glyph. When `renderWhitespace` renders a
  selected space (`·`) or a one-cell tab (`→`), the guide paints over the
  marker and keeps the shared cell. A wider tab keeps the guide at its first
  cell and repeats the arrow in the next padding cell, so the guide stays
  visible and the tab remains indicated. Horizontal bracket guide segments are
  therefore not painted, and wrapped continuation rows do not paint guides in
  the terminal compositor even though the view-model query returns their
  blocked counts. `editor.guides.*` settings are not mapped by the terminal
  configuration reader yet; the terminal keeps indentation and bracket-pair
  guides enabled with horizontal segments off.
- Visible whitespace (`renderWhitespace` `all`/`boundary`/`trailing`/
  `selection`) is produced by the shared line renderer as upstream
  `mtkw`-style runs: a space becomes `·`, a tab `→` plus its padding, and the
  run carries no token metadata. The view paints every whitespace run with
  `editorWhitespace.foreground`; when the theme does not define that id, the
  default foreground is dimmed over the editor background instead of inheriting
  the neighboring token color, so all whitespace cells share one subdued
  color.
- Find, bracket and word ranges are stored in the model as `TextModel`
  decorations (`findMatch`, `currentFindMatch`, `bracket-match`,
  `wordHighlight*`). `View.ModelDecorationSink` replaces each contribution's
  owner ID directly against the model; the view's bracket pass does the same.
  The rebuild reads the model's inline and overview-ruler decorations back
  through `getLineDecorations` / `getOverviewRulerDecorations`. This gives all
  contributions one range tracking and z-order path. Bracket colorization is
  the model-wide provider on the same path: its `bracket-highlighting-N` and
  `unexpected-closing-bracket` inline classes are resolved to cell foregrounds
  from `editorBracketHighlight.foreground1..6` /
  `editorBracketHighlight.unexpectedBracket.foreground` at the paint boundary,
  instead of through CSS. The view prepares the bracket AST before resolving
  these decorations, and the AST change event invalidates the resolved
  decoration cache.
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
  names. They are `className` decorations, not inline classes, so the view
  paints them through the ported `DecorationsOverlay`: the overlay maps each
  marker range with `RenderingContext.linesVisibleRangesForRange` to visible
  cell ranges, and `TerminalViewHost` turns those ranges into the same cell flags
  `ViewLine` uses for inline classes. Error/warning/info ranges get a curly
  underline in `editorError`/`editorWarning`/`editorInfo.foreground`, hints get
  a dotted underline, unused code is dimmed with a dashed underline, and
  deprecated ranges are struck through. The underline shape is emitted as SGR
  `4:2`/`4:3`/`4:4`/`4:5` after a plain `4`, so terminals without ECMA-48
  underline subparameters fall back to a single underline. A collapsed marker
  at or past the last rendered glyph paints a styled trailing space cell so the
  underline remains visible; trailing cells are clipped to the text-area width.
  The translucent `editorError.background`-style range backgrounds are not
  painted (the default themes leave them unset). The existing overview-ruler
  lane carries the marker color. Hovering a marker range, or pressing `gh`
  with the caret inside one, shows the diagnostic message in the content hover
  through the marker hover participant. The workbench
  `status.problems` entry shows workspace-wide error/warning/info counts from
  `MarkerService.getStatistics()`, and the Problems panel view groups
  markers by file with selection, preview/open and scrolling. Selecting a
  marker previews its range in the editor and paints the upstream
  `rangeHighlight` background while Problems owns focus; Enter opens the range
  and focuses the editor. Problems is registered at
  `ViewContainerLocation.Panel` like upstream, so it opens in the bottom panel
  beside the terminal; the panel part (`parts/panel/panelPart.zig`) builds the
  one-row composite bar as a `ui.Document` element tree in a one-row
  `ui.Surface` (the same DOM-to-cells path as the status bar), the Problems
  tab carries the error/warning badge and `hideIfEmpty` drops the tab while
  the container is empty and inactive.
  Filters, table/tree mode, related information, quick fixes and file
  decorations are not ported. The minimap metadata produced by the marker
  decorator is ignored.

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
  no HTML/CSS engine, so links show their URL in dim text, hover images show
  their alt text, tables render as width-capped box-drawing grids, and raw HTML
  is ignored. The Markdown *preview* adds local image blocks through the kitty
  placeholder path described in §6.9. Nested/task lists, setext/indented code, autolinks and reference
  links are supported; wide table rows are clipped to the hover width. Fenced
  code blocks use the editor's TextMate tokenizer: the fence info string is
  resolved through common aliases, a missing language falls back to the editor
  model language, and unknown languages render plain. Their background comes
  from the theme's `textCodeBlock.background`; without that entry the code
  spans are transparent so the hover/preview surface shows through.
  The marker participant (`markerHoverParticipant.zig`) resolves each marker
  decoration through `MarkerDecorationsService.getMarker` and renders the
  severity glyph, the diagnostic message (including embedded newlines) and a
  dim `source(code)` line. Marker quick fixes, related-information links and
  the "View Problem" status-bar action are not ported: the marker model has no
  related information and the TUI has no code-action controller. Hovering a
  squiggle and the keyboard `gh` command both show the marker message.
- `ui/src/widgets/inputbox.zig` is the terminal single-line input: UTF-8 buffer,
  `(anchor, cursor)` selection with keyboard/mouse extension and selection
  paint, shell-like word movement/deletion, Ctrl+A, clipboard hooks
  (`on_copy`/`on_paste`; the library does no clipboard IO), snapshot
  undo/redo, caret-follow horizontal scrolling with wheel and drag-edge
  scrolling, enable/disable, and the upstream
  `select`/`getSelection`/`isSelectionAtEnd`/`insertAtCursor` shape.
  The focused caret is a `│` glyph that occupies one cell between characters.
  Up/Down and Tab stay host-owned; the find widget owns its search
  history, other input validation/history stays host-owned, and action bars
  remain host concerns. Terminal limits: no double-click word
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
  the view and syncs the hardware cursor after each frame; a viewport change
  resizes the `ui.Surface` in place and discards only the line window, while
  the retained chrome roots survive. The terminal runs in mouse mode 1003 with SGR coordinates (1006), so
  press, release, idle/button-held motion and wheel arrive as `ui.MouseEvent`s.
  `View.dispatchMouse` hit-tests, applies press-to-focus, places the caret
  (Shift extends), drag-selects, synthesizes the release click on the common
  ancestor and scrolls three view lines per wheel notch. Clicking a find input
  focuses it and places the byte caret; the option toggles (`Aa`, `ab`, `.*`,
  `Sel`) and `All` highlight on idle hover and run their action on click while
  keeping input focus. Clicking the editor blurs the bar without closing it.
- The right edge reserves two text cells for the 1.5-cell overview-ruler and
  scrollbar strip. `decorationsOverviewRuler.zig` ports the upstream scaled
  `y1`/`y2` projection and z-order paint rules, but writes cell rows instead of
  canvas pixels. Each row is split into two half-cells, so the projection keeps
  half-row precision: a marker edge can land on the upper or lower half of a
  row and is painted with the lane's half block or a quadrant (`▘`/`▖` for the
  center lane, `▝`/`▗` for the left and right lanes). A marker that would be
  smaller than a row is one half-cell tall. A row represents a range
  of document lines when the document is taller than the track, and lanes
  collapse onto the cell halves. The view supplies markers from find, the
  current find match, bracket matches with the overview-ruler option, word
  occurrences and cursor positions. The thumb is painted afterwards in the
  same cells as a foreground block glyph, so it covers the markers on its
  rows. This follows Flow's vertical-scrollbar rendering technique: a plane
  erased to the editor background and then a single glyph, with no background
  run at the terminal edge (the terminal equivalent of the browser's
  overlapping slider and ruler layers). `ScrollbarState` is ported from
  `base/browser/ui/scrollbar` and drives a 1.5-cell-wide slider with a
  one-row minimum; the thumb paint uses its exact fractional position and
  size quantized to half cells, and its mouse hit box covers every row the
  painted thumb touches. Click, thumb drag and wheel still use the upstream
  rounded offset/delta math at row resolution. A row shares one
  foreground color, so markers are hidden on the cells the thumb covers.
  Cells have no alpha, so the marker colors are composited over the dark
  editor background. There is no minimap, horizontal scrollbar, pixel-lane
  width, border or smooth scrolling.
- Gutter width follows the existing `gutterWidthFor` logic; line numbers are
  right-aligned with `text_align = .right`.
- Text soft-wraps at the terminal width by default. `editor.wordWrap` is
  honored (`off`, `on`, `wordWrapColumn`, `bounded`, plus `wordWrapColumn` and
  `wrappingIndent`); `off` removes soft wrapping and the line content becomes a
  horizontal `ui.ScrollView` viewport. Wheel/Shift+wheel and the `scrollLeft`/
  `scrollRight` commands scroll it, the caret and reveal paths keep the cursor
  visible, and cursor/mouse/content-widget coordinates subtract the offset.
  There is still no horizontal scrollbar.
  The line-break computer reads the model's last-visited line. The terminal
  dispatches each decoded sidebar mouse move to the sash in input order.
- The old `src/tui/screen.zig`/`render.zig` path is gone.
- Multi-file editing keeps one `View` per tab. The workbench mounts the visible
  editor instances in a single editor document. The portable
  editor-part layers live at their upstream paths:
  `src/vs/workbench/browser/parts/editor/editorPart.zig` owns the group
  registry, grid and sash resize; `editorGroupView.zig` maps model editors to
  tab views and drives the active pane; `editorPanes.zig` keeps the active pane
  and page position. `src/tui/workbench.zig` composites the parts, paints cell
  borders and sashes, and sends image data, the ANSI frame and the hardware cursor
  position to the terminal. The browser workbench still owns part input routing
  and synchronizes the editor DOM. `EditorGroupModel` owns
  tab order/MRU/preview/pinned/sticky state, `FileEditorInput` exposes each
  editor's path/dirty/save state, and `Tab` keeps one persistent
  view/contribution set per file. The terminal grid gives each split leaf an
  absolute cell rectangle in the shared document. `Surface.paintInto` then
  paints the editor tree into the workbench frame. Text and diff views hit-test
  against that same tree, and wheel listeners run through DOM propagation.
  Each tab keeps its scroll position and decorations while detached. The
  standalone preview uses its own document. Workbench title chrome, shell
  parts, the terminal emulator and image/Markdown preview output use their
  existing cell painters. Group state is serialized
  through the workbench editor serializer registry. The session stores the
  editor grid with group models at its leaves, the active group ID and the
  most recently active groups. Saved branch sizes are in cells and scale to
  the restored viewport. Older group-list sessions use horizontal splits. Dirty working copies are not persisted.
- Workspace roots come from the portable `Workspace` /
  `WorkspaceContextService` models (`src/vs/platform/workspace/common/` and
  `src/vs/workbench/services/workspaces/common/`). The CLI classifies directory
  arguments as workspace folders and file arguments as initial editors;
  `ExplorerModel` creates one root per workspace folder. The workbench starts
  with an empty editor group when only a folder is opened.
- The editor group watermark uses retained terminal UI nodes for its centered
  cell artwork and shortcut rows. The sole empty group shows three actions
  with resolved terminal keybindings, updated when the user keymap reloads.
  Short panes keep the rows when the full logo would exceed the viewport.
  Empty split groups show the artwork alone when it fits. The browser SVG,
  toolbar and randomized tips are replaced by cell artwork and a fixed list.
- The Explorer sidebar is a terminal tree view
  (`src/vs/workbench/contrib/files/browser/views/explorerView.zig`) over `ExplorerModel`/`ExplorerItem` from
  `src/vs/workbench/contrib/files/common/explorerModel.zig`: lazy directory
  resolution, directories-first ordering, expand/collapse, selection and
  scroll. A single-folder workspace uses the folder as the tree input, so its
  children are top-level rows; multi-root workspaces show roots and expand the
  first five by default. Directory listings resolve symbolic links to the
  target file type like upstream `DiskFileSystemProvider.readdir`, so a linked
  directory expands and its files open through the link path; a dangling link
  stays an unknown entry. Filtering runs through the upstream-shaped
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
  file opens it through the async workbench open path. Directory resolution is
  lazy and asynchronous (`ExplorerDataSource`). The
  Explorer now renders through the ported list/tree view layer
  (`rangeMap` + `ListView`/`ListWidget` + `IndexTreeModel`/`ObjectTreeModel` +
  `CompressedObjectTreeModel` + `AbstractTree`), including virtualization,
  branch-local compressed child updates and unit-row list-splice fast paths,
  wheel scrolling, collapse state and `explorer.compactFolders`. The
  `CompressibleObjectTree` adapter renders a compressed path as one
  `a/b/c` row, and object/index/synchronous-data tree view adapters are ported
  too. Rows paint Nerd Font folder/file glyphs
  (`src/vs/workbench/services/themes/browser/fileIconThemeData.zig`), the terminal adaptation of
  `workbench.iconTheme`: there is no SVG/image layer, so a Nerd Font configured
  in the terminal supplies the icons. Indent guides follow
  `workbench.tree.renderIndentGuides` (`none`, `onHover`, `always`; default
  `onHover`) and `workbench.tree.indent` is counted in cells (default 2).
  Tree sticky scroll is ported from the generic tree view
  (`src/vs/base/browser/ui/tree/abstractTree.zig`): the controller pins the
  ancestors of the first visible row, `CompressibleStickyScrollDelegate`
  merges an overflowing ancestor chain into one compressed row, and
  `workbench.tree.enableStickyScroll` / `stickyScrollMaxItemCount` select the
  behavior. Sticky rows are overlays painted after the list rows through the
  same renderer, so they keep indentation, twisties, icons and compressed
  labels. They use a distinct header tint (`sideBarStickyScroll.background`,
  falling back to `sideBarSectionHeader.background` and then a derived shade)
  so they are visible on every terminal; when the host reports cell-border
  support, the last pinned row also gets a `sideBarStickyScroll.border` bottom
  border as a cell attribute, which costs no row. Without the protocol the
  bottom pinned row is underlined across its cells instead, so the separator
  still costs no row. The probe result (`supported`, protocol version and
  feature mask) is written to the log as `cell borders: ...`. There is no retained overlay or scroll event in the terminal view,
  so the pinned state is recomputed before every paint. Clicking a pinned row
  reproduces upstream's `handleStickyScrollMouseEvent`: the tree scrolls the
  node below the remaining sticky rows and selects it; a click on the row's
  twistie toggles the folder. Model splices restore the selected row without
  revealing it, so selecting an already-visible file does not move the
  viewport. Terminal rows are whole
  cells, so the upstream pixel-level slide-out clip becomes "paint the whole
  row or hide it"; the hover/focus
  outline becomes the list hover background (bold while focused). `Tab` enters
  the widget (the terminal stand-in for DOM tab order) and `Escape`/`Tab`
  leave it; Up/Down/Enter/Space/Left implement the upstream
  `list.stickyScroll*` bindings. The sticky widget is read at Explorer
  construction rather than live-updated from a configuration change, like the
  other Explorer tree settings.
  The async data tree (`AsyncDataTree`/`CompressibleAsyncDataTree`) and the
  Explorer data source are ported: a directory's children are requested from
  `Io.async` only when the tree needs them, and each completed listing wakes the window
  to apply the children and resume a pending reveal. Identity-aware smart splicing is ported
  through the object/compressed tree models. Loading placeholders, Explorer
  file drag/drop and the compressed-label navigation controller (per-segment
  focus/hover) are not ported. The side-bar divider is a draggable part splitter, separate
  from Explorer file drag/drop.
  The activity bar is split into the ported model
  (`src/vs/workbench/browser/parts/activitybar/activitybarPart.zig`), the
  activity service model
  (`src/vs/workbench/services/activity/browser/activityService.zig`) and the
  terminal view (`src/vs/workbench/browser/parts/activitybar/activitybarPart.zig`). The Search activity shows a badge
  dot while matches are present (the exact count is in the panel); the service
  also supports view and global badges. It switches fixed Explorer, Search and
  Source Control containers. There is no Settings container: upstream's
  Settings entry is the activity-bar gear action whose Settings item opens the
  Settings editor as an editor tab, not a view container, and the port has no
  Settings editor.
  Problems is not an activity-bar container: it lives in the panel
  (`ViewContainerLocation.Panel`) like upstream. The model owns activity
  order, visibility, the active container and compact width. Containers are
  declared in the ported view-container registry
  (`src/vs/workbench/common/views.zig`) and placed through
  `ViewDescriptorService`; live file-change refresh, resizing and context
  menus are not ported, and there is no extension contribution point yet.
  `workbench.activityBar.location` (`default`/`top`/`bottom`/`hidden`),
  `workbench.activityBar.autoHide` and `workbench.activityBar.compact` are
  applied by `LayoutSettingsValues` in
  `src/vs/workbench/services/layout/browser/layoutService.zig`; the defaults
  live in `src/vs/workbench/browser/workbenchConfiguration.zig`. For
  `top`/`bottom` the rail is hidden and the activity items become a one-row
  icon composite bar in the side bar header/footer. The rail stays when the
  side bar is closed, and an entry click reopens it.
- The side bar sash uses SplitView's drag-start sizes, snap threshold and
  cached visible width. Horizontal workbench minimums follow the existing
  scale of 17 CSS pixels per terminal column, rounded up. The side bar needs
  10 columns, each editor group needs 13, and a visible bottom panel needs 18.
  Glyph borders and split gutters take additional cells. Double-click fits the
  visible Explorer labels, including their indentation and compressed folder
  paths. Source Control requests 24 columns and Search uses the 18-column
  preferred-width floor. Alt-drag uses the upstream last-sash bounds. Terminal
  mouse reports carry modifier changes on pointer motion.
- The primary side bar is a ported pane-composite part
  (`src/vs/workbench/browser/parts/sidebar/sidebarPart.zig`), mirroring the
  panel: `SidebarPart` keeps the pane-composite registry, width/position/
  visibility, the active viewlet, the `workbench.contributions.viewlets`
  registry id and the activity bar position, while `PaneCompositePart` (shared
  with the panel) carries the title label, the title toolbar actions and the
  composite bar position (`top`/`title`/`bottom`). The title row is one cell
  built with the `ui` DOM and painted through a `ui.Surface`, so the part owns
  the `EXPLORER`/`SEARCH`/`SOURCE CONTROL` label (uppercased like
  `text-transform: uppercase`) and its actions; the Explorer, Search and SCM
  views render below it with `show_header = false` instead of painting their
  own section headers. Title colors come from `sideBarTitle.*`; the
  top/bottom composite bar uses `activityBarTop.*`. The Search toolbar runs
  `search.action.clearSearchResults` and
  `workbench.action.search.toggleQueryDetails`; the SCM title toolbar refreshes
  the provider and toggles list/tree mode. The Explorer title/file actions are
  not ported as commands. `Ctrl-0` focuses the side bar,
  `workbench.action.closeSidebar` hides it and
  `workbench.action.previousSideBarView`/`nextSideBarView` cycle the visible
  containers. Not ported: the 35 px title metrics and its 1 px theme borders
  (a cell row and the workbench dividers replace them), view title context
  menus, the title toolbar overflow/"More Actions" menu, `focusActivityBar`,
  `workbench.activityBar.iconClickBehavior`, the
  toggle-activity-bar-visibility action, the right-hand side bar position, the
  and the `workbench.sidebar.activeviewletid`
  storage persistence.
- The Search panel is split into a portable search service/tree and a terminal
  view. `searchService.zig` searches open/dirty editor buffers synchronously
  through the host callback and the ported regex/word matcher, then delegates
  workspace files to `ripgrepTextSearchEngine.zig`/`textSearchWorker.zig`
  (`rg --json`) on one bounded worker thread. The worker streams per-file
  matches and surrounding-context rows. A POSIX pipe or Windows event wakes the
  window when results or completion are ready. The requesting sidebar or Search
  Editor receives its batch on the main thread. Debounced edits set a deadline
  in the same wait loop. The main thread applies query filters
  and publishes owned results. `glob.zig` provides the pattern language used by
  the query filter: `**`, `?`, `{}` groups, `[...]` character classes,
  `trimForExclusions`, `ignoreCase` and `!` exceptions. `.gitignore`/`.ignore`
  filtering is left to ripgrep for workspace files; the Explorer still uses
  `ignoreFile.zig` for its own tree. `searchTreeModel` ports the result
  hierarchy, replacement pattern and change events, and stores context rows on
  `FileMatch` like upstream. `queryBuilder.zig` builds the text query and
  `searchService.zig` applies `files.exclude`/`search.exclude` through the
  ported glob expression, including `false` entries, `!` exceptions and
  `{ when: ... }` sibling clauses.
  `src/vs/workbench/contrib/search/browser/searchView.zig` is the portable view
  controller (query lifecycle, focus state, counts/messages and replace-all
  request/execute); `searchResultsView.zig` owns the data source, ordering,
  row labels and accessibility labels; `searchCompare.zig` and
  `searchActions*.zig` port the comparers and action helpers.
  `src/vs/workbench/contrib/search/browser/searchWidget.zig` renders the input/replace/details rows on a
  `ui.Surface` with the hand-ported `media/searchview_css.zig` classes.
  Input boxes use one text row, and rounded outlines use native cell borders
  when the terminal supports them. The replace-all request uses the workbench
  modal dialog. `src/vs/workbench/contrib/search/browser/searchViewTerminal.zig`
  owns focus routing and paints the upstream row parts into the result window.
  Tree guides align with each ancestor chevron. They use centered cell
  strokes or vertical glyphs and follow the tree guide setting. The renderer
  maps text overflow to cell-width ellipses.
  **Open in editor** opens a pinned Search Editor. Its query controls share the
  Search widget, including context lines and file filters. The pane runs an
  independent search and updates the generated, read-only result model using
  the bundled Search Result TextMate grammar. Opening a result uses the file
  path and source line from the serialization. The result editor uses the
  terminal scrollbar. The browser minimap and saved Search Editor backing
  files are outside this port.
  After an individual replacement, the workspace provider refreshes positions
  for the remaining matches, including matches in closed files.
  Completed match selections write a `rangeHighlight` model decoration through
  `View.setSearchHighlights`. Remaining gaps are the browser tree's
  compression/virtualization, multi-selection, drag/drop, context menus,
  clipboard/history storage, AI/notebook/search-editor results, compressed
  folder chains, search-path expansion and Settings view.
- Configuration lives in
  `src/vs/workbench/services/configuration/browser/configurationService.zig`,
  over the platform `configuration.zig`, `configurationModels.zig` and
  `configurationRegistry.zig` ports. It reads defaults, the VS Code profile's
  `User/settings.json`, the TUI profile's `<user-data-dir>/User/settings.json`,
  the workspace file's `settings` object and each folder's
  `.vscode/settings.json`, with folder > workspace > terminal user > VS Code
  user > defaults precedence. `src/tui/vscodeProfile.zig` discovers the layers:
  the stable VS Code `Code/User` path has no override, and the TUI user data
  dir follows upstream `userDataPath.ts` (`VSCODE_PORTABLE`, `VSCODE_APPDATA`,
  `--user-data-dir`, then the platform application-data directory). Settings
  JSON accepts comments and trailing commas. The service exposes `getValue`, `inspect`, `keys`, `reload` and a
  change emitter; `getValue` resolves `[language]` override identifiers.
  Settings subscribe to changes from the shared file service. Its worker uses
  inotify on Linux, kqueue for individual files on macOS and overlapped
  `ReadDirectoryChangesW` on Windows. The recursive macOS watcher uses FSEvents.
  The same watcher covers the user keybinding files, so editing them reloads the
  workbench. Not ported in this configuration-service port:
  - `updateValue` and settings editing; these need the JSONC-preserving
    configuration-editing service, which is not ported;
  - policy, application, remote and profile scopes; the corresponding
    services do not exist in the terminal workbench;
  - trusted-workspace filtering and restricted settings; there is no
    workspace-trust service;
  - the browser Settings editor/view; with it, the activity-bar gear's
    Settings entry is unported, so settings are edited through the JSON file.

- User keybindings live in `src/vs/workbench/services/keybinding/browser/userKeybindings.zig`,
  over the ported `base/common/keybindingParser.zig` and
  `workbench/services/keybinding/common/keybindingIO.zig`. The VS Code profile
  file is the base layer and the terminal file overrides it; JSONC, platform
  key variants, chords, `when`, `args` and `-command` removals all follow the
  upstream reader. The workbench owns one `ContextKeyService` and passes its
  focus keys to the global host, appends the user items as resolver overrides
  (last match wins, matching user-over-default priority) and passes the removal
  items to every host so `KeybindingResolver.handleRemovals` subtracts the
  affected defaults. The settings watcher rebuilds the hosts and the per-editor
  shortcut hosts on change. User commands that the terminal does not register
  are filtered out (documented deviation) so they cannot swallow typing.
  The `list.*` navigation ids are registered as a bridge that synthesizes the
  matching list key for the focused Explorer/Search/Source Control view.
  Extension-contributed keybindings remain unported.

- Color themes are registered from the `theme-defaults` declarative scan and
  from `extensionsRegistry.scanThemes` over the profile/TUI extension roots,
  keyed by the contributed theme settings id. `ThemeService` loads JSONC theme
  files (and include chains) from the extension root, applies
  `workbench.colorCustomizations` and the token color customizations, and the
  workbench rebuilds the token theme from the active `ColorThemeData`.
  `src/vs/workbench/browser/themeColors.zig` is the cell palette bridge
  (resolves ids, composites alpha over `editor.background` and falls back to
  the previous literal). It paints the workbench background/dividers/pane
  borders/placeholders, tab strip, breadcrumbs, activity bar, status bar,
  side bar title/header/footer rows, Explorer, Search, Source Control,
  terminal panel, quick picker, Markdown preview and the editor
  background/highlights/guides. Terminal ANSI output,
  overview-ruler marker accents and a few legacy badge literals keep their
  fallback colors. The Color Theme picker and icon themes are not ported.

Explorer and Source Control share the ViewPane section header and vertical
split layout. Shift+Tab from the body focuses its heading. Up and Down move
between headings, Left and Right collapse and expand, and Enter or Space
toggles the section. Tab reaches the header toolbar and then the body. The
header context menu opens at the pointer. Keyboard activation of a toolbar
menu opens it below the focused button. Drag headers to reorder
them. The highlighted half of the destination pane shows where the view will
land. Drop a header on either container's activity icon to move the view.
The workspace restores view order, visibility, expansion and divider sizes
when reopened.

### 8.1 Integrated terminal panel

The terminal panel and terminal editors share the terminal cell renderer.
`TerminalTabbedView` mirrors upstream's side-list `SplitView`: the enclosing
panel supplies the title row inside its rounded frame. Cell-border terminals
keep the full panel area for the title and content. With box-drawing glyphs,
the panel reserves a one-cell frame when the title and at least one content
row fit inside. The tab list takes a configurable left or right column, and
its visibility follows instance and group counts. List and split
sashes measure widths in whole cells. `TerminalTabList` paints one row per
instance and uses branch markers for split group members. Its glyphs stand in
for the browser's codicons.

`TerminalEditorInput` gives the same instance an editor resource and label.
The editor group supplies the viewport, while `TerminalEditor` attaches the
renderer and measures the PTY. Moving between hosts transfers the instance
without restarting the process. Panel and editor instances share the TUI poll
loop, mouse and keyboard encoding, and raw bracketed-paste path.

The engine is libghostty-vt, not a port of xterm.js:

- `src/vs/workbench/contrib/terminal/browser/terminalEmulator.zig` owns the
  ghostty `Terminal`, one persistent `TerminalStream` (parser state survives
  read boundaries), the render state and the effect callbacks. The ghostty Zig
  API is treated as an unstable implementation detail behind this file.
- `src/vs/platform/terminal/node/pty.zig` is the POSIX host: `forkpty`,
  non-blocking master fd, queued writes, resize ioctl and process-group
  signalling. Darwin uses a kqueue process-exit event and Linux uses a pidfd.
  POSIX hosts without a native descriptor use a blocking waitid and a pipe. The host reaps the child, drains its output and dispatches
  TerminalInstance.onExit before disposing the tab. Pending input resumes on
  writable master descriptors. The child only performs async-signal-safe calls after fork.
- `src/vs/workbench/contrib/terminal/browser/terminalRenderer.zig` reads `RenderState` rows/cells, resolves palette
  and RGB colors, maps SGR attributes to `ui.cell.Attr`, and writes graphemes
  into the shared frame grid. Text is not rebuilt in a second cell buffer.
- `src/vs/workbench/contrib/terminal/browser/terminalInput.zig` maps decoded `ui` key/mouse events through the
  ghostty key/mouse/paste encoders. Bracketed paste is taken from the raw input
  bytes while the terminal has focus because the editor decoder intentionally
  turns pasted control bytes into key events.
- The panel always paints the terminal into `Frame.next`; the existing frame
  diff still limits ANSI output to changed cells. Synchronized output (mode
  2026) holds are captured at the start of the hold and released by the engine.

`ui.CellGrid` now has a grapheme plane next to the first-codepoint plane. A
shared intern table (like the border table) stores the UTF-8 cluster and makes
frame diffs compare ids; `putCodepoint` keeps the old single-glyph path. This is
what lets prompt emoji, combining marks and ZWJ sequences survive the terminal
pipeline.

The panel toolbar uses terminal glyphs and anchored dropdown menus. Right-clicking
a terminal tab or empty tab-list space opens the corresponding context menu. It stores the side-list width in the active profile.
Terminal text selection and copy, find, links, shell-integration decorations,
Windows ConPTY, persistent and remote processes, cross-window drag and drop,
ligatures, WebGL, and runtime theme switching remain outside this port. The
integrated terminal panel does not forward kitty images; only the editor's
Markdown/image previews use them. Cursor shape is the outer terminal's; bar/underline settings are
approximated by the cursor position and block/inverse paint.

### 8.1.1 Async I/O and the event loop

Interactive file, directory and network work uses Zig's `Io.async` directly; no
Promise/Task framework is introduced. `Workbench` owns a dedicated
`std.Io.Threaded` instance (passed as `async_io`) configured with an unlimited
async limit, separate from the terminal/synchronous-startup `io`. Features that
can block read from it:

- `Workbench.requestOpenPath` reads, BOM-detects, decodes and canonicalizes the
  file in a job; the TUI thread only builds the editor from `LoadedText` when
  the worker posts its completion to the window.
- Explorer expansion is driven by the ported async data tree. Each stale node
  returns a pending `ExplorerDataSource` request. A completed listing wakes
  the window to expand and render the node.
  Already-resolved children use the synchronous data-source fast path. Multiple
  directories can be requested concurrently and a pending `explorer.autoReveal`
  walk resumes after each applied listing.
- Image tabs and Markdown images use `ImagePreviewPane.requestLoad` and
  `MarkdownPreview` image jobs; local reads/decodes and remote http(s) fetches
  never touch the TUI thread. Remote jobs have a 30 s deadline scheduled by
  the preview.
- `platform/request/node/requestService.zig` is a synchronous `std.http`
  request layer; callers wrap it in `Io.async` when they need the TUI thread
  free.

File reads, image tab decodes, keybindings and color themes post a completion
callback to the window queue. A POSIX pipe or Windows event wakes terminal
input waiting on another thread. The window thread consumes the completed
future. Explorer listings and workspace file changes also wake the window.
Markdown image, math and diagram completions wake the window as well; the preview schedules its scroll and refresh deadlines.
Shutdown cancels and joins every job before the async `Io.Threaded` and the
services/panes that own the results are freed. Background workers (search,
watcher JSON server, extension host) continue to use dedicated threads, which
is the terminal counterpart of upstream's worker processes.

Watcher-triggered reloads use the same model. `SettingsWatcher` reads the raw
user/workspace/folder settings sources on the async Io and applies/merges them
with `ConfigurationService.applySources` on the TUI thread before invoking the
reload callback. `Workbench.onSettingsReloaded` then starts asynchronous
user-keybindings and color-theme loads: `UserKeybindings.load` runs on the
worker, and `ThemeService.prepareTheme` reads the theme plus its `include`
chain into a detached `ColorThemeData` that `applyPreparedTheme` installs on the
event loop. Clean-editor external changes use `TextFileService.resolve` on
the worker and `applyReloadedContent` on window delivery. The tab is resolved by
path again at completion, so closing it during the read is safe.

Known boundaries: provider methods remain synchronous and are only called from
the TUI thread today; save/close/quit keeps a synchronous write pipeline;
startup workspace/theme/extension scans happen before the first frame. These
are listed in the README as remaining async-port work.

### 8.2 Source Control, quick diff and diff editor

The terminal workbench ports the Git/SCM pipeline without the
extension host. `src/extensions/git/src/git.zig` is the `IGitExtensionDelegate` host: it
runs Git with argv (never a shell), an explicit working directory, bounded
stdout/stderr and a deadline, parses `status --porcelain=v2 -z --branch -uall`
into the ported `GitRepositoryState`, and serves `HEAD`/index/working blobs from
a status-invalidated cache. `src/vs/workbench/contrib/git/` keeps the upstream
service/repository contract (one delegate, state getter plus change event
instead of observables), `src/vs/workbench/contrib/scm/common/` ports the SCM
service/provider/resource subset and the quick-diff service, and
`src/extensions/git/src/repository.zig` maps the repository state to the upstream
`Merge Changes`/`Staged Changes`/`Changes` groups, maps porcelain `XY` statuses
to the upstream file decoration letters, status texts and theme colors, and
provides the primary/secondary quick-diff providers. Model edits and repository
refreshes schedule the same 200 ms quick-diff delay. A lazily started native editor worker
serves the file editors visible in the editor groups. Changing tabs detaches the hidden editor.
The SCM controller reads its own whitespace and gutter-pattern settings on configuration changes. It receives owned original and modified text because the terminal provider supplies file
contents and the worker has no synchronized URI-backed models. The UI thread
delivers replies in order. Each live model publishes the completed result with
its captured version and the decorator receives the model's change event.
Closing a model detaches its outstanding reply.

The Source Control Changes view (`src/vs/workbench/contrib/scm/browser/scmViewPane.zig`)
keeps the upstream `SCMTreeDataSource`/`SCMTreeSorter`/`SCMTreeFilter` behavior
for changes. With a single repository the groups are the tree-root
children (the repository header only appears with `scm.alwaysShowRepositories`
or multiple repositories). Groups and tree-mode folders are collapsible rows
with twisties and count badges. Change rows use the shared file icons, file
labels, Git decorations, and the upstream strike-through and faded styles. List
sorting follows `scm.defaultViewSortKey`, tree mode folders sort before files
and a deeper single-child folder chain is compressed when `scm.compactFolders`
is on (top-level folders stay uncompressed, matching
`SCMTreeCompressionDelegate`).
Selection is preserved by element identity across refreshes, collapse changes
and view-mode switches.

The SCM stylesheet gives the message input and split action button the same
inset and uses terminal border strokes in place of CSS pixel borders. Commit
and toolbar overflow actions open native menus. Changes groups the view modes
and sort keys under View & Sort. Graph and Outline mark the selected mode.
Sidebar header menus show view visibility and disable hiding the last visible view. The Changes and Graph pane
divider resizes in whole rows. The Graph uses cell glyphs for the upstream
commit circles and connectors and reserves space on the right for ref badges.

Terminal substitutions and their reasons:

- **No-alpha decoration colors.** Upstream quick-diff and diff-editor colors are
  translucent CSS backgrounds. Cells have no alpha, so the gutter, whole-line
  and inline colors are pre-composited over the dark editor background
  (`quickDiff.zig`, `diffEditorDecorations.zig`, `src/tui/editorView.zig`).
  `scm.diffDecorationsGutterPattern` is represented by dimming; the pattern,
  minimap and gutter-width settings cannot be represented as cells.
- **Changes rows as cells.** Upstream rows are 22px flex DOM rows with icons
  and a 0.9em description. A terminal row is one cell: indentation is two cells
  per tree level plus a twistie gutter, the file/status icon theme is replaced
  by the Git decoration letter badge (`M`/`U`/`!`, ...), folder rows append
  `/` to stand in for the folder icon, the relative directory
  is painted in `descriptionForeground` instead of a smaller font,
  strikethrough uses the cell attribute, and the `.faded` opacity is a 0.7
  color blend over the row background. Hover and selection use
  `list.hoverBackground`/`list.activeSelectionBackground`/
  `list.inactiveSelectionBackground`. There is no double click (single click
  toggles a collapsible row and opens a change row), no multi-selection, no
  tree filter/find, no hover tooltip, no drag/drop and no auto-reveal. The
  commit-message input and Commit button scroll with the tree. The terminal
  message input is single-line, and its placeholder substitutes Enter for the
  `Ctrl-Enter` binding label, and Enter (or the labelled Commit button below
  the input, or Ctrl-Enter from the list) commits. Staged changes commit
  as-is; with an empty index
  the terminal replaces upstream's smart-commit prompt by staging changed
  files (`git.smartCommitChanges` all/tracked) and committing. The commit
  dropdown (amend/signed/push), staging/discard commands, multi-line
  messages, validation/history, the Git action button and the inline
  staging/discard actions remain unported; the list/tree and sort-key
  commands are reachable from the pane title action and the command palette
  because the view-title dropdown menu is not ported.
- **Gutter marker cell.** `Margin` paints `line numbers | fold | quick diff`;
  the editor reserves `line_decorations_width` (0 or 1) after the fold cell and
  exposes `foldCellColumn()`/`quickDiffCellColumn()` so hit testing and the fold
  toggle stay correct. The marker glyph is `+`/`~`/`-`.
- **Whole-line decoration data.** The ported `DecorationsOverlay` produces
  per-visible-line class lists instead of positioned `<div>`s; the terminal maps
  `line-insert`/`line-delete`/`diff-filler` to row backgrounds and
  `char-insert`/`char-delete` to inline cell styles.
- **Model-anchored diff view zones.** The view layout accepts whitespace
  transactions and emits zone-change events. Both panes keep their real
  resource models; filler rows are represented by view zones rather than
  synthetic model lines. Line numbers, scroll, selection, wrapping and
  hit testing use the shared view/model mapping and layout. A working-tree
  diff mounts an independent view of the existing editable file document;
  Git revision resources resolve to read-only models owned by the
  TextResourceEditorInput. The working copy is registered once per document,
  regardless of the number of mounted file or diff views.
- **Diff action controls.** The registered editor-title and gutter menus keep
  upstream context keys and actions. A hunk toolbar places the primary and
  overflow affordances in two adjacent terminal cells instead of vertically
  stacking browser buttons; actual gutter items use the real layout bounds.
  Legacy revert arrows use model-anchored glyph-margin widgets. The inline
  deleted-code margin exposes the original line numbers, selection and exact
  copy via the terminal clipboard service. Both normal and compact disclosure
  controls project the browser's narrow top and bottom drag strips alongside
  the text in a one-cell row, with separate hit targets and model-driven lower
  scroll anchoring. The hand-ported diff stylesheet registers those classes;
  pixel transforms, CSS selectors, transitions and shadows are omitted.
  Symbol breadcrumbs use shared terminal symbol glyphs and a chevron, with
  compact keyboard focus targets and the same outline-based reveal behavior.
- **Combined overview ruler and sash.** The upstream ruler's original and
  modified lanes occupy one terminal cell each; markers use the existing
  overview renderer's half-cell projection and the viewport slider uses
  scrollbar geometry and mouse events. The sash uses whole-cell geometry and
  two stationary primary clicks to reset to the configured ratio.
- **Decoration generation events.** Quick-diff/diff decorations change without
  a content edit. `TerminalViewHost.renderRange` dispatches
  `ViewDecorationsChanged` when `Editor.decorationGeneration()` changes, so the
  line-decorations and whole-line overlays re-prepare instead of staying stale.
- The main loop drives the quick-diff delay and dispatches completed worker
  results. The native worker receives owned text snapshots.

Limitations are documented in `README.md` and `docs/diff-view-audit.md`.
Both panes retain their real text models. The retained ViewZones part aligns
changed ranges, wrapped lines and other zone heights. Inline mode inserts
deleted original code above the modified model, using the shared token and
line-decoration rendering pipeline and building only visible zone rows. The
gutter finds the first visible hunk by binary search and walks the intersecting
item bounds once per viewport. Unchanged
regions own direct hidden areas and model-anchored disclosure controls; the
compact disclosure keeps its keyboard target across expand/collapse. The
terminal collapses browser disclosure geometry to a single cell row.
Moved blocks use side-by-side model decorations, connector tracks and
Compare controls. Both pane controllers attach and dispose with their editor
views. The CodeLens contribution uses one model-anchored terminal row per
lens line, shared ViewZones, and retained clickable command labels instead of
DOM links and a reduced browser font size. Visible commands resolve through
the language-feature registry; the command picker uses the active code
editor context. Both pane resources are mirrored independently to Node
extensions, and switching focus changes the active editor without closing
its document. True-inline word changes inject deleted
text into view projections, preserving model coordinates and painting removed
text with strikethrough. Browser
three-pixel empty-range borders become one marker cell. The accessible review
viewer uses the same line renderer and a retained unified row window; its
ARIA labels are represented in the terminal document, not exposed through a
browser accessibility tree. File-to-file diff inputs restore through the
composite serializer. The two code editor states and collapsed-region model
state are stored using the ordered pair of model URIs and the group ID;
ordinary file tabs and diff panes resolve shared documents during restoration.
Virtual Git revision inputs have no upstream text-resource serializer. The SCM
change peek reuses a retained `ZoneWidget` and `PeekViewWidget`; its child
inline diff mounts the shared working document and the provider's real
original resource. The terminal replaces the browser arrow/frame and
pixel-sized header with cell geometry, the base selector with the shared
quick-input picker, and action icons with cell glyphs. The child unmounts
before its containing zone is removed or rebuilt. Keyboard focus, hardware
cursor and code-editor service lookup follow the embedded editor while it has
focus. Git actions are resolved from the scoped `SCMChangeContext` menu and
forward the selected provider changes to the Git commands. Git snapshot
resolution and the initial diff computation now run in the editor worker;
the window receives completion events and obsolete replies are detached.
The registered diff accessibility help uses a retained read-only code editor
rather than a browser dialog, with resolved shortcut labels and Alt-F6
verbosity configuration. The ARIA metadata is retained; terminal-native
screen reader detection, the browser accessibility tree and audio signals
are unavailable.

The multi-diff widget composes a compressed virtual scroll view, typed item
template pools and independently owned diff view models. Integer cell geometry
replaces the browser's pixel-sized headers, spacing and viewport ranges. The
header uses a retained typed CSS sheet; browser box shadows are not rendered
but the sticky-header state remains. Child editor views paint through the
normal diff renderer into clipped viewports; the shared CellGrid copies only
intersecting rows without changing the child's layout or scroll coordinates.
Each retained template owns its diff widget and both code editor widgets.
On unbind, the model-bound Views, cursor and feature registrations detach
through the set-model lifecycle; on direct replacement, existing Views for
unchanged sides remain attached. The URI model resolver owns shared model
references and delivers asynchronous provider changes on the window dispatcher.
Graph revision sources resolve asynchronously and preserve URI identity, absent sides,
binary placeholders, collapse state and active item across virtualization.
The live SCM source and explicit resource-pair inputs mount the same pane and
restore through the editor input serializer. The optional changed-files
composite uses the existing compressed object tree and a cell-sized SplitView;
file/folder labels and status decorations are rendered by the shared list
renderer rather than browser CSS font/absolute-position rules. Profile state
uses the native atomic JSON storage adapter; viewport visibility and focus
remain event-driven. The retained header toolbar resolves actual registered
menu actions in source/item context and passes the resource URI. Accessibility
help is exposed through the same read-only Accessible View service; browser
screen reader detection and native ARIA traversal are not available.

## 9. POC acceptance

- `zig build` and `zig build test --summary all` pass with no leaks.
- A preview of a fixture file at 80x24 shows: text, syntax colors,
  right-aligned line numbers, empty lines, tabs, CJK/emoji wide characters,
  wrapped lines, long-line clipping, gutters for lines past 9 and 99.
- Snapshot tests in `src/tui/` assert text rows and per-cell styles for ASCII,
  CJK, tabs, wrapping and long-line clipping; selection background/dimming,
  visible-whitespace markers inside a selection, and the guide cells inside a
  selection; the hardware cursor cell; an unchanged refresh writing no bytes;
  mouse click/shift-click/drag/wheel caret and viewport effects; find-control
  hover highlighting and click activation; input click-to-caret; plus keyboard
  scrolling and Ctrl-Q through the library dispatcher. Content-widget tests
  cover model-position anchoring, wrapped anchors, above/below flipping and
  cell clamping; the hover
  contribution tests cover the upstream `contentHover.test.ts` placement cases,
  markdown/decoration participants, rendering the box and highlight, focus with
  Escape, and wheel scrolling of long hover content without moving the
  editor viewport. Word-highlighter tests cover the textual provider, the
  delayed run, keeping/updating occurrences, stopping on edits, multi-line
  selections and focus loss, and next/previous navigation. Scrollbar tests
  cover the reserved column, marker colors and rows, half-row marker edges and
  quadrant glyphs, single-line half-cell markers, the thumb covering a marker
  row, cursor markers, the no-thumb short-document case, half-cell thumb
  geometry, click/drag scrolling, narrow terminals and the per-decoration
  overview-ruler flag. The
  ported `ScrollbarState` tests include the upstream cases, a one-row minimum
  and the exact fractional slider geometry.
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
  remains the collapsed `src/tui/editorView.zig`. Cursor, selection and a two-cell
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
   (`src/tui/editorView.zig`) already covers gutter, tokens, selection, cursor and
   status; the split into upstream-shaped view parts is still open.
5. Generic scrollable viewport (`overflow: auto` boxes) and CSS-style
   `:hover`; cursor blink/timers; row damage bands and the `DECSTBM` +
   `IL`/`DL` scroll shift; hardware-cursor caret. The editor scrollbar and
   overview ruler are in as a shared one-column terminal adaptation with
   `ScrollbarState`, including click, thumb drag and wheel scrolling; the
   generic scroll and selector machinery is not.
6. Replace the adapter with a port of `viewModelImpl.ts` +
   `CursorsController`; port edit context/controllers; then the remaining
   widgets and contributions (glyph/color-picker/inlay-hint hover, and the
   quick-pick list's icons/buttons/virtualization). The workbench quick-open
   overlay, file and command providers, and their terminal view are in.

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
- No source-tree test duplication: library tests live under `ui/tests/tests.zig`; editor
  tests mirror upstream paths under `src/vs/.../test/...`.

## 12. Deferred / explicit limitations

- No CSS parser/selectors/`!important`/custom properties/units, HTML or
  `innerHTML`; no grid or table layout, transitions, opacity compositing,
  borders/radii. Declaration cascade, class records and the document stylesheet
  are implemented; see `docs/css.md`.
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
  are not cancelable and there are no `:focus`-style selectors; focus is
  explicit state plus listeners. Hiding or removing focusability from the
  focused element keeps it focused, matching Chrome's dynamic behavior; only
  removing the node clears focus (silently).
- The one-line input has no system clipboard (host hooks only), no
  double-click word selection, no horizontal scrollbar and no validation
  message/context view; history (`HistoryInputBox`) stays host-owned. Its
  selection and editing are codepoint based, so combining marks/graphemes are
  not grouped. For a box built into a `Document`, focus/blur listeners keep
  `InputBox.focused` in sync with `document.activeElement`, and the retained
  node is validated against the document generation so `Document.clear` cannot
  leave a dangling node behind. `deinit` does not touch the document; a host
  must clear the document or remove the node before destroying a box whose
  listeners could still fire.
- The editor scrollbar/overview ruler is a right-aligned 1.5-cell strip with
  three half-cell marker lanes projected to half rows; the 1.5-cell thumb
  covers markers on its rows and resolves its top/bottom edges to half-cell
  half blocks and quadrants. It has no pixel lanes, minimap, horizontal
  scrollbar, rounded/smooth slider, translucent marker alpha or diagnostics
  markers; a marker row can represent many document lines. There is no
  generic scrollable
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
  fragmentation. It has no bidi reordering, grapheme-cluster segmentation for DOM text, CSS
  `line-height`/`text-indent`/`vertical-align`, `<br>` elements, or font-aware
  shaping; forced breaks come from newlines under preserving white-space
  modes.
- No grid formatting contexts, table boxes or incremental box reuse yet; the
  box tree is rebuilt from the DOM when mutations invalidate it, then solved whole.
- No JS interop, WebIDL, shadow DOM, custom elements, HTML parsing, or the full
  DOM API; only the node/tree/attribute subset above.
- Mouse pointer shapes cover editor text, Markdown links, input boxes, widget
  rows/buttons, editor tabs, activity-bar entries, status-bar command entries,
  panel tabs, quick-pick rows, dialog buttons, sashes and terminal chrome.
  Direct-painted surfaces without a style node map their shape in the workbench
  explicitly; search/SCM result rows, Problems rows, breadcrumb segments, hover
  Markdown links and overview-ruler drags still show the terminal default. The
  OSC 22 push/pop stack and support query are not implemented, only CSS names
  are emitted, and an integrated-terminal child's OSC 22 is not forwarded.
- The `ui/` name, module name and exact style field set are provisional;
  renaming before the first commit is cheap.

## 12.1 Performance measurement

The standalone library has its own stress/benchmark harness, shaped after
TermDOM's `bench/` suite but native: scenarios report first-iteration and
p50/p90/p99 samples, an `--allocated` bytes-per-step mode, and optional
baseline comparison. No iteration is called a warmup because Zig has no JIT;
one-time page-fault and allocator-growth costs are reported as part of the
first sample.

```sh
cd ui
zig build bench -Dbench-args="--runs 5 --markdown"
zig build bench -Doptimize=ReleaseFast -Dbench-args="--allocated --runs 3 --markdown"
zig build test
```

The retained editor still bounds its box arena (32 MB) in `syncBoxes`. The
per-solve layout scratch is bounded by the UI library instead: after an
incremental `BoxTree.layoutSubtree`, crossing the 32 MB scratch budget marks
the tree for a full rebuild, and the next `ensureLayout` resets both arenas.
`RetainedViewPartHost.rebuildSubtree` relies on `BoxTree.rebuildSubtree` to
refresh the element style and inherited pointer, so it does not issue a
zero-delta translation afterwards. These are terminal retained-view boundary
rules, not changes to the ported view pipeline.

## 13. Open questions

- Final library name/location (`ui/` is a placeholder).
- Whether the same tree should later get a native/window backend or remain
  terminal-only.
- Whether to enable mode 2027 / terminal width negotiation once the renderer
  handles grapheme clusters.

### Workbench layout storage

The terminal saves side bar width, panel alignment and the last non-maximized
panel width and height in terminal cells under
`User/globalStorage/layout.state.json`. Workspace storage keeps pane visibility,
panel position, maximization history, the last active sidebar and panel containers, editor centering, zen
mode and its exit information. The panel defaults to bottom and supports all
four dock positions; its sash follows the horizontal or vertical sizing axis.
Layout restores containers through the registered pane-composite service;
hidden containers retain the saved last-active ID without mounting their view.
PanelTitle navigation actions occupy trailing title cells; their visibility and
Maximize/Restore state are resolved from the live menu/context-key events. Each file
is replaced atomically on shutdown. An explicit session path identifies an
empty window across launches. A window without a folder or session path has
only profile-level sizing. Restoring a terminal panel opens the pane without
restarting processes from the previous session.

Workbench focus changes are delivered from the active editor/group, quick-input
show/hide, modal dialog, search-input focus and terminal active-instance events.
EditorPart forwards these to the mounted editor views and TerminalInstance owns
encoding its PTY focus report; frame painting does not synchronize focus.
