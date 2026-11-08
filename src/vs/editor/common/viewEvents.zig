const std = @import("std");
const ScrollEvent = @import("../../base/common/scrollable.zig").ScrollEvent;
const ConfigurationChangedEvent = @import("./config/editorOptions.zig").ConfigurationChangedEvent;
const EditorOption = @import("./config/editorOptions.zig").EditorOption;
const Range = @import("./core/range.zig").Range;
const rangeFromPositions = @import("./core/range.zig").fromPositions;
const Selection = @import("./core/selection.zig").Selection;
const CursorChangeReason = @import("./cursorEvents.zig").CursorChangeReason;
const ScrollType = @import("./editorCommon.zig").ScrollType;
const ModelDecorationsChangedEvent = @import("./textModelEvents.zig").ModelDecorationsChangedEvent;
const IColorTheme = @import("../../platform/theme/common/themeService.zig").IColorTheme;

pub const ViewEventType = enum(u8) {
    ViewCompositionStart = 0,
    ViewCompositionEnd = 1,
    ViewConfigurationChanged = 2,
    ViewCursorStateChanged = 3,
    ViewDecorationsChanged = 4,
    ViewFlushed = 5,
    ViewFocusChanged = 6,
    ViewLanguageConfigurationChanged = 7,
    ViewLineMappingChanged = 8,
    ViewLinesChanged = 9,
    ViewLinesDeleted = 10,
    ViewLinesInserted = 11,
    ViewRevealRangeRequest = 12,
    ViewScrollChanged = 13,
    ViewThemeChanged = 14,
    ViewTokensChanged = 15,
    ViewTokensColorsChanged = 16,
    ViewZonesChanged = 17,
};

pub const ViewCompositionStartEvent = struct {};
pub const ViewCompositionEndEvent = struct {};

pub const ViewConfigurationChangedEvent = struct {
    _source: ConfigurationChangedEvent,

    pub fn init(source: ConfigurationChangedEvent) ViewConfigurationChangedEvent {
        return .{ ._source = source };
    }

    pub fn hasChanged(self: ViewConfigurationChangedEvent, id: EditorOption) bool {
        return self._source.hasChanged(id);
    }
};

pub const ViewCursorStateChangedEvent = struct {
    selections: []const Selection,
    modelSelections: []const Selection,
    reason: CursorChangeReason,
};

pub const ViewDecorationsChangedEvent = struct {
    affectsMinimap: bool,
    affectsOverviewRuler: bool,
    affectsGlyphMargin: bool,
    affectsLineNumber: bool,

    pub fn init(source: ?ModelDecorationsChangedEvent) ViewDecorationsChangedEvent {
        if (source) |event| {
            return .{
                .affectsMinimap = event.affectsMinimap,
                .affectsOverviewRuler = event.affectsOverviewRuler,
                .affectsGlyphMargin = event.affectsGlyphMargin,
                .affectsLineNumber = event.affectsLineNumber,
            };
        }
        return .{
            .affectsMinimap = true,
            .affectsOverviewRuler = true,
            .affectsGlyphMargin = true,
            .affectsLineNumber = true,
        };
    }
};

pub const ViewFlushedEvent = struct {};

pub const ViewFocusChangedEvent = struct {
    isFocused: bool,
};

pub const ViewLanguageConfigurationEvent = struct {};

pub const ViewLineMappingChangedEvent = struct {};

pub const ViewLinesChangedEvent = struct {
    /// The first line that has changed.
    fromLineNumber: usize,
    /// The number of lines that have changed.
    count: usize,
};

pub const ViewLinesDeletedEvent = struct {
    /// At what line the deletion began (inclusive).
    fromLineNumber: usize,
    /// At what line the deletion stopped (inclusive).
    toLineNumber: usize,
};

pub const ViewLinesInsertedEvent = struct {
    /// Before what line did the insertion begin.
    fromLineNumber: usize,
    /// `toLineNumber - fromLineNumber + 1` denotes the number of lines that were inserted.
    toLineNumber: usize,
};

pub const VerticalRevealType = enum(u8) {
    Simple = 0,
    Center = 1,
    CenterIfOutsideViewport = 2,
    Top = 3,
    Bottom = 4,
    NearTop = 5,
    NearTopIfOutsideViewport = 6,
};

pub const ViewRevealRangeRequestEvent = struct {
    /// Source of the call that caused the event.
    source: ?[]const u8,
    /// Reduce the revealing to a minimum.
    minimalReveal: bool,
    /// Range to be revealed.
    range: ?Range,
    /// Selections to be revealed.
    selections: ?[]const Selection,
    /// The vertical reveal strategy.
    verticalType: VerticalRevealType,
    /// If true: there should be a horizontal & vertical revealing.
    revealHorizontal: bool,
    /// The scroll type.
    scrollType: ScrollType,
};

pub const ViewScrollChangedEvent = struct {
    scrollWidth: f64,
    scrollLeft: f64,
    scrollHeight: f64,
    scrollTop: f64,

    scrollWidthChanged: bool,
    scrollLeftChanged: bool,
    scrollHeightChanged: bool,
    scrollTopChanged: bool,

    pub fn init(source: ScrollEvent) ViewScrollChangedEvent {
        return .{
            .scrollWidth = source.scrollWidth,
            .scrollLeft = source.scrollLeft,
            .scrollHeight = source.scrollHeight,
            .scrollTop = source.scrollTop,
            .scrollWidthChanged = source.scrollWidthChanged,
            .scrollLeftChanged = source.scrollLeftChanged,
            .scrollHeightChanged = source.scrollHeightChanged,
            .scrollTopChanged = source.scrollTopChanged,
        };
    }
};

pub const ViewThemeChangedEvent = struct {
    theme: *const IColorTheme,
};

pub const ViewTokensChangedRange = struct {
    /// Start line number of range.
    fromLineNumber: usize,
    /// End line number of range.
    toLineNumber: usize,
};

pub const ViewTokensChangedEvent = struct {
    ranges: []const ViewTokensChangedRange,
};

pub const ViewTokensColorsChangedEvent = struct {};

pub const ViewZonesChangedEvent = struct {};

pub const ViewEvent = union(ViewEventType) {
    ViewCompositionStart: ViewCompositionStartEvent,
    ViewCompositionEnd: ViewCompositionEndEvent,
    ViewConfigurationChanged: ViewConfigurationChangedEvent,
    ViewCursorStateChanged: ViewCursorStateChangedEvent,
    ViewDecorationsChanged: ViewDecorationsChangedEvent,
    ViewFlushed: ViewFlushedEvent,
    ViewFocusChanged: ViewFocusChangedEvent,
    ViewLanguageConfigurationChanged: ViewLanguageConfigurationEvent,
    ViewLineMappingChanged: ViewLineMappingChangedEvent,
    ViewLinesChanged: ViewLinesChangedEvent,
    ViewLinesDeleted: ViewLinesDeletedEvent,
    ViewLinesInserted: ViewLinesInsertedEvent,
    ViewRevealRangeRequest: ViewRevealRangeRequestEvent,
    ViewScrollChanged: ViewScrollChangedEvent,
    ViewThemeChanged: ViewThemeChangedEvent,
    ViewTokensChanged: ViewTokensChangedEvent,
    ViewTokensColorsChanged: ViewTokensColorsChangedEvent,
    ViewZonesChanged: ViewZonesChangedEvent,

    pub fn eventType(self: ViewEvent) ViewEventType {
        return std.meta.activeTag(self);
    }
};

test "viewEvents: decorations changed event defaults to all affected" {
    const all = ViewDecorationsChangedEvent.init(null);
    try std.testing.expect(all.affectsMinimap);
    try std.testing.expect(all.affectsOverviewRuler);
    try std.testing.expect(all.affectsGlyphMargin);
    try std.testing.expect(all.affectsLineNumber);

    const partial = ViewDecorationsChangedEvent.init(.{
        .affectsMinimap = true,
        .affectsOverviewRuler = false,
        .affectsGlyphMargin = false,
        .affectsLineNumber = true,
    });
    try std.testing.expect(partial.affectsMinimap);
    try std.testing.expect(!partial.affectsOverviewRuler);
    try std.testing.expect(!partial.affectsGlyphMargin);
    try std.testing.expect(partial.affectsLineNumber);
}

test "viewEvents: configuration changed event" {
    const option_count = @typeInfo(EditorOption).@"enum".field_names.len;
    var values: [option_count]bool = @splat(false);
    values[@backingInt(EditorOption.lineNumbers)] = true;

    const event = ViewConfigurationChangedEvent.init(.{ ._values = &values });
    try std.testing.expect(event.hasChanged(.lineNumbers));
    try std.testing.expect(!event.hasChanged(.wordWrap));
}

test "viewEvents: scroll event from scrollable" {
    var scroll_event = ScrollEvent{
        .inSmoothScrolling = true,
        .oldWidth = 10,
        .oldScrollWidth = 100,
        .oldScrollLeft = 0,
        .width = 10,
        .scrollWidth = 120,
        .scrollLeft = 5,
        .oldHeight = 20,
        .oldScrollHeight = 200,
        .oldScrollTop = 0,
        .height = 20,
        .scrollHeight = 220,
        .scrollTop = 15,
        .widthChanged = false,
        .scrollWidthChanged = true,
        .scrollLeftChanged = true,
        .heightChanged = false,
        .scrollHeightChanged = true,
        .scrollTopChanged = true,
    };

    const view_event = ViewScrollChangedEvent.init(scroll_event);
    try std.testing.expectEqual(@as(f64, 120), view_event.scrollWidth);
    try std.testing.expectEqual(@as(f64, 5), view_event.scrollLeft);
    try std.testing.expectEqual(@as(f64, 220), view_event.scrollHeight);
    try std.testing.expectEqual(@as(f64, 15), view_event.scrollTop);
    try std.testing.expect(view_event.scrollWidthChanged);
    try std.testing.expect(!view_event.scrollTopChanged == false);

    scroll_event.scrollTop = 99;
    try std.testing.expectEqual(@as(f64, 15), view_event.scrollTop);
}

test "viewEvents: event union tags" {
    const composition = ViewEvent{ .ViewCompositionStart = .{} };
    try std.testing.expectEqual(ViewEventType.ViewCompositionStart, composition.eventType());

    const lines = ViewEvent{ .ViewLinesChanged = .{ .fromLineNumber = 3, .count = 4 } };
    try std.testing.expectEqual(ViewEventType.ViewLinesChanged, lines.eventType());
    try std.testing.expectEqual(@as(usize, 3), lines.ViewLinesChanged.fromLineNumber);
    try std.testing.expectEqual(@as(usize, 4), lines.ViewLinesChanged.count);

    const tokens = ViewEvent{ .ViewTokensChanged = .{ .ranges = &.{
        .{ .fromLineNumber = 1, .toLineNumber = 2 },
        .{ .fromLineNumber = 5, .toLineNumber = 5 },
    } } };
    try std.testing.expectEqual(@as(usize, 2), tokens.ViewTokensChanged.ranges.len);
    try std.testing.expectEqual(@as(usize, 5), tokens.ViewTokensChanged.ranges[1].fromLineNumber);
}

test "viewEvents: reveal range request" {
    const range = rangeFromPositions(.{ .lineNumber = 1, .column = 1 }, .{ .lineNumber = 2, .column = 3 });
    const selection = @import("./core/selection.zig").fromPositions(.{ .lineNumber = 1, .column = 1 }, .{ .lineNumber = 2, .column = 3 });
    const selections = [_]Selection{selection};
    const event = ViewRevealRangeRequestEvent{
        .source = "test",
        .minimalReveal = true,
        .range = range,
        .selections = &selections,
        .verticalType = .CenterIfOutsideViewport,
        .revealHorizontal = true,
        .scrollType = .Smooth,
    };
    try std.testing.expectEqualStrings("test", event.source.?);
    try std.testing.expect(event.minimalReveal);
    try std.testing.expectEqual(VerticalRevealType.CenterIfOutsideViewport, event.verticalType);
    try std.testing.expectEqual(ScrollType.Smooth, event.scrollType);
    try std.testing.expectEqual(@as(usize, 1), event.selections.?.len);
}
