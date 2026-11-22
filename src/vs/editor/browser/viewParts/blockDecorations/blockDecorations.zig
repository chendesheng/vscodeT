// Port of `src/vs/editor/browser/viewParts/blockDecorations/blockDecorations.ts`.
//
// Terminal adaptation: upstream owns a DOM container and creates one
// positioned `<div>` block per decoration that carries `blockClassName`. The
// terminal has no browser DOM or box model, so this view part computes the
// same block ranges in view-line rows and exposes them to the cell
// compositor. The compositor maps the class names to cell backgrounds or cell
// borders; the ported `blockDecorations_css.zig` supplies the class records.
// Class names that have no terminal rule stay invisible, matching an upstream
// class without a registered CSS rule. A terminal border is one cell wide; the
// browser's 2 px moved-block border becomes that cell border.
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_part = @import("../../view/viewPart.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const view_model_decoration = @import("../../../common/viewModel/viewModelDecoration.zig");

const ViewPart = view_part.ViewPart;
const RenderingContext = rendering_context.RenderingContext;
const RestrictedRenderingContext = rendering_context.RestrictedRenderingContext;
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const ViewModelDecoration = view_model_decoration.ViewModelDecoration;

/// One block decoration in scrolled terminal rows.
///
/// `class_name` is borrowed from the model decoration options and stays valid
/// until the next decoration change. `top` is the block's first row and
/// `bottom` is the offset after its last row, both relative to the viewport
/// scroll position. `padding` is upstream's `blockPadding` in cells
/// (`top`, `right`, `bottom`, `left`).
pub const Block = struct {
    class_name: []const u8,
    top: f64,
    bottom: f64,
    padding: [4]usize,
};

/// Port of `BlockDecorations`.
pub const BlockDecorations = struct {
    base: ViewPart,
    allocator: Allocator,
    blocks: std.array_list.Managed(Block),

    pub fn init(self: *BlockDecorations, allocator: Allocator, context: *ViewContext) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .blocks = std.array_list.Managed(Block).init(allocator),
        };
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *BlockDecorations) void {
        self.base.deinit();
        self.blocks.deinit();
    }

    /// The blocks computed by the last `render` pass. Valid until the next
    /// render or deinit.
    pub fn blocksSlice(self: *const BlockDecorations) []const Block {
        return self.blocks.items;
    }

    // --- begin event handlers

    fn onConfigurationChanged(_: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        return true;
    }

    fn onScrollChanged(_: *anyopaque, event: *const view_events.ViewScrollChangedEvent) bool {
        return event.scrollTopChanged or event.scrollLeftChanged;
    }

    fn onDecorationsChanged(_: *anyopaque, _: *const view_events.ViewDecorationsChangedEvent) bool {
        return true;
    }

    fn onZonesChanged(_: *anyopaque, _: *const view_events.ViewZonesChangedEvent) bool {
        return true;
    }

    fn callbacks() EventHandlerCallbacks {
        return .{
            .onConfigurationChanged = onConfigurationChanged,
            .onScrollChanged = onScrollChanged,
            .onDecorationsChanged = onDecorationsChanged,
            .onZonesChanged = onZonesChanged,
        };
    }

    // --- end event handlers

    fn prepareRenderCallback(_: *ViewPart, _: *RenderingContext) void {}

    fn renderCallback(part: *ViewPart, restricted: *RestrictedRenderingContext) void {
        const self: *BlockDecorations = @fieldParentPtr("base", part);
        self.render(restricted);
    }

    /// Port of `BlockDecorations.render`. The upstream loop reads the viewport
    /// decorations, computes the block's top/bottom from the view layout and
    /// stops when the decoration has no `blockClassName`.
    pub fn render(self: *BlockDecorations, restricted: *RestrictedRenderingContext) void {
        self.blocks.clearRetainingCapacity();
        const decorations = restricted.getDecorationsInViewport(self.allocator) catch return;
        defer self.allocator.free(decorations);
        collectBlocks(restricted, decorations, &self.blocks) catch return;
    }
};

/// Computes the block range for every decoration that has a `blockClassName`.
///
/// This is the portable part of upstream `BlockDecorations.render`: the
/// decoration order and the `blockIsAfterEnd`/`blockDoesNotCollapse` branches
/// are kept. The only change is that offsets are already scrolled rows instead
/// of being converted to pixels.
pub fn collectBlocks(
    restricted: *const RestrictedRenderingContext,
    decorations: []const ViewModelDecoration,
    out: *std.array_list.Managed(Block),
) !void {
    for (decorations) |decoration| {
        const class_name = decoration.options.blockClassName orelse continue;

        var top: f64 = 0;
        var bottom: f64 = 0;
        if (decoration.options.blockIsAfterEnd orelse false) {
            // The range is empty and sits on the last line.
            top = restricted.getVerticalOffsetAfterLineNumber(decoration.range.endLineNumber, false);
            bottom = restricted.getVerticalOffsetAfterLineNumber(decoration.range.endLineNumber, true);
        } else {
            top = restricted.getVerticalOffsetForLineNumber(decoration.range.startLineNumber, true);
            bottom = if (decoration.range.isEmpty() and !(decoration.options.blockDoesNotCollapse orelse false))
                restricted.getVerticalOffsetForLineNumber(decoration.range.startLineNumber, false)
            else
                restricted.getVerticalOffsetAfterLineNumber(decoration.range.endLineNumber, true);
        }

        try out.append(.{
            .class_name = class_name,
            .top = top - restricted.scrollTop,
            .bottom = bottom - restricted.scrollTop,
            // Upstream treats a missing `blockPadding` as all zeros.
            .padding = decoration.options.blockPadding orelse .{ 0, 0, 0, 0 },
        });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const view_model = @import("../../../common/viewModel.zig");
const model = @import("../../../common/model.zig");
const Range = @import("../../../common/core/range.zig").Range;
const viewport_data = @import("../../../common/viewLayout/viewLinesViewportData.zig");

const TestLayout = struct {
    scroll_top: f64 = 0,

    fn interface(self: *TestLayout) view_model.IViewLayout {
        return .{
            .context = self,
            .get_scroll_width = getScrollWidth,
            .get_scroll_height = getScrollHeight,
            .get_current_viewport = getCurrentViewport,
            .get_vertical_offset_for_line_number = getVerticalOffset,
            .get_vertical_offset_after_line_number = getVerticalOffsetAfter,
            .get_line_height_for_line_number = getLineHeight,
        };
    }

    fn getScrollWidth(_: *anyopaque) f64 {
        return 80;
    }

    fn getScrollHeight(_: *anyopaque) f64 {
        return 100;
    }

    fn getCurrentViewport(context: *anyopaque) view_model.Viewport {
        const self: *TestLayout = @ptrCast(@alignCast(context));
        return view_model.Viewport.init(self.scroll_top, 0, 80, 10);
    }

    fn getVerticalOffset(_: *anyopaque, line_number: usize, _: bool) f64 {
        return @floatFromInt(line_number -| 1);
    }

    fn getVerticalOffsetAfter(_: *anyopaque, line_number: usize, _: bool) f64 {
        return @floatFromInt(line_number);
    }

    fn getLineHeight(_: *anyopaque, _: usize) f64 {
        return 1;
    }
};

fn testRestricted(layout: *TestLayout) RestrictedRenderingContext {
    const viewport = viewport_data.ViewportData{
        .selections = &.{},
        .startLineNumber = 1,
        .endLineNumber = 10,
        .relativeVerticalOffset = &.{},
        .visibleRange = Range.init(1, 1, 10, 1),
        .bigNumbersDelta = 0,
        .whitespaceViewportData = &.{},
        .lineHeight = 1,
        ._model = undefined,
    };
    return RestrictedRenderingContext.init(layout.interface(), &viewport);
}

test "block decorations: computes a non-empty block range in scrolled rows" {
    var options = model.ModelDecorationOptions.init("block", .AlwaysGrowsWhenTypingAtEdges);
    options.blockClassName = "movedModified";
    options.blockPadding = .{ 1, 2, 3, 4 };
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(2, 1, 3, 1), .options = &options },
    };

    var layout = TestLayout{ .scroll_top = 1 };
    const restricted = testRestricted(&layout);
    var blocks = std.array_list.Managed(Block).init(testing.allocator);
    defer blocks.deinit();
    try collectBlocks(&restricted, &decorations, &blocks);

    try testing.expectEqual(@as(usize, 1), blocks.items.len);
    try testing.expectEqualStrings("movedModified", blocks.items[0].class_name);
    // Line 2 starts at offset 1, line 3 ends at offset 3; scrollTop is 1.
    try testing.expectEqual(@as(f64, 0), blocks.items[0].top);
    try testing.expectEqual(@as(f64, 2), blocks.items[0].bottom);
    try testing.expectEqual([4]usize{ 1, 2, 3, 4 }, blocks.items[0].padding);
}

test "block decorations: empty ranges collapse unless blockDoesNotCollapse is set" {
    var collapse = model.ModelDecorationOptions.init("collapse", .AlwaysGrowsWhenTypingAtEdges);
    collapse.blockClassName = "movedOriginal";
    var keep = model.ModelDecorationOptions.init("keep", .AlwaysGrowsWhenTypingAtEdges);
    keep.blockClassName = "movedOriginal";
    keep.blockDoesNotCollapse = true;
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(2, 1, 2, 1), .options = &collapse },
        .{ .range = Range.init(2, 1, 2, 1), .options = &keep },
    };

    var layout = TestLayout{};
    const restricted = testRestricted(&layout);
    var blocks = std.array_list.Managed(Block).init(testing.allocator);
    defer blocks.deinit();
    try collectBlocks(&restricted, &decorations, &blocks);

    try testing.expectEqual(@as(usize, 2), blocks.items.len);
    // The collapsed block has zero height; the preserved one covers one row.
    try testing.expectEqual(@as(f64, 1), blocks.items[0].top);
    try testing.expectEqual(@as(f64, 1), blocks.items[0].bottom);
    try testing.expectEqual(@as(f64, 1), blocks.items[1].top);
    try testing.expectEqual(@as(f64, 2), blocks.items[1].bottom);
}

test "block decorations: blockIsAfterEnd uses the after-end offsets" {
    var options = model.ModelDecorationOptions.init("after", .AlwaysGrowsWhenTypingAtEdges);
    options.blockClassName = "movedOriginal";
    options.blockIsAfterEnd = true;
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(4, 1, 4, 1), .options = &options },
    };

    var layout = TestLayout{};
    const restricted = testRestricted(&layout);
    var blocks = std.array_list.Managed(Block).init(testing.allocator);
    defer blocks.deinit();
    try collectBlocks(&restricted, &decorations, &blocks);

    try testing.expectEqual(@as(usize, 1), blocks.items.len);
    try testing.expectEqual(@as(f64, 4), blocks.items[0].top);
    try testing.expectEqual(@as(f64, 4), blocks.items[0].bottom);
}

test "block decorations: ignores decorations without a block class" {
    var without = model.ModelDecorationOptions.init("without", .AlwaysGrowsWhenTypingAtEdges);
    without.className = "line-insert";
    var with = model.ModelDecorationOptions.init("with", .AlwaysGrowsWhenTypingAtEdges);
    with.blockClassName = "movedModified";
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(1, 1, 2, 1), .options = &without },
        .{ .range = Range.init(1, 1, 2, 1), .options = &with },
    };

    var layout = TestLayout{};
    const restricted = testRestricted(&layout);
    var blocks = std.array_list.Managed(Block).init(testing.allocator);
    defer blocks.deinit();
    try collectBlocks(&restricted, &decorations, &blocks);

    try testing.expectEqual(@as(usize, 1), blocks.items.len);
    try testing.expectEqualStrings("movedModified", blocks.items[0].class_name);
}

test "block decorations: render reads decorations from the viewport" {
    const browser_config = @import("../../config/editorConfiguration.zig");
    const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
    const actions = @import("../../../../platform/actions/common/actions.zig");
    const test_stubs = @import("../../../test/common/viewModelTestStubs.zig");

    var options = model.ModelDecorationOptions.init("block", .AlwaysGrowsWhenTypingAtEdges);
    options.blockClassName = "movedModified";
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(2, 1, 3, 1), .options = &options },
    };

    var layout = TestLayout{};
    var view_model_stub = test_stubs.TestViewModel.init(layout.interface());
    view_model_stub.line_count = 4;
    view_model_stub.decorations = &decorations;
    const line_lengths = try testing.allocator.alloc(usize, 4);
    defer testing.allocator.free(line_lengths);
    @memset(line_lengths, 20);
    view_model_stub.line_lengths = line_lengths;

    var options_set = browser_config.ComputedEditorOptions.init();
    var configuration = editor_configuration.IEditorConfiguration{
        .is_simple_widget = false,
        .context_menu_id = actions.menu_ids.EditorContext,
        .options = options_set.interface(),
    };
    var context = ViewContext.init(&configuration, test_stubs.TestColorTheme.dark(), view_model_stub.interface());

    var part: BlockDecorations = undefined;
    part.init(testing.allocator, &context);
    defer part.deinit();

    const viewport = viewport_data.ViewportData{
        .selections = &.{},
        .startLineNumber = 1,
        .endLineNumber = 4,
        .relativeVerticalOffset = &.{},
        .visibleRange = Range.init(1, 1, 4, 1),
        .bigNumbersDelta = 0,
        .whitespaceViewportData = &.{},
        .lineHeight = 1,
        ._model = view_model_stub.interface(),
    };
    var restricted = RestrictedRenderingContext.init(layout.interface(), &viewport);
    part.render(&restricted);

    try testing.expectEqual(@as(usize, 1), part.blocksSlice().len);
    try testing.expectEqualStrings("movedModified", part.blocksSlice()[0].class_name);
}
