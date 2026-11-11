//! A small card drawn with direct styles: backgrounds, text colors, bold,
//! alignment and inline text runs.
//!
//! Run with `cd ui && zig build example-hello`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const example = try helloExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, example);
}

pub fn helloExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "hello", .build = build };
}

fn build(
    _: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    _: common.Size,
) !void {
    const root = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = common.rgb(18, 18, 24),
    });

    _ = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 46 },
        .height = .{ .cells = 6 },
        .border = ui.Edges.all(1),
        .border_color = common.rgb(70, 70, 100),
        .background = common.rgb(30, 30, 42),
        .overflow = .hidden,
    });

    _ = try common.addLabel(doc, root, "terminal ui", .{
        .position = .absolute,
        .left = .{ .cells = 4 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 44 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
    }, .{
        .color = common.rgb(255, 255, 255),
        .bold = true,
    });

    _ = try common.addLabel(doc, root, "a DOM-like tree, rendered one cell at a time", .{
        .position = .absolute,
        .left = .{ .cells = 4 },
        .top = .{ .cells = 3 },
        .width = .{ .cells = 44 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
    }, .{
        .color = common.rgb(120, 200, 255),
    });

    // Three inline runs in one row: the layout advances each by its width.
    const runs = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 4 },
        .top = .{ .cells = 5 },
        .width = .{ .cells = 44 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
    });
    _ = try common.addText(doc, runs, "direct styles", .{ .color = common.rgb(120, 220, 160), .bold = true });
    _ = try common.addText(doc, runs, "  no CSS", .{ .color = common.rgb(230, 200, 120) });
    _ = try common.addText(doc, runs, "  no HTML", .{ .color = common.rgb(200, 140, 200) });

    _ = try common.addLabel(doc, root, "one frame, one cell diff", .{
        .position = .absolute,
        .left = .{ .cells = 4 },
        .top = .{ .cells = 7 },
        .width = .{ .cells = 44 },
        .height = .{ .cells = 1 },
        .text_align = .right,
        .overflow = .hidden,
    }, .{
        .color = common.rgb(140, 140, 160),
    });
}
