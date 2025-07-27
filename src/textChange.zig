const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fs = std.fs;
const strings = @import("strings.zig");
const Pair = @import("utils.zig").Pair;
const pair = @import("utils.zig").pair;
const usizeSub = @import("utils.zig").usizeSub;
const usizeAdd = @import("utils.zig").usizeAdd;
const String = @import("strings.zig").String;

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
            return try std.fmt.allocPrint(allocator, "(inserted@{d} \"{s}\")", .{ self.oldPosition, escaped });
        }

        if (self.newText.isEmpty()) {
            const escaped = try strings.escapeNewLine(self.oldText.items(), allocator);
            defer allocator.free(escaped);
            return try std.fmt.allocPrint(allocator, "(deleted@{d} \"{s}\")", .{ self.oldPosition, escaped });
        }

        const escapedOldText = try strings.escapeNewLine(self.oldText.items(), allocator);
        const escapedNewText = try strings.escapeNewLine(self.newText.items(), allocator);
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
        + _wriateStringSize(self.oldText.items()) //
        + _wriateStringSize(self.newText.items());
    }

    pub fn write(self: *const TextChange, writer: io.AnyWriter) !void {
        try writer.writeInt(u32, @intCast(self.oldPosition), .big);
        try writer.writeInt(u32, @intCast(self.newPosition), .big);
        try _writeString(writer, self.oldText.items());
        try _writeString(writer, self.newText.items());
    }

    pub fn read(reader: io.AnyReader, allocator: Allocator, dest: *ArrayList(TextChange)) !void {
        const oldPosition = try reader.readInt(u32, .big);
        const newPosition = try reader.readInt(u32, .big);
        const oldText = String.initOwned(try _readString(reader, allocator));
        const newText = String.initOwned(try _readString(reader, allocator));
        try dest.append(TextChange.init(oldPosition, oldText, newPosition, newText));
    }
};

pub fn compressConsecutiveTextChanges(allocator: Allocator, prevEdits: ArrayList(TextChange), currEdits: []const TextChange) !ArrayList(TextChange) {
    if (prevEdits.items.len == 0) {
        var result = ArrayList(TextChange).init(allocator);
        try result.appendSlice(currEdits);
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
        var result = &self._result;
        var write_index: usize = 0;
        var prev = &result.items[write_index];
        for (1..result.items.len) |i| {
            const curr = &result.items[i];

            if (prev.oldEnd() == curr.oldPosition) {
                // Merge into `prev`
                var oldText = prev.oldText;
                defer oldText.deinit();
                var newText = prev.newText;
                defer newText.deinit();
                prev.oldText = String.initOwned(try strings.concat(allocator, prev.oldText.items(), curr.oldText.items()));
                prev.newText = String.initOwned(try strings.concat(allocator, prev.newText.items(), curr.newText.items()));
            } else {
                write_index += 1;
                prev = &result.items[write_index];
                if (prev != curr) {
                    prev.* = curr.*;
                }
            }
        }
        try self._result.resize(write_index);
    }

    pub fn _removeNoOps(self: *TextChangeCompressor) !void {
        if (self._result.items.len == 0) {
            return;
        }

        var result = &self._result;
        var write_index: usize = 0;
        for (result.items) |edit| {
            if (edit.oldText.eql(edit.newText)) {
                continue;
            }
            result.items[write_index] = edit;
            write_index += 1;
        }

        try result.resize(write_index);
    }
};

fn _wriateStringSize(str: []const u8) usize {
    return 4 + str.len;
}

fn _writeString(writer: io.AnyWriter, str: []const u8) !void {
    const len: u32 = @intCast(str.len);
    try writer.writeInt(u32, len, .big);
    try writer.writeAll(str);
}

fn _readString(reader: io.AnyReader, allocator: Allocator) !ArrayList(u8) {
    const len: usize = @intCast(try reader.readInt(u32, .big));
    var str = try ArrayList(u8).initCapacity(allocator, len);
    try str.resize(len);
    const readLen = try reader.readAll(str.items);
    std.debug.assert(readLen == len);
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
            item.deinit();
        }
    }
    try TextChange.read(reader, allocator, &readChanges);

    try std.testing.expectEqualDeep(change, readChanges.items[0]);
}
