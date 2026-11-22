// Port of `src/vs/editor/common/core/textChange.ts`.
//
// Serialization note: editor positions and offsets in this port are UTF-8 byte
// offsets, not JavaScript's UTF-16 code-unit offsets. The wire format below
// therefore stores UTF-8 byte lengths. It is self-consistent but intentionally
// not byte-compatible with upstream's UTF-16 serialization.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const strings = @import("../../../base/common/strings.zig");
const Pair = @import("../../../base/common/utils.zig").Pair;
const pair = @import("../../../base/common/utils.zig").pair;
const usizeSub = @import("../../../base/common/utils.zig").usizeSub;
const usizeAdd = @import("../../../base/common/utils.zig").usizeAdd;
const String = @import("../../../base/common/strings.zig").String;

pub const TextChange = struct {
    oldPosition: usize,
    oldText: String,
    newPosition: usize,
    newText: String,

    pub fn init(oldPosition: usize, oldText: String, newPosition: usize, newText: String) TextChange {
        return TextChange{
            .oldPosition = oldPosition,
            .oldText = oldText,
            .newPosition = newPosition,
            .newText = newText,
        };
    }

    pub fn deinit(self: *TextChange) void {
        self.oldText.deinit();
        self.newText.deinit();
    }

    pub fn clone(self: *const TextChange, allocator: Allocator) !TextChange {
        return TextChange.init(
            self.oldPosition,
            try String.allocPrint(allocator, "{s}", .{self.oldText.items()}),
            self.newPosition,
            try String.allocPrint(allocator, "{s}", .{self.newText.items()}),
        );
    }

    pub fn oldLength(self: *const TextChange) usize {
        return self.oldText.len();
    }

    pub fn oldEnd(self: *const TextChange) usize {
        return self.oldPosition + self.oldLength();
    }

    pub fn newLength(self: *const TextChange) usize {
        return self.newText.len();
    }

    pub fn newEnd(self: *const TextChange) usize {
        return self.newPosition + self.newLength();
    }

    pub fn toString(self: *const TextChange, allocator: Allocator) ![]const u8 {
        if (self.oldText.isEmpty()) {
            const escaped = try strings.escapeNewLine(self.newText.items(), allocator);
            defer allocator.free(escaped);
            return try std.fmt.allocPrint(allocator, "(insert@{d} \"{s}\")", .{ self.oldPosition, escaped });
        }

        if (self.newText.isEmpty()) {
            const escaped = try strings.escapeNewLine(self.oldText.items(), allocator);
            defer allocator.free(escaped);
            return try std.fmt.allocPrint(allocator, "(delete@{d} \"{s}\")", .{ self.oldPosition, escaped });
        }

        const escapedOldText = try strings.escapeNewLine(self.oldText.items(), allocator);
        const escapedNewText = try strings.escapeNewLine(self.newText.items(), allocator);
        defer allocator.free(escapedOldText);
        defer allocator.free(escapedNewText);
        return try std.fmt.allocPrint(allocator, "(replace@{d} \"{s}\" with \"{s}\")", .{
            self.oldPosition,
            escapedOldText,
            escapedNewText,
        });
    }

    pub fn writeSize(self: *const TextChange) usize {
        return 4 // oldPosition
        + 4 // newPosition
        + _wriateStringSize(self.oldText.items()) //
        + _wriateStringSize(self.newText.items());
    }

    pub fn write(self: *const TextChange, writer: *Io.Writer) !void {
        try writer.writeInt(u32, @intCast(self.oldPosition), .big);
        try writer.writeInt(u32, @intCast(self.newPosition), .big);
        try _writeString(writer, self.oldText.items());
        try _writeString(writer, self.newText.items());
    }

    pub fn read(reader: *Io.Reader, allocator: Allocator, dest: *ArrayList(TextChange)) !void {
        const oldPosition = try reader.takeInt(u32, .big);
        const newPosition = try reader.takeInt(u32, .big);
        const oldText = String.initOwned(try _readString(reader, allocator));
        const newText = String.initOwned(try _readString(reader, allocator));
        try dest.append(TextChange.init(oldPosition, oldText, newPosition, newText));
    }
};

pub fn compressConsecutiveTextChanges(allocator: Allocator, prevEdits: ArrayList(TextChange), currEdits: []const TextChange) !ArrayList(TextChange) {
    if (prevEdits.items.len == 0) {
        var result = ArrayList(TextChange).init(allocator);
        errdefer {
            for (result.items) |*change| change.deinit();
            result.deinit();
        }
        try result.ensureTotalCapacity(currEdits.len);
        for (currEdits) |change| {
            result.appendAssumeCapacity(try change.clone(allocator));
        }
        return result;
    }

    var compressor = TextChangeCompressor.init(allocator, prevEdits.items, currEdits);
    return try compressor.compress();
}

pub const TextChangeCompressor = struct {
    _prevEdits: []const TextChange,
    _currEdits: []const TextChange,

    _prevDeltaOffset: isize,

    _currDeltaOffset: isize,

    _result: ArrayList(TextChange),

    const PairTextChange = Pair(TextChange, TextChange);

    pub fn init(allocator: Allocator, prevEdits: []const TextChange, currEdits: []const TextChange) TextChangeCompressor {
        return TextChangeCompressor{
            ._prevEdits = prevEdits,
            ._currEdits = currEdits,

            ._prevDeltaOffset = 0,
            ._currDeltaOffset = 0,

            ._result = ArrayList(TextChange).init(allocator),
        };
    }

    pub fn compress(self: *TextChangeCompressor) !ArrayList(TextChange) {
        var prevIndex: usize = 0;
        var currIndex: usize = 0;

        var prevEdit = self._getPrev(prevIndex);
        var currEdit = self._getCurr(currIndex);

        while (prevIndex < self._prevEdits.len or currIndex < self._currEdits.len) {
            if (prevEdit == null) {
                try self._acceptCurr(currEdit.?);
                currIndex += 1;
                currEdit = self._getCurr(currIndex);
                continue;
            }

            if (currEdit == null) {
                try self._acceptPrev(prevEdit.?);
                prevIndex += 1;
                prevEdit = self._getPrev(prevIndex);
                continue;
            }

            if (currEdit.?.oldEnd() <= prevEdit.?.newPosition) {
                try self._acceptCurr(currEdit.?);
                currIndex += 1;
                currEdit = self._getCurr(currIndex);
                continue;
            }

            if (prevEdit.?.newEnd() <= currEdit.?.oldPosition) {
                try self._acceptPrev(prevEdit.?);
                prevIndex += 1;
                prevEdit = self._getPrev(prevIndex);
                continue;
            }

            if (currEdit.?.oldPosition < prevEdit.?.newPosition) {
                const split = _splitCurr(currEdit.?, prevEdit.?.newPosition - currEdit.?.oldPosition);
                try self._acceptCurr(split.first);
                currEdit = split.second;
                continue;
            }

            if (prevEdit.?.newPosition < currEdit.?.oldPosition) {
                const split = _splitPrev(prevEdit.?, currEdit.?.oldPosition - prevEdit.?.newPosition);
                try self._acceptPrev(split.first);
                prevEdit = split.second;
                continue;
            }

            // At this point, currEdit.oldPosition === prevEdit.newPosition

            var mergePrev: TextChange = undefined;
            var mergeCurr: TextChange = undefined;

            if (currEdit.?.oldEnd() == prevEdit.?.newEnd()) {
                mergePrev = prevEdit.?;
                mergeCurr = currEdit.?;
                prevIndex += 1;
                prevEdit = self._getPrev(prevIndex);
                currIndex += 1;
                currEdit = self._getCurr(currIndex);
            } else if (currEdit.?.oldEnd() < prevEdit.?.newEnd()) {
                const split = _splitPrev(prevEdit.?, currEdit.?.oldLength());
                mergePrev = split.first;
                mergeCurr = currEdit.?;
                prevEdit = split.second;
                currIndex += 1;
                currEdit = self._getCurr(currIndex);
            } else {
                const split = _splitCurr(currEdit.?, prevEdit.?.newLength());

                mergePrev = prevEdit.?;
                mergeCurr = split.first;
                prevIndex += 1;
                prevEdit = self._getPrev(prevIndex);
                currEdit = split.second;
            }

            try self._result.append(TextChange{
                .oldPosition = mergePrev.oldPosition,
                .oldText = mergePrev.oldText,
                .newPosition = mergeCurr.newPosition,
                .newText = mergeCurr.newText,
            });
            self._prevDeltaOffset = self._prevDeltaOffset + usizeSub(mergePrev.newLength(), mergePrev.oldLength());
            self._currDeltaOffset = self._currDeltaOffset + usizeSub(mergeCurr.newLength(), mergeCurr.oldLength());
        }

        try self._merge();
        try self._removeNoOps();
        return self._result;
    }

    pub fn _acceptCurr(self: *TextChangeCompressor, currEdit: TextChange) !void {
        try self._result.append(_rebaseCurr(self._prevDeltaOffset, currEdit));
        self._currDeltaOffset = self._currDeltaOffset + usizeSub(currEdit.newLength(), currEdit.oldLength());
    }

    pub fn _getCurr(self: *const TextChangeCompressor, currIndex: usize) ?TextChange {
        return if (currIndex < self._currEdits.len) self._currEdits[currIndex] else null;
    }

    pub fn _acceptPrev(self: *TextChangeCompressor, prevEdit: TextChange) !void {
        try self._result.append(_rebasePrev(self._currDeltaOffset, prevEdit));
        self._prevDeltaOffset = self._prevDeltaOffset + usizeSub(prevEdit.newLength(), prevEdit.oldLength());
    }

    pub fn _getPrev(self: *const TextChangeCompressor, prevIndex: usize) ?TextChange {
        return if (prevIndex < self._prevEdits.len) self._prevEdits[prevIndex] else null;
    }

    pub fn _rebaseCurr(prevDeltaOffset: isize, currEdit: TextChange) TextChange {
        return TextChange{
            .oldPosition = usizeAdd(currEdit.oldPosition, -prevDeltaOffset),
            .oldText = currEdit.oldText,
            .newPosition = currEdit.newPosition,
            .newText = currEdit.newText,
        };
    }

    pub fn _rebasePrev(currDeltaOffset: isize, prevEdit: TextChange) TextChange {
        return TextChange{
            .oldPosition = prevEdit.oldPosition,
            .oldText = prevEdit.oldText,
            .newPosition = usizeAdd(prevEdit.newPosition, currDeltaOffset),
            .newText = prevEdit.newText,
        };
    }

    pub fn _splitPrev(edit: TextChange, offset: usize) PairTextChange {
        const preText = edit.newText.substring(0, offset);
        const postText = edit.newText.substring(offset, edit.newText.len());

        return pair(
            TextChange{
                .oldPosition = edit.oldPosition,
                .oldText = edit.oldText,
                .newPosition = edit.newPosition,
                .newText = preText,
            },
            TextChange{
                .oldPosition = edit.oldEnd(),
                .oldText = String.Empty,
                .newPosition = edit.newPosition + offset,
                .newText = postText,
            },
        );
    }

    pub fn _splitCurr(edit: TextChange, offset: usize) PairTextChange {
        const preText = edit.oldText.substring(0, offset);
        const postText = edit.oldText.substring(offset, edit.oldText.len());

        return pair(
            TextChange{
                .oldPosition = edit.oldPosition,
                .oldText = preText,
                .newPosition = edit.newPosition,
                .newText = edit.newText,
            },
            TextChange{
                .oldPosition = edit.oldPosition + offset,
                .oldText = postText,
                .newPosition = edit.newEnd(),
                .newText = String.Empty,
            },
        );
    }

    pub fn _merge(self: *TextChangeCompressor) !void {
        if (self._result.items.len == 0) {
            return;
        }

        const allocator = self._result.allocator;
        var merged = ArrayList(TextChange).init(allocator);
        errdefer merged.deinit();
        try merged.ensureTotalCapacity(self._result.items.len);

        var prev = self._result.items[0];
        for (self._result.items[1..]) |curr| {
            if (prev.oldEnd() == curr.oldPosition) {
                // Merge into `prev`. `curr` is consumed by this replacement.
                var old_text = try strings.concat(allocator, prev.oldText.items(), curr.oldText.items());
                const new_text = strings.concat(allocator, prev.newText.items(), curr.newText.items()) catch |err| {
                    old_text.deinit();
                    return err;
                };

                prev.oldText.deinit();
                prev.newText.deinit();
                var consumed = curr;
                consumed.oldText.deinit();
                consumed.newText.deinit();

                prev = TextChange.init(
                    prev.oldPosition,
                    String.initOwned(old_text),
                    prev.newPosition,
                    String.initOwned(new_text),
                );
            } else {
                merged.appendAssumeCapacity(prev);
                prev = curr;
            }
        }
        merged.appendAssumeCapacity(prev);

        self._result.deinit();
        self._result = merged;
    }

    pub fn _removeNoOps(self: *TextChangeCompressor) !void {
        if (self._result.items.len == 0) {
            return;
        }

        const allocator = self._result.allocator;
        var cleaned = ArrayList(TextChange).init(allocator);
        errdefer cleaned.deinit();
        try cleaned.ensureTotalCapacity(self._result.items.len);

        for (self._result.items) |item| {
            var edit = item;
            if (edit.oldText.eql(edit.newText)) {
                edit.deinit();
                continue;
            }
            cleaned.appendAssumeCapacity(edit);
        }

        self._result.deinit();
        self._result = cleaned;
    }
};

fn _wriateStringSize(str: []const u8) usize {
    return 4 + str.len;
}

fn _writeString(writer: *Io.Writer, str: []const u8) !void {
    try writer.writeInt(u32, @intCast(str.len), .big);
    try writer.writeAll(str);
}

fn _readString(reader: *Io.Reader, allocator: Allocator) !ArrayList(u8) {
    const len: usize = @intCast(try reader.takeInt(u32, .big));
    var str = try ArrayList(u8).initCapacity(allocator, len);
    try str.resize(len);
    const read_len = try reader.readSliceShort(str.items);
    if (read_len != len) return error.UnexpectedEof;
    return str;
}

test "compress consecutive insertions with owned strings" {
    const allocator = std.testing.allocator;

    var prev = ArrayList(TextChange).init(allocator);
    defer prev.deinit();
    try prev.append(TextChange.init(
        0,
        try String.allocPrint(allocator, "{s}", .{""}),
        0,
        try String.allocPrint(allocator, "{s}", .{"a"}),
    ));

    var curr = ArrayList(TextChange).init(allocator);
    defer curr.deinit();
    try curr.append(TextChange.init(
        1,
        try String.allocPrint(allocator, "{s}", .{""}),
        1,
        try String.allocPrint(allocator, "{s}", .{"b"}),
    ));

    var result = try compressConsecutiveTextChanges(allocator, prev, curr.items);
    defer {
        for (result.items) |*change| change.deinit();
        result.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("ab", result.items[0].newText.items());
}

test "textChange wire format uses UTF-8 byte lengths" {
    const allocator = std.testing.allocator;
    var change = TextChange.init(0, .initBorrowed("aé😀"), 0, .initBorrowed("😀é"));
    defer change.deinit();

    // 8 + (4 + 7) + (4 + 6)
    try std.testing.expectEqual(@as(usize, 29), change.writeSize());

    var buf: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);
    try change.write(&writer);

    var reader = Io.Reader.fixed(writer.buffered());
    var readChanges = ArrayList(TextChange).init(allocator);
    defer readChanges.deinit();
    defer {
        for (readChanges.items) |*item| item.deinit();
    }
    try TextChange.read(&reader, allocator, &readChanges);

    try std.testing.expectEqual(@as(usize, 1), readChanges.items.len);
    try std.testing.expectEqualStrings("aé😀", readChanges.items[0].oldText.items());
    try std.testing.expectEqualStrings("😀é", readChanges.items[0].newText.items());
}

test "compress consecutive insertions" {
    const allocator = std.testing.allocator;
    var prev = ArrayList(TextChange).init(allocator);
    defer prev.deinit();
    try prev.append(TextChange.init(3, String.initBorrowed(""), 3, String.initBorrowed("a")));
    var curr = [_]TextChange{TextChange.init(4, String.initBorrowed(""), 4, String.initBorrowed("b"))};
    var result = try compressConsecutiveTextChanges(allocator, prev, &curr);
    defer {
        for (result.items) |*change| change.deinit();
        result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("ab", result.items[0].newText.items());
}

test "textChange toString labels" {
    var change = TextChange.init(0, .initBorrowed("Hello"), 0, .initBorrowed("World"));
    defer change.deinit();

    const result = try change.toString(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("(replace@0 \"Hello\" with \"World\")", result);
}
