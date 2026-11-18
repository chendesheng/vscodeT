// Port of `src/vs/editor/contrib/folding/browser/foldingRanges.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Selection = @import("../../../common/core/selection.zig").Selection;

pub const MAX_FOLDING_REGIONS: usize = 0xFFFF;
pub const MAX_LINE_NUMBER: u32 = 0xFFFFFF;
const MASK_INDENT: u32 = 0xFF000000;

pub const FoldSource = enum(u8) {
    provider = 0,
    user_defined = 1,
    recovered = 2,
};

pub fn foldSourceAbbr(source: FoldSource) []const u8 {
    return switch (source) {
        .provider => " ",
        .user_defined => "u",
        .recovered => "r",
    };
}

pub const FoldRange = struct {
    startLineNumber: usize,
    endLineNumber: usize,
    type: ?[]const u8 = null,
    isCollapsed: bool = false,
    source: FoldSource = .provider,
};

const BitField = struct {
    states: []u32,

    fn init(allocator: Allocator, size: usize) !BitField {
        const words = (size + 31) / 32;
        const states = try allocator.alloc(u32, words);
        @memset(states, 0);
        return .{ .states = states };
    }

    fn deinit(self: *BitField, allocator: Allocator) void {
        allocator.free(self.states);
    }

    fn get(self: *const BitField, index: usize) bool {
        const array_index = index / 32;
        const bit: u5 = @intCast(index % 32);
        return (self.states[array_index] & (@as(u32, 1) << bit)) != 0;
    }

    fn set(self: *BitField, index: usize, value: bool) void {
        const array_index = index / 32;
        const bit: u5 = @intCast(index % 32);
        if (value) {
            self.states[array_index] |= @as(u32, 1) << bit;
        } else {
            self.states[array_index] &= ~(@as(u32, 1) << bit);
        }
    }
};

pub const SelectedLines = struct {
    selections: []const Selection,

    pub fn startsInside(self: SelectedLines, start: usize, end: usize) bool {
        for (self.selections) |selection| {
            if (selection.selectionStartLineNumber >= start and selection.selectionStartLineNumber <= end) return true;
        }
        return false;
    }
};

pub const FoldingRegions = struct {
    allocator: Allocator,
    start_indexes: []u32,
    end_indexes: []u32,
    collapse_states: BitField,
    user_defined_states: BitField,
    recovered_states: BitField,
    parents_computed: bool = false,
    types: ?[]?[]const u8,

    pub fn init(allocator: Allocator, start_indexes: []const u32, end_indexes: []const u32, types: ?[]?[]const u8) !FoldingRegions {
        if (start_indexes.len != end_indexes.len or start_indexes.len > MAX_FOLDING_REGIONS) return error.InvalidFoldingRegions;
        const starts = try allocator.dupe(u32, start_indexes);
        errdefer allocator.free(starts);
        const ends = try allocator.dupe(u32, end_indexes);
        errdefer allocator.free(ends);
        var collapse = try BitField.init(allocator, starts.len);
        errdefer collapse.deinit(allocator);
        var user = try BitField.init(allocator, starts.len);
        errdefer user.deinit(allocator);
        var recovered = try BitField.init(allocator, starts.len);
        errdefer recovered.deinit(allocator);
        const stored_types = if (types) |values| try allocator.dupe(?[]const u8, values) else null;
        errdefer if (stored_types) |values| allocator.free(values);
        return .{
            .allocator = allocator,
            .start_indexes = starts,
            .end_indexes = ends,
            .collapse_states = collapse,
            .user_defined_states = user,
            .recovered_states = recovered,
            .types = stored_types,
        };
    }

    pub fn deinit(self: *FoldingRegions) void {
        self.allocator.free(self.start_indexes);
        self.allocator.free(self.end_indexes);
        self.collapse_states.deinit(self.allocator);
        self.user_defined_states.deinit(self.allocator);
        self.recovered_states.deinit(self.allocator);
        if (self.types) |types| self.allocator.free(types);
    }

    pub fn length(self: *const FoldingRegions) usize {
        return self.start_indexes.len;
    }

    pub fn getStartLineNumber(self: *const FoldingRegions, index: usize) usize {
        return self.start_indexes[index] & MAX_LINE_NUMBER;
    }

    pub fn getEndLineNumber(self: *const FoldingRegions, index: usize) usize {
        return self.end_indexes[index] & MAX_LINE_NUMBER;
    }

    pub fn getType(self: *const FoldingRegions, index: usize) ?[]const u8 {
        return if (self.types) |types| types[index] else null;
    }

    pub fn hasTypes(self: *const FoldingRegions) bool {
        return self.types != null;
    }

    pub fn isCollapsed(self: *const FoldingRegions, index: usize) bool {
        return self.collapse_states.get(index);
    }

    pub fn setCollapsed(self: *FoldingRegions, index: usize, value: bool) void {
        self.collapse_states.set(index, value);
    }

    fn isUserDefined(self: *const FoldingRegions, index: usize) bool {
        return self.user_defined_states.get(index);
    }

    fn setUserDefined(self: *FoldingRegions, index: usize, value: bool) void {
        self.user_defined_states.set(index, value);
    }

    fn isRecovered(self: *const FoldingRegions, index: usize) bool {
        return self.recovered_states.get(index);
    }

    fn setRecovered(self: *FoldingRegions, index: usize, value: bool) void {
        self.recovered_states.set(index, value);
    }

    pub fn getSource(self: *const FoldingRegions, index: usize) FoldSource {
        if (self.isUserDefined(index)) return .user_defined;
        if (self.isRecovered(index)) return .recovered;
        return .provider;
    }

    pub fn setSource(self: *FoldingRegions, index: usize, source: FoldSource) void {
        switch (source) {
            .user_defined => {
                self.setUserDefined(index, true);
                self.setRecovered(index, false);
            },
            .recovered => {
                self.setUserDefined(index, false);
                self.setRecovered(index, true);
            },
            .provider => {
                self.setUserDefined(index, false);
                self.setRecovered(index, false);
            },
        }
    }

    pub fn setCollapsedAllOfType(self: *FoldingRegions, type_name: []const u8, value: bool) bool {
        const types = self.types orelse return false;
        var changed = false;
        for (types, 0..) |item, i| {
            if (item) |t| {
                if (std.mem.eql(u8, t, type_name)) {
                    self.setCollapsed(i, value);
                    changed = true;
                }
            }
        }
        return changed;
    }

    fn ensureParentIndices(self: *FoldingRegions) !void {
        if (self.parents_computed) return;
        self.parents_computed = true;
        var parent_indexes = ArrayList(usize).init(self.allocator);
        defer parent_indexes.deinit();

        for (0..self.start_indexes.len) |i| {
            const start = self.start_indexes[i];
            const end = self.end_indexes[i];
            if (start > MAX_LINE_NUMBER or end > MAX_LINE_NUMBER) return error.InvalidFoldingRegions;
            while (parent_indexes.items.len > 0) {
                const index = parent_indexes.items[parent_indexes.items.len - 1];
                if (self.getStartLineNumber(index) <= start and self.getEndLineNumber(index) >= end) break;
                _ = parent_indexes.pop();
            }
            const parent_index: usize = if (parent_indexes.items.len > 0) parent_indexes.items[parent_indexes.items.len - 1] else MAX_FOLDING_REGIONS;
            try parent_indexes.append(i);
            self.start_indexes[i] = @intCast(start + ((parent_index & 0xFF) << 24));
            self.end_indexes[i] = @intCast(end + ((parent_index & 0xFF00) << 16));
        }
    }

    pub fn getParentIndex(self: *FoldingRegions, index: usize) !isize {
        try self.ensureParentIndices();
        const parent = ((self.start_indexes[index] & MASK_INDENT) >> 24) + ((self.end_indexes[index] & MASK_INDENT) >> 16);
        if (parent == MAX_FOLDING_REGIONS) return -1;
        return @intCast(parent);
    }

    pub fn contains(self: *const FoldingRegions, index: usize, line: usize) bool {
        return self.getStartLineNumber(index) <= line and self.getEndLineNumber(index) >= line;
    }

    fn findIndex(self: *const FoldingRegions, line: usize) isize {
        var low: usize = 0;
        var high: usize = self.start_indexes.len;
        if (high == 0) return -1;
        while (low < high) {
            const mid = (low + high) / 2;
            if (line < self.getStartLineNumber(mid)) high = mid else low = mid + 1;
        }
        return @as(isize, @intCast(low)) - 1;
    }

    pub fn findRange(self: *FoldingRegions, line: usize) !isize {
        var index = self.findIndex(line);
        if (index >= 0) {
            if (self.getEndLineNumber(@intCast(index)) >= line) return index;
            index = try self.getParentIndex(@intCast(index));
            while (index != -1) {
                if (self.contains(@intCast(index), line)) return index;
                index = try self.getParentIndex(@intCast(index));
            }
        }
        return -1;
    }

    pub fn toFoldRange(self: *const FoldingRegions, index: usize) FoldRange {
        return .{
            .startLineNumber = self.getStartLineNumber(index),
            .endLineNumber = self.getEndLineNumber(index),
            .type = self.getType(index),
            .isCollapsed = self.isCollapsed(index),
            .source = self.getSource(index),
        };
    }

    pub fn fromFoldRanges(allocator: Allocator, ranges: []const FoldRange) !FoldingRegions {
        const starts = try allocator.alloc(u32, ranges.len);
        defer allocator.free(starts);
        const ends = try allocator.alloc(u32, ranges.len);
        defer allocator.free(ends);
        var types = try allocator.alloc(?[]const u8, ranges.len);
        defer allocator.free(types);
        var got_types = false;
        for (ranges, 0..) |range, i| {
            starts[i] = @intCast(range.startLineNumber);
            ends[i] = @intCast(range.endLineNumber);
            types[i] = range.type;
            if (range.type != null) got_types = true;
        }
        var regions = try FoldingRegions.init(allocator, starts, ends, if (got_types) types else null);
        errdefer regions.deinit();
        for (ranges, 0..) |range, i| {
            regions.setCollapsed(i, range.isCollapsed);
            regions.setSource(i, range.source);
        }
        return regions;
    }
};

pub const RangeInput = union(enum) {
    regions: *FoldingRegions,
    ranges: []const FoldRange,

    fn length(self: RangeInput) usize {
        return switch (self) {
            .regions => |r| r.length(),
            .ranges => |r| r.len,
        };
    }

    fn get(self: RangeInput, index: usize) ?FoldRange {
        if (index >= self.length()) return null;
        return switch (self) {
            .regions => |r| r.toFoldRange(index),
            .ranges => |r| r[index],
        };
    }
};

/// Merges the provider ranges with the previously collapsed/user-defined
/// ranges. The second input wins on conflicts.
pub fn sanitizeAndMerge(allocator: Allocator, ranges_a: RangeInput, ranges_b: RangeInput, max_line_number: ?usize, selection: ?SelectedLines) ![]FoldRange {
    const max_line = max_line_number orelse std.math.maxInt(usize);
    var index_a: usize = 0;
    var index_b: usize = 0;
    var next_a = ranges_a.get(0);
    var next_b = ranges_b.get(0);

    var stacked = ArrayList(FoldRange).init(allocator);
    defer stacked.deinit();
    var top_stacked: ?FoldRange = null;
    var prev_line_number: usize = 0;
    var result = ArrayList(FoldRange).init(allocator);
    errdefer result.deinit();

    while (next_a != null or next_b != null) {
        var use_range: ?FoldRange = null;
        if (next_b != null and (next_a == null or next_a.?.startLineNumber >= next_b.?.startLineNumber)) {
            if (next_a != null and next_a.?.startLineNumber == next_b.?.startLineNumber) {
                if (next_b.?.source == .user_defined) {
                    use_range = next_b;
                } else {
                    use_range = next_a;
                    const starts_inside = if (selection) |sel| sel.startsInside(next_a.?.startLineNumber + 1, next_a.?.endLineNumber + 1) else false;
                    use_range.?.isCollapsed = next_b.?.isCollapsed and (next_a.?.endLineNumber == next_b.?.endLineNumber or !starts_inside);
                    use_range.?.source = .provider;
                }
                index_a += 1;
                next_a = ranges_a.get(index_a);
            } else {
                use_range = next_b;
                if (next_b.?.isCollapsed and next_b.?.source == .provider) use_range.?.source = .recovered;
            }
            index_b += 1;
            next_b = ranges_b.get(index_b);
        } else {
            var scan_index = index_b;
            var prescan_b = next_b;
            while (true) {
                if (prescan_b == null or prescan_b.?.startLineNumber > next_a.?.endLineNumber) {
                    use_range = next_a;
                    break;
                }
                if (prescan_b.?.source == .user_defined and prescan_b.?.endLineNumber > next_a.?.endLineNumber) break;
                scan_index += 1;
                prescan_b = ranges_b.get(scan_index);
            }
            index_a += 1;
            next_a = ranges_a.get(index_a);
        }

        if (use_range) |candidate| {
            while (top_stacked != null and top_stacked.?.endLineNumber < candidate.startLineNumber) {
                top_stacked = stacked.pop();
            }
            if (candidate.endLineNumber > candidate.startLineNumber and
                candidate.startLineNumber > prev_line_number and
                candidate.endLineNumber <= max_line and
                (top_stacked == null or top_stacked.?.endLineNumber >= candidate.endLineNumber))
            {
                try result.append(candidate);
                prev_line_number = candidate.startLineNumber;
                if (top_stacked) |top| try stacked.append(top);
                top_stacked = candidate;
            }
        }
    }

    return try result.toOwnedSlice();
}
