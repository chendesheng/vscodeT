const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fs = std.fs;
const strings = @import("strings.zig");
const Pair = @import("utils.zig").Pair;
const pair = @import("utils.zig").pair;

pub const TextChange = struct {
    oldPosition: usize,
    oldText: []const u8,
    newPosition: usize,
    newText: []const u8,

    pub fn init(oldPosition: usize, oldText: []const u8, newPosition: usize, newText: []const u8) TextChange {
        return TextChange{
            .oldPosition = oldPosition,
            .oldText = oldText,
            .newPosition = newPosition,
            .newText = newText,
        };
    }

    pub fn deinit(self: *const TextChange, allocator: Allocator) void {
        allocator.free(self.oldText);
        allocator.free(self.newText);
    }

    pub fn oldLength(self: *const TextChange) usize {
        return self.oldText.len;
    }

    pub fn oldEnd(self: *const TextChange) usize {
        return self.oldPosition + self.oldLength();
    }

    pub fn newLength(self: *const TextChange) usize {
        return self.newText.len;
    }

    pub fn newEnd(self: *const TextChange) usize {
        return self.newPosition + self.newLength();
    }

    pub fn toString(self: *const TextChange, allocator: Allocator) ![]const u8 {
        if (self.oldText.len == 0) {
            const escaped = try strings.escapeNewLine(self.newText, allocator);
            defer allocator.free(escaped);
            return try std.fmt.allocPrint(allocator, "(inserted@{d} \"{s}\")", .{ self.oldPosition, escaped });
        }

        if (self.newText.len == 0) {
            const escaped = try strings.escapeNewLine(self.oldText, allocator);
            defer allocator.free(escaped);
            return try std.fmt.allocPrint(allocator, "(deleted@{d} \"{s}\")", .{ self.oldPosition, escaped });
        }

        const escapedOldText = try strings.escapeNewLine(self.oldText, allocator);
        const escapedNewText = try strings.escapeNewLine(self.newText, allocator);
        defer allocator.free(escapedOldText);
        defer allocator.free(escapedNewText);
        return try std.fmt.allocPrint(allocator, "(replaced@{d} \"{s}\" with \"{s}\")", .{
            self.oldPosition,
            escapedOldText,
            escapedNewText,
        });
    }

    pub fn writeSize(self: *const TextChange) usize {
        return 4 // oldPosition
        + 4 // newPosition
        + _wriateStringSize(self.oldText) + _wriateStringSize(self.newText);
    }

    pub fn write(self: *const TextChange, writer: io.AnyWriter) !void {
        try writer.writeInt(u32, @intCast(self.oldPosition), .big);
        try writer.writeInt(u32, @intCast(self.newPosition), .big);
        try _writeString(writer, self.oldText);
        try _writeString(writer, self.newText);
    }

    pub fn read(reader: io.AnyReader, allocator: Allocator, dest: *ArrayList(TextChange)) !void {
        const oldPosition = try reader.readInt(u32, .big);
        const newPosition = try reader.readInt(u32, .big);
        const oldText = try _readString(reader, allocator);
        const newText = try _readString(reader, allocator);
        try dest.append(TextChange.init(oldPosition, oldText, newPosition, newText));
    }
};

pub fn compressConsecutiveTextChanges(allocator: Allocator, prevEdits: ?[]TextChange, currEdits: []TextChange) ![]TextChange {
    if (prevEdits == null or prevEdits.?.len == 0) {
        return currEdits;
    }

    const compressor = TextChangeCompressor.init(allocator, prevEdits.?, currEdits);
    return try compressor.compress();
}

pub const TextChangeCompressor = struct {
    _prevEdits: []TextChange,
    _currEdits: []TextChange,

    _result: ArrayList(TextChange),

    _prevLen: usize,
    _prevDeltaOffset: usize,

    _currLen: usize,
    _currDeltaOffset: usize,

    const PairTextChange = Pair(TextChange, TextChange);

    pub fn init(allocator: Allocator, prevEdits: []TextChange, currEdits: []TextChange) TextChangeCompressor {
        return TextChangeCompressor{
            ._prevEdits = prevEdits,
            ._currEdits = currEdits,

            ._result = ArrayList(TextChange).init(allocator),

            ._prevLen = prevEdits.len,
            ._prevDeltaOffset = 0,

            ._currLen = currEdits.len,
            ._currDeltaOffset = 0,
        };
    }

    pub fn compress(self: *TextChangeCompressor) ![]TextChange {
        var prevIndex: usize = 0;
        var currIndex: usize = 0;

        var prevEdit = self._getPrev(prevIndex);
        var currEdit = self._getCurr(currIndex);

        while (prevIndex < self._prevLen or currIndex < self._currLen) {
            if (prevEdit == null) {
                try self._acceptCurr(currEdit);
                currIndex += 1;
                currEdit = self._getCurr(currIndex);
                continue;
            }

            if (currEdit == null) {
                try self._acceptPrev(prevEdit);
                prevIndex += 1;
                prevEdit = self._getPrev(prevIndex);
                continue;
            }

            if (currEdit.oldEnd <= prevEdit.newPosition) {
                try self._acceptCurr(currEdit);
                currIndex += 1;
                currEdit = self._getCurr(currIndex);
                continue;
            }

            if (prevEdit.newEnd <= currEdit.oldPosition) {
                try self._acceptPrev(prevEdit);
                prevIndex += 1;
                prevEdit = self._getPrev(prevIndex);
                continue;
            }

            if (currEdit.oldPosition < prevEdit.newPosition) {
                const split = _splitCurr(currEdit, prevEdit.newPosition - currEdit.oldPosition);
                try self._acceptCurr(split.first);
                currEdit = split.second;
                continue;
            }

            if (prevEdit.newPosition < currEdit.oldPosition) {
                const split = _splitPrev(prevEdit, currEdit.oldPosition - prevEdit.newPosition);
                try self._acceptPrev(split.first);
                prevEdit = split.second;
                continue;
            }

            // At this point, currEdit.oldPosition === prevEdit.newPosition

            var mergePrev: TextChange = undefined;
            var mergeCurr: TextChange = undefined;

            if (currEdit.oldEnd == prevEdit.newEnd) {
                mergePrev = prevEdit;
                mergeCurr = currEdit;
                prevIndex += 1;
                prevEdit = self._getPrev(prevIndex);
                currIndex += 1;
                currEdit = self._getCurr(currIndex);
            } else if (currEdit.oldEnd < prevEdit.newEnd) {
                const split = _splitPrev(prevEdit, currEdit.oldLength);
                mergePrev = split.first;
                mergeCurr = currEdit;
                prevEdit = split.second;
                currIndex += 1;
                currEdit = self._getCurr(currIndex);
            } else {
                const split = _splitCurr(currEdit, prevEdit.newLength);

                mergePrev = prevEdit;
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
            self._prevDeltaOffset += mergePrev.newLength - mergePrev.oldLength;
            self._currDeltaOffset += mergeCurr.newLength - mergeCurr.oldLength;
        }

        const merged = try self._merge(self._result);
        const cleaned = try self._removeNoOps(merged);
        return cleaned;
    }

    pub fn _acceptCurr(self: *TextChangeCompressor, currEdit: TextChange) !void {
        try self._result.append(_rebaseCurr(self._prevDeltaOffset, currEdit));
        self._currDeltaOffset += currEdit.newLength - currEdit.oldLength;
    }

    pub fn _getCurr(self: *TextChangeCompressor, currIndex: usize) ?TextChange {
        return if (currIndex < self._currLen) self._currEdits[currIndex] else null;
    }

    pub fn _acceptPrev(self: *TextChangeCompressor, prevEdit: TextChange) !void {
        try self._result.append(_rebasePrev(self._currDeltaOffset, prevEdit));
        self._prevDeltaOffset += prevEdit.newLength - prevEdit.oldLength;
    }

    pub fn _getPrev(self: *TextChangeCompressor, prevIndex: usize) ?TextChange {
        return if (prevIndex < self._prevLen) self._prevEdits[prevIndex] else null;
    }

    pub fn _rebaseCurr(prevDeltaOffset: usize, currEdit: TextChange) TextChange {
        return TextChange{
            .oldPosition = currEdit.oldPosition - prevDeltaOffset,
            .oldText = currEdit.oldText,
            .newPosition = currEdit.newPosition,
            .newText = currEdit.newText,
        };
    }

    pub fn _rebasePrev(currDeltaOffset: usize, prevEdit: TextChange) TextChange {
        return TextChange{
            .oldPosition = prevEdit.oldPosition,
            .oldText = prevEdit.oldText,
            .newPosition = prevEdit.newPosition + currDeltaOffset,
            .newText = prevEdit.newText,
        };
    }

    pub fn _splitPrev(edit: TextChange, offset: usize) PairTextChange {
        const preText = edit.newText[0..offset];
        const postText = edit.newText[offset..];

        return pair(
            TextChange{
                .oldPosition = edit.oldPosition,
                .oldText = edit.oldText,
                .newPosition = edit.newPosition,
                .newText = preText,
            },
            TextChange{
                .oldPosition = edit.oldEnd,
                .oldText = "",
                .newPosition = edit.newPosition + offset,
                .newText = postText,
            },
        );
    }

    pub fn _splitCurr(edit: TextChange, offset: usize) PairTextChange {
        const preText = edit.oldText[0..offset];
        const postText = edit.oldText[offset..];

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
                .newPosition = edit.newEnd,
                .newText = "",
            },
        );
    }

    pub fn _merge(self: *TextChangeCompressor, edits: []TextChange) ![]TextChange {
        if (edits.len == 0) {
            return edits;
        }

        var prev = edits[0];
        for (1..edits.len) |i| {
            const curr = edits[i];

            if (prev.oldEnd == curr.oldPosition) {
                // Merge into `prev`
                prev = TextChange{
                    .oldPosition = prev.oldPosition,
                    .oldText = prev.oldText + curr.oldText,
                    .newPosition = prev.newPosition,
                    .newText = prev.newText + curr.newText,
                };
            } else {
                try self._result.append(prev);
                prev = curr;
            }
        }
        try self._result.append(prev);

        return self._result.items;
    }

    pub fn _removeNoOps(self: *TextChangeCompressor, edits: []TextChange) ![]TextChange {
        if (edits.len == 0) {
            return edits;
        }

        for (edits) |edit| {
            if (edit.oldText == edit.newText) {
                continue;
            }
            try self._result.append(edit);
        }

        return self._result.items;
    }
};

fn _wriateStringSize(str: []u8) usize {
    return 4 + 2 * str.len;
}

fn _writeString(writer: io.AnyWriter, str: []const u8) !void {
    const len = str.len;
    try writer.writeInt(usize, len, .big);
    try writer.writeAll(str);
}

fn _readString(reader: io.AnyReader, allocator: Allocator) ![]const u8 {
    const len = try reader.readInt(usize, .big);
    const str = try allocator.alloc(u8, len);
    _ = try reader.readAll(str);
    return str;
}

test "textChange" {
    const change = TextChange.init(0, "Hello", 0, "World");

    const result = try change.toString(std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("(replaced@0 \"Hello\" with \"World\")", result);
}

test "textChange read/write" {
    const allocator = std.testing.allocator;
    const change = TextChange.init(0, "Hello", 0, "World");

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer().any();
    try change.write(writer);

    stream.reset();
    const reader = stream.reader().any();
    var readChanges = ArrayList(TextChange).init(allocator);
    defer readChanges.deinit();
    defer {
        for (readChanges.items) |item| {
            item.deinit(allocator);
        }
    }
    try TextChange.read(reader, allocator, &readChanges);

    try std.testing.expectEqualDeep(change, readChanges.items[0]);
}
