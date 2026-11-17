// Port of `src/vs/editor/common/viewModel.ts`

const std = @import("std");
const strings = @import("../../base/common/strings.zig");

const Range = @import("./core/range.zig").Range;
const LanguageIdCodec = @import("./languages.zig").LanguageIdCodec;
const TextDirection = @import("./standalone/standaloneEnums.zig").TextDirection;
const IViewLineTokens = @import("./tokens/lineTokens.zig").IViewLineTokens;
const InlineDecoration = @import("./viewModel/inlineDecorations.zig").InlineDecoration;

pub const ViewModelDecoration = @import("./viewModel/viewModelDecoration.zig").ViewModelDecoration;

/// The viewport of the editor, expressed in integer pixels.
pub const Viewport = struct {
    top: i32,
    left: i32,
    width: i32,
    height: i32,

    /// Upstream truncates each dimension with `value | 0`.
    pub fn init(top: f64, left: f64, width: f64, height: f64) Viewport {
        return .{
            .top = truncToI32(top),
            .left = truncToI32(left),
            .width = truncToI32(width),
            .height = truncToI32(height),
        };
    }

    pub fn equals(a: Viewport, b: Viewport) bool {
        return a.top == b.top and a.left == b.left and a.width == b.width and a.height == b.height;
    }
};

fn truncToI32(value: f64) i32 {
    const truncated = @trunc(value);
    if (truncated >= 2147483647.0) return std.math.maxInt(i32);
    if (truncated <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(truncated);
}

pub const MinimapLinesRenderingData = struct {
    tabSize: usize,
    /// `null` entries are lines that are not needed by the minimap. The slice
    /// and the contents it points at are borrowed from the caller.
    data: []const ?ViewLineData,
};

/// A single view line, i.e. a line of the view model. A model line maps to one
/// or more view lines when word wrapping is enabled, in which case `content`
/// points at the corresponding slice of the model line.
pub const ViewLineData = struct {
    content: []const u8,
    continuesWithWrappedLine: bool,
    minColumn: usize,
    maxColumn: usize,
    startVisibleColumn: usize,
    tokens: IViewLineTokens,
    inlineDecorations: ?[]const InlineDecoration,

    pub fn init(
        content: []const u8,
        continuesWithWrappedLine: bool,
        minColumn: usize,
        maxColumn: usize,
        startVisibleColumn: usize,
        tokens: IViewLineTokens,
        inlineDecorations: ?[]const InlineDecoration,
    ) ViewLineData {
        return .{
            .content = content,
            .continuesWithWrappedLine = continuesWithWrappedLine,
            .minColumn = minColumn,
            .maxColumn = maxColumn,
            .startVisibleColumn = startVisibleColumn,
            .tokens = tokens,
            .inlineDecorations = inlineDecorations,
        };
    }
};

pub const ViewLineRenderingData = struct {
    minColumn: usize,
    maxColumn: usize,
    content: []const u8,
    continuesWithWrappedLine: bool,
    /// Whether `content` contains right-to-left characters.
    containsRTL: bool,
    /// Whether `content` is made up of basic ASCII characters only.
    isBasicASCII: bool,
    tokens: IViewLineTokens,
    inlineDecorations: []const InlineDecoration,
    tabSize: usize,
    startVisibleColumn: usize,
    textDirection: TextDirection,
    hasVariableFonts: bool,

    pub fn init(
        minColumn: usize,
        maxColumn: usize,
        content: []const u8,
        continuesWithWrappedLine: bool,
        mightContainRTL: bool,
        mightContainNonBasicASCII: bool,
        tokens: IViewLineTokens,
        inlineDecorations: []const InlineDecoration,
        tabSize: usize,
        startVisibleColumn: usize,
        textDirection: TextDirection,
        hasVariableFonts: bool,
    ) ViewLineRenderingData {
        const isBasicASCII = ViewLineRenderingData.isBasicASCIIContent(content, mightContainNonBasicASCII);
        const containsRTL = ViewLineRenderingData.containsRTLContent(content, isBasicASCII, mightContainRTL);
        return .{
            .minColumn = minColumn,
            .maxColumn = maxColumn,
            .content = content,
            .continuesWithWrappedLine = continuesWithWrappedLine,
            .containsRTL = containsRTL,
            .isBasicASCII = isBasicASCII,
            .tokens = tokens,
            .inlineDecorations = inlineDecorations,
            .tabSize = tabSize,
            .startVisibleColumn = startVisibleColumn,
            .textDirection = textDirection,
            .hasVariableFonts = hasVariableFonts,
        };
    }

    pub fn isBasicASCIIContent(line_content: []const u8, mightContainNonBasicASCII: bool) bool {
        if (mightContainNonBasicASCII) {
            return strings.isBasicASCII(line_content);
        }
        return true;
    }

    pub fn containsRTLContent(line_content: []const u8, is_basic_ascii: bool, mightContainRTL: bool) bool {
        if (!is_basic_ascii and mightContainRTL) {
            return strings.containsRTL(line_content);
        }
        return false;
    }
};

/// A group of overview ruler decorations that share a color and a z-index.
pub const OverviewRulerDecorationsGroup = struct {
    color: []const u8,
    zIndex: i32,
    /// Decorations are encoded in a number array using the following scheme:
    ///  - `3*i`     = lane
    ///  - `3*i + 1` = startLineNumber
    ///  - `3*i + 2` = endLineNumber
    data: []const u32,

    pub fn compareByRenderingProps(a: OverviewRulerDecorationsGroup, b: OverviewRulerDecorationsGroup) i32 {
        if (a.zIndex == b.zIndex) {
            return switch (std.mem.order(u8, a.color, b.color)) {
                .lt => -1,
                .gt => 1,
                .eq => 0,
            };
        }
        return a.zIndex - b.zIndex;
    }

    pub fn equals(a: OverviewRulerDecorationsGroup, b: OverviewRulerDecorationsGroup) bool {
        return std.mem.eql(u8, a.color, b.color) and
            a.zIndex == b.zIndex and
            std.mem.eql(u32, a.data, b.data);
    }

    pub fn equalsArr(a: []const OverviewRulerDecorationsGroup, b: []const OverviewRulerDecorationsGroup) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!equals(x, y)) return false;
        }
        return true;
    }
};

pub const IEditorWhitespace = struct {
    /// Opaque identifier handed out by `IWhitespaceChangeAccessor.insertWhitespace`.
    id: []const u8,
    afterLineNumber: usize,
    height: f64,
};

/// Allows whitespace (view zones) to be added, removed or changed in bulk.
///
/// Unlike upstream, the accessor is fallible: inserting a whitespace may have to
/// allocate an id.
pub const IWhitespaceChangeAccessor = struct {
    context: *anyopaque,
    insertWhitespace: *const fn (context: *anyopaque, afterLineNumber: usize, ordinal: i32, heightInPx: f64, minWidth: f64) anyerror![]const u8,
    changeOneWhitespace: *const fn (context: *anyopaque, id: []const u8, newAfterLineNumber: usize, newHeight: f64) anyerror!void,
    removeWhitespace: *const fn (context: *anyopaque, id: []const u8) anyerror!void,

    pub fn insert(
        self: IWhitespaceChangeAccessor,
        after_line_number: usize,
        ordinal: i32,
        height_in_px: f64,
        min_width: f64,
    ) anyerror![]const u8 {
        return self.insertWhitespace(self.context, after_line_number, ordinal, height_in_px, min_width);
    }

    pub fn changeOne(self: IWhitespaceChangeAccessor, id: []const u8, new_after_line_number: usize, new_height: f64) anyerror!void {
        return self.changeOneWhitespace(self.context, id, new_after_line_number, new_height);
    }

    pub fn remove(self: IWhitespaceChangeAccessor, id: []const u8) anyerror!void {
        return self.removeWhitespace(self.context, id);
    }
};

pub const ILineHeightChangeAccessor = struct {
    context: *anyopaque,
    insertOrChangeCustomLineHeight: *const fn (context: *anyopaque, decorationId: []const u8, startLineNumber: usize, endLineNumber: usize, lineHeight: f64) anyerror!void,
    removeCustomLineHeight: *const fn (context: *anyopaque, decorationId: []const u8) anyerror!void,

    pub fn insertOrChange(
        self: ILineHeightChangeAccessor,
        decoration_id: []const u8,
        start_line_number: usize,
        end_line_number: usize,
        line_height: f64,
    ) anyerror!void {
        return self.insertOrChangeCustomLineHeight(self.context, decoration_id, start_line_number, end_line_number, line_height);
    }

    pub fn remove(self: ILineHeightChangeAccessor, decoration_id: []const u8) anyerror!void {
        return self.removeCustomLineHeight(self.context, decoration_id);
    }
};

/// The subset of upstream `IViewModel` that the modules ported so far need. It
/// grows as more consumers are ported; the full interface is much larger.
pub const IViewModel = struct {
    context: *anyopaque,
    getLineMinColumn: *const fn (context: *anyopaque, lineNumber: usize) usize,
    getLineMaxColumn: *const fn (context: *anyopaque, lineNumber: usize) usize,
    getViewportViewLineRenderingData: *const fn (context: *anyopaque, visibleRange: Range, lineNumber: usize) anyerror!ViewLineRenderingData,
    getViewLineContinuesWithWrappedLine: *const fn (context: *anyopaque, lineNumber: usize) bool,
    /// Returns an array owned by the caller.
    getDecorationsInViewport: *const fn (context: *anyopaque, visibleRange: Range) anyerror![]ViewModelDecoration,

    pub fn lineMinColumn(self: IViewModel, line_number: usize) usize {
        return self.getLineMinColumn(self.context, line_number);
    }

    pub fn lineMaxColumn(self: IViewModel, line_number: usize) usize {
        return self.getLineMaxColumn(self.context, line_number);
    }

    pub fn viewportViewLineRenderingData(self: IViewModel, visible_range: Range, line_number: usize) !ViewLineRenderingData {
        return self.getViewportViewLineRenderingData(self.context, visible_range, line_number);
    }

    pub fn viewLineContinuesWithWrappedLine(self: IViewModel, line_number: usize) bool {
        return self.getViewLineContinuesWithWrappedLine(self.context, line_number);
    }

    pub fn decorationsInViewport(self: IViewModel, visible_range: Range) ![]ViewModelDecoration {
        return self.getDecorationsInViewport(self.context, visible_range);
    }
};

pub const IPartialViewLinesViewportData = struct {
    /// Value to be subtracted from `scrollTop` (in order to keep vertical
    /// offset numbers below one million, so they stay exact as f64).
    bigNumbersDelta: f64,
    /// The first (partially) visible line number.
    startLineNumber: usize,
    /// The last (partially) visible line number.
    endLineNumber: usize,
    /// `relativeVerticalOffset[i]` is the `top` position for the line at
    /// `i + startLineNumber`.
    relativeVerticalOffset: []const f64,
    /// The centered line in the viewport.
    centeredLineNumber: usize,
    /// The first completely visible line number.
    completelyVisibleStartLineNumber: usize,
    /// The last completely visible line number.
    completelyVisibleEndLineNumber: usize,
    /// The height of a line.
    lineHeight: f64,
};

pub const IViewWhitespaceViewportData = struct {
    id: []const u8,
    afterLineNumber: usize,
    verticalOffset: f64,
    height: f64,
};

test "Viewport truncates its dimensions" {
    const viewport = Viewport.init(10.9, -3.7, 100.5, 0.25);
    try std.testing.expectEqual(@as(i32, 10), viewport.top);
    try std.testing.expectEqual(@as(i32, -3), viewport.left);
    try std.testing.expectEqual(@as(i32, 100), viewport.width);
    try std.testing.expectEqual(@as(i32, 0), viewport.height);
    try std.testing.expect(Viewport.equals(viewport, Viewport.init(10, -3, 100, 0)));
    try std.testing.expect(!Viewport.equals(viewport, Viewport.init(10, -3, 100, 1)));
}

test "ViewLineRenderingData computes ASCII and RTL flags" {
    const allocator = std.testing.allocator;
    TestTokens.decoder = try LanguageIdCodec.init(allocator);
    defer TestTokens.decoder.deinit();

    const content = "hello world";
    try std.testing.expect(ViewLineRenderingData.isBasicASCIIContent(content, true));
    // When the model claims it cannot contain non-ASCII, the scan is skipped.
    try std.testing.expect(ViewLineRenderingData.isBasicASCIIContent("\u{1F600}", false));

    try std.testing.expect(!ViewLineRenderingData.containsRTLContent(content, true, true));
    try std.testing.expect(!ViewLineRenderingData.containsRTLContent(content, false, false));

    var tokens = try testLineTokens(allocator, content);
    defer tokens.deinit();

    const data = ViewLineRenderingData.init(
        1,
        12,
        content,
        false,
        true,
        true,
        IViewLineTokens.init(&tokens),
        &.{},
        4,
        0,
        .LTR,
        false,
    );
    try std.testing.expect(data.isBasicASCII);
    try std.testing.expect(!data.containsRTL);
    try std.testing.expectEqual(@as(usize, 12), data.maxColumn);
    try std.testing.expectEqual(@as(usize, 4), data.tabSize);
    try std.testing.expectEqual(TextDirection.LTR, data.textDirection);
}

test "ViewLineRenderingData detects RTL content" {
    const allocator = std.testing.allocator;
    TestTokens.decoder = try LanguageIdCodec.init(allocator);
    defer TestTokens.decoder.deinit();

    const content = "\u{5E9}\u{5DC}\u{5D5}\u{5DD}";
    try std.testing.expect(!ViewLineRenderingData.isBasicASCIIContent(content, true));
    try std.testing.expect(ViewLineRenderingData.containsRTLContent(content, false, true));
    try std.testing.expect(!ViewLineRenderingData.containsRTLContent(content, false, false));

    var tokens = try testLineTokens(allocator, content);
    defer tokens.deinit();

    const data = ViewLineRenderingData.init(
        1,
        6,
        content,
        false,
        true,
        true,
        IViewLineTokens.init(&tokens),
        &.{},
        4,
        0,
        .RTL,
        false,
    );
    try std.testing.expect(data.containsRTL);
    try std.testing.expect(!data.isBasicASCII);
    try std.testing.expectEqual(TextDirection.RTL, data.textDirection);
}

test "OverviewRulerDecorationsGroup ordering and equality" {
    const a = OverviewRulerDecorationsGroup{ .color = "#ff0000", .zIndex = 1, .data = &.{ 0, 1, 5 } };
    const b = OverviewRulerDecorationsGroup{ .color = "#00ff00", .zIndex = 1, .data = &.{ 1, 2, 3 } };
    const c = OverviewRulerDecorationsGroup{ .color = "#0000ff", .zIndex = 5, .data = &.{} };

    // Same z-index orders by color ("#ff0000" sorts after "#00ff00").
    try std.testing.expectEqual(@as(i32, 1), OverviewRulerDecorationsGroup.compareByRenderingProps(a, b));
    try std.testing.expectEqual(@as(i32, -1), OverviewRulerDecorationsGroup.compareByRenderingProps(b, a));
    // Different z-index orders by z-index.
    try std.testing.expectEqual(@as(i32, -4), OverviewRulerDecorationsGroup.compareByRenderingProps(a, c));
    try std.testing.expectEqual(@as(i32, 0), OverviewRulerDecorationsGroup.compareByRenderingProps(a, a));

    try std.testing.expect(OverviewRulerDecorationsGroup.equals(a, a));
    try std.testing.expect(!OverviewRulerDecorationsGroup.equals(a, b));

    const same = OverviewRulerDecorationsGroup{ .color = "#ff0000", .zIndex = 1, .data = &.{ 0, 1, 5 } };
    try std.testing.expect(OverviewRulerDecorationsGroup.equalsArr(&.{ a, b }, &.{ same, b }));
    try std.testing.expect(!OverviewRulerDecorationsGroup.equalsArr(&.{a}, &.{ a, b }));
    // Data length differences are detected.
    const shorter = OverviewRulerDecorationsGroup{ .color = "#ff0000", .zIndex = 1, .data = &.{ 0, 1 } };
    try std.testing.expect(!OverviewRulerDecorationsGroup.equals(a, shorter));
}

test "ViewLineData carries borrowed content" {
    const allocator = std.testing.allocator;
    TestTokens.decoder = try LanguageIdCodec.init(allocator);
    defer TestTokens.decoder.deinit();

    const content = "some text";
    var tokens = try testLineTokens(allocator, content);
    defer tokens.deinit();

    const data = ViewLineData.init(content, true, 1, 10, 0, IViewLineTokens.init(&tokens), null);
    try std.testing.expectEqualStrings(content, data.content);
    try std.testing.expect(data.continuesWithWrappedLine);
    try std.testing.expect(data.inlineDecorations == null);
    try std.testing.expectEqual(@as(usize, 1), data.tokens.getCount());

    const minimap = MinimapLinesRenderingData{ .tabSize = 8, .data = &.{ null, data } };
    try std.testing.expectEqual(@as(usize, 8), minimap.tabSize);
    try std.testing.expect(minimap.data[0] == null);
    try std.testing.expectEqualStrings(content, minimap.data[1].?.content);
}

test "IViewLineTokens delegates to the sliced view" {
    const allocator = std.testing.allocator;
    TestTokens.decoder = try LanguageIdCodec.init(allocator);
    defer TestTokens.decoder.deinit();

    const content = "hello world";
    var tokens = try testLineTokens(allocator, content);
    defer tokens.deinit();

    const whole = IViewLineTokens.init(&tokens);
    try std.testing.expectEqual(@as(usize, 1), whole.getCount());
    try std.testing.expectEqualStrings(content, whole.getLineContent());

    const slice = IViewLineTokens.initSlice(tokens.sliceAndInflate(6, 11, 0));
    try std.testing.expectEqual(@as(usize, 1), slice.getCount());
    try std.testing.expectEqualStrings("world", slice.getLineContent());
    try std.testing.expectEqual(@as(usize, 5), slice.getEndOffset(0));

    // Comparing different representations yields false; same representation
    // compares structurally.
    try std.testing.expect(!whole.equals(slice));
    try std.testing.expect(slice.equals(IViewLineTokens.initSlice(tokens.sliceAndInflate(6, 11, 0))));
}

const TestTokens = struct {
    var decoder: LanguageIdCodec = undefined;
};

fn testLineTokens(allocator: std.mem.Allocator, content: []const u8) !@import("./tokens/lineTokens.zig").LineTokens {
    var line_content = std.array_list.Managed(u8).init(allocator);
    errdefer line_content.deinit();
    try line_content.appendSlice(content);
    return @import("./tokens/lineTokens.zig").LineTokens.createEmpty(allocator, line_content, &TestTokens.decoder);
}

/// The subset of upstream `IViewLayout` consumed by `view/renderingContext.ts`.
/// The scroll/set operations, whitespace data and overlay-widget width are not
/// ported until the view layout is split out of the terminal view.
pub const IViewLayout = struct {
    context: *anyopaque,
    get_scroll_width: *const fn (context: *anyopaque) f64,
    get_scroll_height: *const fn (context: *anyopaque) f64,
    get_current_viewport: *const fn (context: *anyopaque) Viewport,
    get_vertical_offset_for_line_number: *const fn (context: *anyopaque, line_number: usize, include_view_zones: bool) f64,
    get_vertical_offset_after_line_number: *const fn (context: *anyopaque, line_number: usize, include_view_zones: bool) f64,
    get_line_height_for_line_number: *const fn (context: *anyopaque, line_number: usize) f64,

    pub fn getScrollWidth(self: IViewLayout) f64 {
        return self.get_scroll_width(self.context);
    }

    pub fn getScrollHeight(self: IViewLayout) f64 {
        return self.get_scroll_height(self.context);
    }

    pub fn getCurrentViewport(self: IViewLayout) Viewport {
        return self.get_current_viewport(self.context);
    }

    pub fn getVerticalOffsetForLineNumber(self: IViewLayout, line_number: usize, include_view_zones: bool) f64 {
        return self.get_vertical_offset_for_line_number(self.context, line_number, include_view_zones);
    }

    pub fn getVerticalOffsetAfterLineNumber(self: IViewLayout, line_number: usize, include_view_zones: bool) f64 {
        return self.get_vertical_offset_after_line_number(self.context, line_number, include_view_zones);
    }

    pub fn getLineHeightForLineNumber(self: IViewLayout, line_number: usize) f64 {
        return self.get_line_height_for_line_number(self.context, line_number);
    }
};
