const std = @import("std");
const Position = @import("./core/position.zig").Position;

pub const IGuidesTextModelPart = struct {
    context: *anyopaque,
    getActiveIndentGuide: *const fn (context: *anyopaque, lineNumber: usize, minLineNumber: usize, maxLineNumber: usize) IActiveIndentGuideInfo,
    getLinesIndentGuides: *const fn (context: *anyopaque, startLineNumber: usize, endLineNumber: usize) []const usize,
    getLinesBracketGuides: *const fn (
        context: *anyopaque,
        startLineNumber: usize,
        endLineNumber: usize,
        activePosition: ?Position,
        options: BracketGuideOptions,
    ) []const []const IndentGuide,
};

pub const IActiveIndentGuideInfo = struct {
    startLineNumber: usize,
    endLineNumber: usize,
    indent: usize,
};

pub const HorizontalGuidesState = enum {
    Disabled,
    EnabledForActive,
    Enabled,
};

pub const BracketGuideOptions = struct {
    includeInactive: bool,
    horizontalGuides: HorizontalGuidesState,
    highlightActive: bool,
};

pub const IndentGuide = struct {
    /// `-1` if this is a horizontal guide.
    visibleColumn: isize,
    /// `-1` if this is a vertical guide.
    column: isize,
    className: []const u8,
    /// If set, this indent guide is a horizontal guide (no vertical part).
    /// It starts at visibleColumn and continues until endColumn.
    horizontalLine: ?IndentGuideHorizontalLine,
    /// If set (!= -1), only show this guide for wrapped lines that don't contain this model column, but are after it.
    forWrappedLinesAfterColumn: isize,
    /// If set (!= -1), only show this guide for wrapped lines that end before or at this model column.
    forWrappedLinesBeforeOrAtColumn: isize,

    pub fn init(
        visibleColumn: isize,
        column: isize,
        className: []const u8,
        horizontalLine: ?IndentGuideHorizontalLine,
        forWrappedLinesAfterColumn: isize,
        forWrappedLinesBeforeOrAtColumn: isize,
    ) !IndentGuide {
        if ((visibleColumn != -1) == (column != -1)) {
            return error.InvalidIndentGuide;
        }
        return .{
            .visibleColumn = visibleColumn,
            .column = column,
            .className = className,
            .horizontalLine = horizontalLine,
            .forWrappedLinesAfterColumn = forWrappedLinesAfterColumn,
            .forWrappedLinesBeforeOrAtColumn = forWrappedLinesBeforeOrAtColumn,
        };
    }
};

pub const IndentGuideHorizontalLine = struct {
    top: bool,
    endColumn: usize,
};

test "textModelGuides: indent guide requires exactly one column kind" {
    const vertical = try IndentGuide.init(4, -1, "indent-guide", null, -1, -1);
    try std.testing.expectEqual(@as(isize, 4), vertical.visibleColumn);
    try std.testing.expectEqual(@as(isize, -1), vertical.column);

    const horizontal = try IndentGuide.init(-1, 6, "indent-guide", .{ .top = true, .endColumn = 10 }, -1, -1);
    try std.testing.expectEqual(@as(isize, 6), horizontal.column);
    try std.testing.expect(horizontal.horizontalLine.?.top);

    try std.testing.expectError(error.InvalidIndentGuide, IndentGuide.init(4, 6, "indent-guide", null, -1, -1));
    try std.testing.expectError(error.InvalidIndentGuide, IndentGuide.init(-1, -1, "indent-guide", null, -1, -1));
}

test "textModelGuides: bracket guide options" {
    const options = BracketGuideOptions{
        .includeInactive = true,
        .horizontalGuides = .EnabledForActive,
        .highlightActive = false,
    };
    try std.testing.expect(options.includeInactive);
    try std.testing.expectEqual(HorizontalGuidesState.EnabledForActive, options.horizontalGuides);
    try std.testing.expectEqual(@as(usize, 10), (IndentGuideHorizontalLine{ .top = false, .endColumn = 10 }).endColumn);
}
