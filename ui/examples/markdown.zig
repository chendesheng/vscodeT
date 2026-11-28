//! Markdown: headings, inline styles, links, lists, block quotes, code,
//! thematic breaks and a GFM table rendered with the `ui` cell primitives.
//! The document taller than the viewport scrolls with the wheel and shows a
//! proportional scrollbar on the right.
//!
//! Run with `cd ui && zig build example-markdown`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const background = common.rgb(18, 18, 24);
const panel_background = common.rgb(24, 26, 34);
const text_color = common.rgb(204, 204, 204);
const dim = common.rgb(140, 140, 160);
const heading_color = common.rgb(235, 235, 235);
const code_color = common.rgb(215, 186, 125);
const code_background = common.rgb(30, 30, 30);
const link_color = common.rgb(55, 148, 255);
const rule_color = common.rgb(90, 90, 90);
const scrollbar_track_color = common.rgb(34, 36, 46);
const scrollbar_thumb_color = common.rgb(96, 102, 128);

const rule_text = "────────────────────────────────────────────────────";
const content_height: usize = 36;

const Scene = struct {
    allocator: std.mem.Allocator,
    scroll_view: ui.ScrollView = undefined,
    initialized: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const example = try markdownExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, init.io, example);
}

pub fn markdownExample(allocator: std.mem.Allocator) !common.Example {
    const scene = try allocator.create(Scene);
    scene.* = .{ .allocator = allocator };
    return .{
        .title = "markdown",
        .context = scene,
        .build = build,
        .deinit = sceneDeinit,
    };
}

fn sceneDeinit(context: ?*anyopaque) void {
    const scene: *Scene = @ptrCast(@alignCast(context orelse return));
    scene.allocator.destroy(scene);
}

fn build(
    context: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    size: common.Size,
) !void {
    const scene: *Scene = @ptrCast(@alignCast(context orelse return));

    const root = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = background,
    });

    const panel_width: usize = @max(@min(size.width -| 4, 58), 1);
    const panel_height: usize = @max(@min(size.height -| 2, 24), 1);
    const previous_scroll = if (scene.initialized) scene.scroll_view.scrollTop() else 0;
    try scene.scroll_view.init(doc, root, .{
        .left = 2,
        .top = 1,
        .width = panel_width,
        .height = panel_height,
        .content_height = content_height,
        .initial_scroll = previous_scroll,
        .background = panel_background,
        .track_color = scrollbar_track_color,
        .thumb_color = scrollbar_thumb_color,
    });
    scene.initialized = true;

    const row_width = scene.scroll_view.contentWidth() -| 2;
    try addContent(doc, scene.scroll_view.contentNode(), row_width);
}

fn addContent(doc: *ui.Document, content: *ui.Node, row_width: usize) !void {
    var row = try addRow(doc, content, 0, row_width);
    try addRun(doc, row, "Terminal Markdown", .{
        .color = heading_color,
        .bold = true,
        .underline = true,
    });

    row = try addRow(doc, content, 2, row_width);
    try addRun(doc, row, "Hover contents render as ", .{ .color = text_color });
    try addRun(doc, row, "bold", .{ .color = text_color, .bold = true });
    try addRun(doc, row, ", ", .{ .color = text_color });
    try addRun(doc, row, "italic", .{ .color = text_color, .italic = true });
    try addRun(doc, row, ", ", .{ .color = text_color });
    try addRun(doc, row, "code", .{ .color = code_color });
    try addRun(doc, row, " and ", .{ .color = text_color });
    try addRun(doc, row, "links", .{ .color = link_color, .underline = true });

    row = try addRow(doc, content, 3, row_width);
    try addRun(doc, row, "see ", .{ .color = text_color });
    try addRun(doc, row, "docs", .{ .color = link_color, .underline = true });
    try addRun(doc, row, " (https://example.com)", .{ .color = link_color, .dim = true });

    try addTextRow(doc, content, 5, row_width, "• first item", .{ .color = text_color });
    try addTextRow(doc, content, 6, row_width, "  • nested item", .{ .color = text_color });
    try addTextRow(doc, content, 7, row_width, "[x] done", .{ .color = text_color });
    try addTextRow(doc, content, 8, row_width, "[ ] todo", .{ .color = dim });

    row = try addRow(doc, content, 10, row_width);
    try addRun(doc, row, "│ ", .{ .color = rule_color, .dim = true });
    try addRun(doc, row, "Quoted text", .{ .color = text_color });

    try addCodeRow(doc, content, 12, row_width, "  const answer = 42;");
    try addCodeRow(doc, content, 13, row_width, "  render(markdown);");

    row = try addRow(doc, content, 15, row_width);
    const rule_bytes = @min(rule_text.len, row_width * "─".len);
    try addRun(doc, row, rule_text[0..rule_bytes], .{ .color = rule_color });

    try addTextRow(doc, content, 17, row_width, "┌───────┬───────┐", .{ .color = rule_color });
    row = try addRow(doc, content, 18, row_width);
    try addRun(doc, row, "│ ", .{ .color = rule_color });
    try addRun(doc, row, "name", .{ .color = heading_color, .bold = true });
    try addRun(doc, row, "  │ ", .{ .color = rule_color });
    try addRun(doc, row, "value", .{ .color = heading_color, .bold = true });
    try addRun(doc, row, " │", .{ .color = rule_color });
    try addTextRow(doc, content, 19, row_width, "├───────┼───────┤", .{ .color = rule_color });
    row = try addRow(doc, content, 20, row_width);
    try addRun(doc, row, "│ ", .{ .color = rule_color });
    try addRun(doc, row, "alpha", .{ .color = text_color });
    try addRun(doc, row, " │ ", .{ .color = rule_color });
    try addRun(doc, row, "1", .{ .color = text_color });
    try addRun(doc, row, "     │", .{ .color = rule_color });
    try addTextRow(doc, content, 21, row_width, "└───────┴───────┘", .{ .color = rule_color });

    row = try addRow(doc, content, 23, row_width);
    try addRun(doc, row, "More Markdown", .{ .color = heading_color, .bold = true });

    try addTextRow(doc, content, 24, row_width, "Scroll with the wheel to read the rest.", .{ .color = dim });
    try addTextRow(doc, content, 25, row_width, "• headings", .{ .color = text_color });
    try addTextRow(doc, content, 26, row_width, "• lists", .{ .color = text_color });
    try addTextRow(doc, content, 27, row_width, "• tables", .{ .color = text_color });
    try addCodeRow(doc, content, 29, row_width, "  const scroll = true;");
    try addCodeRow(doc, content, 30, row_width, "  reveal(more);");

    row = try addRow(doc, content, 32, row_width);
    try addRun(doc, row, "│ ", .{ .color = rule_color, .dim = true });
    try addRun(doc, row, "The scrollbar tracks", .{ .color = text_color });
    row = try addRow(doc, content, 33, row_width);
    try addRun(doc, row, "│ ", .{ .color = rule_color, .dim = true });
    try addRun(doc, row, "wrapped content.", .{ .color = text_color });
    try addTextRow(doc, content, 35, row_width, "End of document.", .{ .color = dim });
}

fn addRow(doc: *ui.Document, parent: *ui.Node, y: usize, width: usize) !*ui.Node {
    return common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = @floatFromInt(y) },
        .width = .{ .cells = @floatFromInt(width) },
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .overflow = .clip,
    });
}

fn addRun(doc: *ui.Document, row: *ui.Node, text: []const u8, style: ui.Style) !void {
    _ = try common.addText(doc, row, text, style);
}

fn addTextRow(
    doc: *ui.Document,
    parent: *ui.Node,
    y: usize,
    width: usize,
    text: []const u8,
    style: ui.Style,
) !void {
    const row = try addRow(doc, parent, y, width);
    try addRun(doc, row, text, style);
}

fn addCodeRow(
    doc: *ui.Document,
    parent: *ui.Node,
    y: usize,
    width: usize,
    text: []const u8,
) !void {
    const row = try addRow(doc, parent, y, width);
    var style = row.style().*;
    style.background = code_background;
    row.setStyle(style);
    try addRun(doc, row, text, .{ .color = code_color });
}
