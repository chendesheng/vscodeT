//! Overflow modes: the same long text and absolute child inside three fixed
//! boxes. `visible` lets both spill past the border; `hidden` and `clip` cut
//! them to the padding box. There is no scrolling yet, so `hidden` and `clip`
//! render the same.
//!
//! Run with `cd ui && zig build example-overflow`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const modes = [_]struct {
    name: []const u8,
    overflow: ui.Overflow,
}{
    .{ .name = "visible (spills)", .overflow = .visible },
    .{ .name = "hidden (clipped)", .overflow = .hidden },
    .{ .name = "clip (clipped)", .overflow = .clip },
};

const box_width = 16;
const box_height = 8;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const example = try overflowExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, init.io, example);
}

pub fn overflowExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "overflow", .build = build };
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

    _ = try common.addLabel(doc, root, "overflow", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 40 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(255, 255, 255), .bold = true });
    _ = try common.addLabel(doc, root, "long text and an absolute child in each box", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 60 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(140, 140, 160) });

    for (modes, 0..) |mode, index| {
        const left: f64 = @floatFromInt(1 + index * 21);
        _ = try common.addLabel(doc, root, mode.name, .{
            .position = .absolute,
            .left = .{ .cells = left },
            .top = .{ .cells = 2 },
            .width = .{ .cells = box_width },
            .height = .{ .cells = 1 },
        }, .{
            .color = common.rgb(220, 220, 235),
            .bold = true,
        });

        const container = try common.addBox(doc, root, .{
            .position = .absolute,
            .left = .{ .cells = left },
            .top = .{ .cells = 3 },
            .width = .{ .cells = box_width },
            .height = .{ .cells = box_height },
            .padding = ui.EdgeDecl.all(1),
            .border = ui.EdgeDecl.all(1),
            .border_color = common.rgb(90, 90, 120),
            .background = common.rgb(28, 30, 40),
            .overflow = mode.overflow,
        });

        _ = try common.addText(doc, container, "this text is longer than the box", .{
            .color = common.rgb(200, 210, 230),
        });

        const child = try common.addBox(doc, container, .{
            .position = .absolute,
            .left = .{ .cells = 14 },
            .top = .{ .cells = 4 },
            .width = .{ .cells = 12 },
            .height = .{ .cells = 1 },
            .background = common.rgb(60, 86, 130),
        });
        _ = try common.addText(doc, child, "absolute child", .{
            .color = common.rgb(240, 240, 255),
        });
    }

    _ = try common.addLabel(doc, root, "hidden/clip cut to the padding box; visible lets content leave it", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = @floatFromInt(size.height -| 2) },
        .width = .{ .cells = 60 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(140, 140, 160) });
}
