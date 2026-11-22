// Port of `src/vs/editor/common/model/prefixSumComputer.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

pub const PrefixSumIndexOfResult = struct {
    index: usize,
    remainder: usize,
};

pub const PrefixSumComputer = struct {
    values: ArrayList(usize),
    prefix_sum: ArrayList(usize),
    prefix_sum_valid_index: isize,

    pub fn init(allocator: Allocator, values: []const usize) !PrefixSumComputer {
        var self = PrefixSumComputer{
            .values = ArrayList(usize).init(allocator),
            .prefix_sum = ArrayList(usize).init(allocator),
            .prefix_sum_valid_index = -1,
        };
        try self.values.appendSlice(values);
        try self.prefix_sum.resize(values.len);
        return self;
    }

    pub fn deinit(self: *PrefixSumComputer) void {
        self.values.deinit();
        self.prefix_sum.deinit();
    }

    pub fn getCount(self: *const PrefixSumComputer) usize {
        return self.values.items.len;
    }

    pub fn insertValues(self: *PrefixSumComputer, insert_index: usize, insert_values: []const usize) !bool {
        if (insert_values.len == 0) return false;
        try self.values.insertSlice(insert_index, insert_values);
        if (@as(isize, @intCast(insert_index)) - 1 < self.prefix_sum_valid_index) {
            self.prefix_sum_valid_index = @as(isize, @intCast(insert_index)) - 1;
        }
        self.prefix_sum.resize(self.values.items.len) catch unreachable;
        return true;
    }

    pub fn setValue(self: *PrefixSumComputer, index: usize, value: usize) bool {
        if (self.values.items[index] == value) return false;
        self.values.items[index] = value;
        if (@as(isize, @intCast(index)) - 1 < self.prefix_sum_valid_index) {
            self.prefix_sum_valid_index = @as(isize, @intCast(index)) - 1;
        }
        return true;
    }

    pub fn removeValues(self: *PrefixSumComputer, start_index: usize, count: usize) bool {
        if (start_index >= self.values.items.len) return false;
        const max_count = self.values.items.len - start_index;
        const actual_count = @min(count, max_count);
        if (actual_count == 0) return false;
        self.values.replaceRange(start_index, actual_count, &.{}) catch unreachable;
        self.prefix_sum.resize(self.values.items.len) catch unreachable;
        if (@as(isize, @intCast(start_index)) - 1 < self.prefix_sum_valid_index) {
            self.prefix_sum_valid_index = @as(isize, @intCast(start_index)) - 1;
        }
        return true;
    }

    pub fn getTotalSum(self: *PrefixSumComputer) usize {
        if (self.values.items.len == 0) return 0;
        return self.getPrefixSum(@intCast(self.values.items.len - 1));
    }

    pub fn getPrefixSum(self: *PrefixSumComputer, index: isize) usize {
        if (index < 0) return 0;
        return self._getPrefixSum(@intCast(index));
    }

    fn _getPrefixSum(self: *PrefixSumComputer, index: usize) usize {
        if (@as(isize, @intCast(index)) <= self.prefix_sum_valid_index) {
            return self.prefix_sum.items[index];
        }

        var start_index: usize = @intCast(self.prefix_sum_valid_index + 1);
        if (start_index == 0) {
            self.prefix_sum.items[0] = self.values.items[0];
            start_index += 1;
        }

        const clamped_index = @min(index, self.values.items.len - 1);
        var i = start_index;
        while (i <= clamped_index) : (i += 1) {
            self.prefix_sum.items[i] = self.prefix_sum.items[i - 1] + self.values.items[i];
        }
        self.prefix_sum_valid_index = @max(self.prefix_sum_valid_index, @as(isize, @intCast(clamped_index)));
        return self.prefix_sum.items[clamped_index];
    }

    pub fn getIndexOf(self: *PrefixSumComputer, sum: usize) PrefixSumIndexOfResult {
        const total = self.getTotalSum();
        if (self.values.items.len == 0) return .{ .index = 0, .remainder = sum };
        if (sum >= total) {
            const last = self.values.items.len - 1;
            return .{ .index = last, .remainder = sum - self.getPrefixSum(@as(isize, @intCast(last)) - 1) };
        }

        var low: usize = 0;
        var high: usize = self.values.items.len - 1;
        var mid: usize = 0;
        var mid_start: usize = 0;
        var mid_stop: usize = 0;
        while (low <= high) {
            mid = low + (high - low) / 2;
            mid_stop = self.prefix_sum.items[mid];
            mid_start = mid_stop - self.values.items[mid];
            if (sum < mid_start) {
                if (mid == 0) break;
                high = mid - 1;
            } else if (sum >= mid_stop) {
                low = mid + 1;
            } else {
                break;
            }
        }
        return .{ .index = mid, .remainder = sum - mid_start };
    }
};

pub const ConstantTimePrefixSumComputer = struct {
    values: ArrayList(usize),
    is_valid: bool,
    valid_end_index: isize,
    prefix_sum: ArrayList(usize),
    index_by_sum: ArrayList(usize),

    pub fn init(allocator: Allocator, values: []const usize) !ConstantTimePrefixSumComputer {
        var self = ConstantTimePrefixSumComputer{
            .values = ArrayList(usize).init(allocator),
            .is_valid = false,
            .valid_end_index = -1,
            .prefix_sum = ArrayList(usize).init(allocator),
            .index_by_sum = ArrayList(usize).init(allocator),
        };
        try self.values.appendSlice(values);
        return self;
    }

    pub fn deinit(self: *ConstantTimePrefixSumComputer) void {
        self.values.deinit();
        self.prefix_sum.deinit();
        self.index_by_sum.deinit();
    }

    pub fn getTotalSum(self: *ConstantTimePrefixSumComputer) usize {
        self.ensureValid();
        return self.index_by_sum.items.len;
    }

    pub fn getPrefixSum(self: *ConstantTimePrefixSumComputer, count: usize) usize {
        self.ensureValid();
        if (count == 0) return 0;
        return self.prefix_sum.items[count - 1];
    }

    pub fn getIndexOf(self: *ConstantTimePrefixSumComputer, sum: usize) PrefixSumIndexOfResult {
        self.ensureValid();
        if (sum < self.index_by_sum.items.len) {
            const idx = self.index_by_sum.items[sum];
            const above = if (idx > 0) self.prefix_sum.items[idx - 1] else 0;
            return .{ .index = idx, .remainder = sum - above };
        }
        const last = if (self.values.items.len == 0) 0 else self.values.items.len - 1;
        const above = if (last > 0 and last - 1 < self.prefix_sum.items.len) self.prefix_sum.items[last - 1] else 0;
        return .{ .index = last, .remainder = sum - above };
    }

    pub fn setValue(self: *ConstantTimePrefixSumComputer, index: usize, value: usize) void {
        if (self.values.items[index] == value) return;
        self.values.items[index] = value;
        self.invalidate(index);
    }

    pub fn insertValues(self: *ConstantTimePrefixSumComputer, insert_index: usize, insert_values: []const usize) !void {
        try self.values.insertSlice(insert_index, insert_values);
        self.invalidate(insert_index);
    }

    pub fn removeValues(self: *ConstantTimePrefixSumComputer, start: usize, delete_count: usize) void {
        self.values.replaceRange(start, delete_count, &.{}) catch unreachable;
        self.invalidate(start);
    }

    fn invalidate(self: *ConstantTimePrefixSumComputer, index: usize) void {
        self.is_valid = false;
        const new_end = @as(isize, @intCast(index)) - 1;
        self.valid_end_index = @min(self.valid_end_index, new_end);
    }

    fn ensureValid(self: *ConstantTimePrefixSumComputer) void {
        if (self.is_valid) return;

        self.prefix_sum.resize(self.values.items.len) catch unreachable;
        var i: usize = @intCast(self.valid_end_index + 1);
        while (i < self.values.items.len) : (i += 1) {
            const value = self.values.items[i];
            const sum_above = if (i > 0) self.prefix_sum.items[i - 1] else 0;
            self.prefix_sum.items[i] = sum_above + value;
            if (value > 0) {
                self.index_by_sum.resize(sum_above + value) catch unreachable;
                for (0..value) |j| self.index_by_sum.items[sum_above + j] = i;
            }
        }
        // Upstream trims indexBySum to the current total, so removed or
        // zeroed trailing values shrink getTotalSum.
        const total = if (self.values.items.len > 0) self.prefix_sum.items[self.values.items.len - 1] else 0;
        self.index_by_sum.resize(total) catch unreachable;
        self.is_valid = true;
        self.valid_end_index = @as(isize, @intCast(self.values.items.len)) - 1;
    }
};

test "prefix sum: total, prefix, and getIndexOf" {
    const allocator = std.testing.allocator;
    var computer = try PrefixSumComputer.init(allocator, &[_]usize{ 2, 3, 0, 4 });
    defer computer.deinit();
    try std.testing.expectEqual(@as(usize, 9), computer.getTotalSum());
    try std.testing.expectEqual(@as(usize, 2), computer.getPrefixSum(0));
    try std.testing.expectEqual(@as(usize, 5), computer.getPrefixSum(1));
    try std.testing.expectEqual(PrefixSumIndexOfResult{ .index = 1, .remainder = 1 }, computer.getIndexOf(3));
    try std.testing.expectEqual(PrefixSumIndexOfResult{ .index = 3, .remainder = 1 }, computer.getIndexOf(6));
}

test "prefix sum: set, insert, and remove" {
    const allocator = std.testing.allocator;
    var computer = try PrefixSumComputer.init(allocator, &[_]usize{ 2, 3, 4 });
    defer computer.deinit();
    try std.testing.expect(computer.setValue(1, 5));
    try std.testing.expectEqual(@as(usize, 11), computer.getTotalSum());
    try std.testing.expect(try computer.insertValues(1, &[_]usize{ 1, 1 }));
    try std.testing.expectEqual(@as(usize, 13), computer.getTotalSum());
    try std.testing.expect(computer.removeValues(1, 2));
    try std.testing.expectEqual(@as(usize, 11), computer.getTotalSum());
}

test "constant prefix sum: basic operations" {
    const allocator = std.testing.allocator;
    var computer = try ConstantTimePrefixSumComputer.init(allocator, &[_]usize{ 2, 3, 0, 4 });
    defer computer.deinit();
    try std.testing.expectEqual(@as(usize, 9), computer.getTotalSum());
    try std.testing.expectEqual(@as(usize, 5), computer.getPrefixSum(2));
    try std.testing.expectEqual(PrefixSumIndexOfResult{ .index = 1, .remainder = 1 }, computer.getIndexOf(3));
    computer.setValue(0, 1);
    try std.testing.expectEqual(@as(usize, 8), computer.getTotalSum());
}

test "constant prefix sum: total shrinks when trailing values are removed" {
    const allocator = std.testing.allocator;
    var computer = try ConstantTimePrefixSumComputer.init(allocator, &[_]usize{ 1, 2, 3 });
    defer computer.deinit();
    try std.testing.expectEqual(@as(usize, 6), computer.getTotalSum());

    computer.removeValues(2, 1);
    try std.testing.expectEqual(@as(usize, 3), computer.getTotalSum());

    computer.setValue(0, 0);
    try std.testing.expectEqual(@as(usize, 2), computer.getTotalSum());
}
