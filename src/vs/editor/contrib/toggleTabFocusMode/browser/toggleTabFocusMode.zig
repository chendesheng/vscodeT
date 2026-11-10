const std = @import("std");
// Port of `src/vs/editor/contrib/toggleTabFocusMode/browser/toggleTabFocusMode.ts`.
const editor_extensions = @import("../../../browser/editorExtensions.zig");
const EditorAction = editor_extensions.EditorAction;

pub const TabFocusMode = struct {
    enabled: bool = false,

    pub fn get(self: *const TabFocusMode) bool {
        return self.enabled;
    }

    pub fn set(self: *TabFocusMode, value: bool) void {
        self.enabled = value;
    }

    pub fn toggle(self: *TabFocusMode) bool {
        self.enabled = !self.enabled;
        return self.enabled;
    }
};

pub const ToggleTabFocusModeAction = struct {
    pub const id = "editor.action.toggleTabFocusMode";
    pub const label = "Toggle Tab Key Moves Focus";
    pub const description = "Determines whether the tab key moves focus around the workbench or inserts the tab character in the current editor.";

    pub fn action(mode: *TabFocusMode) EditorAction {
        return EditorAction.init(.{
            .id = id,
            .label = label,
            .description = description,
            .context = mode,
            .run = struct {
                fn run(context: *anyopaque) anyerror!void {
                    const state: *TabFocusMode = @ptrCast(@alignCast(context));
                    _ = state.toggle();
                }
            }.run,
        });
    }
};

test "toggleTabFocusMode: toggles state" {
    var mode = TabFocusMode{};
    const action = ToggleTabFocusModeAction.action(&mode);
    try std.testing.expect(!mode.get());
    try action.run();
    try std.testing.expect(mode.get());
    try action.run();
    try std.testing.expect(!mode.get());
}
