//! Absolute and percentage layout with left, center and right text alignment.
//!
//! Run with `cd ui && zig build example-layout`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const Panel = struct {
    left: f64,
    width: f64,
    alignment: ui.TextAlign,
    title: []const u8,
    body: []const u8,
    fill: ui.Color,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var surface = try ui.Surface.init(allocator, .{ .cols = 60, .rows = 11 });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = common.rgb(18, 18, 24),
    });
    doc.setRoot(root);

    const panels = [_]Panel{
        .{
            .left = 2,
            .width = 17,
            .alignment = .left,
            .title = "left",
            .body = "aligned at the left edge",
            .fill = common.rgb(30, 34, 48),
        },
        .{
            .left = 21,
            .width = 17,
            .alignment = .center,
            .title = "center",
            .body = "centered text",
            .fill = common.rgb(34, 38, 52),
        },
        .{
            .left = 40,
            .width = 18,
            .alignment = .right,
            .title = "right",
            .body = "right aligned",
            .fill = common.rgb(38, 32, 48),
        },
    };

    for (panels) |panel| {
        _ = try common.addBox(doc, root, .{
            .position = .absolute,
            .left = .{ .cells = panel.left },
            .top = .{ .cells = 2 },
            .width = .{ .cells = panel.width },
            .height = .{ .cells = 6 },
            .background = panel.fill,
        });

        _ = try common.addLabel(doc, root, panel.title, .{
            .position = .absolute,
            .left = .{ .cells = panel.left },
            .top = .{ .cells = 3 },
            .width = .{ .cells = panel.width },
            .height = .{ .cells = 1 },
            .text_align = panel.alignment,
        }, .{
            .color = common.rgb(255, 255, 255),
            .bold = true,
        });

        _ = try common.addLabel(doc, root, panel.body, .{
            .position = .absolute,
            .left = .{ .cells = panel.left },
            .top = .{ .cells = 5 },
            .width = .{ .cells = panel.width },
            .height = .{ .cells = 1 },
            .text_align = panel.alignment,
        }, .{
            .color = common.rgb(180, 200, 220),
        });
    }

    const bar = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 9 },
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .reverse = true,
    });
    _ = try common.addText(doc, bar, " absolute cells + percent width + text-align ", .{
        .reverse = true,
    });

    try common.present(&surface);
}
