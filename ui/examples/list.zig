//! A small table of rows: loops, alternating backgrounds, a highlighted row
//! and right-aligned columns.
//!
//! Run with `cd ui && zig build example-list`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const files = [_]struct { name: []const u8, lines: u32 }{
    .{ .name = "src/main.zig", .lines = 42 },
    .{ .name = "src/tui/app.zig", .lines = 343 },
    .{ .name = "src/tui/preview.zig", .lines = 321 },
    .{ .name = "ui/dom.zig", .lines = 470 },
    .{ .name = "ui/surface.zig", .lines = 121 },
    .{ .name = "docs/terminal-ui.md", .lines = 481 },
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var surface = try ui.Surface.init(allocator, .{ .cols = 58, .rows = 13 });
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

    _ = try common.addLabel(doc, root, "files", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 40 },
        .height = .{ .cells = 1 },
    }, .{
        .color = common.rgb(255, 255, 255),
        .bold = true,
    });

    _ = try common.addLabel(doc, root, "name", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 40 },
        .height = .{ .cells = 1 },
    }, .{
        .color = common.rgb(140, 140, 160),
    });
    _ = try common.addLabel(doc, root, "lines", .{
        .position = .absolute,
        .left = .{ .cells = 44 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 12 },
        .height = .{ .cells = 1 },
        .text_align = .right,
    }, .{
        .color = common.rgb(140, 140, 160),
    });

    for (files, 0..) |file, index| {
        const top: f64 = @floatFromInt(3 + index);
        const selected = index == 1;
        if (selected) {
            _ = try common.addBox(doc, root, .{
                .position = .absolute,
                .left = .{ .cells = 1 },
                .top = .{ .cells = top },
                .width = .{ .cells = 56 },
                .height = .{ .cells = 1 },
                .background = common.rgb(40, 44, 66),
            });
        }

        _ = try common.addLabel(doc, root, file.name, .{
            .position = .absolute,
            .left = .{ .cells = 2 },
            .top = .{ .cells = top },
            .width = .{ .cells = 40 },
            .height = .{ .cells = 1 },
        }, .{
            .color = if (selected) common.rgb(255, 255, 255) else common.rgb(200, 200, 210),
            .bold = selected,
        });

        var number_buf: [16]u8 = undefined;
        const number = try std.fmt.bufPrint(&number_buf, "{d}", .{file.lines});
        _ = try common.addLabel(doc, root, number, .{
            .position = .absolute,
            .left = .{ .cells = 44 },
            .top = .{ .cells = top },
            .width = .{ .cells = 12 },
            .height = .{ .cells = 1 },
            .text_align = .right,
        }, .{
            .color = common.rgb(120, 220, 160),
        });
    }

    _ = try common.addLabel(doc, root, "6 files", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 11 },
        .width = .{ .cells = 54 },
        .height = .{ .cells = 1 },
    }, .{
        .color = common.rgb(140, 140, 160),
    });

    try common.present(&surface, allocator);
}
