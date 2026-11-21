// Port of the action metadata in
// `src/vs/editor/contrib/stickyScroll/browser/stickyScrollActions.ts`.
//
// Terminal adaptation: the TUI has no context-key/action registry, so the
// metadata is kept as plain values. The workbench registers the toggle and
// focus command ids; the focused-widget keys are handled by the sticky widget
// itself (Up/Down/Enter/Escape), matching the upstream keybindings.

const editorExtensions = @import("../../../browser/editorExtensions.zig");

pub const Metadata = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
    precondition: ?[]const u8 = null,
};

pub const toggle_sticky_scroll = Metadata{
    .id = "editor.action.toggleStickyScroll",
    .label = "Toggle Editor Sticky Scroll",
    .description = "Toggle/enable the editor sticky scroll which shows the nested scopes at the top of the viewport",
};

pub const focus_sticky_scroll = Metadata{
    .id = "editor.action.focusStickyScroll",
    .label = "Focus Editor Sticky Scroll",
    .description = "Focus the editor sticky scroll lines",
    .precondition = "config.editor.stickyScroll.enabled && editorStickyScrollVisible",
};

pub const select_next_sticky_scroll_line = Metadata{
    .id = "editor.action.selectNextStickyScrollLine",
    .label = "Select the next editor sticky scroll line",
    .description = "Select the next editor sticky scroll line",
    .precondition = "editorStickyScrollFocused",
};

pub const select_previous_sticky_scroll_line = Metadata{
    .id = "editor.action.selectPreviousStickyScrollLine",
    .label = "Select the previous editor sticky scroll line",
    .description = "Select the previous editor sticky scroll line",
    .precondition = "editorStickyScrollFocused",
};

pub const go_to_sticky_scroll_line = Metadata{
    .id = "editor.action.goToFocusedStickyScrollLine",
    .label = "Go to the focused sticky scroll line",
    .description = "Go to the focused sticky scroll line",
    .precondition = "editorStickyScrollFocused",
};

pub const select_editor = Metadata{
    .id = "editor.action.selectEditor",
    .label = "Select Editor",
    .description = "Return focus to the editor",
    .precondition = "editorStickyScrollFocused",
};

/// Terminal-facing action records for a future `EditorActionRegistry` wiring.
pub fn action(
    metadata: Metadata,
    context: *anyopaque,
    runFn: *const fn (context: *anyopaque) anyerror!void,
) editorExtensions.EditorAction {
    return editorExtensions.EditorAction.init(.{
        .id = metadata.id,
        .label = metadata.label,
        .description = metadata.description,
        .precondition = metadata.precondition,
        .context = context,
        .run = runFn,
    });
}

const std = @import("std");
const testing = std.testing;

test "sticky scroll action ids stay upstream-shaped" {
    try testing.expectEqualStrings("editor.action.toggleStickyScroll", toggle_sticky_scroll.id);
    try testing.expectEqualStrings("editor.action.focusStickyScroll", focus_sticky_scroll.id);
    try testing.expectEqualStrings("editor.action.selectNextStickyScrollLine", select_next_sticky_scroll_line.id);
    try testing.expectEqualStrings("editor.action.selectPreviousStickyScrollLine", select_previous_sticky_scroll_line.id);
    try testing.expectEqualStrings("editor.action.goToFocusedStickyScrollLine", go_to_sticky_scroll_line.id);
    try testing.expectEqualStrings("editor.action.selectEditor", select_editor.id);
}
