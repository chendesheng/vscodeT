// Port of `src/vs/editor/contrib/hover/browser/hoverContribution.ts`.
// The content-hover constructor receives the native view binding; its
// registration retains the upstream BeforeFirstInteraction policy.
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ContentHoverController = @import("contentHoverController.zig").ContentHoverController;

pub fn register(editor: *Editor, context: *anyopaque, instantiate: *const fn (*anyopaque) anyerror!void) !void {
    try editor.registerContributionFactory(.{ .id = ContentHoverController.ID, .instantiation = .before_first_interaction, .context = context, .instantiate = instantiate });
}

pub fn registerGlyph(editor: *Editor, context: *anyopaque, instantiate: *const fn (*anyopaque) anyerror!void) !void {
    const GlyphHoverController = @import("glyphHoverController.zig").GlyphHoverController;
    try editor.registerContributionFactory(.{ .id = GlyphHoverController.ID, .instantiation = .before_first_interaction, .context = context, .instantiate = instantiate });
}
