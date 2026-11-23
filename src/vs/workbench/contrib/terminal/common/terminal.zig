// Port of the terminal command IDs and the skip-shell subset of
// `src/vs/workbench/contrib/terminal/common/terminal.ts`.
//
// The TUI has fewer commands than the browser workbench, so the default list
// keeps only chords that exist here. A focused terminal still sends every other
// chord to the shell; the app's global dispatcher consults this list.

const std = @import("std");

pub const TerminalCommandId = struct {
    pub const toggle = "workbench.action.terminal.toggleTerminal";
    pub const new = "workbench.action.terminal.new";
    pub const editor = "workbench.action.createTerminalEditor";
    pub const editor_side = "workbench.action.createTerminalEditorSide";
    pub const editor_same_group = "workbench.action.createTerminalEditorSameGroup";
    pub const move_to_editor = "workbench.action.terminal.moveToEditor";
    pub const move_to_panel = "workbench.action.terminal.moveToTerminalPanel";
    pub const split = "workbench.action.terminal.split";
    pub const kill_editor = "workbench.action.terminal.killEditor";
    pub const focus_next_pane = "workbench.action.terminal.focusNextPane";
    pub const focus_previous_pane = "workbench.action.terminal.focusPreviousPane";
    pub const focus_tabs = "workbench.action.terminal.focusTabs";
    pub const rename = "workbench.action.terminal.rename";
    pub const kill = "workbench.action.terminal.kill";
    pub const focus = "workbench.action.terminal.focus";
    pub const focus_next = "workbench.action.terminal.focusNext";
    pub const focus_previous = "workbench.action.terminal.focusPrevious";
    pub const resize_up = "workbench.action.terminal.resizeUp";
    pub const resize_down = "workbench.action.terminal.resizeDown";
};

/// Commands whose keybindings are handled by the workbench even while the
/// terminal has focus. This mirrors the corresponding upstream entries in
/// `DEFAULT_COMMANDS_TO_SKIP_SHELL` for the commands this TUI implements.
pub const DEFAULT_COMMANDS_TO_SKIP_SHELL = [_][]const u8{
    "workbench.action.quickOpen",
    "workbench.action.showCommands",
    TerminalCommandId.toggle,
    TerminalCommandId.new,
    TerminalCommandId.editor,
    TerminalCommandId.editor_side,
    TerminalCommandId.editor_same_group,
    TerminalCommandId.move_to_editor,
    TerminalCommandId.move_to_panel,
    TerminalCommandId.split,
    TerminalCommandId.kill_editor,
    TerminalCommandId.focus_next_pane,
    TerminalCommandId.focus_previous_pane,
    TerminalCommandId.focus_tabs,
    TerminalCommandId.rename,
    TerminalCommandId.kill,
    TerminalCommandId.focus,
    TerminalCommandId.focus_next,
    TerminalCommandId.focus_previous,
    TerminalCommandId.resize_up,
    TerminalCommandId.resize_down,
};

pub fn skipsShell(command_id: []const u8) bool {
    for (DEFAULT_COMMANDS_TO_SKIP_SHELL) |id| {
        if (std.mem.eql(u8, id, command_id)) return true;
    }
    return false;
}

test "terminal: skip-shell list covers terminal commands" {
    try std.testing.expect(skipsShell(TerminalCommandId.toggle));
    try std.testing.expect(skipsShell("workbench.action.quickOpen"));
    try std.testing.expect(!skipsShell("workbench.action.findInFiles"));
}
