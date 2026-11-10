//! A bordered table with aligned columns and alternating row backgrounds.
//!
//! Run with `cd ui && zig build example-table`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const commits = [_]struct { hash: []const u8, subject: []const u8, lines: u32 }{
    .{ .hash = "a3a9c4e", .subject = "Add standalone terminal UI library", .lines = 2986 },
    .{ .hash = "875fb7c", .subject = "Add derived layout tree", .lines = 835 },
    .{ .hash = "8ee35ef", .subject = "Update terminal ui design doc", .lines = 254 },
    .{ .hash = "2d44ebc", .subject = "Port folding ranges and models", .lines = 924 },
    .{ .hash = "41c1ade", .subject = "Port cursor and editing contributions", .lines = 1218 },
    .{ .hash = "758f160", .subject = "Mirror upstream contrib test paths", .lines = 431 },
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var surface = try ui.Surface.init(allocator, .{ .cols = 64, .rows = 16 });
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

    _ = try common.addLabel(doc, root, "recent commits", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 60 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(255, 255, 255), .bold = true });

    const table = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 58 },
        .height = .{ .cells = 8 },
        .padding = ui.Edges.all(1),
        .border = ui.Edges.all(1),
        .border_color = common.rgb(70, 70, 100),
        .background = common.rgb(26, 28, 38),
    });

    _ = try common.addLabel(doc, table, "hash", .{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 8 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(140, 140, 160), .bold = true });
    _ = try common.addLabel(doc, table, "subject", .{
        .position = .absolute,
        .left = .{ .cells = 10 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 28 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(140, 140, 160), .bold = true });
    _ = try common.addLabel(doc, table, "lines", .{
        .position = .absolute,
        .left = .{ .cells = 44 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 12 },
        .height = .{ .cells = 1 },
        .text_align = .right,
    }, .{ .color = common.rgb(140, 140, 160), .bold = true });

    _ = try common.addBox(doc, table, .{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 56 },
        .height = .{ .cells = 1 },
        .background = common.rgb(60, 60, 80),
    });

    for (commits, 0..) |commit, index| {
        const top: f64 = @floatFromInt(2 + index);
        if (index % 2 == 1) {
            _ = try common.addBox(doc, table, .{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = top },
                .width = .{ .cells = 58 },
                .height = .{ .cells = 1 },
                .background = common.rgb(32, 34, 46),
            });
        }

        _ = try common.addLabel(doc, table, commit.hash, .{
            .position = .absolute,
            .left = .{ .cells = 1 },
            .top = .{ .cells = top },
            .width = .{ .cells = 8 },
            .height = .{ .cells = 1 },
        }, .{ .color = common.rgb(200, 200, 210) });

        _ = try common.addLabel(doc, table, commit.subject, .{
            .position = .absolute,
            .left = .{ .cells = 10 },
            .top = .{ .cells = top },
            .width = .{ .cells = 28 },
            .height = .{ .cells = 1 },
        }, .{ .color = common.rgb(200, 200, 210) });

        var number_buf: [16]u8 = undefined;
        const number = try std.fmt.bufPrint(&number_buf, "{d}", .{commit.lines});
        _ = try common.addLabel(doc, table, number, .{
            .position = .absolute,
            .left = .{ .cells = 44 },
            .top = .{ .cells = top },
            .width = .{ .cells = 12 },
            .height = .{ .cells = 1 },
            .text_align = .right,
        }, .{ .color = common.rgb(120, 220, 160) });
    }

    try common.present(&surface, allocator);
}
