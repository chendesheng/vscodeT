// Port of `src/vs/editor/common/model/tokens/annotations.ts`.
//
// The ported subset covers set/rebase/applyEdit. The upstream textmate worker
// serialization format is not ported (the port uses its own worker protocol),
// so `ISerializedAnnotation`/serialize/deserialize are absent.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const arrays = @import("../../../../base/common/arrays.zig");
const OffsetRange = @import("../../core/ranges/offsetRange.zig").OffsetRange;
const StringEdit = @import("../../core/edits/stringEdit.zig").StringEdit;

const SignedRange = struct {
    start: isize,
    endExclusive: isize,

    fn fromOffsetRange(offset_range: OffsetRange) SignedRange {
        return .{
            .start = @intCast(offset_range.start),
            .endExclusive = @intCast(offset_range.endExclusive),
        };
    }

    fn toOffsetRange(self: SignedRange) ?OffsetRange {
        if (self.start < 0 or self.endExclusive < self.start) {
            return null;
        }
        return OffsetRange.init(@intCast(self.start), @intCast(self.endExclusive));
    }

    fn delta(self: SignedRange, offset: isize) SignedRange {
        return .{ .start = self.start + offset, .endExclusive = self.endExclusive + offset };
    }

    fn isEmpty(self: SignedRange) bool {
        return self.start == self.endExclusive;
    }

    fn intersectsOrTouches(self: SignedRange, other: SignedRange) bool {
        return self.start <= other.endExclusive and other.start <= self.endExclusive;
    }

    fn intersectionLength(self: SignedRange, other: SignedRange) isize {
        const start = @max(self.start, other.start);
        const end = @min(self.endExclusive, other.endExclusive);
        return if (end > start) end - start else 0;
    }
};

/// An annotation attached to a range of an annotated string.
pub fn AnnotatedString(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const IAnnotation = struct {
            range: OffsetRange,
            annotation: T,
        };

        pub const IAnnotationUpdate = struct {
            range: OffsetRange,
            annotation: ?T,
        };

        allocator: Allocator,
        /// Annotations are non-intersecting and contiguous in the array.
        annotations: ArrayList(IAnnotation),

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .annotations = ArrayList(IAnnotation).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.annotations.deinit();
        }

        pub fn clone(self: *const Self) !Self {
            var result = Self.init(self.allocator);
            errdefer result.deinit();
            try result.annotations.appendSlice(self.annotations.items);
            return result;
        }

        /// Set annotations for a specific range. Annotations should be sorted
        /// and non-overlapping. If the annotation value is undefined, the
        /// annotation is removed.
        pub fn setAnnotations(self: *Self, updates: []const IAnnotationUpdate) !void {
            for (updates) |annotation| {
                const start_index = self.getStartIndexOfIntersectingAnnotation(annotation.range.start);
                const end_index_exclusive = self.getEndIndexOfIntersectingAnnotation(annotation.range.endExclusive);

                if (annotation.annotation) |value| {
                    try self.replaceRange(
                        start_index,
                        end_index_exclusive - start_index,
                        &.{IAnnotation{ .range = annotation.range, .annotation = value }},
                    );
                } else {
                    try self.replaceRange(start_index, end_index_exclusive - start_index, &.{});
                }
            }
        }

        fn replaceRange(self: *Self, start: usize, count: usize, values: []const IAnnotation) !void {
            const safe_start = @min(start, self.annotations.items.len);
            const safe_count = @min(count, self.annotations.items.len - safe_start);
            try self.annotations.replaceRange(safe_start, safe_count, values);
        }

        /// Returns all annotations that intersect with the given offset range.
        pub fn getAnnotationsIntersecting(self: *const Self, offset_range: OffsetRange) ![]IAnnotation {
            const start_index = self.getStartIndexOfIntersectingAnnotation(offset_range.start);
            const end_index_exclusive = self.getEndIndexOfIntersectingAnnotation(offset_range.endExclusive);
            const safe_start = @min(start_index, self.annotations.items.len);
            const safe_end = @min(@max(end_index_exclusive, safe_start), self.annotations.items.len);
            return self.allocator.dupe(IAnnotation, self.annotations.items[safe_start..safe_end]);
        }

        fn getStartIndexOfIntersectingAnnotation(self: *const Self, offset: usize) usize {
            const Context = struct {
                annotations: []const IAnnotation,
                offset: usize,

                fn compare(context: @This(), index: usize) isize {
                    return @as(isize, @intCast(context.annotations[index].range.start)) - @as(isize, @intCast(context.offset));
                }
            };

            // Find index to the left of the offset.
            const start_index_where_to_replace = arrays.binarySearch2(
                self.annotations.items.len,
                Context{ .annotations = self.annotations.items, .offset = offset },
                Context.compare,
            );

            if (start_index_where_to_replace >= 0) {
                var start_index: usize = @intCast(start_index_where_to_replace);
                // Also include the next annotation if it ends exactly at offset.
                if (start_index < self.annotations.items.len and
                    self.annotations.items[start_index].range.endExclusive == offset and start_index > 0)
                {
                    start_index -= 1;
                }
                return start_index;
            }

            const candidate_index_signed = -(start_index_where_to_replace + 2);
            if (candidate_index_signed >= 0) {
                const candidate_index: usize = @intCast(candidate_index_signed);
                if (candidate_index < self.annotations.items.len) {
                    const candidate = self.annotations.items[candidate_index].range;
                    if (offset >= candidate.start and offset < candidate.endExclusive) {
                        return candidate_index;
                    }
                }
            }
            return @intCast(-(start_index_where_to_replace + 1));
        }

        fn getEndIndexOfIntersectingAnnotation(self: *const Self, offset: usize) usize {
            const Context = struct {
                annotations: []const IAnnotation,
                offset: usize,

                fn compare(context: @This(), index: usize) isize {
                    return @as(isize, @intCast(context.annotations[index].range.endExclusive)) - @as(isize, @intCast(context.offset));
                }
            };

            // Find index to the right of the offset.
            const end_index_where_to_replace = arrays.binarySearch2(
                self.annotations.items.len,
                Context{ .annotations = self.annotations.items, .offset = offset },
                Context.compare,
            );

            if (end_index_where_to_replace >= 0) {
                var end_index_exclusive: usize = @intCast(end_index_where_to_replace + 1);
                // Also include the next annotation if it starts exactly at offset.
                if (end_index_exclusive < self.annotations.items.len and
                    self.annotations.items[end_index_exclusive].range.start == offset)
                {
                    end_index_exclusive += 1;
                }
                return end_index_exclusive;
            }

            const candidate_index_signed = -(end_index_where_to_replace + 1);
            if (candidate_index_signed >= 0) {
                const candidate_index: usize = @intCast(candidate_index_signed);
                if (candidate_index < self.annotations.items.len) {
                    const candidate = self.annotations.items[candidate_index].range;
                    if (offset >= candidate.start and offset <= candidate.endExclusive) {
                        return @intCast(-end_index_where_to_replace);
                    }
                }
            }
            return @intCast(-(end_index_where_to_replace + 1));
        }

        /// Returns a copy of all annotations.
        pub fn getAllAnnotations(self: *const Self) ![]IAnnotation {
            return self.allocator.dupe(IAnnotation, self.annotations.items);
        }

        /// Applies a string edit to the annotated string, updating annotation
        /// ranges accordingly. Returns the annotations that were deleted
        /// (became empty) as a result of the edit.
        pub fn applyEdit(self: *Self, edit: *const StringEdit) ![]IAnnotation {
            const SignedAnnotation = struct {
                range: SignedRange,
                annotation: T,
            };

            var remaining = ArrayList(SignedAnnotation).init(self.allocator);
            defer remaining.deinit();
            try remaining.ensureTotalCapacity(self.annotations.items.len);
            for (self.annotations.items) |annotation| {
                remaining.appendAssumeCapacity(.{
                    .range = SignedRange.fromOffsetRange(annotation.range),
                    .annotation = annotation.annotation,
                });
            }

            var final_annotations = ArrayList(IAnnotation).init(self.allocator);
            errdefer final_annotations.deinit();
            var deleted_annotations = ArrayList(IAnnotation).init(self.allocator);
            errdefer deleted_annotations.deinit();

            var offset: isize = 0;

            for (edit.replacements) |replacement| {
                const replace_range = SignedRange.fromOffsetRange(replacement.replaceRange);

                // Ranges before the current edit.
                while (remaining.items.len > 0 and remaining.items[0].range.endExclusive < replace_range.start) {
                    const annotation = remaining.orderedRemove(0);
                    const moved = annotation.range.delta(offset);
                    if (!moved.isEmpty()) {
                        try final_annotations.append(.{ .range = moved.toOffsetRange() orelse OffsetRange.emptyAt(0), .annotation = annotation.annotation });
                    } else {
                        try deleted_annotations.append(.{ .range = moved.toOffsetRange() orelse OffsetRange.emptyAt(0), .annotation = annotation.annotation });
                    }
                }

                var intersecting = ArrayList(SignedAnnotation).init(self.allocator);
                defer intersecting.deinit();
                while (remaining.items.len > 0 and remaining.items[0].range.intersectsOrTouches(replace_range)) {
                    try intersecting.append(remaining.orderedRemove(0));
                }

                var i = intersecting.items.len;
                while (i > 0) {
                    i -= 1;
                    const annotation = intersecting.items[i];
                    var annotation_range = annotation.range;

                    // Inserted text extends the first intersecting annotation if
                    // the edit truly overlaps it.
                    const should_extend = i == 0 and
                        replace_range.endExclusive > annotation_range.start and
                        replace_range.start < annotation_range.endExclusive;

                    // Annotation shrinks by the overlap then grows with the new
                    // text length.
                    const overlap = annotation_range.intersectionLength(replace_range);
                    annotation_range.endExclusive += -overlap +
                        (if (should_extend) @as(isize, @intCast(replacement.newText.len)) else 0);

                    // If the annotation starts after the edit start, shift left
                    // to the edit start position.
                    const range_ahead_of_replace_range = annotation_range.start - replace_range.start;
                    if (range_ahead_of_replace_range > 0) {
                        annotation_range.start -= range_ahead_of_replace_range;
                        annotation_range.endExclusive -= range_ahead_of_replace_range;
                    }

                    // If the annotation shouldn't be extended AND it is after
                    // or on the edit start, move it after the newly inserted text.
                    if (!should_extend and range_ahead_of_replace_range >= 0) {
                        annotation_range.start += @intCast(replacement.newText.len);
                        annotation_range.endExclusive += @intCast(replacement.newText.len);
                    }

                    // Offset is added again when the annotation is taken from
                    // the queue, so remove it here.
                    const length_delta = replacement.getLengthDelta();
                    annotation_range.start -= length_delta;
                    annotation_range.endExclusive -= length_delta;

                    try remaining.insert(0, .{ .range = annotation_range, .annotation = annotation.annotation });
                }

                offset += replacement.getLengthDelta();
            }

            while (remaining.items.len > 0) {
                const annotation = remaining.orderedRemove(0);
                const moved = annotation.range.delta(offset);
                if (!moved.isEmpty()) {
                    try final_annotations.append(.{ .range = moved.toOffsetRange() orelse OffsetRange.emptyAt(0), .annotation = annotation.annotation });
                } else {
                    try deleted_annotations.append(.{ .range = moved.toOffsetRange() orelse OffsetRange.emptyAt(0), .annotation = annotation.annotation });
                }
            }

            self.annotations.deinit();
            self.annotations = final_annotations;
            return deleted_annotations.toOwnedSlice();
        }
    };
}

/// A set of annotation updates. Used to rebase annotations through edits.
pub fn AnnotationsUpdate(comptime T: type) type {
    return struct {
        const Self = @This();
        const Annotated = AnnotatedString(T);

        allocator: Allocator,
        updates: ArrayList(Annotated.IAnnotationUpdate),

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .updates = ArrayList(Annotated.IAnnotationUpdate).init(allocator),
            };
        }

        pub fn create(allocator: Allocator, initial_updates: []const Annotated.IAnnotationUpdate) !Self {
            var result = Self.init(allocator);
            errdefer result.deinit();
            try result.updates.appendSlice(initial_updates);
            return result;
        }

        pub fn deinit(self: *Self) void {
            self.updates.deinit();
        }

        pub fn annotations(self: *const Self) []const Annotated.IAnnotationUpdate {
            return self.updates.items;
        }

        pub fn rebase(self: *Self, edit: *const StringEdit) !void {
            var annotated = @import("annotations.zig").AnnotatedString(?T).init(self.allocator);
            defer annotated.deinit();

            for (self.updates.items) |update| {
                try annotated.annotations.append(.{ .range = update.range, .annotation = update.annotation });
            }

            const deleted = try annotated.applyEdit(edit);
            self.allocator.free(deleted);

            const all = try annotated.getAllAnnotations();
            defer self.allocator.free(all);

            self.updates.clearRetainingCapacity();
            try self.updates.ensureTotalCapacity(all.len);
            for (all) |annotation| {
                self.updates.appendAssumeCapacity(.{
                    .range = annotation.range,
                    .annotation = annotation.annotation,
                });
            }
        }
    };
}

test "AnnotatedString: set and get annotations" {
    const allocator = std.testing.allocator;

    var annotated = AnnotatedString(u32).init(allocator);
    defer annotated.deinit();

    try annotated.setAnnotations(&.{
        .{ .range = OffsetRange.init(0, 2), .annotation = 1 },
        .{ .range = OffsetRange.init(2, 4), .annotation = 2 },
    });

    try std.testing.expectEqual(@as(usize, 2), annotated.annotations.items.len);
    const intersecting = try annotated.getAnnotationsIntersecting(OffsetRange.init(2, 3));
    defer allocator.free(intersecting);
    try std.testing.expectEqual(@as(usize, 1), intersecting.len);

    try annotated.setAnnotations(&.{
        .{ .range = OffsetRange.init(0, 4), .annotation = null },
    });
    try std.testing.expectEqual(@as(usize, 0), annotated.annotations.items.len);
}

test "AnnotatedString: applyEdit" {
    const allocator = std.testing.allocator;
    const string_edit = @import("../../core/edits/stringEdit.zig");

    var annotated = AnnotatedString(u32).init(allocator);
    defer annotated.deinit();

    try annotated.setAnnotations(&.{
        .{ .range = OffsetRange.init(0, 3), .annotation = 1 },
        .{ .range = OffsetRange.init(6, 9), .annotation = 2 },
    });

    var edit = try string_edit.create(allocator, &.{
        string_edit.StringReplacement.replace(OffsetRange.init(1, 2), "XY"),
    });
    defer edit.deinit();

    const deleted = try annotated.applyEdit(&edit);
    defer allocator.free(deleted);

    try std.testing.expectEqual(@as(usize, 2), annotated.annotations.items.len);
    try std.testing.expectEqual(OffsetRange.init(0, 4), annotated.annotations.items[0].range);
    try std.testing.expectEqual(OffsetRange.init(7, 10), annotated.annotations.items[1].range);
}

test "AnnotationsUpdate: rebase" {
    const allocator = std.testing.allocator;
    const string_edit = @import("../../core/edits/stringEdit.zig");

    var update = try AnnotationsUpdate(u32).create(allocator, &.{
        .{ .range = OffsetRange.init(1, 2), .annotation = 5 },
    });
    defer update.deinit();

    var edit = try string_edit.create(allocator, &.{
        string_edit.StringReplacement.insert(0, "AB"),
    });
    defer edit.deinit();

    try update.rebase(&edit);
    try std.testing.expectEqual(@as(usize, 1), update.annotations().len);
    try std.testing.expectEqual(OffsetRange.init(3, 4), update.annotations()[0].range);
}
