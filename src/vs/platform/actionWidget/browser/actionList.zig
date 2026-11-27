// Port of `src/vs/platform/actionWidget/browser/actionList.ts`.
// The terminal's context-view popup owns native row focus, clipping and input.
// Action items retain their indices and disabled/header semantics.
pub const ActionListItemKind = enum { Header, Action };
pub const IActionListItem = struct {
    kind: ActionListItemKind,
    label: []const u8,
    item: ?usize = null,
    disabled: bool = false,
    keybinding: []const u8 = "",
    can_preview: bool = false,
};
pub const IActionListDelegate = struct {
    context: *anyopaque,
    on_select: *const fn (*anyopaque, usize, bool) anyerror!void,
    on_hide: *const fn (*anyopaque, bool) void,
};
