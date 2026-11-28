//! Class records, a document stylesheet and cascade inheritance.
//!
//! Classes are integer enum values; their declarations live in the document's
//! array-backed stylesheet. Text inherits color and attributes from its
//! container, later classes override earlier ones, and the inline style wins.
//!
//! Run with `cd ui && zig build example-css`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const Class = enum(u16) {
    root,
    panel,
    title,
    row,
    selected,
    muted,
};

const styles = [_]ui.Style{
    .{
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = common.rgb(16, 16, 24),
        .color = common.rgb(205, 205, 220),
    },
    .{
        .padding = ui.EdgeDecl.all(1),
        .border = ui.EdgeDecl.all(1),
        .border_color = common.rgb(62, 72, 105),
        .background = common.rgb(28, 30, 44),
        .color = common.rgb(210, 215, 235),
        .overflow = .hidden,
    },
    .{
        .bold = true,
        .underline = true,
        .color = common.rgb(255, 255, 255),
    },
    .{
        .height = .{ .cells = 1 },
        .padding = .{ .left = 1 },
        .color = common.rgb(160, 165, 185),
    },
    .{
        .background = common.rgb(48, 66, 112),
        .color = common.rgb(255, 255, 255),
        .bold = true,
    },
    .{ .dim = true },
};

const sheet = ui.css.Sheet{ .base = 0, .styles = &styles };

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const example = try cssExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, init.io, example);
}

pub fn cssExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "css", .build = build };
}

fn build(
    _: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    _: common.Size,
) !void {
    _ = try doc.registerSheet(sheet);

    const canvas = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
    });
    try canvas.addClass(Class.root);

    const panel = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 3 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 52 },
        .height = .{ .cells = 8 },
    });
    try panel.addClass(Class.panel);

    const title = try common.addBox(doc, panel, .{
        .height = .{ .cells = 1 },
        .padding = .{ .left = 1 },
    });
    try title.addClass(Class.title);
    _ = try common.addText(doc, title, "cascade from class records", .{});

    drawRow(doc, panel, 1, "plain row", &.{.row});
    drawRow(doc, panel, 2, "selected row (row + selected)", &.{ .row, .selected });
    drawRow(doc, panel, 3, "muted row (row + muted)", &.{ .row, .muted });

    // Inline declaration on the text node wins over the inherited row color.
    const override = try common.addBox(doc, panel, .{
        .height = .{ .cells = 1 },
        .padding = .{ .left = 1 },
    });
    try override.addClass(Class.row);
    _ = try common.addText(doc, override, "inline color beats the row class", .{
        .color = common.rgb(255, 190, 110),
        .italic = true,
    });

    _ = try common.addText(doc, panel, "backgrounds are not inherited; text inherits color and attributes", .{
        .dim = true,
    });
}

fn drawRow(doc: *ui.Document, parent: *ui.Node, top_cell: usize, text: []const u8, classes: []const Class) void {
    const row = common.addBox(doc, parent, .{
        .margin = .{ .top = .{ .cells = @floatFromInt(top_cell) } },
    }) catch return;
    row.setClasses(classes) catch return;
    _ = common.addText(doc, row, text, .{}) catch return;
}
