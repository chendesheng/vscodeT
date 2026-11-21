// Terminal host adapter for the editor sticky-scroll contribution.
//
// This file is the only bridge between `contrib/stickyScroll/browser` and the
// terminal `View`; the contribution itself has no `src/tui` imports. It
// supplies view-model options, resolved theme colors, geometry and the
// click/focus actions the overlay widget needs.

const std = @import("std");
const ui = @import("ui");

const editorView = @import("./editorView.zig");
const View = editorView.View;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const editor_options = @import("../vs/editor/common/config/editorOptions.zig");
const sticky_widget = @import("../vs/editor/contrib/stickyScroll/browser/stickyScrollWidget.zig");
const sticky_controller = @import("../vs/editor/contrib/stickyScroll/browser/stickyScrollController.zig");

const StickyScrollController = sticky_controller.StickyScrollController;
const Colors = sticky_widget.Colors;
const Host = sticky_widget.Host;

const fallback_background = ui.Color{ .r = 30, .g = 30, .b = 33 };
const fallback_hover = ui.Color{ .r = 42, .g = 45, .b = 46 };
const fallback_line_number = ui.Color{ .r = 110, .g = 110, .b = 110 };

pub const StickyScrollHost = struct {
    allocator: std.mem.Allocator,
    view: *View,
    controller: ?*StickyScrollController = null,

    pub fn init(allocator: std.mem.Allocator, view: *View) StickyScrollHost {
        return .{
            .allocator = allocator,
            .view = view,
        };
    }

    pub fn attach(self: *StickyScrollHost, controller: *StickyScrollController) void {
        self.controller = controller;
    }

    pub fn interface(self: *StickyScrollHost) Host {
        return .{
            .context = self,
            .view_context = viewContext,
            .view_model = viewModel,
            .view_line_options = viewLineOptions,
            .style_fn = self.view.lineStyleFunction(),
            .decoration_bits_fn = self.view.decorationBitsFunction(),
            .line_numbers = lineNumbers,
            .cursor_model_line = cursorModelLine,
            .folding_model = foldingModel,
            .options = options,
            .colors = colors,
            .gutter_width = gutterWidth,
            .fold_cell_column = foldCellColumn,
            .show_folding_controls = showFoldingControls,
            .view_line_count = viewLineCount,
            .view_line_for_model_line = viewLineForModelLine,
            .is_model_line_visible = isModelLineVisible,
            .available_width = availableWidth,
            .request_frame = requestFrame,
            .reveal_position = revealPosition,
            .reveal_line_centered = revealLineCentered,
            .toggle_fold = toggleFold,
            .focus_editor = focusEditor,
            .set_show_end_for_line = setShowEndForLine,
            .focus_next = focusNext,
            .focus_previous = focusPrevious,
            .go_to_focused = goToFocused,
            .select_editor = selectEditor,
        };
    }

    fn selfFrom(context: *anyopaque) *StickyScrollHost {
        return @ptrCast(@alignCast(context));
    }

    fn viewContext(context: *anyopaque) *@import("../vs/editor/common/viewModel/viewContext.zig").ViewContext {
        return &selfFrom(context).view.terminal_view_host.context;
    }

    fn viewModel(context: *anyopaque) @import("../vs/editor/common/viewModel.zig").IViewModel {
        return selfFrom(context).view.terminal_view_host.viewModelInterface();
    }

    fn viewLineOptions(context: *anyopaque) @import("../vs/editor/browser/viewParts/viewLines/viewLineOptions.zig").ViewLineOptions {
        return selfFrom(context).view.terminal_view_host.viewLineOptions();
    }

    fn lineNumbers(context: *anyopaque) editor_options.InternalEditorRenderLineNumbersOptions {
        return selfFrom(context).view.terminal_view_host.options.get(.lineNumbers);
    }

    fn cursorModelLine(context: *anyopaque) usize {
        return selfFrom(context).view.editor.modelCursorPosition().lineNumber;
    }

    fn foldingModel(context: *anyopaque) ?*@import("../vs/editor/contrib/folding/browser/foldingModel.zig").FoldingModel {
        return selfFrom(context).view.editor.foldingModel();
    }

    fn options(context: *anyopaque) editor_options.EditorStickyScrollOptions {
        return selfFrom(context).view.terminal_view_host.options.get(.stickyScroll);
    }

    fn colors(context: *anyopaque) Colors {
        const self = selfFrom(context);
        if (self.view.theme_colors) |palette| {
            return .{
                .background = palette.colorOr("editorStickyScroll.background", palette.background),
                .gutter_background = palette.colorOr("editorStickyScrollGutter.background", palette.background),
                .hover_background = palette.colorOr("editorStickyScrollHover.background", fallback_hover),
                .line_number = palette.color("editorLineNumber.foreground", .{
                    fallback_line_number.r,
                    fallback_line_number.g,
                    fallback_line_number.b,
                }),
            };
        }
        return .{
            .background = fallback_background,
            .gutter_background = fallback_background,
            .hover_background = fallback_hover,
            .line_number = fallback_line_number,
        };
    }

    fn gutterWidth(context: *anyopaque) usize {
        return selfFrom(context).view.editor.gutterWidth();
    }

    fn foldCellColumn(context: *anyopaque) usize {
        return selfFrom(context).view.editor.foldCellColumn();
    }

    fn showFoldingControls(context: *anyopaque) editor_options.ShowFoldingControls {
        return selfFrom(context).view.terminal_view_host.options.get(.showFoldingControls);
    }

    fn viewLineCount(context: *anyopaque) usize {
        return selfFrom(context).view.editor.viewLineCount();
    }

    fn viewLineForModelLine(context: *anyopaque, model_line: usize) usize {
        const self = selfFrom(context);
        const line_count = self.view.editor.model.getLineCount();
        if (model_line < 1 or model_line > line_count) return 0;
        return self.view.editor.viewPositionOfModelPosition(Position.init(model_line, 1)).lineNumber;
    }

    fn isModelLineVisible(context: *anyopaque, model_line: usize) bool {
        return selfFrom(context).view.editor.isModelLineVisible(model_line);
    }

    fn availableWidth(context: *anyopaque, cols: usize) usize {
        const self = selfFrom(context);
        return cols -| self.view.editor.scrollbar_width;
    }

    fn requestFrame(context: *anyopaque) void {
        selfFrom(context).view.invalidate();
    }

    fn revealPosition(context: *anyopaque, position: Position) void {
        const self = selfFrom(context);
        self.view.editor.setCursorPosition(position) catch {};
        self.view.focusEditor();
    }

    fn revealLineCentered(context: *anyopaque, line: usize) void {
        const self = selfFrom(context);
        _ = self.view.editor.revealLine(line, .CenterIfOutsideViewport);
        self.view.editor.setCursorPosition(Position.init(line, 1)) catch {};
        self.view.focusEditor();
    }

    fn toggleFold(context: *anyopaque, model_line: usize) void {
        const self = selfFrom(context);
        _ = self.view.editor.toggleFoldAtModelLine(model_line) catch {};
    }

    fn focusEditor(context: *anyopaque) void {
        selfFrom(context).view.focusEditor();
    }

    fn setShowEndForLine(context: *anyopaque, index: ?usize) void {
        const self = selfFrom(context);
        if (self.controller) |controller| controller.setShowEndForLine(index);
    }

    fn focusNext(context: *anyopaque) void {
        const self = selfFrom(context);
        if (self.controller) |controller| controller.focusNext();
    }

    fn focusPrevious(context: *anyopaque) void {
        const self = selfFrom(context);
        if (self.controller) |controller| controller.focusPrevious();
    }

    fn goToFocused(context: *anyopaque) void {
        const self = selfFrom(context);
        if (self.controller) |controller| controller.goToFocused();
    }

    fn selectEditor(context: *anyopaque) void {
        const self = selfFrom(context);
        if (self.controller) |controller| controller.selectEditor();
    }
};
