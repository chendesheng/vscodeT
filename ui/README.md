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
  absolute `left`/`top` anchoring the margin box. Backgrounds paint the border
  box and `overflow: hidden` clips to the padding box. Flex formatting contexts,
  margin collapsing and right/bottom anchoring are next.
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
zig build example-borders  # margin, padding and border boxes, nested absolute child
zig build example-table    # bordered table with aligned columns
zig build example-tree     # box-drawing file tree
zig build example-styling  # text attributes, truecolor, background swatches
zig build example-focus    # interactive: Tab/Shift-Tab, Enter, activeElement
zig build example-mouse    # interactive: click/drag a list, wheel scrolling
zig build example-mouse-events # interactive: down/move/up/click/wheel log
zig build examples         # all ten; press q in each
```

Each example draws on the alternate screen and waits for `q` (or Ctrl-Q) to
exit. Input is read from stdin, so a pipe can drive an example too; EOF exits,
which keeps `zig build examples` terminating in a non-interactive run. The
focus example additionally handles Tab/Shift-Tab and Enter. The two mouse
examples request SGR mouse reports (mode 1002/1006), so they accept real
terminal input or piped `CSI < b ; x ; y M/m` sequences; `example-mouse` shows
selection and wheel scrolling, while `example-mouse-events` logs every mouse
event with its hit-tested target.

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
or hover: those belong to the host (`src/tui/view.zig`) or need terminal mode
1003, which is not requested.

`ui.input.decode` decodes button-held motion only because terminals report it in
mode 1002. It does not decode legacy X10 mouse reports, idle hover, double-click
counts, or terminal focus reports.

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
