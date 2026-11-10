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
zig build examples         # all seven
```

Each example draws one frame on the alternate screen, shows it for two seconds,
and restores the terminal.

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

## Tests

```sh
cd ui
zig build test
```

The root repository's `zig build test` also runs `ui/tests.zig`, so the library
tests stay part of the main suite.
