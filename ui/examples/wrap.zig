//! Text flow: normal wrapping, nowrap clipping, preformatted spaces and
//! per-line alignment.
//!
//! Run with `cd ui && zig build example-wrap`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const example = try wrapExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, example);
}

pub fn wrapExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "wrap", .build = build };
}

fn panel(
    doc: *ui.Document,
    root: *ui.Node,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    fill: ui.Color,
) !*ui.Node {
    return common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = x },
        .top = .{ .cells = y },
        .width = .{ .cells = width },
        .height = .{ .cells = height },
        .padding = ui.Edges.all(1),
        .background = fill,
        .overflow = .hidden,
    });
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

    _ = try common.addLabel(doc, root, "text flow", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 60 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(255, 255, 255), .bold = true });

    // normal: wrap at UAX #14 opportunities and grow the box height.
    const normal = try panel(doc, root, 2, 2, 36, 7, common.rgb(30, 34, 48));
    _ = try common.addLabel(doc, normal, "normal text wraps at the last break opportunity that fits and lets a long unbreakable word overflow.", .{
        .width = .{ .percent = 100 },
        .white_space = .normal,
    }, .{
        .color = common.rgb(220, 220, 235),
        .white_space = .normal,
    });

    // nowrap: one line, clipped by the fixed-height overflow box.
    const clipped = try panel(doc, root, 40, 2, 20, 4, common.rgb(42, 30, 30));
    _ = try common.addLabel(doc, clipped, "nowrap keeps this whole sentence on one line and clips it", .{
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .white_space = .nowrap,
    }, .{
        .color = common.rgb(235, 200, 200),
        .white_space = .nowrap,
    });

    // pre: indentation and runs of spaces survive.
    const pre = try panel(doc, root, 2, 10, 36, 5, common.rgb(26, 40, 32));
    _ = try common.addLabel(doc, pre, "  indented\n    code   keeps   spaces", .{
        .width = .{ .percent = 100 },
        .white_space = .pre,
    }, .{
        .color = common.rgb(200, 230, 205),
        .white_space = .pre,
    });

    // text-align applies to each wrapped line.
    const centered = try panel(doc, root, 40, 7, 38, 5, common.rgb(36, 32, 52));
    _ = try common.addLabel(doc, centered, "each wrapped line is centered independently", .{
        .width = .{ .percent = 100 },
        .text_align = .center,
    }, .{
        .color = common.rgb(220, 210, 245),
        .white_space = .normal,
    });

    // The long word has no break opportunity, so it spills out of its box.
    const word = try panel(doc, root, 40, 13, 20, 3, common.rgb(48, 42, 24));
    _ = try common.addLabel(doc, word, "supercalifragilisticexpialidocious", .{
        .width = .{ .percent = 100 },
        .white_space = .normal,
    }, .{
        .color = common.rgb(240, 225, 160),
        .white_space = .normal,
    });
}
