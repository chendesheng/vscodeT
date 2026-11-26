// Port of the diff editor title/view contributions in
// src/vs/workbench/browser/parts/editor/editor.contribution.ts.
const actions = @import("../../../../platform/actions/common/actions.zig");
const Expr = @import("../../../../platform/contextkey/common/contextkey.zig").Expr;

const compare_active: Expr = .{ .Defined = "textCompareEditorActive" };
const can_swap: Expr = .{ .Defined = "activeCompareEditorCanSwap" };
const compare_can_swap: Expr = .{ .And = @constCast(&[_]*const Expr{ &compare_active, &can_swap }) };
const in_diff: Expr = .{ .Defined = "isInDiffEditor" };
const not_sessions: Expr = .{ .Not = "isSessionsWindow" };
const diff_view_visible: Expr = .{ .And = @constCast(&[_]*const Expr{ &in_diff, &not_sessions }) };
const has_changes: Expr = .{ .Defined = "diffEditorHasChanges" };
const side_by_side: Expr = .{ .Equals = .{ .key = "config.diffEditor.renderSideBySide", .value = .{ .boolean = true } } };
const inline_view: Expr = .{ .Equals = .{ .key = "config.diffEditor.renderSideBySide", .value = .{ .boolean = false } } };
const auto_inline: Expr = .{ .Equals = .{ .key = "config.diffEditor.useInlineViewWhenSpaceIsLimited", .value = .{ .boolean = true } } };
const not_auto_inline: Expr = .{ .Equals = .{ .key = "config.diffEditor.useInlineViewWhenSpaceIsLimited", .value = .{ .boolean = false } } };
const temporary_inline: Expr = .{ .Defined = "diffEditorTemporaryInlineMode" };
const not_temporary: Expr = .{ .Not = "diffEditorTemporaryInlineMode" };
const auto_side_by_side: Expr = .{ .Defined = "diffEditorAutomaticRenderSideBySide" };
const auto_inline_current: Expr = .{ .Not = "diffEditorAutomaticRenderSideBySide" };
const fixed_side_by_side: Expr = .{ .And = @constCast(&[_]*const Expr{ &side_by_side, &not_auto_inline }) };
const automatic: Expr = .{ .And = @constCast(&[_]*const Expr{ &side_by_side, &auto_inline, &not_temporary }) };
const show_whitespace: Expr = .{ .Equals = .{ .key = "config.diffEditor.ignoreTrimWhitespace", .value = .{ .boolean = false } } };
const never: Expr = .{ .False = {} };

pub fn registerDiffEditorTitle(registry: *actions.MenuRegistry) !void {
    const title = actions.menu_ids.EditorTitle;
    const view = actions.menu_ids.DiffEditorViewSubmenu;
    try registry.appendSubmenuItem(title, .{ .submenu = view, .title = "Diff View", .group = "1_diff", .order = 10, .when = &diff_view_visible });
    for ([_]actions.IMenuItem{
        .{ .command = .{ .id = "diffEditor.setViewMode.inline", .title = "Inline", .toggled = &inline_view }, .group = "1_view", .order = 1 },
        .{ .command = .{ .id = "diffEditor.setViewMode.sideBySide", .title = "Side by Side", .toggled = &fixed_side_by_side }, .group = "1_view", .order = 2 },
        .{ .command = .{ .id = "diffEditor.setViewMode.automatic", .title = "Automatic (Currently Side by Side)", .toggled = &automatic }, .group = "1_view", .order = 3, .when = &auto_side_by_side },
        .{ .command = .{ .id = "diffEditor.setViewMode.automatic", .title = "Automatic (Currently Inline)", .toggled = &automatic }, .group = "1_view", .order = 3, .when = &auto_inline_current },
        .{ .command = .{ .id = "diffEditor.viewMode.inlineTemporary", .title = "Inline (Temporary)", .toggled = &temporary_inline, .precondition = &never }, .group = "1_view", .order = 4, .when = &temporary_inline },
    }) |item| try registry.appendMenuItem(view, item);
    for ([_]actions.IMenuItem{
        .{ .command = .{ .id = "workbench.action.compareEditor.previousChange", .title = "Previous Change", .icon = "diff-editor-previous-change", .precondition = &has_changes }, .group = "navigation", .order = 10, .when = &compare_active },
        .{ .command = .{ .id = "workbench.action.compareEditor.nextChange", .title = "Next Change", .icon = "diff-editor-next-change", .precondition = &has_changes }, .group = "navigation", .order = 11, .when = &compare_active },
        .{ .command = .{ .id = "workbench.action.compareEditor.swapSides", .title = "Swap Left and Right Side", .icon = "arrow-swap" }, .group = "navigation", .order = 15, .when = &compare_can_swap },
        .{ .command = .{ .id = "toggle.diff.ignoreTrimWhitespace", .title = "Show Leading/Trailing Whitespace Differences", .icon = "diff-editor-toggle-whitespace", .precondition = &compare_active, .toggled = &show_whitespace }, .group = "navigation", .order = 20, .when = &compare_active },
    }) |item| try registry.appendMenuItem(title, item);
}
