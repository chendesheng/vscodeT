// Port of `src/vs/editor/contrib/stickyScroll/browser/stickyScrollContribution.ts`.
// The native model/view binding supplies the constructor context; the
// contribution registry owns the upstream AfterFirstRender policy.
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const StickyScrollController = @import("stickyScrollController.zig").StickyScrollController;

pub fn register(editor: *Editor, context: *anyopaque, instantiate: *const fn (*anyopaque) anyerror!void) !void {
    try editor.registerContributionFactory(.{ .id = StickyScrollController.ID, .instantiation = .after_first_render, .context = context, .instantiate = instantiate });
}
