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
pub const workbench = @import("../../workbench/browser/media/style_css.zig");
pub const part = @import("../../workbench/browser/media/part_css.zig");
pub const gridview = @import("../../base/browser/ui/grid/gridview_css.zig");
pub const splitview = @import("../../base/browser/ui/splitview/splitview_css.zig");
pub const editor_group = @import("../../workbench/browser/parts/editor/media/editorgroupview_css.zig");
pub const search_view = @import("../../workbench/contrib/search/browser/media/searchview_css.zig");
pub const search_editor = @import("../../workbench/contrib/searchEditor/browser/media/searchEditor_css.zig");
pub const scm = @import("../../workbench/contrib/scm/browser/media/scm_css.zig");
pub const codelens = @import("../contrib/codelens/browser/codelensWidget_css.zig");
pub const zone_widget = @import("../contrib/zoneWidget/browser/zoneWidget_css.zig");
pub const peek_view = @import("../contrib/peekView/browser/media/peekViewWidget_css.zig");
pub const diff_editor = @import("widget/diffEditor/style_css.zig");
pub const multi_diff_editor = @import("widget/multiDiffEditor/style_css.zig");
pub const hover = @import("../contrib/hover/browser/hover_css.zig");
pub const hover_widget = @import("../../base/browser/ui/hover/hoverWidget_css.zig");
pub const light_bulb = @import("../contrib/codeAction/browser/lightBulbWidget_css.zig");
pub const message = @import("../contrib/message/browser/messageController_css.zig");
pub const code_editor = @import("widget/codeEditor/editor_css.zig");

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
    _ = try doc.registerSheet(code_editor.sheet);
    _ = try doc.registerSheet(diff_editor.sheet);
    _ = try doc.registerSheet(multi_diff_editor.sheet);
    _ = try doc.registerSheet(codelens.sheet);
    _ = try doc.registerSheet(zone_widget.sheet);
    _ = try doc.registerSheet(peek_view.sheet);
    _ = try doc.registerSheet(hover_widget.sheet);
    _ = try doc.registerSheet(hover.sheet);
    _ = try doc.registerSheet(light_bulb.sheet);
    _ = try doc.registerSheet(message.sheet);
}

pub fn registerWorkbench(doc: *ui.Document) !void {
    try register(doc);
    _ = try doc.registerSheet(workbench.sheet);
    _ = try doc.registerSheet(part.sheet);
    _ = try doc.registerSheet(gridview.sheet);
    _ = try doc.registerSheet(splitview.sheet);
    _ = try doc.registerSheet(editor_group.sheet);
    try registerSearchView(doc);
    _ = try doc.registerSheet(scm.sheet);
}

pub fn registerSearchView(doc: *ui.Document) !void {
    _ = try doc.registerSheet(search_view.sheet);
    _ = try doc.registerSheet(search_editor.sheet);
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

    const disclosure = doc.classStyle(@backingInt(diff_editor.Class.diff_hidden_lines)).?;
    try std.testing.expectEqual(ui.Display.flex, disclosure.display.?);
    try std.testing.expectEqual(ui.Pointer.pointer, doc.classStyle(@backingInt(diff_editor.Class.bottom)).?.pointer.?);

    try std.testing.expectEqual(ui.Position.absolute, doc.classStyle(@backingInt(zone_widget.Class.zone_widget)).?.position.?);
    try std.testing.expectEqual(ui.Display.flex, doc.classStyle(@backingInt(peek_view.Class.head)).?.display.?);
    try std.testing.expect(codelens.base < zone_widget.base and zone_widget.base < peek_view.base);

    try std.testing.expectEqual(ui.Display.flex, doc.classStyle(@backingInt(multi_diff_editor.Class.header_content)).?.display.?);
    try std.testing.expect(peek_view.base < multi_diff_editor.base);

    try std.testing.expectEqual(ui.Overflow.hidden, doc.classStyle(@backingInt(hover_widget.Class.monaco_hover)).?.overflow.?);
    try std.testing.expectEqual(ui.Position.absolute, doc.classStyle(@backingInt(hover_widget.Class.monaco_hover_content)).?.position.?);
    try std.testing.expect(multi_diff_editor.base < hover_widget.base and hover_widget.base < hover.base);
    try std.testing.expect(hover.base < light_bulb.base and light_bulb.base < message.base);
    try std.testing.expectEqual(ui.WhiteSpace.pre_wrap, doc.classStyle(@backingInt(message.Class.message)).?.white_space.?);
    try std.testing.expectEqual(ui.Pointer.pointer, doc.classStyle(@backingInt(light_bulb.Class.light_bulb_widget)).?.pointer.?);
    const color = ui.Color{ .r = 5, .g = 6, .b = 7 };
    try hover.registerTheme(&doc, .{ .background = color });
    try std.testing.expectEqual(color, doc.classStyle(@backingInt(hover.Class.monaco_hover)).?.background.?);

    try light_bulb.registerTheme(&doc, .{ .ai = color });
    try std.testing.expectEqual(color, doc.classStyle(@backingInt(light_bulb.Class.codicon_sparkle_filled)).?.color.?);

    // Ranges are disjoint.
    try std.testing.expect(block_decorations_css.base < view_lines_css.base);
    try std.testing.expect(view_lines_css.base < overlay_widgets_css.base);
    try std.testing.expect(overlay_widgets_css.base < sash_css.base);
    try std.testing.expect(sash_css.base < folding_css.base);
}

test "editor css: workbench editor and split layout rules register together" {
    var doc = try ui.Document.init(std.testing.allocator, .{ .cols = 20, .rows = 8 });
    defer doc.deinit();
    try registerWorkbench(&doc);

    const root = doc.classStyle(@backingInt(workbench.Class.monaco_workbench)).?;
    try std.testing.expectEqual(ui.Position.relative, root.position.?);
    try std.testing.expectEqual(ui.Overflow.hidden, doc.classStyle(@backingInt(part.Class.part)).?.overflow.?);
    const grid = doc.classStyle(@backingInt(gridview.Class.monaco_grid_view)).?;
    try std.testing.expectEqual(ui.Overflow.hidden, grid.overflow.?);
    const split = doc.classStyle(@backingInt(splitview.Class.split_view_view)).?;
    try std.testing.expectEqual(ui.Position.absolute, split.position.?);
    const hidden = doc.classStyle(@backingInt(splitview.Class.hidden_view)).?;
    try std.testing.expectEqual(ui.Display.none, hidden.display.?);
    const instance = doc.classStyle(@backingInt(editor_group.Class.editor_instance)).?;
    try std.testing.expectEqual(ui.Dimension{ .percent = 100 }, instance.height.?);
    const more = doc.classStyle(@backingInt(search_view.Class.more)).?;
    try std.testing.expectEqual(ui.Pointer.pointer, more.pointer.?);
    const guard = doc.classStyle(@backingInt(code_editor.Class.overflow_guard)).?;
    try std.testing.expectEqual(ui.Overflow.hidden, guard.overflow.?);
}
