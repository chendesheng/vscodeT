//! Text attributes, foreground colors and background swatches.
//!
//! Run with `cd ui && zig build example-styling`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const samples = [_]struct { text: []const u8, style: ui.Style }{
    .{ .text = "bold", .style = .{ .bold = true } },
    .{ .text = "italic", .style = .{ .italic = true } },
    .{ .text = "underline", .style = .{ .underline = true } },
    .{ .text = "strikethrough", .style = .{ .strikethrough = true } },
    .{ .text = "dim", .style = .{ .dim = true } },
    .{ .text = "reverse", .style = .{ .reverse = true } },
    .{ .text = "green on panel", .style = .{ .color = common.rgb(120, 220, 160), .background = common.rgb(30, 34, 48) } },
};

const palette = [_]ui.Color{
    common.rgb(255, 100, 100),
    common.rgb(255, 170, 80),
    common.rgb(255, 230, 100),
    common.rgb(120, 220, 160),
    common.rgb(100, 200, 255),
    common.rgb(140, 140, 255),
    common.rgb(220, 140, 255),
    common.rgb(240, 240, 240),
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var surface = try ui.Surface.init(allocator, .{ .cols = 64, .rows = 14 });
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

    _ = try common.addLabel(doc, root, "text styles and colors", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 60 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(255, 255, 255), .bold = true });

    for (samples, 0..) |sample, index| {
        var style = sample.style;
        style.position = .absolute;
        style.left = .{ .cells = 2 };
        style.top = .{ .cells = @floatFromInt(2 + index) };
        style.width = .{ .cells = 28 };
        style.height = .{ .cells = 1 };
        if (style.color == null) style.color = common.rgb(220, 220, 230);
        _ = try common.addLabel(doc, root, sample.text, style, .{
            .color = style.color,
            .bold = style.bold,
            .italic = style.italic,
            .underline = style.underline,
            .strikethrough = style.strikethrough,
            .dim = style.dim,
            .reverse = style.reverse,
            .background = style.background,
        });
    }

    // Eight 3x2 background swatches.
    for (palette, 0..) |color, index| {
        _ = try common.addBox(doc, root, .{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(38 + index * 3) },
            .top = .{ .cells = 2 },
            .width = .{ .cells = 2 },
            .height = .{ .cells = 2 },
            .background = color,
        });
    }

    _ = try common.addLabel(doc, root, "truecolor foreground, background and attributes", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 11 },
        .width = .{ .cells = 60 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(140, 140, 160) });

    try common.present(&surface);
}
