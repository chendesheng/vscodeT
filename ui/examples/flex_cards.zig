//! Wrapping flex cards with gaps, fixed card sizes and align-content.
//!
//! Run with `cd ui && zig build example-flex-cards`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const example = try flexCardsExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, example);
}

pub fn flexCardsExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "flex cards", .build = build };
}

const cards = [_]struct { title: []const u8, body: []const u8 }{
    .{ .title = "direction", .body = "row / column" },
    .{ .title = "wrap", .body = "line breaking" },
    .{ .title = "grow", .body = "free space" },
    .{ .title = "shrink", .body = "overflow" },
    .{ .title = "basis", .body = "main size" },
    .{ .title = "justify", .body = "main axis" },
    .{ .title = "align", .body = "cross axis" },
    .{ .title = "gap", .body = "row + column" },
    .{ .title = "order", .body = "display order" },
    .{ .title = "margins", .body = "auto space" },
    .{ .title = "stretch", .body = "line cross" },
    .{ .title = "nested", .body = "flex in flex" },
};

const background = common.rgb(16, 17, 23);
const fill = common.rgb(30, 33, 45);
const fill_alt = common.rgb(35, 39, 54);
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

    _ = try common.addLabel(doc, root, "flex cards", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground, .bold = true });
    _ = try common.addLabel(doc, root, "wrap · gap · align-content: flex-start", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });

    const grid = try common.addBox(doc, root, .{
        .display = .flex,
        .flex_wrap = .wrap,
        .gap = .all(1),
        .align_content = .flex_start,
        .align_items = .flex_start,
        .flex_grow = 1,
    });

    for (cards, 0..) |card, index| {
        const tile = try common.addBox(doc, grid, .{
            .width = .{ .cells = 16 },
            .height = .{ .cells = 4 },
            .display = .flex,
            .flex_direction = .column,
            .gap = .{ .row = 0 },
            .padding = .{ .left = 1, .right = 1 },
            .background = if (index % 2 == 0) fill else fill_alt,
        });
        _ = try common.addLabel(doc, tile, card.title, .{
            .height = .{ .cells = 1 },
        }, .{ .color = foreground, .bold = true });
        _ = try common.addLabel(doc, tile, card.body, .{
            .height = .{ .cells = 1 },
        }, .{ .color = dim });
    }

    _ = try common.addLabel(doc, root, "12 cards · 4 per row at 80 columns", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });
}
