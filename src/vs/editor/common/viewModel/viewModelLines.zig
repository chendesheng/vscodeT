// Reduced port of `src/vs/editor/common/viewModel/viewModelLines.ts` for a
// terminal editor.
//
// The browser class also manages folding (hidden areas), view zones, line
// heights, decorations, guides and view events. The TUI has none of those, so
// this port keeps the wrapping/mapping core:
//   * one projection per model line
//   * a constant-time prefix sum of view line counts
//   * view <-> model position/range conversion
//   * incremental model line changed/inserted/deleted updates
//   * an `ICursorSimpleModel` view over wrapped view lines

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const strings = @import("../../../base/common/strings.zig");
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const PositionAffinity = @import("../model.zig").PositionAffinity;
const TextModel = @import("../model/textModel.zig").TextModel;
const ConstantTimePrefixSumComputer = @import("../model/prefixSumComputer.zig").ConstantTimePrefixSumComputer;
const ViewLineData = @import("../viewModel.zig").ViewLineData;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const ICursorSimpleModel = @import("../cursorCommon.zig").ICursorSimpleModel;
const ICoordinatesConverter = @import("../coordinatesConverter.zig").ICoordinatesConverter;
const ModelLineProjection = @import("./modelLineProjection.zig").ModelLineProjection;
const ModelLineProjectionData = @import("../modelLineProjectionData.zig").ModelLineProjectionData;
const WordBreak = @import("../modelLineProjectionData.zig").WordBreak;
const ModelRawContentChangedEvent = @import("../textModelEvents.zig").ModelRawContentChangedEvent;
const WrappingIndent = @import("../config/editorOptions.zig").WrappingIndent;
const monospace = @import("./monospaceLineBreaksComputer.zig");

const WrappingCharacterClassifier = monospace.WrappingCharacterClassifier;

pub const ViewLineInfo = struct {
    model_line: usize,
    output_index: usize,
};

pub const ProjectedViewModelLines = struct {
    allocator: Allocator,
    model: *TextModel,
    classifier: WrappingCharacterClassifier,
    projections: ArrayList(ModelLineProjection),
    prefix: ConstantTimePrefixSumComputer,
    wrapping_column: usize,
    tab_size: usize,
    wrapping_indent: WrappingIndent,
    word_break: WordBreak,

    // Scratch storage used by the cursor interface and the renderer. Data
    // returned by `getLineContent`/`getViewLineData` is borrowed until the next
    // call of the same method.
    cursor_line_content: ArrayList(u8),
    view_line_content: ArrayList(u8),
    view_line_tokens: ?LineTokens,

    pub fn init(
        allocator: Allocator,
        model: *TextModel,
        wrapping_column: usize,
        tab_size: usize,
        wrapping_indent: WrappingIndent,
        word_break: WordBreak,
    ) !ProjectedViewModelLines {
        var classifier = try WrappingCharacterClassifier.init(
            allocator,
            monospace.default_break_before_characters,
            monospace.default_break_after_characters,
        );
        var classifier_owned = true;
        defer if (classifier_owned) classifier.deinit();

        var projections = ArrayList(ModelLineProjection).init(allocator);
        var projections_owned = true;
        defer if (projections_owned) projections.deinit();

        var prefix = try ConstantTimePrefixSumComputer.init(allocator, &.{});
        var prefix_owned = true;
        defer if (prefix_owned) prefix.deinit();

        var result = ProjectedViewModelLines{
            .allocator = allocator,
            .model = model,
            .classifier = classifier,
            .projections = projections,
            .prefix = prefix,
            .wrapping_column = @max(wrapping_column, 1),
            .tab_size = @max(tab_size, 1),
            .wrapping_indent = wrapping_indent,
            .word_break = word_break,
            .cursor_line_content = ArrayList(u8).init(allocator),
            .view_line_content = ArrayList(u8).init(allocator),
            .view_line_tokens = null,
        };
        classifier_owned = false;
        projections_owned = false;
        prefix_owned = false;
        errdefer result.deinit();
        try result.rebuildAll();
        return result;
    }

    pub fn deinit(self: *ProjectedViewModelLines) void {
        for (self.projections.items) |*projection| projection.deinit();
        self.projections.deinit();
        self.prefix.deinit();
        self.classifier.deinit();
        self.cursor_line_content.deinit();
        self.view_line_content.deinit();
        if (self.view_line_tokens) |*tokens| tokens.deinit();
        self.view_line_tokens = null;
    }

    fn computeProjection(self: *ProjectedViewModelLines, line_number: usize) !ModelLineProjection {
        const line = try self.model.getLineContent(line_number);
        defer line.deinit();
        const data = try monospace.computeLineBreaks(
            self.allocator,
            &self.classifier,
            line.items,
            self.tab_size,
            self.wrapping_column,
            self.wrapping_indent,
            self.word_break,
        );
        return ModelLineProjection.init(self.allocator, data);
    }

    pub fn rebuildAll(self: *ProjectedViewModelLines) !void {
        var new_projections = ArrayList(ModelLineProjection).init(self.allocator);
        var projections_owned = true;
        defer if (projections_owned) {
            for (new_projections.items) |*projection| projection.deinit();
            new_projections.deinit();
        };

        var counts = ArrayList(usize).init(self.allocator);
        defer counts.deinit();

        const line_count = self.model.getLineCount();
        var line_number: usize = 1;
        while (line_number <= line_count) : (line_number += 1) {
            var projection = try self.computeProjection(line_number);
            const view_line_count = projection.getViewLineCount();
            new_projections.append(projection) catch |err| {
                projection.deinit();
                return err;
            };
            try counts.append(view_line_count);
        }

        const new_prefix = try ConstantTimePrefixSumComputer.init(self.allocator, counts.items);

        for (self.projections.items) |*projection| projection.deinit();
        self.projections.deinit();
        self.projections = new_projections;
        projections_owned = false;
        self.prefix.deinit();
        self.prefix = new_prefix;
    }

    pub fn setWrappingColumn(self: *ProjectedViewModelLines, column: usize) !bool {
        const new_column = @max(column, 1);
        if (self.wrapping_column == new_column) return false;
        self.wrapping_column = new_column;
        try self.rebuildAll();
        return true;
    }

    pub fn setTabSize(self: *ProjectedViewModelLines, tab_size: usize) !bool {
        const new_tab_size = @max(tab_size, 1);
        if (self.tab_size == new_tab_size) return false;
        self.tab_size = new_tab_size;
        try self.rebuildAll();
        return true;
    }

    pub fn applyRawChanges(self: *ProjectedViewModelLines, event: *const ModelRawContentChangedEvent) !void {
        for (event.changes.items) |change| {
            switch (change) {
                .flush => {
                    try self.rebuildAll();
                    return;
                },
                .linesDeleted => |deleted| self.removeLines(deleted.fromLineNumber, deleted.toLineNumber),
                .linesInserted => |inserted| try self.insertLines(inserted.fromLineNumber, inserted.toLineNumber),
                .lineChanged => |changed| try self.replaceLine(changed.lineNumber),
                .eolChanged => {},
            }
        }
    }

    fn removeLines(self: *ProjectedViewModelLines, from_line: usize, to_line: usize) void {
        const start_index = from_line - 1;
        const count = to_line - from_line + 1;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            var projection = self.projections.orderedRemove(start_index);
            projection.deinit();
        }
        self.prefix.removeValues(start_index, count);
    }

    fn insertLines(self: *ProjectedViewModelLines, from_line: usize, to_line: usize) !void {
        const start_index = from_line - 1;
        var new_projections = ArrayList(ModelLineProjection).init(self.allocator);
        var projections_owned = true;
        defer if (projections_owned) {
            for (new_projections.items) |*projection| projection.deinit();
            new_projections.deinit();
        };

        var counts = ArrayList(usize).init(self.allocator);
        defer counts.deinit();

        var line_number = from_line;
        while (line_number <= to_line) : (line_number += 1) {
            var projection = try self.computeProjection(line_number);
            const view_line_count = projection.getViewLineCount();
            new_projections.append(projection) catch |err| {
                projection.deinit();
                return err;
            };
            try counts.append(view_line_count);
        }

        try self.projections.insertSlice(start_index, new_projections.items);
        projections_owned = false;
        new_projections.deinit();
        try self.prefix.insertValues(start_index, counts.items);
    }

    pub fn replaceLine(self: *ProjectedViewModelLines, line_number: usize) !void {
        var projection = try self.computeProjection(line_number);
        errdefer projection.deinit();
        const index = line_number - 1;
        self.projections.items[index].deinit();
        self.projections.items[index] = projection;
        self.prefix.setValue(index, projection.getViewLineCount());
    }

    pub fn getViewLineCount(self: *ProjectedViewModelLines) usize {
        return self.prefix.getTotalSum();
    }

    fn toValidViewLineNumber(self: *ProjectedViewModelLines, view_line_number: usize) usize {
        if (view_line_number < 1) return 1;
        const count = self.getViewLineCount();
        if (view_line_number > count) return count;
        return view_line_number;
    }

    pub fn getViewLineInfo(self: *ProjectedViewModelLines, view_line_number: usize) ViewLineInfo {
        const view_line = self.toValidViewLineNumber(view_line_number);
        const result = self.prefix.getIndexOf(view_line - 1);
        return .{ .model_line = result.index + 1, .output_index = result.remainder };
    }

    pub fn getModelLineNumber(self: *ProjectedViewModelLines, view_line_number: usize) usize {
        return self.getViewLineInfo(view_line_number).model_line;
    }

    pub fn getOutputLineIndex(self: *ProjectedViewModelLines, view_line_number: usize) usize {
        return self.getViewLineInfo(view_line_number).output_index;
    }

    pub fn getModelLineViewLineCount(self: *ProjectedViewModelLines, model_line_number: usize) usize {
        if (model_line_number < 1 or model_line_number > self.projections.items.len) return 1;
        return self.projections.items[model_line_number - 1].getViewLineCount();
    }

    pub fn getViewLineNumber(self: *ProjectedViewModelLines, model_line_number: usize, output_index: usize) usize {
        return self.prefix.getPrefixSum(model_line_number - 1) + output_index + 1;
    }

    pub fn getViewLineNumberOfModelPosition(self: *ProjectedViewModelLines, model_line_number: usize, model_column: usize) usize {
        if (model_line_number < 1 or model_line_number > self.projections.items.len) return 1;
        const delta = 1 + self.prefix.getPrefixSum(model_line_number - 1);
        return self.projections.items[model_line_number - 1].getViewLineNumberOfModelPosition(delta, model_column);
    }

    pub fn getViewLineData(self: *ProjectedViewModelLines, view_line_number: usize) !ViewLineData {
        const info = self.getViewLineInfo(view_line_number);
        return self.projections.items[info.model_line - 1].getViewLineData(
            self.model,
            info.model_line,
            info.output_index,
            &self.view_line_tokens,
            &self.view_line_content,
        );
    }

    pub fn getLineContent(self: *ProjectedViewModelLines, view_line_number: usize) []const u8 {
        const info = self.getViewLineInfo(view_line_number);
        self.projections.items[info.model_line - 1].fillViewLineContent(
            self.model,
            info.model_line,
            info.output_index,
            &self.cursor_line_content,
        ) catch return "";
        return self.cursor_line_content.items;
    }

    pub fn getLineCount(self: *ProjectedViewModelLines) usize {
        return self.getViewLineCount();
    }

    pub fn getLineMinColumn(self: *ProjectedViewModelLines, view_line_number: usize) usize {
        const info = self.getViewLineInfo(view_line_number);
        return self.projections.items[info.model_line - 1].getViewLineMinColumn(self.model, info.model_line, info.output_index);
    }

    pub fn getLineMaxColumn(self: *ProjectedViewModelLines, view_line_number: usize) usize {
        const info = self.getViewLineInfo(view_line_number);
        return self.projections.items[info.model_line - 1].getViewLineMaxColumn(self.model, info.model_line, info.output_index);
    }

    pub fn getLineFirstNonWhitespaceColumn(self: *ProjectedViewModelLines, view_line_number: usize) usize {
        const content = self.getLineContent(view_line_number);
        const index = strings.firstNonWhitespaceIndex(content) orelse return 0;
        return index + 1;
    }

    pub fn getLineLastNonWhitespaceColumn(self: *ProjectedViewModelLines, view_line_number: usize) usize {
        const content = self.getLineContent(view_line_number);
        const index = strings.lastNonWhitespaceIndex(content) orelse return 0;
        return index + 2;
    }

    pub fn getLineIndentColumn(self: *ProjectedViewModelLines, view_line_number: usize) usize {
        return self.getLineFirstNonWhitespaceColumn(view_line_number);
    }

    pub fn normalizePosition(self: *ProjectedViewModelLines, position: Position, affinity: PositionAffinity) Position {
        const info = self.getViewLineInfo(position.lineNumber);
        return self.projections.items[info.model_line - 1].normalizePosition(info.output_index, position, affinity);
    }

    pub fn interface(self: *ProjectedViewModelLines) ICursorSimpleModel {
        return .{
            .context = self,
            .getLineCount = struct {
                fn call(context: *anyopaque) usize {
                    return @as(*ProjectedViewModelLines, @ptrCast(@alignCast(context))).getLineCount();
                }
            }.call,
            .getLineContent = struct {
                fn call(context: *anyopaque, line_number: usize) []const u8 {
                    return @as(*ProjectedViewModelLines, @ptrCast(@alignCast(context))).getLineContent(line_number);
                }
            }.call,
            .getLineMinColumn = struct {
                fn call(context: *anyopaque, line_number: usize) usize {
                    return @as(*ProjectedViewModelLines, @ptrCast(@alignCast(context))).getLineMinColumn(line_number);
                }
            }.call,
            .getLineMaxColumn = struct {
                fn call(context: *anyopaque, line_number: usize) usize {
                    return @as(*ProjectedViewModelLines, @ptrCast(@alignCast(context))).getLineMaxColumn(line_number);
                }
            }.call,
            .getLineFirstNonWhitespaceColumn = struct {
                fn call(context: *anyopaque, line_number: usize) usize {
                    return @as(*ProjectedViewModelLines, @ptrCast(@alignCast(context))).getLineFirstNonWhitespaceColumn(line_number);
                }
            }.call,
            .getLineLastNonWhitespaceColumn = struct {
                fn call(context: *anyopaque, line_number: usize) usize {
                    return @as(*ProjectedViewModelLines, @ptrCast(@alignCast(context))).getLineLastNonWhitespaceColumn(line_number);
                }
            }.call,
            .normalizePosition = struct {
                fn call(context: *anyopaque, position: Position, affinity: PositionAffinity) Position {
                    return @as(*ProjectedViewModelLines, @ptrCast(@alignCast(context))).normalizePosition(position, affinity);
                }
            }.call,
            .getLineIndentColumn = struct {
                fn call(context: *anyopaque, line_number: usize) usize {
                    return @as(*ProjectedViewModelLines, @ptrCast(@alignCast(context))).getLineIndentColumn(line_number);
                }
            }.call,
        };
    }
};

pub const CoordinatesConverter = struct {
    lines: *ProjectedViewModelLines,

    pub fn init(lines: *ProjectedViewModelLines) CoordinatesConverter {
        return .{ .lines = lines };
    }

    fn fromContext(context: *anyopaque) *CoordinatesConverter {
        return @ptrCast(@alignCast(context));
    }

    fn convertViewPositionToModelPosition(context: *anyopaque, view_position: Position) Position {
        const self = fromContext(context);
        const info = self.lines.getViewLineInfo(view_position.lineNumber);
        const projection = &self.lines.projections.items[info.model_line - 1];
        const model_column = projection.getModelColumnOfViewPosition(info.output_index, view_position.column);
        return self.lines.model.validatePosition(Position.init(info.model_line, model_column));
    }

    fn convertViewRangeToModelRange(context: *anyopaque, view_range: Range) Range {
        const start = convertViewPositionToModelPosition(context, view_range.getStartPosition());
        const end = convertViewPositionToModelPosition(context, view_range.getEndPosition());
        return Range.init(start.lineNumber, start.column, end.lineNumber, end.column);
    }

    fn validateViewPosition(context: *anyopaque, view_position: Position, expected_model_position: Position) Position {
        const self = fromContext(context);
        const info = self.lines.getViewLineInfo(view_position.lineNumber);
        const projection = &self.lines.projections.items[info.model_line - 1];
        var view_column = view_position.column;
        const min_column = projection.getViewLineMinColumn(self.lines.model, info.model_line, info.output_index);
        const max_column = projection.getViewLineMaxColumn(self.lines.model, info.model_line, info.output_index);
        if (view_column < min_column) view_column = min_column;
        if (view_column > max_column) view_column = max_column;

        const computed_model_column = projection.getModelColumnOfViewPosition(info.output_index, view_column);
        const computed_model_position = self.lines.model.validatePosition(Position.init(info.model_line, computed_model_column));
        if (computed_model_position.equals(expected_model_position)) {
            return Position.init(view_position.lineNumber, view_column);
        }
        return convertModelPositionToViewPosition(context, expected_model_position, .None, false, false);
    }

    fn validateViewRange(context: *anyopaque, view_range: Range, expected_model_range: Range) Range {
        const start = validateViewPosition(context, view_range.getStartPosition(), expected_model_range.getStartPosition());
        const end = validateViewPosition(context, view_range.getEndPosition(), expected_model_range.getEndPosition());
        return Range.init(start.lineNumber, start.column, end.lineNumber, end.column);
    }

    fn convertModelPositionToViewPosition(context: *anyopaque, model_position: Position, affinity: PositionAffinity, _: bool, _: bool) Position {
        const self = fromContext(context);
        const valid = self.lines.model.validatePosition(model_position);
        const line_index = valid.lineNumber - 1;
        const delta = 1 + self.lines.prefix.getPrefixSum(line_index);
        return self.lines.projections.items[line_index].getViewPositionOfModelPosition(delta, valid.column, affinity);
    }

    fn convertModelRangeToViewRange(context: *anyopaque, model_range: Range, affinity: PositionAffinity) Range {
        if (model_range.isEmpty()) {
            const start = convertModelPositionToViewPosition(context, model_range.getStartPosition(), affinity, false, false);
            return Range.init(start.lineNumber, start.column, start.lineNumber, start.column);
        }
        const start = convertModelPositionToViewPosition(context, model_range.getStartPosition(), .Right, false, false);
        const end = convertModelPositionToViewPosition(context, model_range.getEndPosition(), .Left, false, false);
        return Range.init(start.lineNumber, start.column, end.lineNumber, end.column);
    }

    fn modelPositionIsVisible(context: *anyopaque, model_position: Position) bool {
        const self = fromContext(context);
        return model_position.lineNumber >= 1 and model_position.lineNumber <= self.lines.projections.items.len;
    }

    fn getModelLineViewLineCount(context: *anyopaque, model_line_number: usize) usize {
        return fromContext(context).lines.getModelLineViewLineCount(model_line_number);
    }

    fn getViewLineNumberOfModelPosition(context: *anyopaque, model_line_number: usize, model_column: usize) usize {
        return fromContext(context).lines.getViewLineNumberOfModelPosition(model_line_number, model_column);
    }

    pub fn interface(self: *CoordinatesConverter) ICoordinatesConverter {
        return .{
            .context = self,
            .convertViewPositionToModelPosition = convertViewPositionToModelPosition,
            .convertViewRangeToModelRange = convertViewRangeToModelRange,
            .validateViewPosition = validateViewPosition,
            .validateViewRange = validateViewRange,
            .convertModelPositionToViewPosition = convertModelPositionToViewPosition,
            .convertModelRangeToViewRange = convertModelRangeToViewRange,
            .modelPositionIsVisible = modelPositionIsVisible,
            .getModelLineViewLineCount = getModelLineViewLineCount,
            .getViewLineNumberOfModelPosition = getViewLineNumberOfModelPosition,
        };
    }
};

test "ProjectedViewModelLines: maps wrapped view lines" {
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;

    var ctx = try TestModel.init(std.testing.allocator, "abcdefghij\nkl", "nullLanguage");
    defer ctx.deinit();

    var lines = try ProjectedViewModelLines.init(std.testing.allocator, ctx.model, 4, 4, .None, .normal);
    defer lines.deinit();

    try std.testing.expectEqual(@as(usize, 4), lines.getViewLineCount());
    try std.testing.expectEqual(@as(usize, 1), lines.getModelLineNumber(1));
    try std.testing.expectEqual(@as(usize, 0), lines.getOutputLineIndex(1));
    try std.testing.expectEqual(@as(usize, 1), lines.getModelLineNumber(3));
    try std.testing.expectEqual(@as(usize, 2), lines.getOutputLineIndex(3));
    try std.testing.expectEqual(@as(usize, 2), lines.getModelLineNumber(4));

    const first = try lines.getViewLineData(1);
    try std.testing.expectEqualStrings("abcd", first.content);
    const third = try lines.getViewLineData(3);
    try std.testing.expectEqualStrings("ij", third.content);
    try std.testing.expect(!third.continuesWithWrappedLine);

    try std.testing.expectEqualStrings("abcd", lines.getLineContent(1));
    try std.testing.expectEqual(@as(usize, 1), lines.getLineMinColumn(2));
    try std.testing.expectEqual(@as(usize, 3), lines.getLineMaxColumn(3));

    var converter = CoordinatesConverter.init(&lines);
    const iface = converter.interface();
    const view_position = iface.convertModelPositionToViewPosition(iface.context, Position.init(1, 5), .Right, false, false);
    try std.testing.expectEqual(@as(usize, 2), view_position.lineNumber);
    try std.testing.expectEqual(@as(usize, 1), view_position.column);
    const model_position = iface.convertViewPositionToModelPosition(iface.context, Position.init(2, 1));
    try std.testing.expectEqual(Position.init(1, 5), model_position);
}

test "ProjectedViewModelLines: incremental changes" {
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;

    var ctx = try TestModel.init(std.testing.allocator, "abcdefghij\nkl", "nullLanguage");
    defer ctx.deinit();

    var lines = try ProjectedViewModelLines.init(std.testing.allocator, ctx.model, 4, 4, .None, .normal);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 4), lines.getViewLineCount());

    try ctx.applyEdit(Range.init(1, 5, 1, 5), "X");
    try lines.replaceLine(1);
    const data = try lines.getViewLineData(1);
    try std.testing.expectEqualStrings("abcd", data.content);
    try std.testing.expectEqual(@as(usize, 4), lines.getViewLineCount());

    try ctx.applyEdit(Range.init(2, 1, 2, 1), "Y\nZ");
    try lines.rebuildAll();
    try std.testing.expectEqual(@as(usize, 5), lines.getViewLineCount());
}

test "ProjectedViewModelLines: applies raw change events" {
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    const InternalModelContentChangeEvent = @import("../textModelEvents.zig").InternalModelContentChangeEvent;

    var ctx = try TestModel.init(std.testing.allocator, "abcdefghij\nkl", "nullLanguage");
    defer ctx.deinit();

    var lines = try ProjectedViewModelLines.init(std.testing.allocator, ctx.model, 4, 4, .None, .normal);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 4), lines.getViewLineCount());

    try ctx.model.onDidChangeContentWithContext(&lines, struct {
        fn cb(event: InternalModelContentChangeEvent, view_lines: *ProjectedViewModelLines) anyerror!void {
            try view_lines.applyRawChanges(&event.rawContentChangedEvent);
        }
    }.cb);

    try ctx.applyEdit(Range.init(1, 5, 1, 5), "X");
    try std.testing.expectEqual(@as(usize, 4), lines.getViewLineCount());

    try ctx.applyEdit(Range.init(2, 1, 2, 1), "Y\nZ");
    try std.testing.expectEqual(@as(usize, 5), lines.getViewLineCount());
}
