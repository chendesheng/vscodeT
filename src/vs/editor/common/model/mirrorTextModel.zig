// Port of `src/vs/editor/common/model/mirrorTextModel.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const strings = @import("../../../base/common/strings.zig");
const String = strings.String;
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const EOL = @import("../core/misc/eolCounter.zig").EOL;
const eolToString = @import("../core/misc/eolCounter.zig").eolToString;
const textModelEvents = @import("../textModelEvents.zig");
const ModelContentChangedEvent = textModelEvents.ModelContentChangedEvent;
const ModelContentChange = textModelEvents.ModelContentChange;
const PrefixSumComputer = @import("./prefixSumComputer.zig").PrefixSumComputer;

/// A simpler text model implementation that mirrors the content of another
/// text model. It is used where a full `TextModel` is unnecessary.
pub const MirrorTextModel = struct {
    allocator: Allocator,
    _uri: []const u8,
    _lines: ArrayList([]u8),
    _eol: EOL,
    _versionId: i64,
    _lineStarts: ?PrefixSumComputer,
    _cachedTextValue: ?[]u8,

    pub fn init(allocator: Allocator, uri: []const u8, lines: []const []const u8, eol: EOL, versionId: i64) !MirrorTextModel {
        var owned_lines = ArrayList([]u8).init(allocator);
        errdefer {
            for (owned_lines.items) |line| allocator.free(line);
            owned_lines.deinit();
        }

        for (lines) |line| {
            try owned_lines.append(try allocator.dupe(u8, line));
        }

        return .{
            .allocator = allocator,
            ._uri = uri,
            ._lines = owned_lines,
            ._eol = eol,
            ._versionId = versionId,
            ._lineStarts = null,
            ._cachedTextValue = null,
        };
    }

    pub fn deinit(self: *MirrorTextModel) void {
        for (self._lines.items) |line| {
            self.allocator.free(line);
        }
        self._lines.deinit();
        if (self._lineStarts) |*line_starts| {
            line_starts.deinit();
        }
        if (self._cachedTextValue) |value| {
            self.allocator.free(value);
        }
    }

    pub fn version(self: *const MirrorTextModel) i64 {
        return self._versionId;
    }

    pub fn getLineCount(self: *const MirrorTextModel) usize {
        return self._lines.items.len;
    }

    pub fn getLineContent(self: *const MirrorTextModel, lineNumber: usize) []const u8 {
        return self._lines.items[lineNumber - 1];
    }

    pub fn getText(self: *MirrorTextModel) ![]const u8 {
        if (self._cachedTextValue == null) {
            var result = ArrayList(u8).init(self.allocator);
            errdefer result.deinit();

            const eol = eolToString(self._eol);
            for (self._lines.items, 0..) |line, i| {
                if (i > 0) {
                    try result.appendSlice(eol);
                }
                try result.appendSlice(line);
            }

            self._cachedTextValue = try result.toOwnedSlice();
        }
        return self._cachedTextValue.?;
    }

    pub fn onEvents(self: *MirrorTextModel, e: *const ModelContentChangedEvent) !void {
        if (e.eol != self._eol) {
            self._eol = e.eol;
            if (self._lineStarts) |*line_starts| {
                line_starts.deinit();
                self._lineStarts = null;
            }
        }

        for (e.changes.items) |*change| {
            try self._acceptDeleteRange(change.range);
            try self._acceptInsertText(Position.init(change.range.startLineNumber, change.range.startColumn), change.text.items());
        }

        self._versionId = e.versionId;
        if (self._cachedTextValue) |value| {
            self.allocator.free(value);
            self._cachedTextValue = null;
        }
    }

    fn _ensureLineStarts(self: *MirrorTextModel) !void {
        if (self._lineStarts == null) {
            const eol_length = eolToString(self._eol).len;
            const line_start_values = try self.allocator.alloc(usize, self._lines.items.len);
            defer self.allocator.free(line_start_values);
            for (self._lines.items, 0..) |line, i| {
                line_start_values[i] = line.len + eol_length;
            }
            self._lineStarts = try PrefixSumComputer.init(self.allocator, line_start_values);
        }
    }

    /// All changes to a line's text go through this method.
    fn _setLineText(self: *MirrorTextModel, lineIndex: usize, newValue: []const u8) !void {
        const oldLine = self._lines.items[lineIndex];
        const newLine = try self.allocator.dupe(u8, newValue);
        self.allocator.free(oldLine);
        self._lines.items[lineIndex] = newLine;

        if (self._lineStarts) |*line_starts| {
            _ = line_starts.setValue(lineIndex, newLine.len + eolToString(self._eol).len);
        }
    }

    fn _acceptDeleteRange(self: *MirrorTextModel, range: Range) !void {
        if (range.startLineNumber == range.endLineNumber) {
            if (range.startColumn == range.endColumn) {
                // Nothing to delete.
                return;
            }
            const line = self._lines.items[range.startLineNumber - 1];
            const newValue = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                substring(line, 0, range.startColumn - 1),
                substring(line, range.endColumn - 1, line.len),
            });
            defer self.allocator.free(newValue);
            try self._setLineText(range.startLineNumber - 1, newValue);
            return;
        }

        // Take remaining text on the last line and append it to remaining text on the first line.
        const firstLine = self._lines.items[range.startLineNumber - 1];
        const lastLine = self._lines.items[range.endLineNumber - 1];
        const newValue = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
            substring(firstLine, 0, range.startColumn - 1),
            substring(lastLine, range.endColumn - 1, lastLine.len),
        });
        defer self.allocator.free(newValue);
        try self._setLineText(range.startLineNumber - 1, newValue);

        // Delete middle lines.
        const delete_count = range.endLineNumber - range.startLineNumber;
        for (self._lines.items[range.startLineNumber .. range.startLineNumber + delete_count]) |line| {
            self.allocator.free(line);
        }
        self._lines.replaceRange(range.startLineNumber, delete_count, &.{}) catch unreachable;
        if (self._lineStarts) |*line_starts| {
            _ = line_starts.removeValues(range.startLineNumber, delete_count);
        }
    }

    fn _acceptInsertText(self: *MirrorTextModel, position: Position, insertText: []const u8) !void {
        if (insertText.len == 0) {
            // Nothing to insert.
            return;
        }

        var insertLines = try strings.splitLines(self.allocator, insertText);
        defer insertLines.deinit();

        if (insertLines.items.len == 1) {
            const line = self._lines.items[position.lineNumber - 1];
            const newValue = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
                substring(line, 0, position.column - 1),
                insertLines.items[0],
                substring(line, position.column - 1, line.len),
            });
            defer self.allocator.free(newValue);
            try self._setLineText(position.lineNumber - 1, newValue);
            return;
        }

        // Append overflowing text from first line to the end of text to insert.
        const firstLine = self._lines.items[position.lineNumber - 1];
        const remaining = substring(firstLine, position.column - 1, firstLine.len);
        const lastInserted = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ insertLines.items[insertLines.items.len - 1], remaining });
        defer self.allocator.free(lastInserted);

        // Delete overflowing text from first line and insert text on first line.
        const newFirstLine = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
            substring(firstLine, 0, position.column - 1),
            insertLines.items[0],
        });
        defer self.allocator.free(newFirstLine);
        try self._setLineText(position.lineNumber - 1, newFirstLine);

        // Insert new lines and store lengths.
        const newLengths = try self.allocator.alloc(usize, insertLines.items.len - 1);
        defer self.allocator.free(newLengths);

        for (insertLines.items[1..], 0..) |line, i| {
            const owned = try self.allocator.dupe(u8, if (i == insertLines.items.len - 2) lastInserted else line);
            try self._lines.insert(position.lineNumber + i, owned);
            newLengths[i] = owned.len + eolToString(self._eol).len;
        }

        if (self._lineStarts) |*line_starts| {
            _ = try line_starts.insertValues(position.lineNumber, newLengths);
        }
    }
};

fn substring(text: []const u8, start_: usize, end_: usize) []const u8 {
    var start = @min(start_, text.len);
    var end = @min(end_, text.len);
    if (start > end) {
        const tmp = start;
        start = end;
        end = tmp;
    }
    return text[start..end];
}

fn makeChange(allocator: Allocator, range: Range, text: []const u8) !ModelContentChange {
    const owned = try allocator.dupe(u8, text);
    return .{
        .range = range,
        .rangeOffset = 0,
        .rangeLength = 0,
        .text = String.initOwned(ArrayList(u8).fromOwnedSlice(allocator, owned)),
    };
}

test "mirrorTextModel: text and version" {
    const allocator = std.testing.allocator;
    var model = try MirrorTextModel.init(allocator, "inmemory://model/1", &[_][]const u8{ "hello", "world" }, .LF, 3);
    defer model.deinit();

    try std.testing.expectEqual(@as(i64, 3), model.version());
    try std.testing.expectEqualStrings("hello\nworld", try model.getText());
    // The cached value is returned on subsequent calls.
    try std.testing.expectEqualStrings("hello\nworld", try model.getText());
}

test "mirrorTextModel: insert text on one line" {
    const allocator = std.testing.allocator;
    var model = try MirrorTextModel.init(allocator, "inmemory://model/1", &[_][]const u8{"hello"}, .LF, 1);
    defer model.deinit();

    var changes = ArrayList(ModelContentChange).init(allocator);
    try changes.append(try makeChange(allocator, Range.init(1, 3, 1, 3), "XY"));

    var event = ModelContentChangedEvent{
        .changes = changes,
        .eol = .LF,
        .versionId = 2,
        .isUndoing = false,
        .isRedoing = false,
        .isFlush = false,
        .isEolChange = false,
    };
    defer event.deinit();

    try model.onEvents(&event);
    try std.testing.expectEqualStrings("heXYllo", try model.getText());
    try std.testing.expectEqual(@as(i64, 2), model.version());
}

test "mirrorTextModel: delete across lines" {
    const allocator = std.testing.allocator;
    var model = try MirrorTextModel.init(allocator, "inmemory://model/1", &[_][]const u8{ "hello", "beautiful", "world" }, .LF, 1);
    defer model.deinit();

    var changes = ArrayList(ModelContentChange).init(allocator);
    try changes.append(try makeChange(allocator, Range.init(1, 3, 2, 5), ""));

    var event = ModelContentChangedEvent{
        .changes = changes,
        .eol = .LF,
        .versionId = 2,
        .isUndoing = false,
        .isRedoing = false,
        .isFlush = false,
        .isEolChange = false,
    };
    defer event.deinit();

    try model.onEvents(&event);
    // "he" + "tiful" + "\n" + "world"
    try std.testing.expectEqualStrings("hetiful\nworld", try model.getText());
}

test "mirrorTextModel: insert multiple lines" {
    const allocator = std.testing.allocator;
    var model = try MirrorTextModel.init(allocator, "inmemory://model/1", &[_][]const u8{ "hello", "world" }, .LF, 1);
    defer model.deinit();

    var changes = ArrayList(ModelContentChange).init(allocator);
    try changes.append(try makeChange(allocator, Range.init(1, 6, 1, 6), "\nnew\nlines"));

    var event = ModelContentChangedEvent{
        .changes = changes,
        .eol = .LF,
        .versionId = 2,
        .isUndoing = false,
        .isRedoing = false,
        .isFlush = false,
        .isEolChange = false,
    };
    defer event.deinit();

    try model.onEvents(&event);
    try std.testing.expectEqualStrings("hello\nnew\nlines\nworld", try model.getText());
}
