// Port of `src/vs/editor/browser/viewParts/viewLines/viewLine.ts`.
//
// Terminal adaptation: upstream manages DOM spans and incrementally updates
// them; the terminal renders the line text into a `StringBuilder` each frame
// (the TUI repaints from that builder). Change detection uses a hash of the
// rendered text instead of retaining a second copy of every line. GPU
// rendering, DOM reading, ligatures and cursor text content are not
// applicable. Inline decorations/whitespace
// options are not consumed by the shared terminal line renderer yet; the TUI
// paints decoration cells separately.
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_line_options = @import("./viewLineOptions.zig");
const view_line_renderer = @import("../../../common/viewLayout/viewLineRenderer.zig");
const viewport_data = @import("../../../common/viewLayout/viewLinesViewportData.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const StringBuilder = @import("../../../common/core/stringBuilder.zig").StringBuilder;
const OffsetRange = @import("../../../common/core/ranges/offsetRange.zig").OffsetRange;

const ViewLineOptions = view_line_options.ViewLineOptions;
const RenderingContext = view_context.ViewContext;

/// Port of `ViewLine` (the `IVisibleLine` implementation used by
/// `VisibleLinesCollection`).
pub const ViewLine = struct {
    allocator: Allocator,
    context: *RenderingContext,
    options: ViewLineOptions,
    is_maybe_invalid: bool = true,
    rendered_hash: ?u64 = null,

    pub fn init(allocator: Allocator, context: *RenderingContext, options: ViewLineOptions) ViewLine {
        return .{
            .allocator = allocator,
            .context = context,
            .options = options,
        };
    }

    pub fn deinit(self: *ViewLine, allocator: Allocator) void {
        _ = allocator;
        self.rendered_hash = null;
    }

    pub fn onContentChanged(self: *ViewLine) void {
        self.is_maybe_invalid = true;
    }

    pub fn onTokensChanged(self: *ViewLine) void {
        self.is_maybe_invalid = true;
    }

    pub fn onDecorationsChanged(self: *ViewLine) void {
        self.is_maybe_invalid = true;
    }

    pub fn onOptionsChanged(self: *ViewLine, new_options: ViewLineOptions) void {
        self.is_maybe_invalid = true;
        self.options = new_options;
    }

    /// Only `renderWhitespace: selection` depends on the selection in the
    /// terminal renderer, so other selection changes do not invalidate.
    pub fn onSelectionChanged(self: *ViewLine) bool {
        if (self.options.render_whitespace == .selection) {
            self.is_maybe_invalid = true;
            return true;
        }
        return false;
    }

    pub fn layoutLine(_: *ViewLine, _: usize, _: f64, _: f64) void {}

    pub fn shouldRender(self: *const ViewLine) bool {
        return self.is_maybe_invalid;
    }

    pub fn onDidRender(self: *ViewLine) void {
        self.is_maybe_invalid = false;
    }

    /// Appends the rendered terminal text for `line_number` to `sb` and returns
    /// whether the rendered content changed since the previous call.
    pub fn renderLine(
        self: *ViewLine,
        line_number: usize,
        delta_top: f64,
        line_height: f64,
        viewport: *const viewport_data.ViewportData,
        sb: *StringBuilder,
    ) bool {
        _ = delta_top;
        _ = line_height;

        const line_data = viewport.getViewLineRenderingData(line_number) catch return false;

        var selection_ranges: [16]OffsetRange = undefined;
        var selection_range_count: usize = 0;
        if (self.options.render_whitespace == .selection) {
            for (self.context.view_model.getSelections()) |selection| {
                if (selection.endLineNumber < line_number or selection.startLineNumber > line_number) continue;
                const start_column = if (selection.startLineNumber == line_number) selection.startColumn else line_data.minColumn;
                const end_column = if (selection.endLineNumber == line_number) selection.endColumn else line_data.maxColumn;
                const start = @min(start_column -| 1, line_data.content.len);
                const end = @min(end_column -| 1, line_data.content.len);
                if (start < end and selection_range_count < selection_ranges.len) {
                    selection_ranges[selection_range_count] = OffsetRange.init(start, end);
                    selection_range_count += 1;
                }
            }
        }

        var rendered = view_line_renderer.renderLine(self.allocator, .{
            .content = line_data.content,
            .tokens = line_data.tokens,
            .tab_size = line_data.tabSize,
            .start_visible_column = line_data.startVisibleColumn,
            .render_whitespace = self.options.render_whitespace,
            .selection_ranges = selection_ranges[0..selection_range_count],
            .render_control_characters = self.options.render_control_characters,
        }) catch return false;
        defer rendered.deinit(self.allocator);

        const changed = self.updateRenderedText(rendered.bytes);
        sb.appendString(rendered.bytes) catch return false;
        return changed;
    }

    fn updateRenderedText(self: *ViewLine, text: []const u8) bool {
        const hash = std.hash.Wyhash.hash(0, text);
        if (self.rendered_hash) |previous| {
            if (previous == hash) return false;
        }
        self.rendered_hash = hash;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const view_layer = @import("../../view/viewLayer.zig");
const view_model = @import("../../../common/viewModel.zig");
const browser_config = @import("../../config/editorConfiguration.zig");
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const test_stubs = @import("../../../test/common/viewModelTestStubs.zig");
const languages = @import("../../../common/languages.zig");
const line_tokens = @import("../../../common/tokens/lineTokens.zig");
const Range = @import("../../../common/core/range.zig").Range;
const Position = @import("../../../common/core/position.zig").Position;
const TextDirection = @import("../../../common/standalone/standaloneEnums.zig").TextDirection;
const LanguageIdCodec = languages.LanguageIdCodec;
const ViewLineRenderingData = view_model.ViewLineRenderingData;
const IViewLineTokens = line_tokens.IViewLineTokens;

fn makeLineTokens(allocator: Allocator, codec: *LanguageIdCodec, content: []const u8) !line_tokens.LineTokens {
    var owned_content = std.array_list.Managed(u8).init(allocator);
    errdefer owned_content.deinit();
    try owned_content.appendSlice(content);
    return line_tokens.LineTokens.createEmpty(allocator, owned_content, codec);
}

const Fixture = struct {
    allocator: Allocator,
    codec: LanguageIdCodec,
    tokens: line_tokens.LineTokens,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    context: view_context.ViewContext,
    offsets: [1]f64 = .{0},
    viewport: viewport_data.ViewportData,

    fn init(self: *Fixture, allocator: Allocator, content: []const u8) !void {
        self.allocator = allocator;
        self.codec = try LanguageIdCodec.init(allocator);
        errdefer self.codec.deinit();
        self.tokens = try makeLineTokens(allocator, &self.codec, content);
        errdefer self.tokens.deinit();

        self.options = browser_config.ComputedEditorOptions.init();
        self.layout = .{};
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.view_model.view_line_data = ViewLineRenderingData.init(
            1,
            content.len + 1,
            content,
            false,
            false,
            false,
            IViewLineTokens.init(&self.tokens),
            &.{},
            4,
            0,
            TextDirection.LTR,
            false,
        );

        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
        self.context = view_context.ViewContext.init(&self.configuration, test_stubs.TestColorTheme.dark(), self.view_model.interface());
        self.viewport = .{
            .selections = &.{},
            .startLineNumber = 1,
            .endLineNumber = 1,
            .relativeVerticalOffset = &self.offsets,
            .visibleRange = Range.init(1, 1, 1, 1),
            .bigNumbersDelta = 0,
            .whitespaceViewportData = &.{},
            .lineHeight = 19,
            ._model = self.view_model.interface(),
        };
    }

    fn deinit(self: *Fixture) void {
        self.tokens.deinit();
        self.codec.deinit();
    }
};

test "view line renders tab-expanded text and tracks invalidation" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "a\tb");
    defer fixture.deinit();

    const line_options = ViewLineOptions.init(&fixture.configuration, .DARK);
    var line = ViewLine.init(allocator, &fixture.context, line_options);
    defer line.deinit(allocator);

    var sb = try StringBuilder.init(allocator, 8);
    defer sb.deinit();

    try testing.expect(line.shouldRender());
    try testing.expect(line.renderLine(1, 0, 19, &fixture.viewport, &sb));
    try testing.expectEqualStrings("a   b", sb.build());
    line.onDidRender();
    try testing.expect(!line.shouldRender());

    // Rendering the same content again reports no change but still appends.
    sb.reset();
    try testing.expect(!line.renderLine(1, 0, 19, &fixture.viewport, &sb));
    try testing.expectEqualStrings("a   b", sb.build());

    // Token changes invalidate the line.
    line.onTokensChanged();
    try testing.expect(line.shouldRender());
    line.onDidRender();
    try testing.expect(!line.shouldRender());
}

test "view line renders through the visible lines collection" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "x\ty");
    defer fixture.deinit();

    const line_options = ViewLineOptions.init(&fixture.configuration, .DARK);
    const Factory = struct {
        allocator: Allocator,
        context: *view_context.ViewContext,
        options: ViewLineOptions,

        fn create(context: *anyopaque) anyerror!ViewLine {
            const self: *@This() = @ptrCast(@alignCast(context));
            return ViewLine.init(self.allocator, self.context, self.options);
        }
    };
    var factory = Factory{ .allocator = allocator, .context = &fixture.context, .options = line_options };
    var collection = view_layer.VisibleLinesCollection(ViewLine).init(allocator, fixture.layout.interface(), .{
        .context = &factory,
        .create = Factory.create,
    });
    defer collection.deinit();

    var sb = try StringBuilder.init(allocator, 8);
    defer sb.deinit();
    try collection.renderLines(&fixture.viewport, &sb);
    try testing.expectEqualStrings("x   y", sb.build());
    _ = collection.onFlushed(&.{});
}
