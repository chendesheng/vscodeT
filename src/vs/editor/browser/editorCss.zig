//! Registry for the hand-ported VSCode CSS files.
//!
//! Each `*_css.zig` file owns a disjoint `u16` class-ID range and an
//! array-backed `Sheet`. The document stores the styles; nodes only hold the
//! integer class IDs. There is no generator: new ports pick a free block and
//! are registered here.

const std = @import("std");
const ui = @import("ui");

const block_decorations_css = @import("viewParts/blockDecorations/blockDecorations_css.zig");
const view_lines_css = @import("viewParts/viewLines/viewLines_css.zig");
const overlay_widgets_css = @import("viewParts/overlayWidgets/overlayWidgets_css.zig");
const sash_css = @import("../../base/browser/ui/sash/sash_css.zig");
const folding_css = @import("../contrib/folding/browser/folding_css.zig");

pub const block_decorations = block_decorations_css;
pub const view_lines = view_lines_css;
pub const overlay_widgets = overlay_widgets_css;
pub const folding = folding_css;

/// Registers every ported sheet. Safe to call once per document; `Document.clear`
/// keeps the stylesheet. Re-registering a themed sheet would overwrite its own
/// range in place.
pub fn register(doc: *ui.Document) !void {
    _ = try doc.registerSheet(block_decorations_css.sheet);
    _ = try doc.registerSheet(view_lines_css.sheet);
    _ = try doc.registerSheet(overlay_widgets_css.sheet);
    _ = try doc.registerSheet(sash_css.sheet);
    _ = try doc.registerSheet(folding_css.sheet);
}

test "editor css: sheets register into disjoint class ranges" {
    const allocator = std.testing.allocator;
    var doc = try ui.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();

    try register(&doc);

    const block = doc.classStyle(@backingInt(block_decorations_css.Class.block_decorations_block)).?;
    try std.testing.expectEqual(ui.Position.absolute, block.position.?);

    const container = doc.classStyle(@backingInt(block_decorations_css.Class.block_decorations_container)).?;
    try std.testing.expectEqual(ui.Position.absolute, container.position.?);

    const lines = doc.classStyle(@backingInt(view_lines_css.Class.view_lines)).?;
    try std.testing.expectEqual(ui.WhiteSpace.nowrap, lines.white_space.?);

    const line = doc.classStyle(@backingInt(view_lines_css.Class.view_line)).?;
    try std.testing.expectEqual(ui.Position.absolute, line.position.?);

    const overlays = doc.classStyle(@backingInt(overlay_widgets_css.Class.overlay_widgets)).?;
    try std.testing.expectEqual(ui.Position.absolute, overlays.position.?);

    const vertical_sash = doc.classStyle(@backingInt(sash_css.Class.vertical)).?;
    try std.testing.expectEqual(ui.Pointer.ew_resize, vertical_sash.pointer.?);
    const horizontal_sash = doc.classStyle(@backingInt(sash_css.Class.horizontal)).?;
    try std.testing.expectEqual(ui.Pointer.ns_resize, horizontal_sash.pointer.?);

    const fold_icon = doc.classStyle(@backingInt(folding_css.Class.codicon_folding)).?;
    try std.testing.expectEqual(ui.Visibility.hidden, fold_icon.visibility.?);

    // Ranges are disjoint.
    try std.testing.expect(block_decorations_css.base < view_lines_css.base);
    try std.testing.expect(view_lines_css.base < overlay_widgets_css.base);
    try std.testing.expect(overlay_widgets_css.base < sash_css.base);
    try std.testing.expect(sash_css.base < folding_css.base);
}
