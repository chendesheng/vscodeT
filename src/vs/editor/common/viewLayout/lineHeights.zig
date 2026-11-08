// Port of `src/vs/editor/common/viewLayout/lineHeights.ts`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const binarySearch2 = @import("../../../base/common/arrays.zig").binarySearch2;

/// Sentinel for `Infinity` in `_invalidIndex`.
const INVALID_INDEX: isize = std.math.maxInt(isize);

const PendingChangeKind = enum {
    InsertOrChange,
    Remove,
    LinesDeleted,
    LinesInserted,
};

const PendingChange = union(PendingChangeKind) {
    InsertOrChange: struct {
        decorationId: []const u8,
        startLineNumber: usize,
        endLineNumber: usize,
        lineHeight: f64,
    },
    Remove: struct {
        decorationId: []const u8,
    },
    LinesDeleted: struct {
        fromLineNumber: usize,
        toLineNumber: usize,
    },
    LinesInserted: struct {
        fromLineNumber: usize,
        toLineNumber: usize,
    },
};

/// `Math.round` semantics: rounds half towards positive infinity.
fn jsRound(value: f64) f64 {
    return @floor(value + 0.5);
}

pub const CustomLine = struct {
    decorationId: []const u8,
    index: isize,
    lineNumber: usize,
    specialHeight: f64,
    prefixSum: f64,
    maximumSpecialHeight: f64,
    deleted: bool,

    pub fn init(
        decorationId: []const u8,
        index: isize,
        lineNumber: usize,
        specialHeight: f64,
        prefixSum: f64,
    ) CustomLine {
        return .{
            .decorationId = decorationId,
            .index = index,
            .lineNumber = lineNumber,
            .specialHeight = jsRound(specialHeight),
            .prefixSum = prefixSum,
            .maximumSpecialHeight = jsRound(specialHeight),
            .deleted = false,
        };
    }
};

pub const CustomLineHeightData = struct {
    decorationId: []const u8,
    startLineNumber: usize,
    endLineNumber: usize,
    lineHeight: f64,
};

/// Maps a decoration id onto all the custom lines it produced. Upstream uses an
/// `ArrayMap`; the lists own their buffers, which `remove`/`clear` hand back or
/// release.
const ArrayMap = struct {
    allocator: Allocator,
    map: std.StringHashMap(ArrayList(*CustomLine)),

    fn init(allocator: Allocator) ArrayMap {
        return .{ .allocator = allocator, .map = std.StringHashMap(ArrayList(*CustomLine)).init(allocator) };
    }

    fn deinit(self: *ArrayMap) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit();
        self.map.deinit();
    }

    fn add(self: *ArrayMap, key: []const u8, value: *CustomLine) !void {
        const entry = try self.map.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = ArrayList(*CustomLine).init(self.allocator);
        }
        try entry.value_ptr.append(value);
    }

    fn get(self: *const ArrayMap, key: []const u8) ?[]const *CustomLine {
        const list = self.map.get(key) orelse return null;
        return list.items;
    }

    /// Removes `key` and returns its owned list, which the caller must free.
    fn remove(self: *ArrayMap, key: []const u8) ?[]*CustomLine {
        const entry = self.map.fetchRemove(key) orelse return null;
        var list = entry.value;
        return list.toOwnedSlice() catch null;
    }

    fn clear(self: *ArrayMap) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit();
        self.map.clearRetainingCapacity();
    }
};

/// Manages line heights in the editor with support for custom line heights from
/// decorations.
///
/// Line heights are stored in a sorted array for efficient binary search
/// operations. Each line with a custom height is represented by a
/// `CustomLine`, which tracks its special height, accumulated height prefix sum
/// and associated decoration id.
///
/// The class optimises by:
/// - using binary search to locate lines in the ordered array
/// - batching updates through a pending changes mechanism
/// - computing prefix sums for O(1) accumulated height lookup
/// - tracking the maximum height for lines with multiple decorations
/// - handling document changes (line insertions and deletions) by shifting line
///   numbers and prefix sums of all affected lines
///
/// All query operations commit pending changes first, so results are always
/// consistent. Custom line heights are tracked by decoration id.
pub const LineHeightsManager = struct {
    allocator: Allocator,
    _decorationIDToCustomLine: ArrayMap,
    _orderedCustomLines: ArrayList(*CustomLine),
    _pendingChanges: ArrayList(PendingChange),
    _invalidIndex: isize,
    _defaultLineHeight: f64,
    _hasPending: bool,
    /// Owns every `CustomLine` ever allocated, so they can all be freed in one
    /// sweep; upstream relies on the garbage collector here.
    _allocatedCustomLines: ArrayList(*CustomLine),
    /// Owns the decoration id strings referenced by pending changes and
    /// `CustomLine` instances.
    _internedDecorations: std.StringHashMap(void),

    pub fn init(allocator: Allocator, default_line_height: f64, customLineHeightData: []const CustomLineHeightData) !LineHeightsManager {
        var self = LineHeightsManager{
            .allocator = allocator,
            ._decorationIDToCustomLine = ArrayMap.init(allocator),
            ._orderedCustomLines = ArrayList(*CustomLine).init(allocator),
            ._pendingChanges = ArrayList(PendingChange).init(allocator),
            ._invalidIndex = INVALID_INDEX,
            ._defaultLineHeight = default_line_height,
            ._hasPending = false,
            ._allocatedCustomLines = ArrayList(*CustomLine).init(allocator),
            ._internedDecorations = std.StringHashMap(void).init(allocator),
        };
        errdefer self.deinit();
        for (customLineHeightData) |data| {
            try self.insertOrChangeCustomLineHeight(
                data.decorationId,
                data.startLineNumber,
                data.endLineNumber,
                data.lineHeight,
            );
        }
        return self;
    }

    pub fn deinit(self: *LineHeightsManager) void {
        for (self._allocatedCustomLines.items) |custom_line| self.allocator.destroy(custom_line);
        self._allocatedCustomLines.deinit();
        self._orderedCustomLines.deinit();
        self._pendingChanges.deinit();
        self._decorationIDToCustomLine.deinit();
        var it = self._internedDecorations.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self._internedDecorations.deinit();
    }

    pub fn defaultLineHeight(self: *const LineHeightsManager) f64 {
        return self._defaultLineHeight;
    }

    pub fn setDefaultLineHeight(self: *LineHeightsManager, default_line_height: f64) void {
        self._defaultLineHeight = default_line_height;
    }

    /// Returns a stable, manager-owned copy of `decoration_id`.
    fn intern(self: *LineHeightsManager, decoration_id: []const u8) ![]const u8 {
        if (self._internedDecorations.getKey(decoration_id)) |existing| return existing;
        const owned = try self.allocator.dupe(u8, decoration_id);
        errdefer self.allocator.free(owned);
        try self._internedDecorations.put(owned, {});
        return owned;
    }

    fn newCustomLine(
        self: *LineHeightsManager,
        decoration_id: []const u8,
        index: isize,
        line_number: usize,
        line_height: f64,
        prefix_sum: f64,
    ) !*CustomLine {
        const custom_line = try self.allocator.create(CustomLine);
        errdefer self.allocator.destroy(custom_line);
        custom_line.* = CustomLine.init(decoration_id, index, line_number, line_height, prefix_sum);
        try self._allocatedCustomLines.append(custom_line);
        return custom_line;
    }

    pub fn removeCustomLineHeight(self: *LineHeightsManager, decorationID: []const u8) !void {
        const owned = try self.intern(decorationID);
        try self._pendingChanges.append(.{ .Remove = .{ .decorationId = owned } });
        self._hasPending = true;
    }

    pub fn insertOrChangeCustomLineHeight(
        self: *LineHeightsManager,
        decorationId: []const u8,
        startLineNumber: usize,
        endLineNumber: usize,
        lineHeight: f64,
    ) !void {
        const owned = try self.intern(decorationId);
        try self._pendingChanges.append(.{ .InsertOrChange = .{
            .decorationId = owned,
            .startLineNumber = startLineNumber,
            .endLineNumber = endLineNumber,
            .lineHeight = lineHeight,
        } });
        self._hasPending = true;
    }

    pub fn heightForLineNumber(self: *LineHeightsManager, lineNumber: usize) !f64 {
        try self.commit();
        const search_index = self.binarySearchOverOrderedCustomLinesArray(lineNumber);
        if (search_index >= 0) {
            return self._orderedCustomLines.items[@intCast(search_index)].maximumSpecialHeight;
        }
        return self._defaultLineHeight;
    }

    pub fn getAccumulatedLineHeightsIncludingLineNumber(self: *LineHeightsManager, lineNumber: usize) !f64 {
        try self.commit();
        const search_index = self.binarySearchOverOrderedCustomLinesArray(lineNumber);
        if (search_index >= 0) {
            const custom_line = self._orderedCustomLines.items[@intCast(search_index)];
            return custom_line.prefixSum + custom_line.maximumSpecialHeight;
        }
        if (search_index == -1) {
            return self._defaultLineHeight * @as(f64, @floatFromInt(lineNumber));
        }
        const modified_index: usize = @intCast(-(search_index + 1));
        const previous_special_line = self._orderedCustomLines.items[modified_index - 1];
        return previous_special_line.prefixSum +
            previous_special_line.maximumSpecialHeight +
            self._defaultLineHeight * @as(f64, @floatFromInt(lineNumber - previous_special_line.lineNumber));
    }

    pub fn onLinesDeleted(self: *LineHeightsManager, fromLineNumber: usize, toLineNumber: usize) !void {
        try self._pendingChanges.append(.{ .LinesDeleted = .{
            .fromLineNumber = fromLineNumber,
            .toLineNumber = toLineNumber,
        } });
        self._hasPending = true;
    }

    pub fn onLinesInserted(self: *LineHeightsManager, fromLineNumber: usize, toLineNumber: usize) !void {
        try self._pendingChanges.append(.{ .LinesInserted = .{
            .fromLineNumber = fromLineNumber,
            .toLineNumber = toLineNumber,
        } });
        self._hasPending = true;
    }

    pub fn hasPendingChanges(self: *const LineHeightsManager) bool {
        return self._hasPending;
    }

    pub fn commit(self: *LineHeightsManager) !void {
        if (!self._hasPending) return;
        const changes = self._pendingChanges;
        self._pendingChanges = ArrayList(PendingChange).init(self.allocator);
        defer changes.deinit();
        self._hasPending = false;

        var staged_inserts = ArrayList(*CustomLine).init(self.allocator);
        defer staged_inserts.deinit();
        var staged_id_map = ArrayMap.init(self.allocator);
        defer staged_id_map.deinit();

        for (changes.items) |change| {
            switch (change) {
                .Remove => |c| try self.doRemoveCustomLineHeight(c.decorationId, &staged_id_map),
                .InsertOrChange => |c| try self.doInsertOrChangeCustomLineHeight(
                    c.decorationId,
                    c.startLineNumber,
                    c.endLineNumber,
                    c.lineHeight,
                    &staged_inserts,
                    &staged_id_map,
                ),
                .LinesDeleted => |c| {
                    try self.flushStagedDecorationChanges(&staged_inserts, &staged_id_map);
                    try self.doLinesDeleted(c.fromLineNumber, c.toLineNumber);
                },
                .LinesInserted => |c| {
                    try self.flushStagedDecorationChanges(&staged_inserts, &staged_id_map);
                    try self.doLinesInserted(c.fromLineNumber, c.toLineNumber, &staged_inserts, &staged_id_map);
                },
            }
        }
        try self.flushStagedDecorationChanges(&staged_inserts, &staged_id_map);
    }

    fn doRemoveCustomLineHeight(
        self: *LineHeightsManager,
        decorationID: []const u8,
        stagedIdMap: *ArrayMap,
    ) !void {
        if (self._decorationIDToCustomLine.remove(decorationID)) |custom_lines| {
            for (custom_lines) |custom_line| {
                custom_line.deleted = true;
                self._invalidIndex = @min(self._invalidIndex, custom_line.index);
            }
            self.allocator.free(custom_lines);
        }
        if (stagedIdMap.remove(decorationID)) |staged_lines| {
            for (staged_lines) |line| line.deleted = true;
            self.allocator.free(staged_lines);
        }
    }

    fn doInsertOrChangeCustomLineHeight(
        self: *LineHeightsManager,
        decorationId: []const u8,
        startLineNumber: usize,
        endLineNumber: usize,
        lineHeight: f64,
        stagedInserts: *ArrayList(*CustomLine),
        stagedIdMap: *ArrayMap,
    ) !void {
        try self.doRemoveCustomLineHeight(decorationId, stagedIdMap);
        var line_number = startLineNumber;
        while (line_number <= endLineNumber) : (line_number += 1) {
            const custom_line = try self.newCustomLine(decorationId, -1, line_number, lineHeight, 0);
            try stagedInserts.append(custom_line);
            try stagedIdMap.add(decorationId, custom_line);
        }
    }

    fn flushStagedDecorationChanges(
        self: *LineHeightsManager,
        stagedInserts: *ArrayList(*CustomLine),
        stagedIdMap: *ArrayMap,
    ) !void {
        if (stagedInserts.items.len == 0 and self._invalidIndex == INVALID_INDEX) return;

        for (stagedInserts.items) |pending_change| {
            if (pending_change.deleted) continue;
            const candidate = self.binarySearchOverOrderedCustomLinesArray(pending_change.lineNumber);
            const insertion_index: isize = if (candidate >= 0) candidate else -(candidate + 1);
            try self._orderedCustomLines.insert(@intCast(insertion_index), pending_change);
            self._invalidIndex = @min(self._invalidIndex, insertion_index);
        }
        stagedInserts.clearRetainingCapacity();
        stagedIdMap.clear();
        if (self._invalidIndex == INVALID_INDEX) return;

        var new_ordered = ArrayList(*CustomLine).init(self.allocator);
        var new_ordered_assigned = false;
        defer if (!new_ordered_assigned) new_ordered.deinit();
        var new_id_map = ArrayMap.init(self.allocator);
        var new_id_map_assigned = false;
        defer if (!new_id_map_assigned) new_id_map.deinit();

        const items = self._orderedCustomLines.items;
        const invalid_index: usize = @intCast(self._invalidIndex);

        for (items[0..invalid_index]) |custom_line| {
            try new_ordered.append(custom_line);
            try new_id_map.add(custom_line.decorationId, custom_line);
        }

        var number_of_deletions: isize = 0;
        var previous_special_line: ?*CustomLine = if (invalid_index > 0) new_ordered.items[invalid_index - 1] else null;
        var i = invalid_index;
        while (i < items.len) : (i += 1) {
            const custom_line = items[i];
            if (custom_line.deleted) {
                number_of_deletions += 1;
                continue;
            }
            custom_line.index = @as(isize, @intCast(i)) - number_of_deletions;
            if (previous_special_line != null and previous_special_line.?.lineNumber == custom_line.lineNumber) {
                custom_line.maximumSpecialHeight = previous_special_line.?.maximumSpecialHeight;
                custom_line.prefixSum = previous_special_line.?.prefixSum;
            } else {
                var maximum_special_height = custom_line.specialHeight;
                var j = i;
                while (j < items.len) : (j += 1) {
                    const next_special_line = items[j];
                    if (next_special_line.deleted) continue;
                    if (next_special_line.lineNumber != custom_line.lineNumber) break;
                    maximum_special_height = @max(maximum_special_height, next_special_line.specialHeight);
                }
                custom_line.maximumSpecialHeight = maximum_special_height;

                const prefix_sum = if (previous_special_line) |previous|
                    previous.prefixSum +
                        previous.maximumSpecialHeight +
                        self._defaultLineHeight * @as(f64, @floatFromInt(custom_line.lineNumber - previous.lineNumber - 1))
                else
                    self._defaultLineHeight * @as(f64, @floatFromInt(custom_line.lineNumber - 1));
                custom_line.prefixSum = prefix_sum;
            }
            previous_special_line = custom_line;
            try new_ordered.append(custom_line);
            try new_id_map.add(custom_line.decorationId, custom_line);
        }

        self._orderedCustomLines.deinit();
        self._orderedCustomLines = new_ordered;
        new_ordered_assigned = true;
        self._decorationIDToCustomLine.deinit();
        self._decorationIDToCustomLine = new_id_map;
        new_id_map_assigned = true;
        self._invalidIndex = INVALID_INDEX;
    }

    /// Translates a "not found" binary search result into the index the range
    /// starts at. Mirrors the `-(candidate + 1)` / "last element" logic.
    fn deletionIndexAfterSearch(candidate: isize, number_of_custom_lines: usize) isize {
        if (candidate == -(@as(isize, @intCast(number_of_custom_lines)) + 1) and candidate != -1) {
            return @as(isize, @intCast(number_of_custom_lines)) - 1;
        }
        return -(candidate + 1);
    }

    fn doLinesDeleted(self: *LineHeightsManager, fromLineNumber: usize, toLineNumber: usize) !void {
        const delete_count = toLineNumber - fromLineNumber + 1;
        const items = self._orderedCustomLines.items;
        const number_of_custom_lines = items.len;

        const candidate_start = self.binarySearchOverOrderedCustomLinesArray(fromLineNumber);
        var start_index: isize = undefined;
        if (candidate_start >= 0) {
            start_index = candidate_start;
            var i = candidate_start - 1;
            while (i >= 0) : (i -= 1) {
                if (items[@intCast(i)].lineNumber == fromLineNumber) {
                    start_index -= 1;
                } else break;
            }
        } else {
            start_index = deletionIndexAfterSearch(candidate_start, number_of_custom_lines);
        }

        const candidate_end = self.binarySearchOverOrderedCustomLinesArray(toLineNumber);
        var end_index: isize = undefined;
        if (candidate_end >= 0) {
            end_index = candidate_end;
            var i = candidate_end + 1;
            while (i < @as(isize, @intCast(number_of_custom_lines))) : (i += 1) {
                if (items[@intCast(i)].lineNumber == toLineNumber) {
                    end_index += 1;
                } else break;
            }
        } else {
            end_index = deletionIndexAfterSearch(candidate_end, number_of_custom_lines);
        }

        const end_bigger_than_start = end_index > start_index;
        const end_equals_start_and_covers =
            end_index == start_index and
            start_index >= 0 and start_index < @as(isize, @intCast(number_of_custom_lines)) and
            items[@intCast(start_index)].lineNumber >= fromLineNumber and
            items[@intCast(start_index)].lineNumber <= toLineNumber;

        if (end_bigger_than_start or end_equals_start_and_covers) {
            var maximum_special_height_on_deleted_interval: f64 = 0;
            var i = start_index;
            while (i <= end_index) : (i += 1) {
                maximum_special_height_on_deleted_interval = @max(
                    maximum_special_height_on_deleted_interval,
                    items[@intCast(i)].maximumSpecialHeight,
                );
            }

            const prefix_sum_on_deleted_interval: f64 = if (start_index > 0) blk: {
                const previous_special_line = items[@intCast(start_index - 1)];
                break :blk previous_special_line.prefixSum +
                    previous_special_line.maximumSpecialHeight +
                    self._defaultLineHeight * lineDelta(fromLineNumber, previous_special_line.lineNumber, 1);
            } else if (fromLineNumber > 0)
                lineDelta(fromLineNumber, 0, 1) * self._defaultLineHeight
            else
                0;

            const first_special_line_deleted = items[@intCast(start_index)];
            const last_special_line_deleted = items[@intCast(end_index)];
            const after_index: usize = @intCast(end_index + 1);
            const first_special_line_after: ?*CustomLine = if (after_index < items.len) items[after_index] else null;
            const height_of_first_line_after_deletion: f64 = if (first_special_line_after != null and first_special_line_after.?.lineNumber == toLineNumber + 1)
                first_special_line_after.?.maximumSpecialHeight
            else
                self._defaultLineHeight;

            const total_height_deleted = last_special_line_deleted.prefixSum +
                last_special_line_deleted.maximumSpecialHeight -
                first_special_line_deleted.prefixSum +
                lineDelta(toLineNumber, last_special_line_deleted.lineNumber, 0) * self._defaultLineHeight +
                lineDelta(first_special_line_deleted.lineNumber, fromLineNumber, 0) * self._defaultLineHeight +
                height_of_first_line_after_deletion -
                maximum_special_height_on_deleted_interval;

            var decoration_ids_seen = std.StringHashMap(void).init(self.allocator);
            defer decoration_ids_seen.deinit();

            var new_ordered = ArrayList(*CustomLine).init(self.allocator);
            var new_ordered_assigned = false;
            defer if (!new_ordered_assigned) new_ordered.deinit();
            var new_id_map = ArrayMap.init(self.allocator);
            var new_id_map_assigned = false;
            defer if (!new_id_map_assigned) new_id_map.deinit();

            var number_of_deletions: isize = 0;
            var k: usize = 0;
            while (k < items.len) : (k += 1) {
                const custom_line = items[k];
                const k_index: isize = @intCast(k);
                if (k_index < start_index) {
                    try new_ordered.append(custom_line);
                    try new_id_map.add(custom_line.decorationId, custom_line);
                } else if (k_index >= start_index and k_index <= end_index) {
                    const decoration_id = custom_line.decorationId;
                    if (!decoration_ids_seen.contains(decoration_id)) {
                        custom_line.index -= number_of_deletions;
                        custom_line.lineNumber = fromLineNumber;
                        custom_line.prefixSum = prefix_sum_on_deleted_interval;
                        custom_line.maximumSpecialHeight = maximum_special_height_on_deleted_interval;
                        try new_ordered.append(custom_line);
                        try new_id_map.add(custom_line.decorationId, custom_line);
                    } else {
                        number_of_deletions += 1;
                    }
                } else {
                    custom_line.index -= number_of_deletions;
                    custom_line.lineNumber -= delete_count;
                    custom_line.prefixSum -= total_height_deleted;
                    try new_ordered.append(custom_line);
                    try new_id_map.add(custom_line.decorationId, custom_line);
                }
                try decoration_ids_seen.put(custom_line.decorationId, {});
            }

            self._orderedCustomLines.deinit();
            self._orderedCustomLines = new_ordered;
            new_ordered_assigned = true;
            self._decorationIDToCustomLine.deinit();
            self._decorationIDToCustomLine = new_id_map;
            new_id_map_assigned = true;
        } else {
            const total_height_deleted = @as(f64, @floatFromInt(delete_count)) * self._defaultLineHeight;
            var i = end_index;
            while (i < @as(isize, @intCast(items.len))) : (i += 1) {
                const custom_line = items[@intCast(i)];
                if (custom_line.lineNumber > toLineNumber) {
                    custom_line.lineNumber -= delete_count;
                    custom_line.prefixSum -= total_height_deleted;
                }
            }
        }
    }

    fn doLinesInserted(
        self: *LineHeightsManager,
        fromLineNumber: usize,
        toLineNumber: usize,
        stagedInserts: *ArrayList(*CustomLine),
        stagedIdMap: *ArrayMap,
    ) !void {
        const insert_count = toLineNumber - fromLineNumber + 1;
        const items = self._orderedCustomLines.items;

        const candidate_start = self.binarySearchOverOrderedCustomLinesArray(fromLineNumber);
        var start_index: isize = undefined;
        if (candidate_start >= 0) {
            start_index = candidate_start;
            var i = candidate_start - 1;
            while (i >= 0) : (i -= 1) {
                if (items[@intCast(i)].lineNumber == fromLineNumber) {
                    start_index -= 1;
                } else break;
            }
        } else {
            start_index = -(candidate_start + 1);
        }

        var decorations_immediately_after = std.StringHashMap(void).init(self.allocator);
        defer decorations_immediately_after.deinit();
        {
            var i: usize = @intCast(start_index);
            while (i < items.len) : (i += 1) {
                if (items[i].lineNumber == fromLineNumber) {
                    try decorations_immediately_after.put(items[i].decorationId, {});
                }
            }
        }

        var decorations_immediately_before = std.StringHashMap(void).init(self.allocator);
        defer decorations_immediately_before.deinit();
        {
            var i = start_index - 1;
            while (i >= 0) : (i -= 1) {
                if (items[@intCast(i)].lineNumber == fromLineNumber -| 1) {
                    try decorations_immediately_before.put(items[@intCast(i)].decorationId, {});
                }
            }
        }

        const prefix_sum_to_add = @as(f64, @floatFromInt(insert_count)) * self._defaultLineHeight;
        {
            var i: usize = @intCast(start_index);
            while (i < items.len) : (i += 1) {
                items[i].lineNumber += insert_count;
                items[i].prefixSum += prefix_sum_to_add;
            }
        }

        // Only decorations that are adjacent both before and after the
        // insertion point span the inserted gap.
        var decorations_with_gaps = ArrayList([]const u8).init(self.allocator);
        defer decorations_with_gaps.deinit();
        var it = decorations_immediately_before.keyIterator();
        while (it.next()) |key| {
            if (decorations_immediately_after.contains(key.*)) {
                try decorations_with_gaps.append(key.*);
            }
        }

        if (decorations_with_gaps.items.len > 0) {
            var to_re_add = ArrayList(CustomLineHeightData).init(self.allocator);
            defer to_re_add.deinit();

            for (decorations_with_gaps.items) |decoration_id| {
                const decoration = self._decorationIDToCustomLine.get(decoration_id) orelse continue;
                var start_line_number = fromLineNumber;
                var end_line_number = fromLineNumber;
                var line_height: f64 = 0;
                for (decoration) |custom_line| {
                    start_line_number = @min(start_line_number, custom_line.lineNumber);
                    end_line_number = @max(end_line_number, custom_line.lineNumber);
                    line_height = @max(line_height, custom_line.specialHeight);
                }
                try to_re_add.append(.{
                    .decorationId = decoration_id,
                    .startLineNumber = start_line_number,
                    .endLineNumber = end_line_number,
                    .lineHeight = line_height,
                });
            }

            for (to_re_add.items) |dec| {
                try self.doInsertOrChangeCustomLineHeight(
                    dec.decorationId,
                    dec.startLineNumber,
                    dec.endLineNumber,
                    dec.lineHeight,
                    stagedInserts,
                    stagedIdMap,
                );
            }
        }
    }

    fn binarySearchOverOrderedCustomLinesArray(self: *const LineHeightsManager, lineNumber: usize) isize {
        const Ctx = struct {
            items: []const *CustomLine,
            line_number: usize,

            fn compare(ctx: @This(), index: usize) isize {
                const line = ctx.items[index];
                if (line.lineNumber == ctx.line_number) return 0;
                if (line.lineNumber < ctx.line_number) return -1;
                return 1;
            }
        };
        return binarySearch2(self._orderedCustomLines.items.len, Ctx{
            .items = self._orderedCustomLines.items,
            .line_number = lineNumber,
        }, Ctx.compare);
    }
};

/// `a - b - extra` evaluated in floating point, so that intermediate results may
/// be negative (as they are upstream, where all of this is `number` maths).
fn lineDelta(a: usize, b: usize, extra: u32) f64 {
    return @as(f64, @floatFromInt(a)) - @as(f64, @floatFromInt(b)) - @as(f64, @floatFromInt(extra));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectClose(expected: f64, actual: f64) !void {
    try testing.expectApproxEqAbs(expected, actual, 0.0001);
}

test "LineHeightsManager default height" {
    const allocator = testing.allocator;
    var manager = try LineHeightsManager.init(allocator, 20, &.{});
    defer manager.deinit();

    try expectClose(20, try manager.heightForLineNumber(1));
    try expectClose(20, try manager.heightForLineNumber(100));
    try expectClose(200, try manager.getAccumulatedLineHeightsIncludingLineNumber(10));
}

test "LineHeightsManager custom line heights" {
    const allocator = testing.allocator;
    var data = [_]CustomLineHeightData{.{
        .decorationId = "d1",
        .startLineNumber = 2,
        .endLineNumber = 3,
        .lineHeight = 50,
    }};
    var manager = try LineHeightsManager.init(allocator, 20, &data);
    defer manager.deinit();

    try expectClose(20, try manager.heightForLineNumber(1));
    try expectClose(50, try manager.heightForLineNumber(2));
    try expectClose(50, try manager.heightForLineNumber(3));
    try expectClose(20, try manager.heightForLineNumber(4));

    // 1 line at 20 + 2 lines at 50
    try expectClose(120, try manager.getAccumulatedLineHeightsIncludingLineNumber(3));
    try expectClose(140, try manager.getAccumulatedLineHeightsIncludingLineNumber(4));
}

test "LineHeightsManager rounds fractional heights" {
    const allocator = testing.allocator;
    var manager = try LineHeightsManager.init(allocator, 20, &.{});
    defer manager.deinit();

    try manager.insertOrChangeCustomLineHeight("d", 1, 1, 30.4);
    try expectClose(30, try manager.heightForLineNumber(1));

    try manager.insertOrChangeCustomLineHeight("d", 1, 1, 30.6);
    try expectClose(31, try manager.heightForLineNumber(1));
}

test "LineHeightsManager keeps the maximum of overlapping decorations" {
    const allocator = testing.allocator;
    var manager = try LineHeightsManager.init(allocator, 10, &.{});
    defer manager.deinit();

    try manager.insertOrChangeCustomLineHeight("small", 1, 3, 20);
    try manager.insertOrChangeCustomLineHeight("large", 2, 2, 40);

    try expectClose(20, try manager.heightForLineNumber(1));
    try expectClose(40, try manager.heightForLineNumber(2));
    try expectClose(20, try manager.heightForLineNumber(3));
    // 3 lines: 20 + 40 + 20
    try expectClose(80, try manager.getAccumulatedLineHeightsIncludingLineNumber(3));
}

test "LineHeightsManager removes custom line heights" {
    const allocator = testing.allocator;
    var manager = try LineHeightsManager.init(allocator, 10, &.{});
    defer manager.deinit();

    try manager.insertOrChangeCustomLineHeight("d", 1, 1, 100);
    try expectClose(100, try manager.heightForLineNumber(1));

    try manager.removeCustomLineHeight("d");
    try expectClose(10, try manager.heightForLineNumber(1));
    try expectClose(10, try manager.heightForLineNumber(5));
}

test "LineHeightsManager onLinesDeleted shifts following lines" {
    const allocator = testing.allocator;
    var manager = try LineHeightsManager.init(allocator, 10, &.{});
    defer manager.deinit();

    try manager.insertOrChangeCustomLineHeight("d", 5, 5, 100);
    try expectClose(100, try manager.heightForLineNumber(5));

    // Delete lines 1..2
    try manager.onLinesDeleted(1, 2);
    try expectClose(100, try manager.heightForLineNumber(3));
    try expectClose(10, try manager.heightForLineNumber(4));
    // 2 default lines + 1 custom line
    try expectClose(120, try manager.getAccumulatedLineHeightsIncludingLineNumber(3));
}

test "LineHeightsManager onLinesDeleted removes decorations inside the range" {
    const allocator = testing.allocator;
    var manager = try LineHeightsManager.init(allocator, 10, &.{});
    defer manager.deinit();

    try manager.insertOrChangeCustomLineHeight("d", 2, 4, 100);
    try expectClose(100, try manager.heightForLineNumber(3));

    // Deleting lines 2..4 removes the decoration, but the decoration is kept on
    // the collapsed line so that undo/redo of the deletion restores it.
    try manager.onLinesDeleted(2, 4);
    try expectClose(100, try manager.heightForLineNumber(2));
    try expectClose(10, try manager.heightForLineNumber(3));
}

test "LineHeightsManager onLinesInserted shifts following lines" {
    const allocator = testing.allocator;
    var manager = try LineHeightsManager.init(allocator, 10, &.{});
    defer manager.deinit();

    try manager.insertOrChangeCustomLineHeight("d", 2, 2, 100);
    try manager.onLinesInserted(1, 3);

    try expectClose(100, try manager.heightForLineNumber(5));
    try expectClose(10, try manager.heightForLineNumber(4));
    // 4 default lines + 1 custom line
    try expectClose(140, try manager.getAccumulatedLineHeightsIncludingLineNumber(5));
}

test "LineHeightsManager onLinesInserted re-applies decorations that span the gap" {
    const allocator = testing.allocator;
    var manager = try LineHeightsManager.init(allocator, 10, &.{});
    defer manager.deinit();

    // A single decoration over lines 2..4, so inserting in the middle must
    // stretch it over the newly inserted lines.
    try manager.insertOrChangeCustomLineHeight("d", 2, 4, 100);
    try manager.onLinesInserted(3, 5);

    // The decoration is re-applied over `min(3, lineNumbers)`..`max(3, lineNumbers)`,
    // evaluated after the shift, so it stretches from line 2 to line 7.
    try expectClose(100, try manager.heightForLineNumber(2));
    try expectClose(100, try manager.heightForLineNumber(5));
    try expectClose(100, try manager.heightForLineNumber(6));
    try expectClose(100, try manager.heightForLineNumber(7));
    try expectClose(10, try manager.heightForLineNumber(8));
}
