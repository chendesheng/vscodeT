const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const OffsetRange = @import("../../core/ranges/offsetRange.zig").OffsetRange;
const LineRange = @import("../../core/ranges/lineRange.zig").LineRange;
const Position = @import("../../core/position.zig").Position;
const Range = @import("../../core/range.zig").Range;
const AbstractText = @import("../../core/text/abstractText.zig").AbstractText;
const lines_diff = @import("../linesDiffComputer.zig");
const ILinesDiffComputer = lines_diff.ILinesDiffComputer;
const ILinesDiffComputerOptions = lines_diff.ILinesDiffComputerOptions;
const LinesDiff = lines_diff.LinesDiff;
const MovedText = lines_diff.MovedText;
const range_mapping = @import("../rangeMapping.zig");
const DetailedLineRangeMapping = range_mapping.DetailedLineRangeMapping;
const LineRangeMapping = range_mapping.LineRangeMapping;
const RangeMapping = range_mapping.RangeMapping;
const lineRangeMappingFromRangeMappings = range_mapping.lineRangeMappingFromRangeMappings;
const diff = @import("algorithms/diffAlgorithm.zig");
const DateTimeout = diff.DateTimeout;
const InfiniteTimeout = diff.InfiniteTimeout;
const ITimeout = diff.ITimeout;
const SequenceDiff = diff.SequenceDiff;
const DiffAlgorithmResult = diff.DiffAlgorithmResult;
const DynamicProgrammingDiffing = @import("algorithms/dynamicProgrammingDiffing.zig").DynamicProgrammingDiffing;
const EqualityScore = @import("algorithms/dynamicProgrammingDiffing.zig").EqualityScore;
const MyersDiffAlgorithm = @import("algorithms/myersDiffAlgorithm.zig").MyersDiffAlgorithm;
const computeMovedLines = @import("computeMovedLines.zig").computeMovedLines;
const heuristics = @import("heuristicSequenceOptimizations.zig");
const LineSequence = @import("lineSequence.zig").LineSequence;
const LinesSliceCharSequence = @import("linesSliceCharSequence.zig").LinesSliceCharSequence;

pub const DefaultLinesDiffComputer = struct {
    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub const DiffWithRawChanges = struct {
        diff: LinesDiff,
        raw_changes: []RangeMapping,
    };

    pub fn computeDiff(
        self: *const Self,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        options: ILinesDiffComputerOptions,
    ) !LinesDiff {
        return self.computeDiffInternal(allocator, original_lines, modified_lines, options, null);
    }

    /// Also returns unweighted character changes, reusing the character diff for large slices.
    pub fn computeDiffWithRawChanges(
        self: *const Self,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        options: ILinesDiffComputerOptions,
    ) !DiffWithRawChanges {
        var raw_changes = ArrayList(RangeMapping).init(allocator);
        errdefer raw_changes.deinit();

        const result = try self.computeDiffInternal(allocator, original_lines, modified_lines, options, &raw_changes);
        return .{
            .diff = result,
            .raw_changes = try raw_changes.toOwnedSlice(),
        };
    }

    fn computeDiffInternal(
        self: *const Self,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        options: ILinesDiffComputerOptions,
        raw_changes: ?*ArrayList(RangeMapping),
    ) !LinesDiff {
        if (original_lines.len <= 1 and linesEqual(original_lines, modified_lines)) {
            return emptyDiff(allocator);
        }

        if ((original_lines.len == 1 and original_lines[0].len == 0) or
            (modified_lines.len == 1 and modified_lines[0].len == 0))
        {
            const original_end_line = original_lines.len;
            const original_end_column = if (original_lines.len > 0) original_lines[original_lines.len - 1].len + 1 else 1;
            const modified_end_line = modified_lines.len;
            const modified_end_column = if (modified_lines.len > 0) modified_lines[modified_lines.len - 1].len + 1 else 1;
            const range = RangeMapping.init(
                Range.init(1, 1, original_end_line, original_end_column),
                Range.init(1, 1, modified_end_line, modified_end_column),
            );
            if (raw_changes) |raw| {
                try raw.append(range);
            }

            const inner = try allocator.alloc(RangeMapping, 1);
            errdefer allocator.free(inner);
            inner[0] = range;
            const changes = try allocator.alloc(DetailedLineRangeMapping, 1);
            errdefer allocator.free(changes);
            changes[0] = DetailedLineRangeMapping.init(
                LineRange.init(1, original_lines.len + 1),
                LineRange.init(1, modified_lines.len + 1),
                inner,
            );
            errdefer changes[0].deinit(allocator);
            return LinesDiff.init(
                allocator,
                changes,
                try allocator.alloc(MovedText, 0),
                false,
            );
        }

        var date_timeout: DateTimeout = undefined;
        const timeout: ITimeout = if (options.maxComputationTimeMs == 0)
            InfiniteTimeout.getInstance()
        else blk: {
            date_timeout = try DateTimeout.init(options.maxComputationTimeMs);
            break :blk date_timeout.interface();
        };
        const consider_whitespace_changes = !options.ignoreTrimWhitespace;

        var perfect_hashes = std.StringHashMap(usize).init(allocator);
        defer perfect_hashes.deinit();

        const original_lines_hashes = try allocator.alloc(u64, original_lines.len);
        defer allocator.free(original_lines_hashes);
        const modified_lines_hashes = try allocator.alloc(u64, modified_lines.len);
        defer allocator.free(modified_lines_hashes);

        for (original_lines, 0..) |line, i| {
            original_lines_hashes[i] = try getOrCreateHash(&perfect_hashes, std.mem.trim(u8, line, " \t\r\n"));
        }
        for (modified_lines, 0..) |line, i| {
            modified_lines_hashes[i] = try getOrCreateHash(&perfect_hashes, std.mem.trim(u8, line, " \t\r\n"));
        }

        var sequence1 = LineSequence.init(original_lines_hashes, original_lines);
        var sequence2 = LineSequence.init(modified_lines_hashes, modified_lines);

        var dynamic_programming = DynamicProgrammingDiffing{};
        var myers = MyersDiffAlgorithm{};

        var line_alignment_result: DiffAlgorithmResult = undefined;
        if (sequence1.length() + sequence2.length() < 1700) {
            // Use the improved algorithm for small files
            var score_context = ScoreContext{
                .original_lines = original_lines,
                .modified_lines = modified_lines,
            };
            line_alignment_result = try dynamic_programming.compute(
                allocator,
                sequence1.sequence(),
                sequence2.sequence(),
                timeout,
                EqualityScore{ .context = &score_context, .score = ScoreContext.score },
            );
        } else {
            line_alignment_result = try myers.compute(allocator, sequence1.sequence(), sequence2.sequence(), timeout);
        }
        defer line_alignment_result.deinit(allocator);

        var line_alignments = line_alignment_result.diffs;
        var hit_timeout = line_alignment_result.hit_timeout;

        var owned_alignments: ?[]SequenceDiff = null;
        defer if (owned_alignments) |owned| allocator.free(owned);

        line_alignments = adoptDiffs(allocator, &owned_alignments, try heuristics.optimizeSequenceDiffs(
            allocator,
            sequence1.sequence(),
            sequence2.sequence(),
            line_alignments,
        ));
        line_alignments = adoptDiffs(allocator, &owned_alignments, try heuristics.removeVeryShortMatchingLinesBetweenDiffs(
            allocator,
            sequence1,
            sequence2,
            line_alignments,
        ));

        var alignments = ArrayList(RangeMapping).init(allocator);
        defer alignments.deinit();

        var seq1_last_start: usize = 0;
        var seq2_last_start: usize = 0;

        for (line_alignments) |diff_value| {
            std.debug.assert(diff_value.seq1Range.start - seq1_last_start == diff_value.seq2Range.start - seq2_last_start);

            const equal_lines_count = diff_value.seq1Range.start - seq1_last_start;
            if (try self.scanForWhitespaceChanges(
                allocator,
                original_lines,
                modified_lines,
                &alignments,
                seq1_last_start,
                seq2_last_start,
                equal_lines_count,
                consider_whitespace_changes,
                timeout,
                options,
                raw_changes,
            )) {
                hit_timeout = true;
            }

            seq1_last_start = diff_value.seq1Range.endExclusive;
            seq2_last_start = diff_value.seq2Range.endExclusive;

            const character_diffs = try self.refineDiff(allocator, original_lines, modified_lines, diff_value, timeout, consider_whitespace_changes, options, raw_changes);
            defer allocator.free(character_diffs.mappings);
            if (character_diffs.hit_timeout) {
                hit_timeout = true;
            }
            try alignments.appendSlice(character_diffs.mappings);
        }

        if (try self.scanForWhitespaceChanges(
            allocator,
            original_lines,
            modified_lines,
            &alignments,
            seq1_last_start,
            seq2_last_start,
            original_lines.len - seq1_last_start,
            consider_whitespace_changes,
            timeout,
            options,
            raw_changes,
        )) {
            hit_timeout = true;
        }

        var original_text = AbstractText.initArray(allocator, original_lines);
        defer original_text.deinit();
        var modified_text = AbstractText.initArray(allocator, modified_lines);
        defer modified_text.deinit();

        const changes = try lineRangeMappingFromRangeMappings(allocator, alignments.items, &original_text, &modified_text, false);
        errdefer {
            for (changes) |*change| {
                change.deinit(allocator);
            }
            allocator.free(changes);
        }

        var moves: []MovedText = undefined;
        if (options.computeMoves) {
            moves = try self.computeMoves(
                allocator,
                changes,
                original_lines,
                modified_lines,
                original_lines_hashes,
                modified_lines_hashes,
                timeout,
                consider_whitespace_changes,
                options,
            );
        } else {
            moves = try allocator.alloc(MovedText, 0);
        }

        return LinesDiff.init(allocator, changes, moves, hit_timeout);
    }

    fn computeMoves(
        self: *const Self,
        allocator: Allocator,
        changes: []DetailedLineRangeMapping,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        hashed_original_lines: []const u64,
        hashed_modified_lines: []const u64,
        timeout: ITimeout,
        consider_whitespace_changes: bool,
        options: ILinesDiffComputerOptions,
    ) ![]MovedText {
        const moves = try computeMovedLines(
            allocator,
            changes,
            original_lines,
            modified_lines,
            hashed_original_lines,
            hashed_modified_lines,
            timeout,
        );
        defer allocator.free(moves);

        var original_text = AbstractText.initArray(allocator, original_lines);
        defer original_text.deinit();
        var modified_text = AbstractText.initArray(allocator, modified_lines);
        defer modified_text.deinit();

        var result = ArrayList(MovedText).init(allocator);
        errdefer result.deinit();

        for (moves) |move| {
            const move_changes = try self.refineDiff(
                allocator,
                original_lines,
                modified_lines,
                SequenceDiff.init(move.original.toOffsetRange(), move.modified.toOffsetRange()),
                timeout,
                consider_whitespace_changes,
                options,
                null,
            );
            defer allocator.free(move_changes.mappings);
            const mappings = try lineRangeMappingFromRangeMappings(allocator, move_changes.mappings, &original_text, &modified_text, true);
            errdefer {
                for (mappings) |*mapping| {
                    mapping.deinit(allocator);
                }
                allocator.free(mappings);
            }
            try result.append(MovedText.init(move, mappings));
        }

        return result.toOwnedSlice();
    }

    fn scanForWhitespaceChanges(
        self: *const Self,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        alignments: *ArrayList(RangeMapping),
        seq1_last_start: usize,
        seq2_last_start: usize,
        equal_lines_count: usize,
        consider_whitespace_changes: bool,
        timeout: ITimeout,
        options: ILinesDiffComputerOptions,
        raw_changes: ?*ArrayList(RangeMapping),
    ) !bool {
        if (!consider_whitespace_changes) {
            return false;
        }

        var hit_timeout = false;
        var i: usize = 0;
        while (i < equal_lines_count) : (i += 1) {
            const seq1_offset = seq1_last_start + i;
            const seq2_offset = seq2_last_start + i;
            if (!std.mem.eql(u8, original_lines[seq1_offset], modified_lines[seq2_offset])) {
                // This is because of whitespace changes, diff these lines
                const character_diffs = try self.refineDiff(
                    allocator,
                    original_lines,
                    modified_lines,
                    SequenceDiff.init(
                        OffsetRange.init(seq1_offset, seq1_offset + 1),
                        OffsetRange.init(seq2_offset, seq2_offset + 1),
                    ),
                    timeout,
                    consider_whitespace_changes,
                    options,
                    raw_changes,
                );
                defer allocator.free(character_diffs.mappings);
                try alignments.appendSlice(character_diffs.mappings);
                if (character_diffs.hit_timeout) {
                    hit_timeout = true;
                }
            }
        }
        return hit_timeout;
    }

    fn refineDiff(
        self: *const Self,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        diff_value: SequenceDiff,
        timeout: ITimeout,
        consider_whitespace_changes: bool,
        options: ILinesDiffComputerOptions,
        raw_changes: ?*ArrayList(RangeMapping),
    ) !RefineResult {
        _ = self;
        const line_range_mapping = toLineRangeMapping(diff_value);
        const character_range_mapping = try line_range_mapping.toRangeMapping2(original_lines, modified_lines);

        var slice1 = try LinesSliceCharSequence.init(allocator, original_lines, character_range_mapping.originalRange, consider_whitespace_changes);
        defer slice1.deinit();
        var slice2 = try LinesSliceCharSequence.init(allocator, modified_lines, character_range_mapping.modifiedRange, consider_whitespace_changes);
        defer slice2.deinit();

        const use_dynamic_programming = slice1.length() + slice2.length() < 500;
        var dynamic_programming = DynamicProgrammingDiffing{};
        var myers = MyersDiffAlgorithm{};

        var diff_result = if (use_dynamic_programming)
            try dynamic_programming.compute(allocator, slice1.sequence(), slice2.sequence(), timeout, null)
        else
            try myers.compute(allocator, slice1.sequence(), slice2.sequence(), timeout);
        defer diff_result.deinit(allocator);

        var hit_timeout = diff_result.hit_timeout;
        if (raw_changes) |raw| {
            // The small-slice display algorithm favors consecutive matches over the longest common subsequence.
            var raw_result: ?DiffAlgorithmResult = null;
            defer {
                if (raw_result) |*result| {
                    result.deinit(allocator);
                }
            }
            if (use_dynamic_programming and !hit_timeout) {
                raw_result = try myers.compute(allocator, slice1.sequence(), slice2.sequence(), timeout);
            }
            const raw_diffs = if (raw_result) |result| result.diffs else diff_result.diffs;
            if (raw_result) |result| {
                if (result.hit_timeout) {
                    hit_timeout = true;
                }
            }
            for (raw_diffs) |change| {
                try raw.append(RangeMapping.init(
                    slice1.translateRange(change.seq1Range),
                    slice2.translateRange(change.seq2Range),
                ));
            }
        }

        var owned_diffs: ?[]SequenceDiff = null;
        defer if (owned_diffs) |owned| allocator.free(owned);
        var diffs = diff_result.diffs;

        diffs = adoptDiffs(allocator, &owned_diffs, try heuristics.optimizeSequenceDiffs(allocator, slice1.sequence(), slice2.sequence(), diffs));
        diffs = adoptDiffs(allocator, &owned_diffs, try heuristics.extendDiffsToEntireWordIfAppropriate(
            allocator,
            &slice1,
            &slice2,
            diffs,
            findWordContainingAny,
            false,
        ));

        if (options.extendToSubwords) {
            diffs = adoptDiffs(allocator, &owned_diffs, try heuristics.extendDiffsToEntireWordIfAppropriate(
                allocator,
                &slice1,
                &slice2,
                diffs,
                findSubWordContainingAny,
                true,
            ));
        }

        diffs = adoptDiffs(allocator, &owned_diffs, try heuristics.removeShortMatches(allocator, slice1.sequence(), slice2.sequence(), diffs));
        diffs = adoptDiffs(allocator, &owned_diffs, try heuristics.removeVeryShortMatchingTextBetweenLongDiffs(allocator, &slice1, &slice2, diffs));

        var result = ArrayList(RangeMapping).init(allocator);
        errdefer result.deinit();
        for (diffs) |current| {
            try result.append(RangeMapping.init(
                slice1.translateRange(current.seq1Range),
                slice2.translateRange(current.seq2Range),
            ));
        }

        return RefineResult{
            .mappings = try result.toOwnedSlice(),
            .hit_timeout = hit_timeout,
        };
    }

    fn computeDiffAny(
        context: *anyopaque,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        options: ILinesDiffComputerOptions,
    ) anyerror!LinesDiff {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.computeDiff(allocator, original_lines, modified_lines, options);
    }

    pub fn asLinesDiffComputer(self: *Self) ILinesDiffComputer {
        return .{
            .context = self,
            .compute_diff = computeDiffAny,
        };
    }
};

const RefineResult = struct {
    mappings: []RangeMapping,
    hit_timeout: bool,
};

const ScoreContext = struct {
    original_lines: []const []const u8,
    modified_lines: []const []const u8,

    /// The upstream implementation uses fractional scores. Scale them to
    /// integers to preserve their ordering with the integer-based DP port.
    fn score(context: *anyopaque, offset1: usize, offset2: usize) isize {
        const self: *ScoreContext = @ptrCast(@alignCast(context));
        const original = self.original_lines[offset1];
        const modified = self.modified_lines[offset2];
        if (std.mem.eql(u8, original, modified)) {
            if (modified.len == 0) {
                return 100; // 0.1
            }
            return 1000 + @as(isize, @intFromFloat(@round(1000.0 * @log(1.0 + @as(f64, @floatFromInt(modified.len))))));
        }
        return 990; // 0.99
    }
};

fn emptyDiff(allocator: Allocator) !LinesDiff {
    const changes = try allocator.alloc(DetailedLineRangeMapping, 0);
    errdefer allocator.free(changes);
    const moves = try allocator.alloc(MovedText, 0);
    return LinesDiff.init(allocator, changes, moves, false);
}

fn getOrCreateHash(perfect_hashes: *std.StringHashMap(usize), text: []const u8) !u64 {
    if (perfect_hashes.get(text)) |hash| {
        return hash;
    }
    const hash = perfect_hashes.count();
    try perfect_hashes.put(text, hash);
    return hash;
}

fn linesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |line_a, line_b| {
        if (!std.mem.eql(u8, line_a, line_b)) {
            return false;
        }
    }
    return true;
}

fn adoptDiffs(allocator: Allocator, owned: *?[]SequenceDiff, new_diffs: []SequenceDiff) []SequenceDiff {
    if (owned.*) |old| {
        allocator.free(old);
    }
    owned.* = new_diffs;
    return new_diffs;
}

fn findWordContainingAny(sequence: *const LinesSliceCharSequence, index: usize) ?OffsetRange {
    return sequence.findWordContaining(index);
}

fn findSubWordContainingAny(sequence: *const LinesSliceCharSequence, index: usize) ?OffsetRange {
    return sequence.findSubWordContaining(index);
}

fn toLineRangeMapping(sequence_diff: SequenceDiff) LineRangeMapping {
    return LineRangeMapping.init(
        LineRange.init(sequence_diff.seq1Range.start + 1, sequence_diff.seq1Range.endExclusive + 1),
        LineRange.init(sequence_diff.seq2Range.start + 1, sequence_diff.seq2Range.endExclusive + 1),
    );
}

test "DefaultLinesDiffComputer: simple change" {
    const allocator = std.testing.allocator;

    const original = [_][]const u8{ "aaa", "bbb", "ccc" };
    const modified = [_][]const u8{ "aaa", "xxx", "ccc" };

    var computer = DefaultLinesDiffComputer.init();
    const options = ILinesDiffComputerOptions{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
        .extendToSubwords = false,
    };
    var result = try computer.computeDiff(allocator, &original, &modified, options);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.changes.len);
    try std.testing.expectEqual(LineRange.init(2, 3), result.changes[0].original);
    try std.testing.expectEqual(LineRange.init(2, 3), result.changes[0].modified);
    try std.testing.expect(!result.hit_timeout);
    try std.testing.expectEqual(@as(usize, 0), result.moves.len);
    try std.testing.expectEqual(@as(usize, 1), result.changes[0].inner_changes.?.len);
}

test "DefaultLinesDiffComputer: empty line diff" {
    const allocator = std.testing.allocator;

    const original = [_][]const u8{"hello"};
    const modified = [_][]const u8{""};

    var computer = DefaultLinesDiffComputer.init();
    const options = ILinesDiffComputerOptions{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
        .extendToSubwords = false,
    };
    var result = try computer.computeDiff(allocator, &original, &modified, options);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.changes.len);
    try std.testing.expectEqual(LineRange.init(1, 2), result.changes[0].original);
    try std.testing.expectEqual(LineRange.init(1, 2), result.changes[0].modified);
}

test "DefaultLinesDiffComputer: whitespace only change" {
    const allocator = std.testing.allocator;

    const original = [_][]const u8{"aaa  "};
    const modified = [_][]const u8{"aaa"};

    var computer = DefaultLinesDiffComputer.init();

    const ignore_options = ILinesDiffComputerOptions{
        .ignoreTrimWhitespace = true,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
        .extendToSubwords = false,
    };
    var ignored = try computer.computeDiff(allocator, &original, &modified, ignore_options);
    defer ignored.deinit();
    try std.testing.expectEqual(@as(usize, 0), ignored.changes.len);

    const consider_options = ILinesDiffComputerOptions{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
        .extendToSubwords = false,
    };
    var considered = try computer.computeDiff(allocator, &original, &modified, consider_options);
    defer considered.deinit();
    try std.testing.expectEqual(@as(usize, 1), considered.changes.len);
}

test "DefaultLinesDiffComputer: computes moves and raw changes" {
    const allocator = std.testing.allocator;

    const original = [_][]const u8{ "aaaaaa", "bbbbbb", "cccccc", "xxxxxx", "yyyyyy", "zzzzzz" };
    const modified = [_][]const u8{ "xxxxxx", "yyyyyy", "zzzzzz", "aaaaaa", "bbbbbb", "cccccc" };

    var computer = DefaultLinesDiffComputer.init();
    const options = ILinesDiffComputerOptions{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = true,
        .extendToSubwords = false,
    };
    var result = try computer.computeDiffWithRawChanges(allocator, &original, &modified, options);
    defer result.diff.deinit();
    defer allocator.free(result.raw_changes);

    try std.testing.expectEqual(@as(usize, 1), result.diff.moves.len);
    try std.testing.expectEqual(@as(usize, 3), result.diff.moves[0].lineRangeMapping.original.length());
    try std.testing.expectEqual(@as(usize, 3), result.diff.moves[0].lineRangeMapping.modified.length());
    try std.testing.expect(result.raw_changes.len > 0);
}

test "DefaultLinesDiffComputer: interface adapter" {
    const allocator = std.testing.allocator;

    const original = [_][]const u8{ "a", "b" };
    const modified = [_][]const u8{ "a", "c" };

    var computer = DefaultLinesDiffComputer.init();
    const computer_interface = computer.asLinesDiffComputer();
    const options = ILinesDiffComputerOptions{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
        .extendToSubwords = false,
    };
    var result = try computer_interface.computeDiff(allocator, &original, &modified, options);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.changes.len);
}
