//! Flex width bounds: max-width caps grow and flex-basis, min-width floors a
//! shrinking item, and a column item's stretch stops at max-width.
//!
//! Run with `cd ui && zig build example-flex-bounds`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const example = try flexBoundsExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, init.io, example);
}

pub fn flexBoundsExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "flex bounds", .build = build };
}

const background = common.rgb(18, 18, 24);
const panel = common.rgb(30, 33, 45);
const raised = common.rgb(42, 46, 62);
const accent = common.rgb(88, 132, 220);
const foreground = common.rgb(232, 234, 244);
const dim = common.rgb(150, 154, 176);

fn section(
    doc: *ui.Document,
    root: *ui.Node,
    title: []const u8,
) !*ui.Node {
    const box = try common.addBox(doc, root, .{
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .row = 1 },
        .padding = .{ .left = 1, .right = 1 },
        .overflow = .hidden,
        .background = panel,
    });
    _ = try common.addLabel(doc, box, title, .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });
    return box;
}

fn row(doc: *ui.Document, parent: *ui.Node) !*ui.Node {
    return common.addBox(doc, parent, .{
        .display = .flex,
        .height = .{ .cells = 1 },
        .gap = .{ .column = 1 },
    });
}

fn item(
    doc: *ui.Document,
    parent: *ui.Node,
    label: []const u8,
    style: ui.Style,
) !*ui.Node {
    return common.addLabel(doc, parent, label, style, .{
        .color = foreground,
        .bold = true,
    });
}

fn build(
    _: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    size: common.Size,
) !void {
    const root = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = @floatFromInt(size.width -| 2) },
        .height = .{ .cells = @floatFromInt(size.height) },
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .row = 1 },
        .overflow = .hidden,
        .background = background,
    });

    _ = try common.addLabel(doc, root, "flex bounds", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground, .bold = true });
    _ = try common.addLabel(doc, root, "min_width / max_width clamp flex main and cross sizes", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });

    const grow = try section(doc, root, "grow capped by max-width: 4");
    const grow_row = try row(doc, grow);
    _ = try item(doc, grow_row, "A", .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .flex_grow = 1,
        .max_width = .{ .cells = 4 },
        .background = accent,
        .text_align = .center,
    });
    _ = try item(doc, grow_row, "B", .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .flex_grow = 1,
        .background = raised,
        .text_align = .center,
    });
    _ = try item(doc, grow_row, "C", .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .flex_grow = 1,
        .background = raised,
        .text_align = .center,
    });

    const shrink = try section(doc, root, "shrink floored by min-width: 50%");
    const shrink_row = try row(doc, shrink);
    _ = try item(doc, shrink_row, "A min 50%", .{
        .width = .{ .percent = 60 },
        .min_width = .{ .percent = 50 },
        .height = .{ .cells = 1 },
        .flex_shrink = 1,
        .background = accent,
        .text_align = .center,
    });
    _ = try item(doc, shrink_row, "B", .{
        .width = .{ .percent = 60 },
        .height = .{ .cells = 1 },
        .flex_shrink = 1,
        .background = raised,
        .text_align = .center,
    });
    _ = try item(doc, shrink_row, "C", .{
        .width = .{ .percent = 30 },
        .height = .{ .cells = 1 },
        .flex_shrink = 1,
        .background = raised,
        .text_align = .center,
    });

    const basis = try section(doc, root, "flex-basis: 40 capped by max-width: 12");
    const basis_row = try row(doc, basis);
    _ = try item(doc, basis_row, "A", .{
        .height = .{ .cells = 1 },
        .flex_basis = .{ .cells = 40 },
        .max_width = .{ .cells = 12 },
        .background = accent,
        .text_align = .center,
    });
    _ = try item(doc, basis_row, "B", .{
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .background = raised,
        .text_align = .center,
    });

    const column_panel = try section(doc, root, "column stretch stops at max-width: 50%");
    const stretch = try common.addBox(doc, column_panel, .{
        .display = .flex,
        .flex_direction = .column,
        .height = .{ .cells = 2 },
        .align_items = .stretch,
    });
    _ = try item(doc, stretch, "A max 50%", .{
        .height = .{ .cells = 1 },
        .max_width = .{ .percent = 50 },
        .background = accent,
        .text_align = .center,
    });
    _ = try item(doc, stretch, "B width 16", .{
        .width = .{ .cells = 16 },
        .height = .{ .cells = 1 },
        .background = raised,
        .text_align = .center,
    });
}
