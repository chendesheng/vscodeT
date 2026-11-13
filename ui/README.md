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
  margin, padding and border widths, single-line box-drawing borders, and
  absolute `left`/`top` anchoring the margin box. Block flow, single-line inline
  flow and flex formatting contexts share the derived tree. Backgrounds paint
  the border box and `overflow: hidden` clips to the padding box.
- Flex containers support `flex_direction`, `flex_wrap`, `justify_content`,
  `align_items`/`align_self`/`align_content`, `flex_grow`, `flex_shrink`,
  `flex_basis`, `order`, `gap`, auto margins and content-derived auto sizes.
  Bare text in a flex container becomes an anonymous flex item. `order` sorts
  the derived box children, so layout, paint order and hit testing agree.
  There is no min/max sizing, CSS text wrapping, grid or table layout, and
  inline flow does not break across lines yet; see the limitations below.
- A double-buffered `CellGrid` renderer that emits only the ANSI frame diff.
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
zig build example-overflow # visible vs hidden/clip for text and absolute children
zig build example-borders  # margin, padding and border boxes, nested absolute child
zig build example-table    # bordered table with aligned columns
zig build example-tree     # box-drawing file tree
zig build example-styling  # text attributes, truecolor, background swatches
zig build example-focus    # interactive: Tab/Shift-Tab, Enter, activeElement
zig build example-mouse    # interactive: hover/click/drag a list, wheel scrolling
zig build example-mouse-events # interactive: hover/down/move/up/click/wheel log
zig build examples         # fullscreen gallery with a side navigation menu
```

Every example fills the terminal (80x24 when stdout is not a TTY), draws on the
alternate screen and waits for `q` (or Ctrl-Q) to exit. Input is read from
stdin, so a pipe can drive an example too; EOF exits. The focus example handles
Tab/Shift-Tab and Enter. The two mouse examples request SGR mouse reports (mode
1003/1006), so they accept real terminal input or piped `CSI < b ; x ; y M/m`
sequences; `example-mouse` shows selection, hover and wheel scrolling, while
`example-mouse-events` logs every mouse event with its hit-tested target and
highlights the hovered zone.

`zig build examples` opens the fullscreen gallery instead of running all
examples in sequence: a side navigation menu on the left and the selected
example in the content area. Up/Down, PageUp/PageDown, Home/End and the wheel
move the selection; hover/click selects a menu item; `q`/Ctrl-Q quits. Mouse
events over the content go to the example, so the mouse demos remain
interactive there; run an individual `example-*` step for the full keyboard
interaction of a scene.

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

Flex limitations: there is no `min-width`/`min-height`/`max-width`/`max-height`
or automatic min-content floor, so shrunk items can overlap unless `overflow`
clips them; percentages are supported for sizes and `flex_basis`, not gaps;
text never wraps across lines; inline flow is a single line; baseline alignment
uses the first text row and falls back to flex-start under `wrap-reverse`;
`position: fixed` resolves like `absolute`; and there is no grid, table layout
or z-index compositing.

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

It owns a UTF-8 buffer and byte caret, paints a block caret (an inverted cell)
instead of using the hardware cursor, and handles text, Backspace, Delete,
Left/Right, Home/End, Enter and Escape. Up/Down and Tab are left to the host.
A left click or held-button drag maps the pointer cell to the byte caret;
`handleMouse` is public for hosts that want to route pointer events themselves.

A view that rebuilds its tree every frame can reuse the same document and the
renderer's previous grid: `Document.clear()` drops the arena, root and focus
pointer while keeping the viewport and arena capacity. Build a new root and
call `setRoot`. To forward an already decoded event and inspect whether a
listener consumed it, use `Document.dispatchEvent(&event)`; it resets
`default_prevented` and `propagation_stopped` before dispatch.

## Tests

```sh
cd ui
zig build test
```

The root repository's `zig build test` also runs `ui/tests.zig`, so the library
tests stay part of the main suite.
