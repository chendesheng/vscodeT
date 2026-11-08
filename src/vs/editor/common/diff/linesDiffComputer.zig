const std = @import("std");
const Allocator = std.mem.Allocator;
const LineRangeMapping = @import("rangeMapping.zig").LineRangeMapping;
const DetailedLineRangeMapping = @import("rangeMapping.zig").DetailedLineRangeMapping;

/// A change as produced by the legacy line diff computer. Shared with
/// `rangeMapping.lineRangeMappingFromChange`.
pub const IChange = struct {
    originalStartLineNumber: usize,
    originalEndLineNumber: usize, // 0 for insertions
    modifiedStartLineNumber: usize,
    modifiedEndLineNumber: usize, // 0 for deletions
};

pub const ILinesDiffComputerOptions = struct {
    ignoreTrimWhitespace: bool,
    maxComputationTimeMs: i64,
    computeMoves: bool,
    extendToSubwords: bool = false,
};

/// A set of line changes and moved texts.
pub const LinesDiff = struct {
    const Self = @This();

    allocator: Allocator,
    /// Sorted by original line ranges.
    changes: []const DetailedLineRangeMapping,
    /// Sorted by original line ranges. Original and modified ranges must be
    /// disjoint (but can be touching).
    moves: []const MovedText,
    /// Indicates if the time out was reached.
    hit_timeout: bool,

    pub fn init(
        allocator: Allocator,
        changes: []const DetailedLineRangeMapping,
        moves: []const MovedText,
        hit_timeout: bool,
    ) Self {
        return .{ .allocator = allocator, .changes = changes, .moves = moves, .hit_timeout = hit_timeout };
    }

    pub fn deinit(self: *Self) void {
        for (@constCast(self.changes)) |*change| {
            change.deinit(self.allocator);
        }
        self.allocator.free(self.changes);
        for (@constCast(self.moves)) |*moved| {
            moved.deinit(self.allocator);
        }
        self.allocator.free(self.moves);
    }
};

/// A diff from the original text to a moved text.
pub const MovedText = struct {
    const Self = @This();

    lineRangeMapping: LineRangeMapping,
    /// The diff from the original text to the moved text. Must be contained in
    /// the original/modified line range. Can be empty if the text didn't change
    /// (only moved).
    changes: []const DetailedLineRangeMapping,

    pub fn init(line_range_mapping: LineRangeMapping, changes: []const DetailedLineRangeMapping) Self {
        return .{ .lineRangeMapping = line_range_mapping, .changes = changes };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        for (@constCast(self.changes)) |*change| {
            change.deinit(allocator);
        }
        allocator.free(self.changes);
    }

    pub fn flip(self: *const Self, allocator: Allocator) !MovedText {
        const flipped = try allocator.alloc(DetailedLineRangeMapping, self.changes.len);
        errdefer allocator.free(flipped);
        for (self.changes, 0..) |change, i| {
            flipped[i] = try change.flip(allocator);
        }
        return MovedText.init(self.lineRangeMapping.flip(), flipped);
    }
};

/// Computes a diff between two arrays of lines.
pub const ILinesDiffComputer = struct {
    context: *anyopaque,
    compute_diff: *const fn (context: *anyopaque, allocator: Allocator, original_lines: []const []const u8, modified_lines: []const []const u8, options: ILinesDiffComputerOptions) anyerror!LinesDiff,

    pub fn computeDiff(
        self: ILinesDiffComputer,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        options: ILinesDiffComputerOptions,
    ) !LinesDiff {
        return self.compute_diff(self.context, allocator, original_lines, modified_lines, options);
    }
};
