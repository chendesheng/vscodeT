// Terminal subset of `src/vs/editor/browser/widget/codeEditor/codeEditorWidget.ts`.
//
// The terminal widget owns the text model, computed configuration, terminal
// `ViewModel` and the `View` (view lines + event fan-out). It exposes the
// text-rendering pipeline (`render`) and selection/focus state. The browser
// DOM container, edit context, cursor controller, mouse controller,
// contributions and layout observers are not ported; the TUI supplies those
// at its own layer.
const std = @import("std");
const Allocator = std.mem.Allocator;

const text_model = @import("../../../common/model/textModel.zig");
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
const view_model_impl = @import("../../../common/viewModel/viewModelImpl.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const viewport_data = @import("../../../common/viewLayout/viewLinesViewportData.zig");
const Selection = @import("../../../common/core/selection.zig").Selection;
const Range = @import("../../../common/core/range.zig").Range;
const StringBuilder = @import("../../../common/core/stringBuilder.zig").StringBuilder;
const ViewModel = view_model_impl.ViewModel;
const ViewContext = view_context.ViewContext;
const View = @import("../../view.zig").View;

pub const CodeEditorWidget = struct {
    allocator: Allocator,
    model: *text_model.TextModel,
    configuration: *const editor_configuration.IEditorConfiguration,
    view_model: *ViewModel,
    context: ViewContext,
    view: View,

    pub fn init(
        allocator: Allocator,
        model: *text_model.TextModel,
        configuration: *const editor_configuration.IEditorConfiguration,
        theme: @import("../../../../platform/theme/common/themeService.zig").IColorTheme,
        wrapping_column: usize,
    ) !*CodeEditorWidget {
        const self = try allocator.create(CodeEditorWidget);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .model = model,
            .configuration = configuration,
            .view_model = undefined,
            .context = undefined,
            .view = undefined,
        };
        self.view_model = try ViewModel.init(allocator, 1, configuration, model, wrapping_column);
        errdefer self.view_model.deinit();
        self.context = ViewContext.init(configuration, theme, self.view_model.interface());
        self.view.init(allocator, &self.context);
        return self;
    }

    pub fn deinit(self: *CodeEditorWidget) void {
        self.view.deinit();
        self.view_model.deinit();
        self.allocator.destroy(self);
    }

    pub fn getModel(self: *CodeEditorWidget) *text_model.TextModel {
        return self.model;
    }

    pub fn getViewModel(self: *CodeEditorWidget) *ViewModel {
        return self.view_model;
    }

    pub fn getView(self: *CodeEditorWidget) *View {
        return &self.view;
    }

    pub fn setSelections(self: *CodeEditorWidget, selections: []const Selection) !void {
        try self.view_model.setSelections(selections);
    }

    pub fn getSelections(self: *CodeEditorWidget) []const Selection {
        return self.view_model.getSelections();
    }

    pub fn getPrimarySelection(self: *CodeEditorWidget) ?Selection {
        const selections = self.getSelections();
        if (selections.len == 0) return null;
        return selections[0];
    }

    pub fn getPosition(self: *CodeEditorWidget) ?Position {
        const selection = self.getPrimarySelection() orelse return null;
        return selection.getPosition();
    }

    pub fn setPosition(self: *CodeEditorWidget, position: Position) !void {
        const selection = Selection.fromPositions(position, position);
        try self.setSelections(&.{selection});
    }

    pub fn setFocus(self: *CodeEditorWidget, focused: bool) bool {
        self.view_model.setFocus(focused);
        return self.view.setFocused(focused);
    }

    pub fn hasFocus(self: *CodeEditorWidget) bool {
        return self.view_model.hasFocus();
    }

    /// Renders the visible line window into `sb` (the terminal replacement for
    /// the browser `View.renderText`).
    pub fn render(self: *CodeEditorWidget, viewport: *const viewport_data.ViewportData, sb: *StringBuilder) !void {
        try self.view.renderText(viewport, sb);
    }

    pub fn visibleRangeForPosition(self: *CodeEditorWidget, position: @import("../../../common/core/position.zig").Position) ?@import("../../view/renderingContext.zig").HorizontalPosition {
        return self.view.getViewLines().visibleRangeForPosition(position);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_support = @import("../../../test/common/port/testSupport.zig");
const browser_config = @import("../../config/editorConfiguration.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const test_stubs = @import("../../../test/common/viewModelTestStubs.zig");
const TextDirection = @import("../../../common/standalone/standaloneEnums.zig").TextDirection;
const Position = @import("../../../common/core/position.zig").Position;

const Fixture = struct {
    allocator: Allocator,
    test_model: test_support.TestModel,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,

    fn init(self: *Fixture, allocator: Allocator, text: []const u8) !void {
        self.allocator = allocator;
        self.test_model = try test_support.TestModel.init(allocator, text, "plaintext");
        self.options = browser_config.ComputedEditorOptions.init();
        self.options.set(.lineHeight, 19);
        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
    }

    fn deinit(self: *Fixture) void {
        self.test_model.deinit();
    }
};

test "code editor widget renders the view model's lines" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "hello\nworld");
    defer fixture.deinit();

    const widget = try CodeEditorWidget.init(
        allocator,
        fixture.test_model.model,
        &fixture.configuration,
        test_stubs.TestColorTheme.dark(),
        80,
    );
    defer widget.deinit();

    const selections = [_]Selection{Selection.init(1, 1, 1, 1)};
    try widget.setSelections(&selections);
    try testing.expectEqual(@as(usize, 1), widget.getSelections().len);
    try widget.setPosition(Position.init(2, 3));
    try testing.expectEqual(Position.init(2, 3), widget.getPosition().?);

    const offsets = [_]f64{ 0, 19 };
    const model_interface = widget.getViewModel().interface();
    var viewport = viewport_data.ViewportData{
        .selections = &selections,
        .startLineNumber = 1,
        .endLineNumber = 2,
        .relativeVerticalOffset = &offsets,
        .visibleRange = Range.init(1, 1, 2, 6),
        .bigNumbersDelta = 0,
        .whitespaceViewportData = &.{},
        .lineHeight = 19,
        ._model = model_interface,
    };

    var sb = try StringBuilder.init(allocator, 16);
    defer sb.deinit();
    try widget.render(&viewport, &sb);
    try testing.expectEqualStrings("helloworld", sb.build());

    const position = widget.visibleRangeForPosition(Position.init(2, 3)).?;
    try testing.expectEqual(@as(i32, 2), position.left);
}

test "code editor widget tracks focus" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "x");
    defer fixture.deinit();

    const widget = try CodeEditorWidget.init(
        allocator,
        fixture.test_model.model,
        &fixture.configuration,
        test_stubs.TestColorTheme.dark(),
        80,
    );
    defer widget.deinit();

    try testing.expect(!widget.hasFocus());
    _ = widget.setFocus(true);
    try testing.expect(widget.hasFocus());
}
