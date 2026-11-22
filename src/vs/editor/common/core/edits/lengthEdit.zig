// Port of `src/vs/editor/common/core/edits/lengthEdit.ts`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;
const edit = @import("edit.zig");

/// Like a normal edit, but only captures the length information.
pub const LengthReplacement = struct {
    const Self = @This();

    replaceRange: OffsetRange,
    newLength: usize,

    pub fn create(start_offset: usize, end_offset_exclusive: usize, new_length: usize) Self {
        return Self.init(OffsetRange.init(start_offset, end_offset_exclusive), new_length);
    }

    pub fn init(range: OffsetRange, new_length: usize) Self {
        return .{ .replaceRange = range, .newLength = new_length };
    }

    pub fn equals(self: Self, other: Self) bool {
        return self.replaceRange.equals(other.replaceRange) and self.newLength == other.newLength;
    }

    pub fn getNewLength(self: Self) usize {
        return self.newLength;
    }

    pub fn tryJoinTouching(self: Self, allocator: Allocator, other: Self) !?Self {
        _ = allocator;
        return Self.init(
            try self.replaceRange.joinRightTouching(other.replaceRange),
            self.newLength + other.newLength,
        );
    }

    pub fn slice(self: Self, allocator: Allocator, range: OffsetRange, range_in_replacement: ?OffsetRange) !Self {
        _ = allocator;
        return Self.init(range, if (range_in_replacement) |r| r.length() else self.newLength);
    }

    pub fn clone(self: Self, allocator: Allocator) !Self {
        _ = allocator;
        return self;
    }

    pub fn getLengthDelta(self: Self) isize {
        return edit.replacementLengthDelta(Self, self);
    }

    pub fn delta(self: Self, allocator: Allocator, offset: isize) !Self {
        return edit.replacementDelta(Self, self, allocator, offset);
    }

    pub fn getRangeAfterReplace(self: Self) OffsetRange {
        return edit.replacementGetRangeAfterReplace(Self, self);
    }

    pub fn isEmpty(self: Self) bool {
        return edit.replacementIsEmpty(Self, self);
    }

    pub fn toString(self: Self, writer: *Io.Writer) !void {
        try writer.print("[{d}, +{d}) -> +{d}}}", .{ self.replaceRange.start, self.replaceRange.length(), self.newLength });
    }
};

pub const LengthEdit = edit.BaseEdit(LengthReplacement);

pub fn empty(allocator: Allocator) LengthEdit {
    return LengthEdit.empty(allocator);
}

pub fn fromEdit(comptime T: type, allocator: Allocator, source: *const edit.BaseEdit(T)) !LengthEdit {
    var replacements = ArrayList(LengthReplacement).init(allocator);
    defer replacements.deinit();
    try replacements.ensureTotalCapacity(source.replacements.len);
    for (source.replacements) |replacement| {
        replacements.appendAssumeCapacity(LengthReplacement.init(replacement.replaceRange, replacement.getNewLength()));
    }
    return LengthEdit.create(allocator, replacements.items);
}

pub fn create(allocator: Allocator, replacements: []const LengthReplacement) !LengthEdit {
    return LengthEdit.create(allocator, replacements);
}

pub fn single(allocator: Allocator, replacement: LengthReplacement) !LengthEdit {
    return LengthEdit.single(allocator, replacement);
}

pub fn replace(allocator: Allocator, range: OffsetRange, new_length: usize) !LengthEdit {
    return LengthEdit.single(allocator, LengthReplacement.init(range, new_length));
}

pub fn insert(allocator: Allocator, offset: usize, new_length: usize) !LengthEdit {
    return LengthEdit.single(allocator, LengthReplacement.init(OffsetRange.emptyAt(offset), new_length));
}

pub fn delete(allocator: Allocator, range: OffsetRange) !LengthEdit {
    return LengthEdit.single(allocator, LengthReplacement.init(range, 0));
}

pub fn composeAll(allocator: Allocator, edits: []const LengthEdit) !LengthEdit {
    var result = LengthEdit.empty(allocator);
    errdefer result.deinit();

    for (edits) |*source| {
        const next = try result.compose(source);
        result.deinit();
        result = next;
    }
    return result;
}

/// Creates an edit that reverts this edit.
pub fn inverse(allocator: Allocator, length_edit: *const LengthEdit) !LengthEdit {
    var replacements = ArrayList(LengthReplacement).init(allocator);
    defer replacements.deinit();
    try replacements.ensureTotalCapacity(length_edit.replacements.len);

    var offset: isize = 0;
    for (length_edit.replacements) |replacement| {
        replacements.appendAssumeCapacity(LengthReplacement.init(
            OffsetRange.ofStartAndLength(
                @intCast(@as(isize, @intCast(replacement.replaceRange.start)) + offset),
                replacement.newLength,
            ),
            replacement.replaceRange.length(),
        ));
        offset += replacement.getLengthDelta();
    }
    return LengthEdit.create(allocator, replacements.items);
}

pub fn applyArray(comptime T: type, allocator: Allocator, length_edit: *const LengthEdit, arr: []const T, fill_item: T) ![]T {
    const new_length = length_edit.getNewDataLength(arr.len);
    if (new_length < 0) {
        return error.InvalidLength;
    }
    const new_arr = try allocator.alloc(T, @intCast(new_length));
    errdefer allocator.free(new_arr);

    var src_pos: usize = 0;
    var dst_pos: usize = 0;

    for (length_edit.replacements) |replacement| {
        // Copy items before the current replacement.
        while (src_pos < replacement.replaceRange.start) : (src_pos += 1) {
            new_arr[dst_pos] = arr[src_pos];
            dst_pos += 1;
        }

        // Skip the replaced items in the source array.
        src_pos = replacement.replaceRange.endExclusive;

        // Fill with the provided item for insertions.
        var i: usize = 0;
        while (i < replacement.newLength) : (i += 1) {
            new_arr[dst_pos] = fill_item;
            dst_pos += 1;
        }
    }

    // Copy any remaining items from the original array.
    while (src_pos < arr.len) : (src_pos += 1) {
        new_arr[dst_pos] = arr[src_pos];
        dst_pos += 1;
    }

    std.debug.assert(dst_pos == new_arr.len);
    return new_arr;
}

test "LengthEdit: replace, insert, delete" {
    const allocator = std.testing.allocator;

    var replaced = try replace(allocator, OffsetRange.init(2, 4), 3);
    defer replaced.deinit();
    try std.testing.expectEqual(@as(isize, 1), replaced.getLengthDelta());
    try std.testing.expectEqual(@as(usize, 3), replaced.replacements[0].newLength);

    var inserted = try insert(allocator, 5, 2);
    defer inserted.deinit();
    try std.testing.expectEqual(@as(isize, 2), inserted.getLengthDelta());
    try std.testing.expectEqual(OffsetRange.emptyAt(5), inserted.replacements[0].replaceRange);

    var deleted = try delete(allocator, OffsetRange.init(1, 4));
    defer deleted.deinit();
    try std.testing.expectEqual(@as(isize, -3), deleted.getLengthDelta());
}

test "LengthEdit: inverse" {
    const allocator = std.testing.allocator;

    var source = try LengthEdit.create(allocator, &.{
        LengthReplacement.create(1, 3, 5),
        LengthReplacement.create(4, 4, 2),
    });
    defer source.deinit();

    var inversed = try inverse(allocator, &source);
    defer inversed.deinit();

    try std.testing.expectEqual(2, inversed.replacements.len);
    try std.testing.expectEqual(OffsetRange.ofStartAndLength(1, 5), inversed.replacements[0].replaceRange);
    try std.testing.expectEqual(@as(usize, 2), inversed.replacements[0].newLength);
    try std.testing.expectEqual(OffsetRange.ofStartAndLength(7, 2), inversed.replacements[1].replaceRange);
    try std.testing.expectEqual(@as(usize, 0), inversed.replacements[1].newLength);
}

test "LengthEdit: applyArray" {
    const allocator = std.testing.allocator;

    var length_edit = try LengthEdit.create(allocator, &.{
        LengthReplacement.create(1, 3, 1),
        LengthReplacement.create(4, 4, 2),
    });
    defer length_edit.deinit();

    const source = [_]u8{ 0, 1, 2, 3, 4, 5 };
    const result = try applyArray(u8, allocator, &length_edit, &source, 9);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, &.{ 0, 9, 3, 9, 9, 4, 5 }, result);
}

test "LengthEdit: composeAll" {
    const allocator = std.testing.allocator;

    var e1 = try LengthEdit.create(allocator, &.{LengthReplacement.create(1, 2, 3)});
    defer e1.deinit();
    var e2 = try LengthEdit.create(allocator, &.{LengthReplacement.create(0, 1, 1)});
    defer e2.deinit();
    var e3 = try LengthEdit.create(allocator, &.{LengthReplacement.create(2, 2, 4)});
    defer e3.deinit();

    var composed = try composeAll(allocator, &.{ e1, e2, e3 });
    defer composed.deinit();
    try std.testing.expect(composed.replacements.len > 0);
}
