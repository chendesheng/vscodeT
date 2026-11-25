// Port of the terminal availability, location and split-pane context keys in
// src/vs/workbench/contrib/terminal/common/terminalContextKey.ts. The native
// panel has no browser DOM focus tracker; process support is the PTY backend's
// capability, and location/count state comes from service and view events.
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");

pub const TerminalContextKeyStrings = struct {
    pub const IsOpen = "terminalIsOpen";
    pub const Count = "terminalCount";
    pub const GroupCount = "terminalGroupCount";
    pub const ProcessSupported = "terminalProcessSupported";
    pub const TerminalHasBeenCreated = "terminalHasBeenCreated";
    pub const TerminalEditorActive = "terminalEditorActive";
    pub const ViewShowing = "terminalViewShowing";
    pub const SplitPaneActive = "terminalSplitPaneActive";
};

pub const TerminalContextKeys = struct {
    pub const is_open: contextkey.Expr = .{ .Defined = TerminalContextKeyStrings.IsOpen };
    pub const group_count: contextkey.Expr = .{ .Defined = TerminalContextKeyStrings.GroupCount };
    pub const process_supported: contextkey.Expr = .{ .Defined = TerminalContextKeyStrings.ProcessSupported };
    pub const terminal_has_been_created: contextkey.Expr = .{ .Defined = TerminalContextKeyStrings.TerminalHasBeenCreated };
    pub const terminal_editor_active: contextkey.Expr = .{ .Defined = TerminalContextKeyStrings.TerminalEditorActive };
    pub const view_showing: contextkey.Expr = .{ .Defined = TerminalContextKeyStrings.ViewShowing };
    pub const split_terminal_active: contextkey.Expr = .{ .Defined = TerminalContextKeyStrings.SplitPaneActive };
};
