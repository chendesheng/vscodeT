// Port of the viewport-anchor portion of `src/vs/editor/browser/stableEditorScroll.ts`.
// Scrolling is immediate in the terminal, so there is no pending animation.
const Editor = @import("widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ViewState = @import("../common/editorCommon.zig").IViewState;
const view_model = @import("../common/viewModel/viewModelImpl.zig");

pub const StableEditorScrollState = struct {
    initial_scroll_top: usize,
    initial_content_height: f64,
    visible_position: ?ViewState,

    pub fn capture(editor: *Editor) StableEditorScrollState {
        return .{
            .initial_scroll_top = editor.scrollTop(),
            .initial_content_height = contentHeight(editor),
            .visible_position = if (editor.scrollTop() == 0) null else view_model.saveState(&editor.view_lines, editor.converter.interface(), editor.viewLayout()),
        };
    }

    pub fn restore(self: StableEditorScrollState, editor: *Editor) void {
        if (self.initial_scroll_top == editor.scrollTop() and self.initial_content_height == contentHeight(editor)) return;
        if (self.visible_position) |position| editor.restoreScrollState(position);
    }

    fn contentHeight(editor: *Editor) f64 {
        return editor.viewLayout().lines_layout.getLinesTotalHeight() catch editor.viewLayout().getScrollHeight();
    }
};
