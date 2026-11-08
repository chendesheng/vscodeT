// Port of `src/vs/editor/common/diff/legacyLinesDiffComputer.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const diff = @import("../../../base/common/diff/diff.zig");
const strings = @import("../../../base/common/strings.zig");
const time_compat = @import("../../../base/common/timeCompat.zig");

const lines_diff_computer = @import("linesDiffComputer.zig");
const range_mapping = @import("rangeMapping.zig");
const range_module = @import("../core/range.zig");
const line_range = @import("../core/ranges/lineRange.zig");

const DiffChange = diff.DiffChange;
const LcsDiff = diff.LcsDiff;
const ISequence = diff.ISequence;
const IDiffResult = diff.IDiffResult;
const LinesDiff = lines_diff_computer.LinesDiff;
const ILinesDiffComputer = lines_diff_computer.ILinesDiffComputer;
const ILinesDiffComputerOptions = lines_diff_computer.ILinesDiffComputerOptions;
const DetailedLineRangeMapping = range_mapping.DetailedLineRangeMapping;
const RangeMapping = range_mapping.RangeMapping;
const Range = range_module.Range;
const LineRange = line_range.LineRange;

const MINIMUM_MATCHING_CHARACTER_LENGTH = 3;

const CharCodeLineFeed = 0x0A;

/// A character level change.
pub const CharChange = struct {
    originalStartLineNumber: usize,
    originalStartColumn: usize,
    originalEndLineNumber: usize,
    originalEndColumn: usize,
    modifiedStartLineNumber: usize,
    modifiedStartColumn: usize,
    modifiedEndLineNumber: usize,
    modifiedEndColumn: usize,

    fn createFromDiffChange(
        diff_change: DiffChange,
        original_char_sequence: *const CharSequence,
        modified_char_sequence: *const CharSequence,
    ) !CharChange {
        const original_end_index = diff_change.originalStart + diff_change.originalLength - 1;
        const modified_end_index = diff_change.modifiedStart + diff_change.modifiedLength - 1;

        return .{
            .originalStartLineNumber = @intCast(try original_char_sequence.getStartLineNumber(diff_change.originalStart)),
            .originalStartColumn = @intCast(try original_char_sequence.getStartColumn(diff_change.originalStart)),
            .originalEndLineNumber = @intCast(try original_char_sequence.getEndLineNumber(original_end_index)),
            .originalEndColumn = @intCast(try original_char_sequence.getEndColumn(original_end_index)),
            .modifiedStartLineNumber = @intCast(try modified_char_sequence.getStartLineNumber(diff_change.modifiedStart)),
            .modifiedStartColumn = @intCast(try modified_char_sequence.getStartColumn(diff_change.modifiedStart)),
            .modifiedEndLineNumber = @intCast(try modified_char_sequence.getEndLineNumber(modified_end_index)),
            .modifiedEndColumn = @intCast(try modified_char_sequence.getEndColumn(modified_end_index)),
        };
    }
};

/// A line change.
pub const LineChange = struct {
    originalStartLineNumber: usize,
    originalEndLineNumber: usize,
    modifiedStartLineNumber: usize,
    modifiedEndLineNumber: usize,
    charChanges: ?[]CharChange,

    pub fn deinit(self: *LineChange, allocator: Allocator) void {
        if (self.charChanges) |char_changes| {
            allocator.free(char_changes);
        }
        self.charChanges = null;
    }
};

pub const IDiffComputerResult = struct {
    quitEarly: bool,
    changes: ArrayList(LineChange),

    pub fn deinit(self: *IDiffComputerResult) void {
        for (self.changes.items) |*change| {
            change.deinit(self.changes.allocator);
        }
        self.changes.deinit();
    }
};

pub const IDiffComputerOpts = struct {
    shouldComputeCharChanges: bool,
    shouldPostProcessCharChanges: bool,
    shouldIgnoreTrimWhitespace: bool,
    shouldMakePrettyDiff: bool,
    maxComputationTime: i64,
};

fn getFirstNonBlankColumn(text: []const u8, default_value: usize) usize {
    const result = strings.firstNonWhitespaceIndex(text);
    if (result == null) {
        return default_value;
    }
    return result.? + 1;
}

fn getLastNonBlankColumn(text: []const u8, default_value: usize) usize {
    const result = strings.lastNonWhitespaceIndex(text);
    if (result == null) {
        return default_value;
    }
    return result.? + 2;
}

/// Predicate that stops the diff when the configured maximum runtime elapsed.
const ContinueProcessingPredicate = struct {
    maximum_runtime: i64,
    start_time: i64,

    fn init(maximum_runtime: i64) ContinueProcessingPredicate {
        return .{ .maximum_runtime = maximum_runtime, .start_time = time_compat.milliTimestamp() };
    }

    fn shouldContinue(self: *const ContinueProcessingPredicate) bool {
        if (self.maximum_runtime == 0) {
            return true;
        }
        return time_compat.milliTimestamp() - self.start_time < self.maximum_runtime;
    }

    fn asInterface(self: *ContinueProcessingPredicate) diff.IContinueProcessingPredicate {
        return .{
            .context = self,
            .predicateFn = struct {
                fn predicate(context: *anyopaque, _: isize, _: isize) bool {
                    const self_: *ContinueProcessingPredicate = @ptrCast(@alignCast(context));
                    return self_.shouldContinue();
                }
            }.predicate,
        };
    }
};

/// Sequence of (trimmed) lines used for the line-level diff.
const LineSequence = struct {
    allocator: Allocator,
    lines: []const []const u8,
    startColumns: []usize,
    endColumns: []usize,
    elements: [][]const u8,

    fn init(allocator: Allocator, lines: []const []const u8) !LineSequence {
        const start_columns = try allocator.alloc(usize, lines.len);
        errdefer allocator.free(start_columns);
        const end_columns = try allocator.alloc(usize, lines.len);
        errdefer allocator.free(end_columns);
        const elements = try allocator.alloc([]const u8, lines.len);
        errdefer allocator.free(elements);

        for (lines, 0..) |line, i| {
            start_columns[i] = getFirstNonBlankColumn(line, 1);
            end_columns[i] = getLastNonBlankColumn(line, 1);
            elements[i] = line[start_columns[i] - 1 .. end_columns[i] - 1];
        }

        return .{
            .allocator = allocator,
            .lines = lines,
            .startColumns = start_columns,
            .endColumns = end_columns,
            .elements = elements,
        };
    }

    fn deinit(self: *LineSequence) void {
        self.allocator.free(self.startColumns);
        self.allocator.free(self.endColumns);
        self.allocator.free(self.elements);
    }

    fn sequence(self: *LineSequence) ISequence {
        return .{
            .context = self,
            .getElementsFn = struct {
                fn get(context: *anyopaque) diff.Elements {
                    const self_: *LineSequence = @ptrCast(@alignCast(context));
                    return .{ .strings = self_.elements };
                }
            }.get,
            .getStrictElementFn = struct {
                fn get(context: *anyopaque, index: usize) []const u8 {
                    const self_: *LineSequence = @ptrCast(@alignCast(context));
                    return self_.lines[index];
                }
            }.get,
        };
    }

    fn getStartLineNumber(self: *const LineSequence, i: usize) usize {
        _ = self;
        return i + 1;
    }

    fn getEndLineNumber(self: *const LineSequence, i: usize) usize {
        _ = self;
        return i + 1;
    }

    fn createCharSequence(self: *const LineSequence, should_ignore_trim_whitespace: bool, start_index: usize, end_index: usize) !CharSequence {
        var char_codes = ArrayList(i32).init(self.allocator);
        errdefer char_codes.deinit();
        var line_numbers = ArrayList(usize).init(self.allocator);
        errdefer line_numbers.deinit();
        var columns = ArrayList(usize).init(self.allocator);
        errdefer columns.deinit();

        var index = start_index;
        while (index <= end_index) : (index += 1) {
            const line_content = self.lines[index];
            const start_column: usize = if (should_ignore_trim_whitespace) self.startColumns[index] else 1;
            const end_column: usize = if (should_ignore_trim_whitespace) self.endColumns[index] else line_content.len + 1;
            var column = start_column;
            while (column < end_column) : (column += 1) {
                try char_codes.append(@as(i32, line_content[column - 1]));
                try line_numbers.append(index + 1);
                try columns.append(column);
            }
            if (!should_ignore_trim_whitespace and index < end_index) {
                // Add \n if trim whitespace is not ignored
                try char_codes.append(CharCodeLineFeed);
                try line_numbers.append(index + 1);
                try columns.append(line_content.len + 1);
            }
        }

        return .{
            .allocator = self.allocator,
            .charCodes = try char_codes.toOwnedSlice(),
            .lineNumbers = try line_numbers.toOwnedSlice(),
            .columns = try columns.toOwnedSlice(),
        };
    }
};

const IllegalIndexError = error{IllegalIndex};

/// Sequence of characters with a mapping back to (line, column) positions.
const CharSequence = struct {
    allocator: Allocator,
    charCodes: []i32,
    lineNumbers: []usize,
    columns: []usize,

    fn deinit(self: *CharSequence) void {
        self.allocator.free(self.charCodes);
        self.allocator.free(self.lineNumbers);
        self.allocator.free(self.columns);
    }

    fn sequence(self: *CharSequence) ISequence {
        return .{
            .context = self,
            .getElementsFn = struct {
                fn get(context: *anyopaque) diff.Elements {
                    const self_: *CharSequence = @ptrCast(@alignCast(context));
                    return .{ .ints = self_.charCodes };
                }
            }.get,
        };
    }

    fn assertIndex(self: *const CharSequence, index: isize, length: usize) IllegalIndexError!void {
        if (index < 0 or index >= @as(isize, @intCast(length))) {
            return error.IllegalIndex;
        }
        _ = self;
    }

    fn getStartLineNumber(self: *const CharSequence, i: isize) IllegalIndexError!isize {
        if (i > 0 and i == @as(isize, @intCast(self.lineNumbers.len))) {
            // the start line number of the element after the last element is
            // the end line number of the last element
            return self.getEndLineNumber(i - 1);
        }
        try self.assertIndex(i, self.lineNumbers.len);
        return @intCast(self.lineNumbers[@intCast(i)]);
    }

    fn getEndLineNumber(self: *const CharSequence, i: isize) IllegalIndexError!isize {
        if (i == -1) {
            // the end line number of the element before the first element is
            // the start line number of the first element
            return self.getStartLineNumber(0);
        }
        try self.assertIndex(i, self.lineNumbers.len);
        if (self.charCodes[@intCast(i)] == CharCodeLineFeed) {
            return @as(isize, @intCast(self.lineNumbers[@intCast(i)])) + 1;
        }
        return @intCast(self.lineNumbers[@intCast(i)]);
    }

    fn getStartColumn(self: *const CharSequence, i: isize) IllegalIndexError!isize {
        if (i > 0 and i == @as(isize, @intCast(self.columns.len))) {
            // the start column of the element after the last element is the
            // end column of the last element
            return self.getEndColumn(i - 1);
        }
        try self.assertIndex(i, self.columns.len);
        return @intCast(self.columns[@intCast(i)]);
    }

    fn getEndColumn(self: *const CharSequence, i: isize) IllegalIndexError!isize {
        if (i == -1) {
            // the end column of the element before the first element is the
            // start column of the first element
            return self.getStartColumn(0);
        }
        try self.assertIndex(i, self.columns.len);
        if (self.charCodes[@intCast(i)] == CharCodeLineFeed) {
            return 1;
        }
        return @as(isize, @intCast(self.columns[@intCast(i)])) + 1;
    }
};

fn computeDiffWithSequences(
    allocator: Allocator,
    original_sequence: ISequence,
    modified_sequence: ISequence,
    continue_processing_predicate: *ContinueProcessingPredicate,
    pretty: bool,
) !IDiffResult {
    var diff_algo = try LcsDiff.init(
        allocator,
        original_sequence,
        modified_sequence,
        continue_processing_predicate.asInterface(),
    );
    defer diff_algo.deinit();
    return diff_algo.computeDiff(pretty);
}

fn postProcessCharChanges(allocator: Allocator, raw_changes: []const DiffChange) ![]DiffChange {
    if (raw_changes.len <= 1) {
        return allocator.dupe(DiffChange, raw_changes);
    }

    var result = ArrayList(DiffChange).init(allocator);
    errdefer result.deinit();
    try result.append(raw_changes[0]);

    for (raw_changes[1..]) |curr_change| {
        const previous_change = result.items[result.items.len - 1];

        const original_matching_length = curr_change.originalStart - (previous_change.originalStart + previous_change.originalLength);
        const modified_matching_length = curr_change.modifiedStart - (previous_change.modifiedStart + previous_change.modifiedLength);
        // Both of the above should be equal, but the continueProcessingPredicate
        // may prevent this from being true.
        const matching_length = @min(original_matching_length, modified_matching_length);

        if (matching_length < MINIMUM_MATCHING_CHARACTER_LENGTH) {
            // Merge the current change into the previous one
            const previous = &result.items[result.items.len - 1];
            previous.originalLength = (curr_change.originalStart + curr_change.originalLength) - previous.originalStart;
            previous.modifiedLength = (curr_change.modifiedStart + curr_change.modifiedLength) - previous.modifiedStart;
        } else {
            // Add the current change
            try result.append(curr_change);
        }
    }

    return result.toOwnedSlice();
}

/// Computes the diff between two documents, producing legacy `LineChange`s.
pub const DiffComputer = struct {
    allocator: Allocator,
    shouldComputeCharChanges: bool,
    shouldPostProcessCharChanges: bool,
    shouldIgnoreTrimWhitespace: bool,
    shouldMakePrettyDiff: bool,
    originalLines: []const []const u8,
    modifiedLines: []const []const u8,
    original: LineSequence,
    modified: LineSequence,
    continueLineDiff: ContinueProcessingPredicate,
    continueCharDiff: ContinueProcessingPredicate,

    pub fn init(
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        opts: IDiffComputerOpts,
    ) !DiffComputer {
        var original = try LineSequence.init(allocator, original_lines);
        errdefer original.deinit();
        var modified = try LineSequence.init(allocator, modified_lines);
        errdefer modified.deinit();

        return .{
            .allocator = allocator,
            .shouldComputeCharChanges = opts.shouldComputeCharChanges,
            .shouldPostProcessCharChanges = opts.shouldPostProcessCharChanges,
            .shouldIgnoreTrimWhitespace = opts.shouldIgnoreTrimWhitespace,
            .shouldMakePrettyDiff = opts.shouldMakePrettyDiff,
            .originalLines = original_lines,
            .modifiedLines = modified_lines,
            .original = original,
            .modified = modified,
            .continueLineDiff = ContinueProcessingPredicate.init(opts.maxComputationTime),
            // never run after 5s for character changes...
            .continueCharDiff = ContinueProcessingPredicate.init(if (opts.maxComputationTime == 0) 0 else @min(opts.maxComputationTime, 5000)),
        };
    }

    pub fn deinit(self: *DiffComputer) void {
        self.original.deinit();
        self.modified.deinit();
    }

    pub fn computeDiff(self: *DiffComputer) !IDiffComputerResult {
        if (self.original.lines.len == 1 and self.original.lines[0].len == 0) {
            // empty original => fast path
            if (self.modified.lines.len == 1 and self.modified.lines[0].len == 0) {
                return .{ .quitEarly = false, .changes = ArrayList(LineChange).init(self.allocator) };
            }

            var changes = ArrayList(LineChange).init(self.allocator);
            errdefer changes.deinit();
            try changes.append(.{
                .originalStartLineNumber = 1,
                .originalEndLineNumber = 1,
                .modifiedStartLineNumber = 1,
                .modifiedEndLineNumber = self.modified.lines.len,
                .charChanges = null,
            });
            return .{ .quitEarly = false, .changes = changes };
        }

        if (self.modified.lines.len == 1 and self.modified.lines[0].len == 0) {
            // empty modified => fast path
            var changes = ArrayList(LineChange).init(self.allocator);
            errdefer changes.deinit();
            try changes.append(.{
                .originalStartLineNumber = 1,
                .originalEndLineNumber = self.original.lines.len,
                .modifiedStartLineNumber = 1,
                .modifiedEndLineNumber = 1,
                .charChanges = null,
            });
            return .{ .quitEarly = false, .changes = changes };
        }

        var diff_result = try computeDiffWithSequences(
            self.allocator,
            self.original.sequence(),
            self.modified.sequence(),
            &self.continueLineDiff,
            self.shouldMakePrettyDiff,
        );
        defer diff_result.deinit(self.allocator);
        const raw_changes = diff_result.changes;
        const quit_early = diff_result.quitEarly;

        // The diff is always computed with ignoring trim whitespace. This
        // ensures we get the prettiest diff.
        if (self.shouldIgnoreTrimWhitespace) {
            var line_changes = ArrayList(LineChange).init(self.allocator);
            errdefer line_changes.deinit();
            for (raw_changes) |raw_change| {
                try line_changes.append(try self.createLineChange(raw_change));
            }
            return .{ .quitEarly = quit_early, .changes = line_changes };
        }

        // Need to post-process and introduce changes where the trim whitespace
        // is different. Note that we are looping starting at -1 to also cover
        // the lines before the first change.
        var result = ArrayList(LineChange).init(self.allocator);
        errdefer result.deinit();

        var original_line_index: usize = 0;
        var modified_line_index: usize = 0;
        var i: isize = -1;
        const length: isize = @intCast(raw_changes.len);
        while (i < length) : (i += 1) {
            const next_change: ?DiffChange = if (i + 1 < length) raw_changes[@intCast(i + 1)] else null;
            const original_stop: usize = if (next_change) |change| @intCast(change.originalStart) else self.originalLines.len;
            const modified_stop: usize = if (next_change) |change| @intCast(change.modifiedStart) else self.modifiedLines.len;

            while (original_line_index < original_stop and modified_line_index < modified_stop) {
                const original_line = self.originalLines[original_line_index];
                const modified_line = self.modifiedLines[modified_line_index];

                if (!std.mem.eql(u8, original_line, modified_line)) {
                    // These lines differ only in trim whitespace

                    // Check the leading whitespace
                    {
                        var original_start_column = getFirstNonBlankColumn(original_line, 1);
                        var modified_start_column = getFirstNonBlankColumn(modified_line, 1);
                        while (original_start_column > 1 and modified_start_column > 1) {
                            const original_char = original_line[original_start_column - 2];
                            const modified_char = modified_line[modified_start_column - 2];
                            if (original_char != modified_char) {
                                break;
                            }
                            original_start_column -= 1;
                            modified_start_column -= 1;
                        }

                        if (original_start_column > 1 or modified_start_column > 1) {
                            try self.pushTrimWhitespaceCharChange(
                                &result,
                                original_line_index + 1,
                                1,
                                original_start_column,
                                modified_line_index + 1,
                                1,
                                modified_start_column,
                            );
                        }
                    }

                    // Check the trailing whitespace
                    {
                        var original_end_column = getLastNonBlankColumn(original_line, 1);
                        var modified_end_column = getLastNonBlankColumn(modified_line, 1);
                        const original_max_column = original_line.len + 1;
                        const modified_max_column = modified_line.len + 1;
                        while (original_end_column < original_max_column and modified_end_column < modified_max_column) {
                            // NOTE: upstream compares the character of the
                            // original line in both places; ported verbatim.
                            const original_char = original_line[original_end_column - 1];
                            const modified_char = original_line[modified_end_column - 1];
                            if (original_char != modified_char) {
                                break;
                            }
                            original_end_column += 1;
                            modified_end_column += 1;
                        }

                        if (original_end_column < original_max_column or modified_end_column < modified_max_column) {
                            try self.pushTrimWhitespaceCharChange(
                                &result,
                                original_line_index + 1,
                                original_end_column,
                                original_max_column,
                                modified_line_index + 1,
                                modified_end_column,
                                modified_max_column,
                            );
                        }
                    }
                }
                original_line_index += 1;
                modified_line_index += 1;
            }

            if (next_change) |change| {
                // Emit the actual change
                try result.append(try self.createLineChange(change));

                original_line_index += @intCast(change.originalLength);
                modified_line_index += @intCast(change.modifiedLength);
            }
        }

        return .{ .quitEarly = quit_early, .changes = result };
    }

    fn createLineChange(self: *DiffComputer, diff_change: DiffChange) !LineChange {
        var original_start_line_number: usize = undefined;
        var original_end_line_number: usize = undefined;
        var modified_start_line_number: usize = undefined;
        var modified_end_line_number: usize = undefined;
        var char_changes: ?[]CharChange = null;

        if (diff_change.originalLength == 0) {
            original_start_line_number = self.original.getStartLineNumber(@intCast(diff_change.originalStart)) - 1;
            original_end_line_number = 0;
        } else {
            original_start_line_number = self.original.getStartLineNumber(@intCast(diff_change.originalStart));
            original_end_line_number = self.original.getEndLineNumber(@intCast(diff_change.originalStart + diff_change.originalLength - 1));
        }

        if (diff_change.modifiedLength == 0) {
            modified_start_line_number = self.modified.getStartLineNumber(@intCast(diff_change.modifiedStart)) - 1;
            modified_end_line_number = 0;
        } else {
            modified_start_line_number = self.modified.getStartLineNumber(@intCast(diff_change.modifiedStart));
            modified_end_line_number = self.modified.getEndLineNumber(@intCast(diff_change.modifiedStart + diff_change.modifiedLength - 1));
        }

        if (self.shouldComputeCharChanges and
            diff_change.originalLength > 0 and diff_change.originalLength < 20 and
            diff_change.modifiedLength > 0 and diff_change.modifiedLength < 20 and
            self.continueCharDiff.shouldContinue())
        {
            // Compute character changes for diff chunks of at most 20 lines...
            var original_char_sequence = try self.original.createCharSequence(
                self.shouldIgnoreTrimWhitespace,
                @intCast(diff_change.originalStart),
                @intCast(diff_change.originalStart + diff_change.originalLength - 1),
            );
            defer original_char_sequence.deinit();

            var modified_char_sequence = try self.modified.createCharSequence(
                self.shouldIgnoreTrimWhitespace,
                @intCast(diff_change.modifiedStart),
                @intCast(diff_change.modifiedStart + diff_change.modifiedLength - 1),
            );
            defer modified_char_sequence.deinit();

            if (original_char_sequence.charCodes.len > 0 and modified_char_sequence.charCodes.len > 0) {
                var raw_result = try computeDiffWithSequences(
                    self.allocator,
                    original_char_sequence.sequence(),
                    modified_char_sequence.sequence(),
                    &self.continueCharDiff,
                    true,
                );
                defer raw_result.deinit(self.allocator);

                const raw_changes = if (self.shouldPostProcessCharChanges)
                    try postProcessCharChanges(self.allocator, raw_result.changes)
                else
                    try self.allocator.dupe(DiffChange, raw_result.changes);
                defer self.allocator.free(raw_changes);

                const mapped = try self.allocator.alloc(CharChange, raw_changes.len);
                errdefer self.allocator.free(mapped);
                for (raw_changes, 0..) |raw_change, index| {
                    mapped[index] = try CharChange.createFromDiffChange(raw_change, &original_char_sequence, &modified_char_sequence);
                }
                char_changes = mapped;
            }
        }

        return .{
            .originalStartLineNumber = original_start_line_number,
            .originalEndLineNumber = original_end_line_number,
            .modifiedStartLineNumber = modified_start_line_number,
            .modifiedEndLineNumber = modified_end_line_number,
            .charChanges = char_changes,
        };
    }

    fn pushTrimWhitespaceCharChange(
        self: *DiffComputer,
        result: *ArrayList(LineChange),
        original_line_number: usize,
        original_start_column: usize,
        original_end_column: usize,
        modified_line_number: usize,
        modified_start_column: usize,
        modified_end_column: usize,
    ) !void {
        if (try self.mergeTrimWhitespaceCharChange(
            result,
            original_line_number,
            original_start_column,
            original_end_column,
            modified_line_number,
            modified_start_column,
            modified_end_column,
        )) {
            // Merged into previous
            return;
        }

        var char_changes: ?[]CharChange = null;
        if (self.shouldComputeCharChanges) {
            const allocated = try self.allocator.alloc(CharChange, 1);
            allocated[0] = .{
                .originalStartLineNumber = original_line_number,
                .originalStartColumn = original_start_column,
                .originalEndLineNumber = original_line_number,
                .originalEndColumn = original_end_column,
                .modifiedStartLineNumber = modified_line_number,
                .modifiedStartColumn = modified_start_column,
                .modifiedEndLineNumber = modified_line_number,
                .modifiedEndColumn = modified_end_column,
            };
            char_changes = allocated;
        }

        try result.append(.{
            .originalStartLineNumber = original_line_number,
            .originalEndLineNumber = original_line_number,
            .modifiedStartLineNumber = modified_line_number,
            .modifiedEndLineNumber = modified_line_number,
            .charChanges = char_changes,
        });
    }

    fn mergeTrimWhitespaceCharChange(
        self: *DiffComputer,
        result: *ArrayList(LineChange),
        original_line_number: usize,
        original_start_column: usize,
        original_end_column: usize,
        modified_line_number: usize,
        modified_start_column: usize,
        modified_end_column: usize,
    ) !bool {
        if (result.items.len == 0) {
            return false;
        }

        const previous_change = &result.items[result.items.len - 1];

        if (previous_change.originalEndLineNumber == 0 or previous_change.modifiedEndLineNumber == 0) {
            // Don't merge with inserts/deletes
            return false;
        }

        if (previous_change.originalEndLineNumber == original_line_number and
            previous_change.modifiedEndLineNumber == modified_line_number)
        {
            if (self.shouldComputeCharChanges) {
                if (previous_change.charChanges) |char_changes| {
                    const appended = try self.allocator.alloc(CharChange, char_changes.len + 1);
                    @memcpy(appended[0..char_changes.len], char_changes);
                    appended[char_changes.len] = .{
                        .originalStartLineNumber = original_line_number,
                        .originalStartColumn = original_start_column,
                        .originalEndLineNumber = original_line_number,
                        .originalEndColumn = original_end_column,
                        .modifiedStartLineNumber = modified_line_number,
                        .modifiedStartColumn = modified_start_column,
                        .modifiedEndLineNumber = modified_line_number,
                        .modifiedEndColumn = modified_end_column,
                    };
                    self.allocator.free(char_changes);
                    previous_change.charChanges = appended;
                }
            }
            return true;
        }

        if (previous_change.originalEndLineNumber + 1 == original_line_number and
            previous_change.modifiedEndLineNumber + 1 == modified_line_number)
        {
            previous_change.originalEndLineNumber = original_line_number;
            previous_change.modifiedEndLineNumber = modified_line_number;
            if (self.shouldComputeCharChanges) {
                if (previous_change.charChanges) |char_changes| {
                    const appended = try self.allocator.alloc(CharChange, char_changes.len + 1);
                    @memcpy(appended[0..char_changes.len], char_changes);
                    appended[char_changes.len] = .{
                        .originalStartLineNumber = original_line_number,
                        .originalStartColumn = original_start_column,
                        .originalEndLineNumber = original_line_number,
                        .originalEndColumn = original_end_column,
                        .modifiedStartLineNumber = modified_line_number,
                        .modifiedStartColumn = modified_start_column,
                        .modifiedEndLineNumber = modified_line_number,
                        .modifiedEndColumn = modified_end_column,
                    };
                    self.allocator.free(char_changes);
                    previous_change.charChanges = appended;
                }
            }
            return true;
        }

        return false;
    }
};

/// The legacy line diff computer, exposed through the modern interface.
pub const LegacyLinesDiffComputer = struct {
    const Self = @This();

    pub fn computeDiff(
        self: *Self,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        options: ILinesDiffComputerOptions,
    ) !LinesDiff {
        _ = self;
        var diff_computer = try DiffComputer.init(allocator, original_lines, modified_lines, .{
            .maxComputationTime = options.maxComputationTimeMs,
            .shouldIgnoreTrimWhitespace = options.ignoreTrimWhitespace,
            .shouldComputeCharChanges = true,
            .shouldMakePrettyDiff = true,
            .shouldPostProcessCharChanges = true,
        });
        defer diff_computer.deinit();
        var result = try diff_computer.computeDiff();
        defer result.deinit();

        var changes = ArrayList(DetailedLineRangeMapping).init(allocator);
        errdefer {
            for (changes.items) |*change| {
                change.deinit(allocator);
            }
            changes.deinit();
        }

        for (result.changes.items) |line_change| {
            const original_range = if (line_change.originalEndLineNumber == 0)
                // Insertion
                LineRange.init(line_change.originalStartLineNumber + 1, line_change.originalStartLineNumber + 1)
            else
                LineRange.init(line_change.originalStartLineNumber, line_change.originalEndLineNumber + 1);

            const modified_range = if (line_change.modifiedEndLineNumber == 0)
                // Deletion
                LineRange.init(line_change.modifiedStartLineNumber + 1, line_change.modifiedStartLineNumber + 1)
            else
                LineRange.init(line_change.modifiedStartLineNumber, line_change.modifiedEndLineNumber + 1);

            var inner_changes: ?[]RangeMapping = null;
            if (line_change.charChanges) |char_changes| {
                const mapped = try allocator.alloc(RangeMapping, char_changes.len);
                for (char_changes, 0..) |char_change, index| {
                    mapped[index] = RangeMapping.init(
                        Range.init(
                            char_change.originalStartLineNumber,
                            char_change.originalStartColumn,
                            char_change.originalEndLineNumber,
                            char_change.originalEndColumn,
                        ),
                        Range.init(
                            char_change.modifiedStartLineNumber,
                            char_change.modifiedStartColumn,
                            char_change.modifiedEndLineNumber,
                            char_change.modifiedEndColumn,
                        ),
                    );
                }
                inner_changes = mapped;
            }

            var change = DetailedLineRangeMapping.init(original_range, modified_range, inner_changes);

            if (changes.items.len > 0) {
                const last_change = changes.items[changes.items.len - 1];
                if (last_change.modified.endLineNumberExclusive == change.modified.startLineNumber or
                    last_change.original.endLineNumberExclusive == change.original.startLineNumber)
                {
                    // join touching diffs. Probably moving diffs up/down in the
                    // algorithm causes touching diffs.
                    const joined_inner: ?[]RangeMapping = blk: {
                        const previous_inner = last_change.inner_changes orelse break :blk null;
                        const current_inner = change.inner_changes orelse break :blk null;
                        const combined = try allocator.alloc(RangeMapping, previous_inner.len + current_inner.len);
                        @memcpy(combined[0..previous_inner.len], previous_inner);
                        @memcpy(combined[previous_inner.len..], current_inner);
                        break :blk combined;
                    };
                    const joined = DetailedLineRangeMapping.init(
                        last_change.original.join(change.original),
                        last_change.modified.join(change.modified),
                        joined_inner,
                    );

                    if (last_change.inner_changes) |inner| {
                        allocator.free(inner);
                    }
                    if (change.inner_changes) |inner| {
                        allocator.free(inner);
                    }
                    change = joined;

                    _ = changes.pop();
                }
            }

            try changes.append(change);
        }

        const moves = try allocator.alloc(lines_diff_computer.MovedText, 0);
        return LinesDiff.init(allocator, try changes.toOwnedSlice(), moves, result.quitEarly);
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
        return .{ .context = self, .compute_diff = computeDiffAny };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn runDiffComputer(
    allocator: Allocator,
    original: []const []const u8,
    modified: []const []const u8,
    opts: IDiffComputerOpts,
) !IDiffComputerResult {
    var computer = try DiffComputer.init(allocator, original, modified, opts);
    defer computer.deinit();
    return computer.computeDiff();
}

const default_opts = IDiffComputerOpts{
    .shouldComputeCharChanges = true,
    .shouldPostProcessCharChanges = true,
    .shouldIgnoreTrimWhitespace = false,
    .shouldMakePrettyDiff = true,
    .maxComputationTime = 0,
};

test "DiffComputer identical documents" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{ "a", "b", "c" };
    var result = try runDiffComputer(allocator, &lines, &lines, default_opts);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.changes.items.len);
    try std.testing.expect(!result.quitEarly);
}

test "DiffComputer simple insertion" {
    const allocator = std.testing.allocator;
    const original = [_][]const u8{ "a", "b", "c" };
    const modified = [_][]const u8{ "a", "x", "b", "c" };
    var result = try runDiffComputer(allocator, &original, &modified, default_opts);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.changes.items.len);
    const change = result.changes.items[0];
    // Insertions report the index of the line *before* which they insert.
    try std.testing.expectEqual(@as(usize, 1), change.originalStartLineNumber);
    try std.testing.expectEqual(@as(usize, 0), change.originalEndLineNumber);
    try std.testing.expectEqual(@as(usize, 2), change.modifiedStartLineNumber);
    try std.testing.expectEqual(@as(usize, 2), change.modifiedEndLineNumber);
}

test "DiffComputer computes character changes" {
    const allocator = std.testing.allocator;
    const original = [_][]const u8{"hello world"};
    const modified = [_][]const u8{"hello brave world"};
    var result = try runDiffComputer(allocator, &original, &modified, default_opts);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.changes.items.len);
    const change = result.changes.items[0];
    try std.testing.expectEqual(@as(usize, 1), change.originalStartLineNumber);
    try std.testing.expectEqual(@as(usize, 1), change.originalEndLineNumber);
    try std.testing.expectEqual(@as(usize, 1), change.modifiedStartLineNumber);
    try std.testing.expectEqual(@as(usize, 1), change.modifiedEndLineNumber);

    const char_changes = change.charChanges.?;
    try std.testing.expectEqual(@as(usize, 1), char_changes.len);
    // "brave " is inserted after "hello ".
    try std.testing.expectEqual(@as(usize, 1), char_changes[0].originalStartLineNumber);
    try std.testing.expectEqual(@as(usize, 7), char_changes[0].originalStartColumn);
    try std.testing.expectEqual(@as(usize, 7), char_changes[0].originalEndColumn);
    try std.testing.expectEqual(@as(usize, 1), char_changes[0].modifiedStartLineNumber);
    try std.testing.expectEqual(@as(usize, 7), char_changes[0].modifiedStartColumn);
    try std.testing.expectEqual(@as(usize, 13), char_changes[0].modifiedEndColumn);
}

test "DiffComputer reports trim whitespace changes" {
    const allocator = std.testing.allocator;
    const original = [_][]const u8{"a  "};
    const modified = [_][]const u8{"a"};
    var result = try runDiffComputer(allocator, &original, &modified, default_opts);
    defer result.deinit();

    try std.testing.expect(result.changes.items.len >= 1);
    const change = result.changes.items[0];
    try std.testing.expectEqual(@as(usize, 1), change.originalStartLineNumber);
    const char_changes = change.charChanges.?;
    try std.testing.expectEqual(@as(usize, 1), char_changes.len);
    // The trailing whitespace is reported as a character change.
    try std.testing.expectEqual(@as(usize, 2), char_changes[0].originalStartColumn);
    try std.testing.expectEqual(@as(usize, 4), char_changes[0].originalEndColumn);
}

test "DiffComputer empty documents" {
    const allocator = std.testing.allocator;

    const empty = [_][]const u8{""};
    var both_empty = try runDiffComputer(allocator, &empty, &empty, default_opts);
    defer both_empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), both_empty.changes.items.len);

    const content = [_][]const u8{ "a", "b" };
    var insert = try runDiffComputer(allocator, &empty, &content, default_opts);
    defer insert.deinit();
    try std.testing.expectEqual(@as(usize, 1), insert.changes.items.len);
    try std.testing.expectEqual(@as(usize, 1), insert.changes.items[0].originalStartLineNumber);
    try std.testing.expectEqual(@as(usize, 1), insert.changes.items[0].originalEndLineNumber);
    try std.testing.expectEqual(@as(usize, 2), insert.changes.items[0].modifiedEndLineNumber);
}

test "LegacyLinesDiffComputer produces line range mappings" {
    const allocator = std.testing.allocator;
    const original = [_][]const u8{ "a", "b", "c", "d" };
    const modified = [_][]const u8{ "a", "b", "x", "c", "d" };

    var computer = LegacyLinesDiffComputer{};
    const interface = computer.asLinesDiffComputer();
    var result = try interface.computeDiff(allocator, &original, &modified, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.changes.len);
    const change = result.changes[0];
    try std.testing.expectEqual(@as(usize, 3), change.original.startLineNumber);
    try std.testing.expectEqual(@as(usize, 3), change.original.endLineNumberExclusive);
    try std.testing.expectEqual(@as(usize, 3), change.modified.startLineNumber);
    try std.testing.expectEqual(@as(usize, 4), change.modified.endLineNumberExclusive);
    // A whole line was inserted, so there are no character changes.
    try std.testing.expectEqual(@as(?[]const RangeMapping, null), change.inner_changes);
    try std.testing.expect(!result.hit_timeout);
}

test "LegacyLinesDiffComputer computes inner changes for modified lines" {
    const allocator = std.testing.allocator;
    const original = [_][]const u8{ "a", "b", "c", "d" };
    const modified = [_][]const u8{ "a", "b2", "c", "d" };

    var computer = LegacyLinesDiffComputer{};
    const interface = computer.asLinesDiffComputer();
    var result = try interface.computeDiff(allocator, &original, &modified, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.changes.len);
    const change = result.changes[0];
    try std.testing.expectEqual(@as(usize, 2), change.original.startLineNumber);
    try std.testing.expectEqual(@as(usize, 3), change.original.endLineNumberExclusive);
    const inner = change.inner_changes.?;
    try std.testing.expectEqual(@as(usize, 1), inner.len);
    try std.testing.expectEqual(@as(usize, 2), inner[0].originalRange.startLineNumber);
    try std.testing.expectEqual(@as(usize, 2), inner[0].modifiedRange.startLineNumber);
    // "b" -> "b2" appends a character at column 2.
    try std.testing.expectEqual(@as(usize, 2), inner[0].originalRange.startColumn);
    try std.testing.expectEqual(@as(usize, 3), inner[0].modifiedRange.endColumn);
}

test "LegacyLinesDiffComputer joins touching diffs" {
    const allocator = std.testing.allocator;
    const original = [_][]const u8{ "a", "b", "c" };
    const modified = [_][]const u8{ "x", "b", "y" };

    var computer = LegacyLinesDiffComputer{};
    const interface = computer.asLinesDiffComputer();
    var result = try interface.computeDiff(allocator, &original, &modified, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    defer result.deinit();

    // The two changed regions are separated by an unchanged line, so they stay
    // separate.
    try std.testing.expectEqual(@as(usize, 2), result.changes.len);
}
