// Port of `src/vs/base/browser/ui/list/rangeMap.ts`.
//
// Item sizes and positions are f64 terminal cells, as in the rest of the
// terminal layout. Group ranges and item indexes are i64/usize and stay exact.

const std = @import("std");
const range_mod = @import("../../../common/range.zig");
const Range = range_mod.Range;

pub const Item = struct {
    size: f64,
};

pub const RangedGroup = struct {
    range: Range,
    size: f64,
};

/// Returns the intersection between a ranged group and a range.
pub fn groupIntersect(
    allocator: std.mem.Allocator,
    range: Range,
    groups: []const RangedGroup,
) ![]RangedGroup {
    var result: std.array_list.Managed(RangedGroup) = .init(allocator);
    errdefer result.deinit();

    for (groups) |group| {
        if (range.start >= group.range.end) continue;
        if (range.end < group.range.start) break;

        const intersection = range_mod.intersect(range, group.range);
        if (range_mod.isEmpty(intersection)) continue;
        try result.append(.{ .range = intersection, .size = group.size });
    }
    return result.toOwnedSlice();
}

/// Shifts a range by `much`.
pub fn shift(range: Range, much: i64) Range {
    return .{ .start = range.start + much, .end = range.end + much };
}

/// Consolidates ranged groups, merging consecutive groups with equal size.
pub fn consolidate(
    allocator: std.mem.Allocator,
    groups: []const RangedGroup,
) ![]RangedGroup {
    var result: std.array_list.Managed(RangedGroup) = .init(allocator);
    errdefer result.deinit();

    var previous: ?*RangedGroup = null;
    for (groups) |group| {
        if (previous) |prev| {
            if (group.size == prev.size) {
                prev.range.end = group.range.end;
                continue;
            }
        }
        try result.append(.{ .range = group.range, .size = group.size });
        previous = &result.items[result.items.len - 1];
    }
    return result.toOwnedSlice();
}

pub const RangeMap = struct {
    allocator: std.mem.Allocator,
    groups: std.array_list.Managed(RangedGroup),
    _size: f64,
    _padding_top: f64,

    pub fn init(allocator: std.mem.Allocator, top_padding: f64) RangeMap {
        return .{
            .allocator = allocator,
            .groups = std.array_list.Managed(RangedGroup).init(allocator),
            ._size = top_padding,
            ._padding_top = top_padding,
        };
    }

    pub fn deinit(self: *RangeMap) void {
        self.groups.deinit();
    }

    pub fn paddingTop(self: *const RangeMap) f64 {
        return self._padding_top;
    }

    pub fn setPaddingTop(self: *RangeMap, padding_top: f64) void {
        self._size = self._size + padding_top - self._padding_top;
        self._padding_top = padding_top;
    }

    /// Resets the map to `count` unit-height rows. Used by the terminal trees,
    /// whose virtual delegate always reports height 1; this keeps list splices
    /// from reallocating and consolidating range groups on every expand.
    pub fn setUniformCount(self: *RangeMap, row_count: usize) void {
        self.groups.clearRetainingCapacity();
        if (row_count > 0) {
            self.groups.append(.{
                .range = .{ .start = 0, .end = @intCast(row_count) },
                .size = 1,
            }) catch {};
        }
        self._size = self._padding_top + @as(f64, @floatFromInt(row_count));
    }

    /// Splices `items` into the map at `index`, deleting `delete_count`.
    pub fn splice(self: *RangeMap, index: usize, delete_count: usize, items: []const Item) !void {
        const diff: i64 = @as(i64, @intCast(items.len)) - @as(i64, @intCast(delete_count));
        const index_i: i64 = @intCast(index);
        const delete_i: i64 = @intCast(delete_count);

        const before = try groupIntersect(
            self.allocator,
            .{ .start = 0, .end = index_i },
            self.groups.items,
        );
        defer self.allocator.free(before);

        const after_raw = try groupIntersect(
            self.allocator,
            .{ .start = index_i + delete_i, .end = std.math.maxInt(i64) },
            self.groups.items,
        );
        defer self.allocator.free(after_raw);

        var after = try self.allocator.alloc(RangedGroup, after_raw.len);
        defer self.allocator.free(after);
        for (after_raw, 0..) |group, i| {
            after[i] = .{ .range = shift(group.range, diff), .size = group.size };
        }

        var combined: std.array_list.Managed(RangedGroup) = .init(self.allocator);
        defer combined.deinit();
        try combined.appendSlice(before);
        for (items, 0..) |item, i| {
            try combined.append(.{
                .range = .{
                    .start = index_i + @as(i64, @intCast(i)),
                    .end = index_i + @as(i64, @intCast(i + 1)),
                },
                .size = item.size,
            });
        }
        try combined.appendSlice(after);

        const consolidated = try consolidate(self.allocator, combined.items);
        self.groups.deinit();
        self.groups = std.array_list.Managed(RangedGroup).fromOwnedSlice(self.allocator, consolidated);

        var total: f64 = self._padding_top;
        for (consolidated) |group| {
            const group_size_count: f64 = @floatFromInt(group.range.end - group.range.start);
            total += group.size * group_size_count;
        }
        self._size = total;
    }

    /// The number of items in the range map.
    pub fn count(self: *const RangeMap) usize {
        if (self.groups.items.len == 0) return 0;
        return @intCast(self.groups.items[self.groups.items.len - 1].range.end);
    }

    /// The sum of the sizes of all items plus the top padding.
    pub fn size(self: *const RangeMap) f64 {
        return self._size;
    }

    /// The index of the item at `position`.
    pub fn indexAt(self: *const RangeMap, position: f64) i64 {
        if (position < 0) return -1;
        if (position < self._padding_top) return 0;

        var index: i64 = 0;
        var cursor = self._padding_top;
        for (self.groups.items) |group| {
            const group_count = group.range.end - group.range.start;
            const new_size = cursor + group.size * @as(f64, @floatFromInt(group_count));
            if (position < new_size) {
                return index + @as(i64, @intFromFloat(@floor((position - cursor) / group.size)));
            }
            index += group_count;
            cursor = new_size;
        }
        return index;
    }

    /// The index of the item right after the item at `position`.
    pub fn indexAfter(self: *const RangeMap, position: f64) i64 {
        return @min(self.indexAt(position) + 1, @as(i64, @intCast(self.count())));
    }

    /// The start position of the item at `index`.
    pub fn positionAt(self: *const RangeMap, index: i64) f64 {
        if (index < 0) return -1;

        var position: f64 = 0;
        var cursor_count: i64 = 0;
        for (self.groups.items) |group| {
            const group_count = group.range.end - group.range.start;
            const new_count = cursor_count + group_count;
            if (index < new_count) {
                return self._padding_top + position +
                    @as(f64, @floatFromInt(index - cursor_count)) * group.size;
            }
            position += @as(f64, @floatFromInt(group_count)) * group.size;
            cursor_count = new_count;
        }
        return -1;
    }
};
