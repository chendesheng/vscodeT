//! Flex reverse directions: row-reverse, column-reverse and wrap-reverse.
//!
//! Run with `cd ui && zig build example-flex-reverse`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const example = try flexReverseExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, init.io, example);
}

pub fn flexReverseExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "flex reverse", .build = build };
}

const background = common.rgb(17, 18, 24);
const panel = common.rgb(29, 32, 44);
const raised = common.rgb(40, 45, 61);
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

    _ = try common.addLabel(doc, root, "flex reverse", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground, .bold = true });

    // row-reverse: the first child is placed at the main-start (right) edge.
    const row = try common.addBox(doc, root, .{
        .height = .{ .cells = 3 },
        .display = .flex,
        .flex_direction = .row_reverse,
        .align_items = .center,
        .gap = .{ .column = 1 },
        .padding = .{ .left = 1, .right = 1 },
        .background = panel,
    });
    for ([_][]const u8{ "1", "2", "3" }) |label| {
        _ = try common.addLabel(doc, row, label, .{
            .width = .{ .cells = 8 },
            .height = .{ .cells = 1 },
            .background = raised,
            .text_align = .center,
        }, .{ .color = foreground });
    }

    const lower = try common.addBox(doc, root, .{
        .display = .flex,
        .gap = .{ .column = 1 },
        .flex_grow = 1,
    });

    // column-reverse: the first child is placed at the bottom.
    const column_demo = try common.addBox(doc, lower, .{
        .width = .{ .percent = 49 },
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .row = 1 },
        .flex_grow = 1,
        .padding = ui.EdgeDecl.all(1),
        .background = panel,
    });
    _ = try common.addLabel(doc, column_demo, "column-reverse", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });
    const column = try common.addBox(doc, column_demo, .{
        .display = .flex,
        .flex_direction = .column_reverse,
        .gap = .{ .row = 1 },
        .flex_grow = 1,
        .padding = ui.EdgeDecl.all(1),
        .background = raised,
    });
    for ([_][]const u8{ "1 first", "2", "3" }) |label| {
        _ = try common.addLabel(doc, column, label, .{
            .height = .{ .cells = 1 },
        }, .{ .color = foreground });
    }

    // wrap-reverse: line 1 is the bottom line.
    const wrap_demo = try common.addBox(doc, lower, .{
        .width = .{ .percent = 49 },
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .row = 1 },
        .flex_grow = 1,
        .padding = ui.EdgeDecl.all(1),
        .background = panel,
    });
    _ = try common.addLabel(doc, wrap_demo, "wrap-reverse", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });
    const wrapped = try common.addBox(doc, wrap_demo, .{
        .display = .flex,
        .flex_wrap = .wrap_reverse,
        .align_content = .flex_start,
        .gap = ui.GapDecl.all(1),
        .flex_grow = 1,
        .overflow = .hidden,
        .background = raised,
    });
    for ([_][]const u8{ "1", "2", "3", "4", "5", "6" }) |label| {
        _ = try common.addLabel(doc, wrapped, label, .{
            // Two items fit per line at every terminal width; 40% + gap + 40%
            // stays inside the container, so wrap-reverse cannot spill upward
            // over the heading or the row above.
            .width = .{ .percent = 40 },
            .height = .{ .cells = 2 },
            .background = accent,
            .text_align = .center,
        }, .{ .color = foreground });
    }
}
