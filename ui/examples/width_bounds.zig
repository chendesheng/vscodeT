//! Width bounds: max-width wraps text and caps a centered card, min-width
//! floors an inline-block chip, and a percentage max-width follows the panel.
//!
//! Run with `cd ui && zig build example-width-bounds`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const example = try widthBoundsExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, init.io, example);
}

pub fn widthBoundsExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "width bounds", .build = build };
}

const background = common.rgb(18, 18, 24);
const panel = common.rgb(30, 33, 45);
const accent = common.rgb(88, 132, 220);
const foreground = common.rgb(232, 234, 244);
const dim = common.rgb(150, 154, 176);

fn section(
    doc: *ui.Document,
    root: *ui.Node,
    title: []const u8,
) !*ui.Node {
    const box = try common.addBox(doc, root, .{
        .padding = .{ .left = 1, .right = 1 },
        .background = panel,
    });
    _ = try common.addLabel(doc, box, title, .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });
    return box;
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

    _ = try common.addLabel(doc, root, "width bounds", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground, .bold = true });
    _ = try common.addLabel(doc, root, "min_width / max_width clamp the content box", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });

    const wrapped = try section(doc, root, "max-width: 24 wraps text");
    _ = try common.addLabel(doc, wrapped, "this paragraph is wider than the bound, so it wraps inside 24 cells and the box grows.", .{
        .max_width = .{ .cells = 24 },
        .white_space = .normal,
    }, .{
        .color = foreground,
        .white_space = .normal,
    });

    const floored = try section(doc, root, "min-width: 18 floors an inline-block chip");
    _ = try common.addLabel(doc, floored, "min-width 18", .{
        .display = .inline_block,
        .min_width = .{ .cells = 18 },
        .height = .{ .cells = 1 },
        .background = accent,
        .text_align = .center,
    }, .{ .color = foreground, .bold = true });
    _ = try common.addText(doc, floored, "  width:auto keeps the floor", .{
        .color = dim,
    });

    const centered = try section(doc, root, "max-width + auto margins center a block");
    _ = try common.addLabel(doc, centered, "centered by auto margins", .{
        .height = .{ .cells = 1 },
        .max_width = .{ .cells = 24 },
        .margin = .{ .left = .auto, .right = .auto },
        .background = accent,
        .text_align = .center,
    }, .{ .color = foreground, .bold = true });

    const percentage = try section(doc, root, "max-width: 50% follows the panel");
    _ = try common.addLabel(doc, percentage, "half of the panel content width, wrapping as needed", .{
        .max_width = .{ .percent = 50 },
        .white_space = .normal,
    }, .{
        .color = foreground,
        .white_space = .normal,
    });
}
