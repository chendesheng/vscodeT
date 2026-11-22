// Port of `src/vs/editor/common/core/edits/arrayEdit.ts`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;
const edit = @import("edit.zig");

/// A replacement of a range of an array with a new value.
pub fn ArrayReplacement(comptime T: type) type {
    return struct {
        const Self = @This();

        replaceRange: OffsetRange,
        newValue: []const T,

        pub fn init(range: OffsetRange, new_value: []const T) Self {
            return .{ .replaceRange = range, .newValue = new_value };
        }

        pub fn equals(self: Self, other: Self) bool {
            if (!self.replaceRange.equals(other.replaceRange) or self.newValue.len != other.newValue.len) {
                return false;
            }
            for (self.newValue, other.newValue) |a, b| {
                if (!std.meta.eql(a, b)) {
                    return false;
                }
            }
            return true;
        }

        pub fn getNewLength(self: Self) usize {
            return self.newValue.len;
        }

        pub fn tryJoinTouching(self: Self, allocator: Allocator, other: Self) !?Self {
            const joined = try allocator.alloc(T, self.newValue.len + other.newValue.len);
            @memcpy(joined[0..self.newValue.len], self.newValue);
            @memcpy(joined[self.newValue.len..], other.newValue);
            return Self.init(try self.replaceRange.joinRightTouching(other.replaceRange), joined);
        }

        pub fn slice(self: Self, allocator: Allocator, range: OffsetRange, range_in_replacement: ?OffsetRange) !Self {
            if (range_in_replacement) |r| {
                return Self.init(range, try allocator.dupe(T, self.newValue[r.start..r.endExclusive]));
            }
            return Self.init(range, try allocator.dupe(T, self.newValue));
        }

        pub fn clone(self: Self, allocator: Allocator) !Self {
            return Self.init(self.replaceRange, try allocator.dupe(T, self.newValue));
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
            // Match upstream `BaseReplacement.toString`, which ArrayReplacement
            // does not override.
            try writer.print("{{ ", .{});
            try self.replaceRange.toString(writer);
            try writer.print(" -> {d} }}", .{self.newValue.len});
        }
    };
}

/// Represents a set of replacements to an array. All these replacements are
/// applied at once.
pub fn ArrayEdit(comptime T: type) type {
    return edit.BaseEdit(ArrayReplacement(T));
}

pub fn empty(comptime T: type, allocator: Allocator) ArrayEdit(T) {
    return ArrayEdit(T).empty(allocator);
}

pub fn create(comptime T: type, allocator: Allocator, replacements: []const ArrayReplacement(T)) !ArrayEdit(T) {
    return ArrayEdit(T).create(allocator, replacements);
}

pub fn single(comptime T: type, allocator: Allocator, replacement: ArrayReplacement(T)) !ArrayEdit(T) {
    return ArrayEdit(T).single(allocator, replacement);
}

pub fn replace(comptime T: type, allocator: Allocator, range: OffsetRange, replacement: []T) !ArrayEdit(T) {
    return ArrayEdit(T).single(allocator, ArrayReplacement(T).init(range, replacement));
}

pub fn insert(comptime T: type, allocator: Allocator, offset: usize, replacement: []T) !ArrayEdit(T) {
    return ArrayEdit(T).single(allocator, ArrayReplacement(T).init(OffsetRange.emptyAt(offset), replacement));
}

pub fn delete(comptime T: type, allocator: Allocator, range: OffsetRange) !ArrayEdit(T) {
    return ArrayEdit(T).single(allocator, ArrayReplacement(T).init(range, &.{}));
}

/// Applies the edit to `data` and returns the resulting array.
pub fn apply(comptime T: type, allocator: Allocator, array_edit: *const ArrayEdit(T), data: []const T) ![]T {
    const new_length = array_edit.getNewDataLength(data.len);
    if (new_length < 0) {
        return error.InvalidLength;
    }

    const result = try allocator.alloc(T, @intCast(new_length));
    errdefer allocator.free(result);

    var pos: usize = 0;
    var dst: usize = 0;
    for (array_edit.replacements) |replacement| {
        while (pos < replacement.replaceRange.start) : (pos += 1) {
            result[dst] = data[pos];
            dst += 1;
        }
        for (replacement.newValue) |value| {
            result[dst] = value;
            dst += 1;
        }
        pos = replacement.replaceRange.endExclusive;
    }
    while (pos < data.len) : (pos += 1) {
        result[dst] = data[pos];
        dst += 1;
    }

    std.debug.assert(dst == result.len);
    return result;
}

/// Creates an edit that reverts this edit.
pub fn inverse(comptime T: type, allocator: Allocator, array_edit: *const ArrayEdit(T), base_val: []const T) !ArrayEdit(T) {
    var replacements = ArrayList(ArrayReplacement(T)).init(allocator);
    defer replacements.deinit();
    try replacements.ensureTotalCapacity(array_edit.replacements.len);

    var offset: isize = 0;
    for (array_edit.replacements) |replacement| {
        replacements.appendAssumeCapacity(ArrayReplacement(T).init(
            OffsetRange.ofStartAndLength(
                @intCast(@as(isize, @intCast(replacement.replaceRange.start)) + offset),
                replacement.newValue.len,
            ),
            try allocator.dupe(T, base_val[replacement.replaceRange.start..replacement.replaceRange.endExclusive]),
        ));
        offset += replacement.getLengthDelta();
    }

    // `create` copies the replacements again; the temporary copies are freed
    // here, but their values are only used until creation is complete.
    const result = try ArrayEdit(T).create(allocator, replacements.items);
    for (replacements.items) |replacement| {
        allocator.free(replacement.newValue);
    }
    return result;
}

test "ArrayEdit: apply and inverse" {
    const allocator = std.testing.allocator;

    const source = [_]u8{ 0, 1, 2, 3, 4, 5 };
    var array_edit = try ArrayEdit(u8).create(allocator, &.{
        ArrayReplacement(u8).init(OffsetRange.init(1, 3), &.{ 9, 9 }),
        ArrayReplacement(u8).init(OffsetRange.emptyAt(4), &.{7}),
    });
    defer array_edit.deinit();

    const applied = try apply(u8, allocator, &array_edit, &source);
    defer allocator.free(applied);
    try std.testing.expectEqualSlices(u8, &.{ 0, 9, 9, 3, 7, 4, 5 }, applied);

    var inversed = try inverse(u8, allocator, &array_edit, &source);
    defer inversed.deinit();
    const reverted = try apply(u8, allocator, &inversed, applied);
    defer allocator.free(reverted);
    try std.testing.expectEqualSlices(u8, &source, reverted);
}

test "ArrayEdit: normalize joins touching replacements" {
    const allocator = std.testing.allocator;

    var array_edit = try ArrayEdit(u8).create(allocator, &.{
        ArrayReplacement(u8).init(OffsetRange.init(0, 1), &.{ 5, 6 }),
        ArrayReplacement(u8).init(OffsetRange.init(1, 2), &.{7}),
    });
    defer array_edit.deinit();

    var normalized = try array_edit.normalize();
    defer normalized.deinit();
    try std.testing.expectEqual(@as(usize, 1), normalized.replacements.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7 }, normalized.replacements[0].newValue);
}

test "ArrayEdit: empty and delete" {
    const allocator = std.testing.allocator;

    var empty_edit = empty(u8, allocator);
    defer empty_edit.deinit();
    try std.testing.expect(empty_edit.isEmpty());

    var deleted = try delete(u8, allocator, OffsetRange.init(0, 2));
    defer deleted.deinit();
    const source = [_]u8{ 1, 2, 3 };
    const applied = try apply(u8, allocator, &deleted, &source);
    defer allocator.free(applied);
    try std.testing.expectEqualSlices(u8, &.{3}, applied);
}
