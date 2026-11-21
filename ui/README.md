# ui

A small, standalone Zig 0.17 terminal UI library. It is the rendering layer used
by the `vscode-textbuffer` preview; it has no dependency on the editor.

- A DOM-like retained tree (`Node` is an element or text) with direct `Style`
  values. No CSS, no HTML, no class selectors.
- A **derived layout box tree** separate from the DOM: a viewport root,
  principal boxes, anonymous inline/flex boxes and text boxes. Layout and paint
  operate on that tree; geometry is copied back to DOM rects only for
  measurement.
- Mutation-driven invalidation. The DOM reports tree/style/text changes to the
  attached box tree; boxes carry `needs_layout`, and the tree carries
  `needs_rebuild` / `needs_layout`. There is no document-level revision or
  dirty flag.
- A whole-cell layout pass with the CSS box model: content `width`/`height`,
  margin, padding and border widths, box-drawing borders with an optional
  cell-border protocol path (the host probes the terminal; unsupported
  terminals keep the glyph fallback and its reserved cells), kitty image
  placeholders (see below), and
  absolute `left`/`top` anchoring the margin box. Block flow, inline text flow
  and flex formatting contexts share the derived tree. Backgrounds paint the
  border box and `overflow: hidden` clips to the padding box.
- CSS-style text flow: UAX #14 line breaking (Unicode 17 data), the
  `white-space` family, `word-break`/`overflow-wrap`, per-line `text-align`,
  hanging spaces, tabs and wide cells. Text boxes carry painted line fragments;
  non-atomic inline elements fragment across lines and paint their background
  and border per fragment. See “Text wrapping” below.
- Flex containers support `flex_direction`, `flex_wrap`, `justify_content`,
  `align_items`/`align_self`/`align_content`, `flex_grow`, `flex_shrink`,
  `flex_basis`, `order`, `gap`, auto margins and content-derived auto sizes.
  Bare text in a flex container becomes an anonymous flex item. `order` sorts
  the derived box children, so layout, paint order and hit testing agree.
  `min_width`/`max_width` clamp content-box widths; there is no
  `min-height`/`max-height`, grid or table layout. Inline line boxes follow CSS
  text flow and wrap at UAX #14 opportunities. See the limitations below.
- A reusable `ScrollView` for content that can overflow: a clipped viewport,
  whole-cell translated content, a proportional scrollbar and wheel handling.
  There is no CSS `overflow: scroll`; list-style windowing and editor scrolling
  keep their own view-model state.
- A reusable modal `Dialog` for confirmations: a warning icon, wrapped message
  and detail, up to three focusable buttons, keyboard wrapping and mouse
  press/release activation. It composites into a host `CellGrid` and dims the
  cells behind it.
- A double-buffered `CellGrid` renderer that emits only the ANSI frame diff.
- Kitty graphics support in `ui/image.zig`: capability probe, PNG/RGBA
  transmission, virtual placements, image deletion and Unicode-placeholder
  cells (`U+10EEEE` + row/column diacritics + the image id in the foreground
  color). `Runtime` owns the id space and queues escape codes for the host to
  flush before the frame body; `putPlaceholder` writes ordinary cells so the
  frame diff, clipping and scrolling need no special image layer. The library
  does not decode image files; callers pass encoded payloads.
- Keyboard and mouse events and focus: per-node listeners with
  capture/target/bubble, `Document.activeElement`, `focus`/`blur` plus
  `focusin`/`focusout`, and `Tab` traversal driven by `Element.focusable` /
  `Element.tab_index`. `Surface.elementFromPoint` hit-tests the box tree against
  a viewport cell, and mouse presses focus the nearest focusable ancestor.
  Terminal bytes are decoded by `ui.input.decode`.
- No hidden globals; allocators are passed explicitly.

The architecture and the staged editor plan are in
[`../docs/terminal-ui.md`](../docs/terminal-ui.md).

## Examples

```sh
cd ui
zig build example-hello    # colors, bold, backgrounds, inline text runs
zig build example-list     # rows, alternating backgrounds, right-aligned columns
zig build example-layout   # absolute + percent layout, left/center/right text
zig build example-flex     # flex row/column, wrap, grow, gaps, auto margins
zig build example-flex-toolbar # grow spacer, justify-content, auto margins, order
zig build example-flex-cards   # wrapping cards with gap and align-content
zig build example-flex-columns # nested column/row flex, growing panels, footer
zig build example-flex-reverse # row-reverse, column-reverse, wrap-reverse
zig build example-width-bounds # block min/max width, wrapping and auto margins
zig build example-flex-bounds  # flex grow/shrink/basis and column-stretch bounds
zig build example-overflow # visible vs hidden/clip for text and absolute children
zig build example-wrap    # normal/nowrap/pre text flow, alignment and overflow
zig build example-borders  # margin, padding and border boxes, nested absolute child
zig build example-table    # bordered table with aligned columns
zig build example-markdown # rendered markdown with a scrollbar: headings, lists, code and a table
zig build example-tree     # box-drawing file tree
zig build example-styling  # text attributes, truecolor, background swatches
zig build example-focus    # interactive: Tab/Shift-Tab, Enter, activeElement
zig build example-mouse    # interactive: hover/click/drag a list, wheel scrolling
zig build example-mouse-events # interactive: hover/down/move/up/click/wheel log
zig build example-todo     # interactive: TodoMVC input, wrapped list, filters and buttons
zig build examples         # fullscreen gallery with a side navigation menu
```

Every example fills the terminal (80x24 when stdout is not a TTY), draws on the
alternate screen and reads input from stdin, so a pipe can drive an example
too; EOF exits. Examples that use the shared presenter wait for `q` (or
Ctrl-Q) to exit; `example-todo` owns its loop, so `q` is text and Ctrl-Q exits.
The examples install a `SIGWINCH` handler backed by a self-pipe: hiding a
software keyboard or rotating the device wakes the loop, re-queries the
terminal size, calls `Surface.resize` and rebuilds the scene at the new
viewport. The focus example handles Tab/Shift-Tab and Enter. The two mouse examples request SGR mouse reports (mode
1003/1006), so they accept real terminal input or piped `CSI < b ; x ; y M/m`
sequences; `example-mouse` shows selection, hover and wheel scrolling, while
`example-mouse-events` logs every mouse event with its hit-tested target and
highlights the hovered zone. `example-todo` is a standalone TodoMVC scene with
its own input loop: add todos through `ui.InputBox`, toggle rows, edit a
focused row, filter All/Active/Completed, clear completed and toggle all.
The subtitle and long todo text wrap, and the list window scrolls in row cells.

`zig build examples` opens the fullscreen gallery instead of running all
examples in sequence: a side navigation menu on the left and the selected
example in the content area. Up/Down, PageUp/PageDown, Home/End and the wheel
move the selection; hover/click selects a menu item; `q`/Ctrl-Q quits. Scenes
that own keyboard focus (TodoMVC) receive keys in the gallery too; while one is
selected, Alt+Up/Down switches scenes and Ctrl-Q quits. Mouse events over the
content go to the example, so the mouse demos remain interactive there; run an
individual `example-*` step for a scene without the gallery chrome.

## Minimal use

```zig
const std = @import("std");
const ui = @import("ui");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var surface = try ui.Surface.init(allocator, .{ .cols = 40, .rows = 8 });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    const label = try doc.createElement(.div);
    label.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 20 },
        .height = .{ .cells = 1 },
    });
    _ = try label.appendChild(try doc.createText("hello"));
    _ = try root.appendChild(label);

    const io = std.Io.Threaded.global_single_threaded.io();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try surface.render(&stdout.interface, .{});
    try stdout.interface.flush();
}
```

### Cell borders

`Surface` can paint borders as terminal cell attributes instead of box-drawing
glyphs, using the draft `DCS 1 + b cell-border` protocol. The terminal must be
probed by the host: `src/tui/cellBorders.zig` sends the query followed by DA1.
Set `Options.cell_borders` or call `surface.setCellBorders(true)` once support
is known. In that mode border widths leave the box model (they no longer
reserve cells), and `paint.zig` puts centred strokes on the box's outer-edge
cells. Two adjacent boxes merge their shared edge in the terminal.

Without support, or with the option off, nothing changes: borders reserve cells
and `paint.zig` writes single-line box-drawing glyphs. The wire encoder emits
solid centred strokes below text; rounded joints, double/dashed/dotted lines and
the outside fill are stored in the model but not painted yet. A terminal that
does not understand the DCS ignores it, so the probe result is the only switch.

`Surface.resize(cols, rows)` reallocates the double buffer, updates the
document viewport and invalidates the box tree; the next layout pass resolves
percentages and absolute geometry against the new size, and the next `render`
clears the terminal. Rebuild the tree (or update the parts whose build captured
the old size) after resizing. The library itself has no resize event: the host
handles `SIGWINCH` and calls `resize`, as `ui/examples/common.zig` does.

Text nodes are inline content. Position and size belong to the parent element;
use a box with a text child (as the examples do) rather than setting
`position`/`left`/`top` on a text node.

Direct writes to the public `Element.style`/`Text.style` fields bypass mutation
tracking. Use `Node.setStyle` so the attached layout observer sees the change.

## Keyboard and focus

```zig
const save = try doc.createElement(.div);
save.asElement().focusable = true;
save.asElement().tab_index = 0; // positive/0: Tab stop; negative: programmatic only
_ = try save.appendChild(try doc.createText("Save"));

try save.addEventListener(.{
    .context = self,
    .key_down = onKey,
    .focus = onFocus,
    .blur = onBlur,
});

// Keys go to Document.activeElement(), or the root when nothing is focused.
var events = try ui.input.decode(allocator, bytes);
defer events.deinit(allocator);
for (events.items) |event| {
    _ = doc.dispatchKey(event.key, event.mods);
}
```

Listeners can also use `capture = true`, `focus_in`/`focus_out` (bubbling), and
`stopPropagation` / `stopImmediatePropagation` / `preventDefault` on a
`ui.KeyEvent`. `doc.focus(node)` moves focus; `doc.blur()` clears it; `Tab` and
`Shift+Tab` are the default action of a non-prevented key event. Focus events
carry `related_target`. A terminal only reports key presses, so there is no
`keyup`/`keypress` and no repeat flag.

Text runs in decoded events borrow the input buffer; dispatch them before
reusing that buffer.

## Mouse, hit testing and scrolling

`ui.input.decode` returns a mixed stream of keyboard and mouse items, in
arrival order. SGR reports (mode 1006) become `ui.MouseEvent`s with zero-based
cell coordinates; `decodeKeys` filters the stream for keyboard-only hosts.

```zig
var items = try ui.input.decode(allocator, bytes);
defer items.deinit(allocator);
for (items.items) |item| switch (item) {
    .key => |key_event| _ = doc.dispatchKey(key_event.key, key_event.mods),
    .mouse => |mouse| {
        const target = (try surface.elementFromPoint(mouse.x, mouse.y)) orelse doc.root.?;
        var event = mouse;
        doc.dispatchMouse(target, &event);
    },
};
```

`Surface.elementFromPoint` solves pending layout, walks the box tree in reverse
paint order and clips to `overflow: hidden`/`clip`, so the deepest, topmost
element under a cell wins. A text box reports its parent element, matching
`document.elementFromPoint`.

Listeners can handle `mouse_down`, `mouse_move`, `mouse_up`, `click` and
`wheel`; all run capture → target → bubble and honor `stopPropagation` /
`preventDefault`. A non-canceled press focuses the nearest focusable ancestor,
or blurs. Wheel deltas are in lines (±3 per notch, as in TermDOM) and cancelable;
the host decides what to scroll. There is no library click synthesis, drag state
or `:hover` selector: those belong to the host. The editor view does the press/
drag/click synthesis and wheel scrolling; widgets derive hover from
`mouse_move` with `button == .none`, reported under terminal mode 1003.

`ui.input.decode` decodes both idle and button-held motion because mode 1003 is
requested. It does not decode legacy X10 mouse reports, double-click counts, or
terminal focus reports.

`InputBox` turns a left click or held-button motion into a byte caret, mapping
the cell through the visible window (wide characters choose the nearest
boundary). Clicking a find toggle or its `All` button runs that control; the
widget tracks the hovered control and clears it when idle motion leaves the bar.

## Flex layout

```zig
const bar = try doc.createElement(.div);
bar.setStyle(.{
    .display = .flex,
    .gap = .{ .column = 1 },
    .padding = .all(1),
});
_ = try bar.appendChild(try doc.createText("left"));

const spacer = try doc.createElement(.div);
spacer.setStyle(.{ .flex_grow = 1 });
_ = try bar.appendChild(spacer);

_ = try bar.appendChild(try doc.createText("right"));
```

Several flex tests are ported from
[Taffy](https://github.com/DioxusLabs/taffy)'s flexbox fixtures (MIT), adapted
to this library's unrounded cell geometry and content-box sizes.

`Style.margin` uses `Margin` rather than `Edges` so a side can be `.auto`.
Auto main-axis margins absorb free space in a flex line, and auto cross-axis
margins center an item; horizontal auto margins also center a definite-width
block in block flow. `Margin.all`, `Gap.all`, `ui.Margin` and `ui.Gap` are
exported for the common cases.

Width bounds are content-box constraints, like `width`:

```zig
const card = try doc.createElement(.div);
card.setStyle(.{
    .width = .{ .cells = 20 },
    .min_width = .{ .cells = 12 },
    .max_width = .{ .percent = 80 },
});
```

`auto` leaves a side unconstrained, percentages resolve against the containing
block's content width, and `min_width` wins when both bounds conflict. The
bounds apply to block, inline-level and flex boxes, including flex base/target
main sizes and stretched column cross sizes. They do not add an automatic
min-content floor.

Flex limitations: there is no `min-height`/`max-height` or automatic
min-content floor, so shrunk items can overlap unless `overflow` clips them;
percentages are supported for sizes, `min_width`/`max_width` and `flex_basis`,
not gaps; baseline alignment uses the first text row and falls back to
flex-start under `wrap-reverse`; `position: fixed` resolves like `absolute`;
and there is no grid, table layout or z-index compositing. Text inside flex
items wraps at the item's resolved content width.

Scrolling is opt-in: `ui.ScrollView` handles arbitrary content with a clipped
viewport, translated content and a proportional scrollbar. There is no
layout-level `overflow: scroll`/`auto` on every element yet; that would move
scroll state into the box tree, clip automatically, paint scrollbars and add a
wheel default action.

## Text wrapping and white space

Text is inline content and wraps at Unicode line-break opportunities unless its
style says otherwise. `white_space` is inherited from the containing box and
can be overridden on a text node:

```zig
const paragraph = try doc.createElement(.div);
paragraph.setStyle(.{
    .width = .{ .cells = 40 },
    .white_space = .normal,      // the initial value
});
_ = try paragraph.appendChild(try doc.createText(
    "long prose wraps at spaces; supercalifragilisticexpialidocious overflows",
));

const chrome = try doc.createElement(.div);
chrome.setStyle(.{
    .width = .{ .cells = 40 },
    .height = .{ .cells = 1 },
    .overflow = .hidden,
    .white_space = .nowrap,      // collapse spaces, do not wrap
});
_ = try chrome.appendChild(try doc.createText("single-line label"));

const code = try doc.createElement(.div);
code.setStyle(.{ .white_space = .pre }); // preserve spaces and newlines
_ = try code.appendChild(try doc.createText("  indented\n    block"));
```

Supported values: `normal`, `nowrap`, `pre`, `pre_wrap`, `pre_line` and
`break_spaces`. `word_break` (`normal`, `break_all`, `keep_all`, `break_word`)
and `overflow_wrap` (`normal`, `break_word`, `anywhere`) control whether an
unbreakable word may be split; the defaults let it overflow, matching CSS. A
word with no break opportunity is never silently truncated by the layout pass;
`overflow: hidden`/`clip` does the clipping.

Auto widths use rendered max-content width; block auto height grows by the
number of lines. Wrapped continuation lines are aligned independently by
`text_align`, trailing spaces hang, and tabs expand to the document tab size.
Text fragments and inline-element fragments are allocated in the box tree's
per-solve scratch arena, so they stay valid through paint and hit testing and
are released on the next solve.

The editor view keeps its own VS Code view-model soft wrapping; its line boxes
use `white_space = .pre` so the already-wrapped code text preserves spaces and
is not wrapped a second time. Single-line chrome (gutter, status bar, find,
suggest and hover rows, input boxes) uses `pre` explicitly.

Remaining text limits: no bidi reordering, grapheme-cluster segmentation,
CSS `line-height`, `text-indent`, `vertical-align` beyond the baseline
approximation, or `<br>`; forced breaks come from newlines under preserving
modes. The UAX #14 tables cover Unicode 17.0.0.

## Input boxes and rebuilt trees

`ui.InputBox` is a single-line editor for widget text fields:

```zig
var input = ui.InputBox.init(allocator);
defer input.deinit();
input.focused = true;
input.placeholder = "Find";
input.on_enter = onEnter;

const node = try input.build(doc, width); // focusable root; call doc.focus(node)
var event = ui.KeyEvent{ .key = .{ .text = "query" } };
_ = input.handleKey(&event);              // true when the input consumed it
```

It owns a UTF-8 buffer, a byte caret and an `(anchor, cursor)` selection, and
paints a block caret (an inverted cell) instead of using the hardware cursor.
The selection is rendered as a background/reverse run and replaces the caret
while non-empty:

```zig
input.select(.{ .start = 1, .end = 4 }); // select(null)/selectAll() selects all
const range = input.getSelection().?;    // normalized byte offsets
_ = input.isSelectionAtEnd();
try input.insertAtCursor("replacement"); // replaces the selection
```

Editing keys: text and bracketed paste insert (replacing the selection);
Backspace/Delete remove the selection, one codepoint, or one word with Ctrl or
Alt; Left/Right move by codepoint or word; Home/End; Shift extends the
selection; Ctrl+A selects all. Ctrl+Z undoes, Ctrl+Y (and Ctrl+Shift+Z when the
terminal reports it) redoes. Up/Down, Tab, PageUp/PageDown and Insert are left
to the host. Enter and Escape call `on_enter`/`on_escape`.

The terminal has no system clipboard, so Ctrl+C/Ctrl+X call `on_copy` and
Ctrl+V calls `on_paste`; without those hooks the chords are safe no-ops. The
host writes/reads the real clipboard (for example OSC 52):

```zig
input.callback_context = self;
input.on_copy = onCopy; // fn (?*anyopaque, []const u8) void
input.on_paste = onPaste; // fn (?*anyopaque) ?[]const u8
```

A left click places the caret, a held-button drag selects (Shift-click extends),
and dragging past an edge scrolls the window. The visible window follows the
caret; a horizontal wheel (`delta_x`, including Shift+wheel) or
`scrollBy(doc, cells)` scrolls it manually and is re-armed by the next edit.
`selection_background`/`selection_foreground` theme the selection (reverse video
when no background is set). `setEnabled(false)`/`disable()` makes the box
non-focusable, dim and keyless; `enable()` restores it.

There is no double-click word selection (terminal reports carry no click
counts), no grapheme/IME segmentation (selection is codepoint based), and no
scrollbar, validation message or browser action bar; hover, history and
validation remain host concerns.

A view that rebuilds its tree every frame can reuse the same document and the
renderer's previous grid: `Document.clear()` drops the arena, root and focus
pointer while keeping the viewport and arena capacity. Build a new root and
call `setRoot`. To forward an already decoded event and inspect whether a
listener consumed it, use `Document.dispatchEvent(&event)`; it resets
`default_prevented` and `propagation_stopped` before dispatch.

## Modal dialogs

`ui.Dialog` is a host-composited modal confirmation. It is useful when a view
already owns a `CellGrid` instead of a `Surface` and needs a blocking choice:

```zig
const dialog = try ui.Dialog.init(allocator, message, detail, &.{
    "Save", "Don't Save", "Cancel",
});
defer dialog.deinit();

// Per frame, after the host content:
dialog.render(&frame.next);

// Route every key/mouse event to the dialog while it is open.
switch (dialog.handleKey(&key_event)) {
    .none => {},
    .activate => |index| resolve(index),
    .cancel => resolve_cancel(),
}
if (dialog.handleMouse(&mouse_event)) |index| resolve(index);
```

The first button is the primary action and starts focused. Tab/Shift-Tab,
Left/Right and Up/Down wrap the focus; Enter or Space activates it and Escape
reports `.cancel`. A mouse press focuses a button and the matching release over
the same button activates it; clicks elsewhere are swallowed. The dialog is
centered and sized from the text, clamped to the grid. When the grid is too
short for the stacked-button layout it puts the buttons on one row and drops
the icon and blank separators. `render` sets `layout` and the `buttonRect`
rectangles for hosts/tests that need the active geometry. Colors and the
warning glyph are terminal defaults; the host supplies the text and labels, so
the same widget serves VS Code-style save confirmations and other messages.

## Tests

```sh
cd ui
zig build test
```

The root repository's `zig build test` also runs `ui/tests.zig`, so the library
tests stay part of the main suite. The text suite includes the checked-in UAX
#14 conformance subset and the VS Code-derived wrapping cases (tabs, wide
cells, CJK/Kinsoku, punctuation and `keepAll`).
