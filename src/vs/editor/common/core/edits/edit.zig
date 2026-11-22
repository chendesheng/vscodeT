// Port of `src/vs/editor/common/core/edits/edit.ts`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;
const usizeAdd = @import("../../../../base/common/utils.zig").usizeAdd;

fn toIsize(value: usize) isize {
    return @intCast(value);
}

/// Returns the range delta (new length - replaced length) of a replacement.
pub fn replacementLengthDelta(comptime T: type, replacement: T) isize {
    return toIsize(replacement.getNewLength()) - toIsize(replacement.replaceRange.length());
}

/// Returns the range occupied by the replacement's new data.
pub fn replacementGetRangeAfterReplace(comptime T: type, replacement: T) OffsetRange {
    return OffsetRange.ofStartAndLength(replacement.replaceRange.start, replacement.getNewLength());
}

/// Returns true when a replacement replaces nothing with nothing.
pub fn replacementIsEmpty(comptime T: type, replacement: T) bool {
    return replacement.getNewLength() == 0 and replacement.replaceRange.length() == 0;
}

/// Moves a replacement by the given offset.
pub fn replacementDelta(comptime T: type, replacement: T, allocator: Allocator, offset: isize) !T {
    return replacement.slice(allocator, replacement.replaceRange.delta(offset), OffsetRange.ofLength(replacement.getNewLength()));
}

/// A set of disjoint, sorted replacements. The edit owns all memory of its
/// replacements, which is released by `deinit`.
///
/// A replacement type `T` must provide:
///   - `replaceRange: OffsetRange`
///   - `getNewLength(self: T) usize`
///   - `tryJoinTouching(self: T, allocator: Allocator, other: T) !?T`
///   - `slice(self: T, allocator: Allocator, newReplaceRange: OffsetRange, rangeInReplacement: ?OffsetRange) !T`
///   - `equals(self: T, other: T) bool`
///   - `clone(self: T, allocator: Allocator) !T`
///   - `toString(self: T, writer: *Io.Writer) !void`
pub fn BaseEdit(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        arena: std.heap.ArenaAllocator,
        replacements: []T,

        pub const Split = struct {
            e1: Self,
            e2: Self,
        };

        pub fn empty(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .arena = std.heap.ArenaAllocator.init(allocator),
                .replacements = &.{},
            };
        }

        /// Creates an edit, copying all replacements (and their data) into the edit.
        pub fn create(allocator: Allocator, replacements: []const T) !Self {
            var result = Self.empty(allocator);
            errdefer result.deinit();

            const arena_allocator = result.arena.allocator();
            result.replacements = try arena_allocator.alloc(T, replacements.len);

            var last_end_ex: isize = -1;
            for (replacements, 0..) |replacement, i| {
                if (toIsize(replacement.replaceRange.start) < last_end_ex) {
                    return error.EditsNotDisjointAndSorted;
                }
                last_end_ex = toIsize(replacement.replaceRange.endExclusive);
                result.replacements[i] = try replacement.clone(arena_allocator);
            }
            return result;
        }

        pub fn single(allocator: Allocator, replacement: T) !Self {
            return Self.create(allocator, &.{replacement});
        }

        pub fn clone(self: *const Self) !Self {
            return Self.create(self.allocator, self.replacements);
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        /// Returns true if and only if this edit and the given edit are structurally equal.
        pub fn equals(self: *const Self, other: *const Self) bool {
            if (self.replacements.len != other.replacements.len) {
                return false;
            }
            for (self.replacements, other.replacements) |a, b| {
                if (!a.equals(b)) {
                    return false;
                }
            }
            return true;
        }

        pub fn toString(self: *const Self, writer: *Io.Writer) !void {
            try writer.writeByte('[');
            for (self.replacements, 0..) |replacement, i| {
                if (i > 0) {
                    try writer.writeAll(", ");
                }
                try replacement.toString(writer);
            }
            try writer.writeByte(']');
        }

        /// Removes empty replacements and joins touching replacements.
        pub fn normalize(self: *const Self) !Self {
            var temp = std.heap.ArenaAllocator.init(self.allocator);
            defer temp.deinit();
            const temp_allocator = temp.allocator();

            var new_replacements = ArrayList(T).init(temp_allocator);
            var last_replacement: ?T = null;
            for (self.replacements) |replacement| {
                if (replacement.getNewLength() == 0 and replacement.replaceRange.length() == 0) {
                    continue;
                }
                if (last_replacement) |last| {
                    if (last.replaceRange.endExclusive == replacement.replaceRange.start) {
                        if (try last.tryJoinTouching(temp_allocator, replacement)) |joined| {
                            last_replacement = joined;
                            continue;
                        }
                    }
                }

                if (last_replacement) |last| {
                    try new_replacements.append(last);
                }
                last_replacement = replacement;
            }

            if (last_replacement) |last| {
                try new_replacements.append(last);
            }
            return Self.create(self.allocator, new_replacements.items);
        }

        /// Combines two edits into one with the same effect.
        pub fn compose(self: *const Self, other: *const Self) !Self {
            var edits1 = try self.normalize();
            defer edits1.deinit();
            var edits2 = try other.normalize();
            defer edits2.deinit();

            if (edits1.isEmpty()) {
                return edits2.clone();
            }
            if (edits2.isEmpty()) {
                return edits1.clone();
            }

            var temp = std.heap.ArenaAllocator.init(self.allocator);
            defer temp.deinit();
            const temp_allocator = temp.allocator();

            var edit1_queue = ArrayList(T).init(temp_allocator);
            try edit1_queue.appendSlice(edits1.replacements);
            var result = ArrayList(T).init(temp_allocator);

            var edit1_to_edit2: isize = 0;

            for (edits2.replacements) |r2| {
                // Copy over edit1 unmodified until it touches edit2.
                while (edit1_queue.items.len > 0) {
                    const r1 = edit1_queue.items[0];
                    if (toIsize(r1.replaceRange.start) + edit1_to_edit2 + toIsize(r1.getNewLength()) >= toIsize(r2.replaceRange.start)) {
                        break;
                    }
                    _ = edit1_queue.orderedRemove(0);

                    try result.append(r1);
                    edit1_to_edit2 += replacementLengthDelta(T, r1);
                }

                const first_edit1_to_edit2 = edit1_to_edit2;
                var first_intersecting: ?T = null;
                var last_intersecting: ?T = null;

                while (edit1_queue.items.len > 0) {
                    const r1 = edit1_queue.items[0];
                    if (toIsize(r1.replaceRange.start) + edit1_to_edit2 > toIsize(r2.replaceRange.endExclusive)) {
                        break;
                    }

                    if (first_intersecting == null) {
                        first_intersecting = r1;
                    }
                    last_intersecting = r1;
                    _ = edit1_queue.orderedRemove(0);

                    edit1_to_edit2 += replacementLengthDelta(T, r1);
                }

                if (first_intersecting == null) {
                    try result.append(try replacementDelta(T, r2, temp_allocator, -edit1_to_edit2));
                } else {
                    const first = first_intersecting.?;
                    const new_replace_range_start = @min(toIsize(first.replaceRange.start), toIsize(r2.replaceRange.start) - first_edit1_to_edit2);

                    const prefix_length = toIsize(r2.replaceRange.start) - (toIsize(first.replaceRange.start) + first_edit1_to_edit2);
                    if (prefix_length > 0) {
                        const prefix = try first.slice(
                            temp_allocator,
                            OffsetRange.emptyAt(@intCast(new_replace_range_start)),
                            OffsetRange.init(0, @intCast(prefix_length)),
                        );
                        try result.append(prefix);
                    }

                    const last = last_intersecting orelse return error.InvariantViolation;
                    const suffix_length = (toIsize(last.replaceRange.endExclusive) + edit1_to_edit2) - toIsize(r2.replaceRange.endExclusive);
                    if (suffix_length > 0) {
                        const e = try last.slice(
                            temp_allocator,
                            OffsetRange.ofStartAndLength(last.replaceRange.endExclusive, 0),
                            OffsetRange.init(@intCast(toIsize(last.getNewLength()) - suffix_length), last.getNewLength()),
                        );
                        try edit1_queue.insert(0, e);
                        edit1_to_edit2 -= replacementLengthDelta(T, e);
                    }

                    const new_replace_range = OffsetRange.init(
                        @intCast(new_replace_range_start),
                        @intCast(toIsize(r2.replaceRange.endExclusive) - edit1_to_edit2),
                    );
                    const middle = try r2.slice(temp_allocator, new_replace_range, OffsetRange.ofLength(r2.getNewLength()));
                    try result.append(middle);
                }
            }

            while (edit1_queue.items.len > 0) {
                try result.append(edit1_queue.orderedRemove(0));
            }

            var composed = try Self.create(self.allocator, result.items);
            defer composed.deinit();
            return composed.normalize();
        }

        /// Splits the edit into two edits, where replacements for which
        /// `should_be_in_e1` returns true go into `e1` and all others into `e2`.
        pub fn decomposeSplit(
            self: *const Self,
            context: anytype,
            comptime should_be_in_e1: fn (@TypeOf(context), T) bool,
        ) !Split {
            var temp = std.heap.ArenaAllocator.init(self.allocator);
            defer temp.deinit();
            const temp_allocator = temp.allocator();

            var e1 = ArrayList(T).init(temp_allocator);
            var e2 = ArrayList(T).init(temp_allocator);

            var e2_delta: isize = 0;
            for (self.replacements) |replacement| {
                if (should_be_in_e1(context, replacement)) {
                    try e1.append(replacement);
                    e2_delta += replacementLengthDelta(T, replacement);
                } else {
                    try e2.append(try replacement.slice(
                        temp_allocator,
                        replacement.replaceRange.delta(e2_delta),
                        OffsetRange.ofLength(replacement.getNewLength()),
                    ));
                }
            }

            var result: Split = undefined;
            result.e1 = try Self.create(self.allocator, e1.items);
            errdefer result.e1.deinit();
            result.e2 = try Self.create(self.allocator, e2.items);
            return result;
        }

        /// Returns the range of each replacement in the applied value.
        pub fn getNewRanges(self: *const Self, allocator: Allocator) ![]OffsetRange {
            const ranges = try allocator.alloc(OffsetRange, self.replacements.len);
            errdefer allocator.free(ranges);

            var offset: isize = 0;
            for (self.replacements, 0..) |replacement, i| {
                ranges[i] = OffsetRange.ofStartAndLength(usizeAdd(replacement.replaceRange.start, offset), replacement.getNewLength());
                offset += replacementLengthDelta(T, replacement);
            }
            return ranges;
        }

        pub fn getJoinedReplaceRange(self: *const Self) ?OffsetRange {
            if (self.replacements.len == 0) {
                return null;
            }
            return self.replacements[0].replaceRange.join(self.replacements[self.replacements.len - 1].replaceRange);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.replacements.len == 0;
        }

        pub fn getLengthDelta(self: *const Self) isize {
            var result: isize = 0;
            for (self.replacements) |replacement| {
                result += replacementLengthDelta(T, replacement);
            }
            return result;
        }

        pub fn getNewDataLength(self: *const Self, data_length: usize) isize {
            return toIsize(data_length) + self.getLengthDelta();
        }

        pub fn applyToOffset(self: *const Self, original_offset: usize) usize {
            var accumulated_delta: isize = 0;
            for (self.replacements) |replacement| {
                if (replacement.replaceRange.start <= original_offset) {
                    if (original_offset < replacement.replaceRange.endExclusive) {
                        // the offset is in the replaced range
                        return usizeAdd(replacement.replaceRange.start, accumulated_delta);
                    }
                    accumulated_delta += replacementLengthDelta(T, replacement);
                } else {
                    break;
                }
            }
            return usizeAdd(original_offset, accumulated_delta);
        }

        pub fn applyToOffsetRange(self: *const Self, original_range: OffsetRange) OffsetRange {
            return OffsetRange.init(
                self.applyToOffset(original_range.start),
                self.applyToOffset(original_range.endExclusive),
            );
        }

        pub fn applyInverseToOffset(self: *const Self, post_edits_offset: usize) usize {
            var accumulated_delta: isize = 0;
            const post_offset: isize = toIsize(post_edits_offset);
            for (self.replacements) |replacement| {
                const edit_length = toIsize(replacement.getNewLength());
                if (toIsize(replacement.replaceRange.start) <= post_offset - accumulated_delta) {
                    if (post_offset - accumulated_delta < toIsize(replacement.replaceRange.start) + edit_length) {
                        // the offset is in the replaced range
                        return replacement.replaceRange.start;
                    }
                    accumulated_delta += edit_length - toIsize(replacement.replaceRange.length());
                } else {
                    break;
                }
            }
            return usizeAdd(post_edits_offset, -accumulated_delta);
        }

        /// Returns null if the original offset is within an edit.
        pub fn applyToOffsetOrUndefined(self: *const Self, original_offset: usize) ?usize {
            var accumulated_delta: isize = 0;
            for (self.replacements) |replacement| {
                if (replacement.replaceRange.start <= original_offset) {
                    if (original_offset < replacement.replaceRange.endExclusive) {
                        // the offset is in the replaced range
                        return null;
                    }
                    accumulated_delta += replacementLengthDelta(T, replacement);
                } else {
                    break;
                }
            }
            return usizeAdd(original_offset, accumulated_delta);
        }

        /// Returns null if the original range touches an edit.
        pub fn applyToOffsetRangeOrUndefined(self: *const Self, original_range: OffsetRange) ?OffsetRange {
            const start = self.applyToOffsetOrUndefined(original_range.start) orelse return null;
            const end = self.applyToOffsetOrUndefined(original_range.endExclusive) orelse return null;
            return OffsetRange.init(start, end);
        }
    };
}

/// A concrete edit. Same as `BaseEdit`.
pub fn Edit(comptime T: type) type {
    return BaseEdit(T);
}

/// A replacement that only records a new length and an annotation.
pub fn AnnotationReplacement(comptime TAnnotation: type) type {
    return struct {
        const Self = @This();

        replaceRange: OffsetRange,
        newLength: usize,
        annotation: TAnnotation,

        pub fn init(range: OffsetRange, new_length: usize, annotation: TAnnotation) Self {
            return .{ .replaceRange = range, .newLength = new_length, .annotation = annotation };
        }

        pub fn getNewLength(self: Self) usize {
            return self.newLength;
        }

        pub fn equals(self: Self, other: Self) bool {
            return self.replaceRange.equals(other.replaceRange) and
                self.newLength == other.newLength and
                std.meta.eql(self.annotation, other.annotation);
        }

        pub fn tryJoinTouching(self: Self, allocator: Allocator, other: Self) !?Self {
            _ = allocator;
            if (!std.meta.eql(self.annotation, other.annotation)) {
                return null;
            }
            return Self.init(
                try self.replaceRange.joinRightTouching(other.replaceRange),
                self.newLength + other.newLength,
                self.annotation,
            );
        }

        pub fn slice(self: Self, allocator: Allocator, range: OffsetRange, range_in_replacement: ?OffsetRange) !Self {
            _ = allocator;
            return Self.init(
                range,
                if (range_in_replacement) |r| r.length() else self.newLength,
                self.annotation,
            );
        }

        pub fn clone(self: Self, allocator: Allocator) !Self {
            _ = allocator;
            return self;
        }

        pub fn getLengthDelta(self: Self) isize {
            return replacementLengthDelta(Self, self);
        }

        pub fn delta(self: Self, allocator: Allocator, offset: isize) !Self {
            return replacementDelta(Self, self, allocator, offset);
        }

        pub fn getRangeAfterReplace(self: Self) OffsetRange {
            return replacementGetRangeAfterReplace(Self, self);
        }

        pub fn isEmpty(self: Self) bool {
            return replacementIsEmpty(Self, self);
        }

        pub fn toString(self: Self, writer: *Io.Writer) !void {
            try writer.print("{{ ", .{});
            try self.replaceRange.toString(writer);
            try writer.print(" -> {d} }}", .{self.getNewLength()});
        }
    };
}

test "Edit: normalize joins touching replacements" {
    const allocator = std.testing.allocator;

    const Replacement = AnnotationReplacement(u8);
    var edit = try Edit(Replacement).create(allocator, &.{
        Replacement.init(OffsetRange.init(0, 1), 2, 'a'),
        Replacement.init(OffsetRange.init(1, 2), 3, 'a'),
        Replacement.init(OffsetRange.init(3, 3), 0, 'a'),
    });
    defer edit.deinit();

    var normalized = try edit.normalize();
    defer normalized.deinit();

    try std.testing.expectEqual(1, normalized.replacements.len);
    try std.testing.expectEqual(OffsetRange.init(0, 2), normalized.replacements[0].replaceRange);
    try std.testing.expectEqual(5, normalized.replacements[0].newLength);
}

test "Edit: normalize keeps non-joinable touching replacements" {
    const allocator = std.testing.allocator;

    const Replacement = AnnotationReplacement(u8);
    var edit = try Edit(Replacement).create(allocator, &.{
        Replacement.init(OffsetRange.init(0, 1), 2, 'a'),
        Replacement.init(OffsetRange.init(1, 2), 3, 'b'),
    });
    defer edit.deinit();

    var normalized = try edit.normalize();
    defer normalized.deinit();
    try std.testing.expectEqual(2, normalized.replacements.len);
}

test "Edit: compose" {
    const allocator = std.testing.allocator;
    const Replacement = AnnotationReplacement(u8);

    var e1 = try Edit(Replacement).create(allocator, &.{
        Replacement.init(OffsetRange.init(1, 3), 4, 'a'),
    });
    defer e1.deinit();

    var e2 = try Edit(Replacement).create(allocator, &.{
        Replacement.init(OffsetRange.init(0, 0), 1, 'b'),
    });
    defer e2.deinit();

    var composed = try e1.compose(&e2);
    defer composed.deinit();
    try std.testing.expectEqual(2, composed.replacements.len);
    try std.testing.expectEqual(OffsetRange.init(0, 0), composed.replacements[0].replaceRange);
    try std.testing.expectEqual(OffsetRange.init(1, 3), composed.replacements[1].replaceRange);
}

test "Edit: compose empty" {
    const allocator = std.testing.allocator;
    const Replacement = AnnotationReplacement(u8);

    var e1 = try Edit(Replacement).create(allocator, &.{
        Replacement.init(OffsetRange.init(1, 3), 4, 'a'),
    });
    defer e1.deinit();

    var empty = Edit(Replacement).empty(allocator);
    defer empty.deinit();

    var composed = try e1.compose(&empty);
    defer composed.deinit();
    try std.testing.expect(composed.equals(&e1));
}

test "Edit: offset mapping" {
    const allocator = std.testing.allocator;
    const Replacement = AnnotationReplacement(u8);

    var edit = try Edit(Replacement).create(allocator, &.{
        Replacement.init(OffsetRange.init(2, 4), 1, 'a'),
        Replacement.init(OffsetRange.init(6, 6), 3, 'a'),
    });
    defer edit.deinit();

    try std.testing.expectEqual(2, edit.getLengthDelta());
    try std.testing.expectEqual(0, edit.applyToOffset(0));
    try std.testing.expectEqual(2, edit.applyToOffset(2));
    try std.testing.expectEqual(2, edit.applyToOffset(3));
    try std.testing.expectEqual(4, edit.applyToOffset(5));
    try std.testing.expectEqual(9, edit.getNewDataLength(7));
    try std.testing.expect(edit.applyToOffsetOrUndefined(3) == null);
    try std.testing.expectEqual(3, edit.applyToOffsetOrUndefined(4).?);
    try std.testing.expectEqual(OffsetRange.init(0, 3), edit.applyToOffsetRange(OffsetRange.init(0, 4)));
    try std.testing.expectEqual(7, edit.applyInverseToOffset(9));
}

test "Edit: decomposeSplit" {
    const allocator = std.testing.allocator;
    const Replacement = AnnotationReplacement(u8);

    const Context = struct {
        fn predicate(_: void, replacement: Replacement) bool {
            return replacement.replaceRange.start < 3;
        }
    };

    var edit = try Edit(Replacement).create(allocator, &.{
        Replacement.init(OffsetRange.init(0, 1), 5, 'a'),
        Replacement.init(OffsetRange.init(3, 4), 2, 'a'),
    });
    defer edit.deinit();

    var split = try edit.decomposeSplit({}, Context.predicate);
    defer split.e1.deinit();
    defer split.e2.deinit();

    try std.testing.expectEqual(1, split.e1.replacements.len);
    try std.testing.expectEqual(1, split.e2.replacements.len);
    try std.testing.expectEqual(OffsetRange.init(0, 1), split.e1.replacements[0].replaceRange);
    try std.testing.expectEqual(OffsetRange.init(7, 8), split.e2.replacements[0].replaceRange);
}

test "Edit: getNewRanges and joined range" {
    const allocator = std.testing.allocator;
    const Replacement = AnnotationReplacement(u8);

    var edit = try Edit(Replacement).create(allocator, &.{
        Replacement.init(OffsetRange.init(1, 3), 4, 'a'),
        Replacement.init(OffsetRange.init(5, 6), 0, 'a'),
    });
    defer edit.deinit();

    const ranges = try edit.getNewRanges(allocator);
    defer allocator.free(ranges);
    try std.testing.expectEqual(2, ranges.len);
    try std.testing.expectEqual(OffsetRange.init(1, 5), ranges[0]);
    try std.testing.expectEqual(OffsetRange.init(7, 7), ranges[1]);
    try std.testing.expectEqual(OffsetRange.init(1, 6), edit.getJoinedReplaceRange().?);
}

test "Edit: sorted and disjoint invariant" {
    const allocator = std.testing.allocator;
    const Replacement = AnnotationReplacement(u8);

    try std.testing.expectError(
        error.EditsNotDisjointAndSorted,
        Edit(Replacement).create(allocator, &.{
            Replacement.init(OffsetRange.init(2, 3), 0, 'a'),
            Replacement.init(OffsetRange.init(1, 2), 0, 'a'),
        }),
    );
}
