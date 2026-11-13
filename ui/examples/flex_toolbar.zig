//! Flex toolbars: a growing spacer, justify-content variants, auto margins and
//! order.
//!
//! Run with `cd ui && zig build example-flex-toolbar`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const example = try flexToolbarExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, example);
}

pub fn flexToolbarExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "flex toolbar", .build = build };
}

const background = common.rgb(18, 18, 24);
const panel = common.rgb(30, 32, 44);
const raised = common.rgb(42, 46, 62);
const accent = common.rgb(88, 132, 220);
const foreground = common.rgb(232, 234, 244);
const dim = common.rgb(150, 154, 176);

fn build(
    _: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    size: common.Size,
) !void {
    const root = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = @floatFromInt(size.width -| 2) },
        .height = .{ .cells = @floatFromInt(size.height -| 2) },
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .row = 1 },
        .background = background,
    });

    _ = try common.addLabel(doc, root, "flex toolbar", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground, .bold = true });

    // A single growing spacer pushes the status label to the right.
    const main_bar = try common.addBox(doc, root, .{
        .height = .{ .cells = 3 },
        .display = .flex,
        .align_items = .center,
        .gap = .{ .column = 1 },
        .padding = .{ .left = 1, .right = 1 },
        .background = panel,
    });
    for ([_][]const u8{ "new", "open", "save" }) |label| {
        _ = try common.addLabel(doc, main_bar, label, .{
            .width = .{ .cells = 8 },
            .height = .{ .cells = 1 },
            .background = raised,
            .text_align = .center,
        }, .{ .color = foreground });
    }
    _ = try common.addBox(doc, main_bar, .{
        .height = .{ .cells = 1 },
        .flex_grow = 1,
    });
    _ = try common.addLabel(doc, main_bar, "main.zig", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });

    _ = try common.addLabel(doc, root, "justify-content", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });
    const justify = try common.addBox(doc, root, .{
        .height = .{ .cells = 3 },
        .display = .flex,
        .align_items = .center,
        .justify_content = .space_between,
        .padding = .{ .left = 1, .right = 1 },
        .background = panel,
    });
    _ = try common.addLabel(doc, justify, "flex-start", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground });
    _ = try common.addLabel(doc, justify, "space-between", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground });
    _ = try common.addLabel(doc, justify, "flex-end", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground });

    // Both auto spaces center the middle label; justify-content contributes
    // nothing while auto margins are absorbing free space.
    const margins = try common.addBox(doc, root, .{
        .height = .{ .cells = 3 },
        .display = .flex,
        .align_items = .center,
        .padding = .{ .left = 1, .right = 1 },
        .background = panel,
    });
    _ = try common.addLabel(doc, margins, "auto left", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });
    _ = try common.addLabel(doc, margins, "auto margins center", .{
        .height = .{ .cells = 1 },
        .margin = .{ .left = .auto, .right = .auto },
        .background = accent,
    }, .{ .color = foreground, .bold = true });
    _ = try common.addLabel(doc, margins, "auto right", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });

    _ = try common.addLabel(doc, root, "order: DOM 1, 2, 3", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });
    const ordered = try common.addBox(doc, root, .{
        .height = .{ .cells = 3 },
        .display = .flex,
        .align_items = .center,
        .gap = .{ .column = 1 },
        .padding = .{ .left = 1, .right = 1 },
        .background = panel,
    });
    _ = try common.addLabel(doc, ordered, "1  order 2", .{
        .width = .{ .cells = 12 },
        .height = .{ .cells = 1 },
        .order = 2,
        .background = raised,
        .text_align = .center,
    }, .{ .color = foreground });
    _ = try common.addLabel(doc, ordered, "2  order 0", .{
        .width = .{ .cells = 12 },
        .height = .{ .cells = 1 },
        .order = 0,
        .background = raised,
        .text_align = .center,
    }, .{ .color = foreground });
    _ = try common.addLabel(doc, ordered, "3  order 1", .{
        .width = .{ .cells = 12 },
        .height = .{ .cells = 1 },
        .order = 1,
        .background = raised,
        .text_align = .center,
    }, .{ .color = foreground });
}
