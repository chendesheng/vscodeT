//! Border, padding and margin boxes, including an absolute child placed inside
//! the parent's padding box.
//!
//! Run with `cd ui && zig build example-borders`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const example = try bordersExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, init.io, example);
}

pub fn bordersExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "borders", .build = build };
}

fn build(
    _: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    size: common.Size,
) !void {
    const root = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = common.rgb(18, 18, 24),
    });

    _ = try common.addLabel(doc, root, "box model", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 60 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(255, 255, 255), .bold = true });

    // Outer box: 26x8 content + 1 padding + 1 border on every side.
    const outer = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 26 },
        .height = .{ .cells = 8 },
        .padding = ui.EdgeDecl.all(1),
        .border = ui.EdgeDecl.all(1),
        .border_color = common.rgb(120, 220, 160),
        .background = common.rgb(28, 32, 44),
    });
    _ = try common.addText(doc, outer, "border + padding", .{
        .color = common.rgb(255, 255, 255),
        .bold = true,
    });

    // Absolute child: left/top resolve against the parent's padding box; the
    // margin box is what gets anchored.
    const inner = try common.addBox(doc, outer, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 18 },
        .height = .{ .cells = 2 },
        .margin = ui.MarginDecl.all(1),
        .padding = ui.EdgeDecl.all(1),
        .border = ui.EdgeDecl.all(1),
        .border_color = common.rgb(230, 170, 100),
        .background = common.rgb(42, 46, 60),
    });
    _ = try common.addText(doc, inner, "margin + border", .{
        .color = common.rgb(230, 200, 140),
    });

    // Margin box anchored by left/top: border starts after the margin.
    const shifted = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 36 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 18 },
        .height = .{ .cells = 8 },
        .margin = ui.MarginDecl.all(2),
        .padding = ui.EdgeDecl.all(1),
        .border = ui.EdgeDecl.all(1),
        .border_color = common.rgb(200, 140, 220),
        .background = common.rgb(34, 28, 42),
        .overflow = .hidden,
    });
    _ = try common.addText(doc, shifted, "left/top anchor the margin box", .{
        .color = common.rgb(220, 190, 240),
    });

    _ = try common.addLabel(doc, root, "outer content 26x8; inner is absolute; shifted clips overflow", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = @floatFromInt(size.height -| 2) },
        .width = .{ .cells = 60 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(140, 140, 160) });
}
