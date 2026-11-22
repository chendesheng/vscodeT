// Port of the terminal-adapted cases from
// `src/vs/workbench/test/browser/parts/statusbar/statusbarItem.test.ts`.
//
// The upstream suite exercises DOM pointer, touch and managed-hover behavior.
// Those browser event/hover services have no terminal counterpart; this file
// covers the portable item state and the terminal label/truncation/paint
// adaptations instead.

const std = @import("std");
const ui = @import("ui");
const item_mod = @import("../../../../browser/parts/statusbar/statusbarItem.zig");
const StatusbarItem = item_mod.StatusbarItem;
const statusbar = @import("../../../../services/statusbar/browser/statusbar.zig");

test "StatusbarItem: update, glyphs, command and tooltip" {
    const allocator = std.testing.allocator;
    var doc = try ui.Document.init(allocator, .{ .cols = 30, .rows = 1 });
    defer doc.deinit();

    var item = StatusbarItem.init(.{
        .name = "Language",
        .text = "Zig",
        .tooltip = "Select Language Mode",
    });
    try std.testing.expectEqualStrings("Language", item.name());
    try std.testing.expectEqualStrings("Zig", item.text());
    try std.testing.expect(item.tooltip() != null);
    try std.testing.expect(!item.hasCommand());
    try std.testing.expect(item.leadingGlyph() == null);

    item.update(.{
        .name = "Language",
        .text = "Zig",
        .show_beak = true,
        .show_progress = .loading,
        .command = .{ .id = "test.command", .arguments = &.{"arg"} },
    });
    try std.testing.expectEqualStrings("\u{27F3} ", item.leadingGlyph().?);
    try std.testing.expect(item.hasCommand());
    try std.testing.expectEqualStrings("test.command", item.command().?.id);
    try std.testing.expectEqualStrings("arg", item.command().?.arguments[0]);

    const nodes = try item.build(&doc, .{ .max_width_cells = 12 }, .{});
    try std.testing.expectEqualStrings("Zig", nodes.text.asText().data);
    try std.testing.expect(nodes.label.style().display == .flex);
    try std.testing.expect(nodes.label.style().overflow == .hidden);
}

test "StatusbarItem: kind colors and progress/beak substitution" {
    const allocator = std.testing.allocator;
    var doc = try ui.Document.init(allocator, .{ .cols = 20, .rows = 1 });
    defer doc.deinit();

    const item = StatusbarItem.init(.{
        .name = "Warn",
        .text = "warning",
        .kind = .warning,
        .show_progress = .syncing,
    });
    const nodes = try item.build(&doc, .{}, .{ .hovered = true, .focused = true });
    try std.testing.expect(nodes.container.style().background != null);
    try std.testing.expect(nodes.label.style().underline == true);
    try std.testing.expectEqualStrings("\u{21BB} ", item.leadingGlyph().?);
}
