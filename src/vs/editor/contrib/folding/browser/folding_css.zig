// Port of `src/vs/editor/contrib/folding/browser/folding.css`.
//
// Terminal adaptation: a cell has no alpha, so the `opacity: 0` fold icons
// become `visibility: hidden` (the box keeps its cell and hit target, only the
// glyph is skipped). `.margin-view-overlays:hover .codicon { opacity: 1 }` has
// no selector engine here; it becomes `hoverStyle()` on the margin container,
// whose paint-only visibility overlay is inherited by the icon text for the
// duration of the hover (see `ui.HoverStyle.visibility`). Transitions, the
// reduce-motion rule, flex centering/font-size/margin rules, `inline-folded`
// (the view paints the end-of-line ellipsis from the fold decoration intent)
// and `folded-background` (painted from `FoldingDecorationOption`) have no cell
// equivalent or are ported in the decoration/view layer. The `cldr` color rule
// is the `editorGutter.foldingControlForeground` theme color resolved by the
// TUI and passed in `TerminalMargin.Theme`; there is no `!important`.

const std = @import("std");
const ui = @import("ui");

pub const base: u16 = 0x0040;

pub const Class = enum(u16) {
    /// `.codicon-folding-manual-collapsed`, `.codicon-folding-manual-expanded`,
    /// `.codicon-folding-expanded`, `.codicon-folding-collapsed`
    codicon_folding = base,
    /// `.codicon-folding-collapsed`, `.codicon-folding-manual-collapsed`
    codicon_folding_collapsed = base + 1,
    /// `.codicon.alwaysShowFoldIcons`
    always_show_fold_icons = base + 2,
};

const styles = [_]ui.Style{
    .{ .visibility = .hidden, .pointer = .pointer },
    .{ .visibility = .visible },
    .{ .visibility = .visible },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };

/// `.monaco-editor .margin-view-overlays:hover .codicon { opacity: 1; }`
///
/// Attach to the margin overlay container. While it is in the hover chain, the
/// painter paints every hidden descendant codicon (and nothing else changes).
pub fn hoverStyle() ui.HoverStyle {
    return .{ .visibility = .visible };
}

test "folding css: hidden codicon and always-visible overrides" {
    const testing = std.testing;
    var doc = try ui.Document.init(testing.allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();
    _ = try doc.registerSheet(sheet);

    const hidden = doc.classStyle(@backingInt(Class.codicon_folding)).?;
    try testing.expectEqual(ui.Visibility.hidden, hidden.visibility.?);
    try testing.expectEqual(ui.Pointer.pointer, hidden.pointer.?);

    const collapsed = doc.classStyle(@backingInt(Class.codicon_folding_collapsed)).?;
    try testing.expectEqual(ui.Visibility.visible, collapsed.visibility.?);

    const always = doc.classStyle(@backingInt(Class.always_show_fold_icons)).?;
    try testing.expectEqual(ui.Visibility.visible, always.visibility.?);

    const hover = hoverStyle();
    try testing.expectEqual(ui.Visibility.visible, hover.visibility.?);
}
