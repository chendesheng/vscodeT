// Terminal adaptation of the view-model and editor dependencies of
// `src/vs/editor/contrib/stickyScroll/browser/stickyScrollWidget.ts`.
// The contribution reads the ported TerminalViewHost and Editor. The
// cell-painter supplies only resolved theme/style and focus/frame callbacks.

const TerminalViewHost = @import("../../../browser/widget/codeEditor/terminalViewHost.zig").TerminalViewHost;
const ViewLine = @import("../../../browser/viewParts/viewLines/viewLine.zig").ViewLine;
const Position = @import("../../../common/core/position.zig").Position;
const editor_options = @import("../../../common/config/editorOptions.zig");
const sticky_widget = @import("stickyScrollWidget.zig");
const sticky_controller = @import("stickyScrollController.zig");

const StickyScrollController = sticky_controller.StickyScrollController;
const Colors = sticky_widget.Colors;
const Host = sticky_widget.Host;

pub const ViewCallbacks = struct {
    context: *anyopaque,
    style_fn: ViewLine.PartStyleFn,
    decoration_bits_fn: ?*const fn ([]const u8) u32,
    colors: *const fn (*anyopaque) Colors,
    request_frame: *const fn (*anyopaque) void,
    focus_editor: *const fn (*anyopaque) void,
};

pub const StickyScrollHost = struct {
    view_model: *TerminalViewHost,
    view_callbacks: ViewCallbacks,
    controller: ?*StickyScrollController = null,

    pub fn init(view_model: *TerminalViewHost, view_callbacks: ViewCallbacks) StickyScrollHost {
        return .{ .view_model = view_model, .view_callbacks = view_callbacks };
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
            .style_fn = self.view_callbacks.style_fn,
            .decoration_bits_fn = self.view_callbacks.decoration_bits_fn,
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
            .scroll_left = scrollLeft,
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

    fn viewContext(context: *anyopaque) *@import("../../../common/viewModel/viewContext.zig").ViewContext {
        return &selfFrom(context).view_model.context;
    }

    fn viewModel(context: *anyopaque) @import("../../../common/viewModel.zig").IViewModel {
        return selfFrom(context).view_model.viewModelInterface();
    }

    fn viewLineOptions(context: *anyopaque) @import("../../../browser/viewParts/viewLines/viewLineOptions.zig").ViewLineOptions {
        return selfFrom(context).view_model.viewLineOptions();
    }

    fn lineNumbers(context: *anyopaque) editor_options.InternalEditorRenderLineNumbersOptions {
        return selfFrom(context).view_model.options.get(.lineNumbers);
    }

    fn cursorModelLine(context: *anyopaque) usize {
        return selfFrom(context).view_model.editor.modelCursorPosition().lineNumber;
    }

    fn foldingModel(context: *anyopaque) ?*@import("../../../contrib/folding/browser/foldingModel.zig").FoldingModel {
        return selfFrom(context).view_model.editor.foldingModel();
    }

    fn options(context: *anyopaque) editor_options.EditorStickyScrollOptions {
        return selfFrom(context).view_model.options.get(.stickyScroll);
    }

    fn colors(context: *anyopaque) Colors {
        const self = selfFrom(context);
        return self.view_callbacks.colors(self.view_callbacks.context);
    }

    fn gutterWidth(context: *anyopaque) usize {
        return selfFrom(context).view_model.editor.gutterWidth();
    }

    fn scrollLeft(context: *anyopaque) usize {
        return selfFrom(context).view_model.editor.scrollLeft();
    }

    fn foldCellColumn(context: *anyopaque) usize {
        return selfFrom(context).view_model.editor.foldCellColumn();
    }

    fn showFoldingControls(context: *anyopaque) editor_options.ShowFoldingControls {
        return selfFrom(context).view_model.options.get(.showFoldingControls);
    }

    fn viewLineCount(context: *anyopaque) usize {
        return selfFrom(context).view_model.editor.viewLineCount();
    }

    fn viewLineForModelLine(context: *anyopaque, model_line: usize) usize {
        const self = selfFrom(context);
        const line_count = self.view_model.editor.model.getLineCount();
        if (model_line < 1 or model_line > line_count) return 0;
        return self.view_model.editor.viewPositionOfModelPosition(Position.init(model_line, 1)).lineNumber;
    }

    fn isModelLineVisible(context: *anyopaque, model_line: usize) bool {
        return selfFrom(context).view_model.editor.isModelLineVisible(model_line);
    }

    fn availableWidth(context: *anyopaque, cols: usize) usize {
        const self = selfFrom(context);
        return cols -| self.view_model.editor.scrollbar_width;
    }

    fn requestFrame(context: *anyopaque) void {
        const self = selfFrom(context);
        self.view_callbacks.request_frame(self.view_callbacks.context);
    }

    fn revealPosition(context: *anyopaque, position: Position) void {
        const self = selfFrom(context);
        self.view_model.editor.setCursorPosition(position) catch {};
        self.view_callbacks.focus_editor(self.view_callbacks.context);
    }

    fn revealLineCentered(context: *anyopaque, line: usize) void {
        const self = selfFrom(context);
        _ = self.view_model.editor.revealLine(line, .CenterIfOutsideViewport);
        self.view_model.editor.setCursorPosition(Position.init(line, 1)) catch {};
        self.view_callbacks.focus_editor(self.view_callbacks.context);
    }

    fn toggleFold(context: *anyopaque, model_line: usize) void {
        const self = selfFrom(context);
        _ = self.view_model.editor.toggleFoldAtModelLine(model_line) catch {};
    }

    fn focusEditor(context: *anyopaque) void {
        const self = selfFrom(context);
        self.view_callbacks.focus_editor(self.view_callbacks.context);
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
