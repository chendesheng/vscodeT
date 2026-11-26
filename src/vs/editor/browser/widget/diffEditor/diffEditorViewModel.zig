// Port of the compute/state subset of
// `src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts`.
//
// Terminal adaptations:
// - The view model works on line arrays and computes synchronously; there is
//   no observable system, cancellation token source or incremental edit
//   application. `recompute` replaces the whole `DiffState`.
// - Unchanged regions (`UnchangedRegion`, hide-unchanged-regions) are outside
//   the read-only terminal scope and are not ported.
// - `normalizeDocumentDiff`/`normalizeRangeMapping` and `toLineChanges` keep
//   the upstream rules: inner ranges that end at the line max column are
//   widened to the next line, and line changes encode empty insert/delete
//   ranges with a zero end line.
const std = @import("std");
const Allocator = std.mem.Allocator;

const doc_diff = @import("../../../common/diff/documentDiffProvider.zig");
const range_mapping = @import("../../../common/diff/rangeMapping.zig");
const lines_diff_computer = @import("../../../common/diff/linesDiffComputer.zig");
const LineRange = @import("../../../common/core/ranges/lineRange.zig").LineRange;
const Range = @import("../../../common/core/range.zig").Range;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const DetailedLineRangeMapping = range_mapping.DetailedLineRangeMapping;
pub const RangeMapping = range_mapping.RangeMapping;
pub const MovedText = lines_diff_computer.MovedText;
pub const DiffAlgorithmName = doc_diff.DiffAlgorithmName;
pub const IChange = lines_diff_computer.IChange;

pub const Options = struct {
    ignore_trim_whitespace: bool = true,
    max_computation_time_ms: i64 = 5000,
    diff_algorithm: DiffAlgorithmName = .advanced,
    show_moves: bool = false,
};

pub const IDocumentDiff = doc_diff.IDocumentDiff;

pub const DiffMapping = struct {
    line_range_mapping: DetailedLineRangeMapping,
};

pub const DiffState = struct {
    mappings: []DiffMapping,
    moved_texts: []MovedText,
    identical: bool,
    quit_early: bool,

    pub fn deinit(self: *DiffState, allocator: Allocator) void {
        for (self.mappings) |*mapping| mapping.line_range_mapping.deinit(allocator);
        if (self.mappings.len > 0) allocator.free(self.mappings);
        for (self.moved_texts) |*moved| moved.deinit(allocator);
        if (self.moved_texts.len > 0) allocator.free(self.moved_texts);
        self.* = undefined;
    }
};

pub const DiffEditorViewModel = struct {
    allocator: Allocator,
    original_lines: []const []const u8,
    modified_lines: []const []const u8,
    options: Options,
    provider: doc_diff.LineDiffProvider,
    state: ?DiffState = null,
    on_did_change: Emitter(void),
    computed_once: bool = false,

    pub fn init(
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        options: Options,
    ) DiffEditorViewModel {
        return .{
            .allocator = allocator,
            .original_lines = original_lines,
            .modified_lines = modified_lines,
            .options = options,
            .provider = doc_diff.LineDiffProvider.init(options.diff_algorithm),
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *DiffEditorViewModel) void {
        if (self.state) |*state| state.deinit(self.allocator);
        self.on_did_change.deinit();
        self.* = undefined;
    }

    pub fn compute(self: *DiffEditorViewModel) !void {
        var result = try self.provider.computeDiffFromLines(
            self.allocator,
            self.original_lines,
            self.modified_lines,
            .{
                .ignoreTrimWhitespace = self.options.ignore_trim_whitespace,
                .maxComputationTimeMs = self.options.max_computation_time_ms,
                .computeMoves = self.options.show_moves,
            },
        );
        defer doc_diff.deinitDiff(self.allocator, &result);

        try self.applyComputedDiff(result);
    }

    pub fn applyComputedDiff(self: *DiffEditorViewModel, result: IDocumentDiff) !void {
        const normalized = try self.normalizeDocumentDiff(result);
        if (self.state) |*state| state.deinit(self.allocator);
        self.state = normalized;
        self.computed_once = true;
        self.on_did_change.fire({}) catch {};
    }

    pub fn stateRef(self: *const DiffEditorViewModel) ?*const DiffState {
        return if (self.state) |*state| state else null;
    }

    /// Copy of the mappings converted to the legacy `IChange` shape.
    pub fn toLineChanges(self: *DiffEditorViewModel, allocator: Allocator) ![]IChange {
        const state = self.stateRef() orelse return allocator.alloc(IChange, 0);
        const result = try allocator.alloc(IChange, state.mappings.len);
        for (state.mappings, 0..) |mapping, index| {
            result[index] = toLineChange(mapping.line_range_mapping);
        }
        return result;
    }

    fn normalizeDocumentDiff(self: *DiffEditorViewModel, diff: doc_diff.IDocumentDiff) !DiffState {
        const mappings = try self.allocator.alloc(DiffMapping, diff.changes.len);
        errdefer self.allocator.free(mappings);
        var initialized: usize = 0;
        errdefer {
            for (mappings[0..initialized]) |*mapping| mapping.line_range_mapping.deinit(self.allocator);
        }
        for (diff.changes, 0..) |change, index| {
            const inner: ?[]const RangeMapping = if (change.inner_changes) |values| blk: {
                const normalized = try self.allocator.alloc(RangeMapping, values.len);
                for (values, 0..) |value, inner_index| {
                    normalized[inner_index] = self.normalizeRangeMapping(value);
                }
                break :blk normalized;
            } else null;
            mappings[index] = .{ .line_range_mapping = .{
                .original = change.original,
                .modified = change.modified,
                .inner_changes = inner,
            } };
            initialized = index + 1;
        }

        // The caller still owns the raw diff and frees it with
        // `deinitDiff`, so the moved texts are cloned rather than moved.
        const moves = try self.cloneMovedTexts(diff.moves);
        return DiffState{
            .mappings = mappings,
            .moved_texts = moves,
            .identical = diff.identical,
            .quit_early = diff.quitEarly,
        };
    }

    fn cloneMovedTexts(self: *DiffEditorViewModel, source: []const MovedText) ![]MovedText {
        if (source.len == 0) return &.{};
        const result = try self.allocator.alloc(MovedText, source.len);
        errdefer self.allocator.free(result);
        var initialized: usize = 0;
        errdefer for (result[0..initialized]) |*moved| moved.deinit(self.allocator);
        for (source, 0..) |moved, index| {
            const changes = try self.allocator.alloc(DetailedLineRangeMapping, moved.changes.len);
            for (moved.changes, 0..) |change, change_index| {
                const inner = if (change.inner_changes) |values| try self.allocator.dupe(RangeMapping, values) else null;
                changes[change_index] = .{
                    .original = change.original,
                    .modified = change.modified,
                    .inner_changes = inner,
                };
            }
            result[index] = .{
                .lineRangeMapping = moved.lineRangeMapping,
                .changes = changes,
            };
            initialized = index + 1;
        }
        return result;
    }

    fn normalizeRangeMapping(self: *DiffEditorViewModel, value: RangeMapping) RangeMapping {
        var original_range = value.originalRange;
        var modified_range = value.modifiedRange;
        const original_line = original_range.endLineNumber;
        const modified_line = modified_range.endLineNumber;
        if (original_range.startColumn == 1 and modified_range.startColumn == 1 and
            (original_range.endColumn != 1 or modified_range.endColumn != 1) and
            original_range.endColumn == self.lineMaxColumn(self.original_lines, original_line) and
            modified_range.endColumn == self.lineMaxColumn(self.modified_lines, modified_line) and
            original_line < self.original_lines.len and
            modified_line < self.modified_lines.len)
        {
            original_range = Range.init(original_range.startLineNumber, original_range.startColumn, original_line + 1, 1);
            modified_range = Range.init(modified_range.startLineNumber, modified_range.startColumn, modified_line + 1, 1);
        }
        return .{ .originalRange = original_range, .modifiedRange = modified_range };
    }

    fn lineMaxColumn(_: *const DiffEditorViewModel, lines: []const []const u8, line_number: usize) usize {
        if (line_number == 0 or line_number > lines.len) return 1;
        return lines[line_number - 1].len + 1;
    }

    /// Upstream `toLineChange`: empty original/modified ranges are encoded with
    /// a zero end line and a start line one before the mapping start.
    pub fn toLineChange(mapping: DetailedLineRangeMapping) IChange {
        var original_start = mapping.original.startLineNumber;
        var original_end: usize = 0;
        if (mapping.original.isEmpty()) {
            original_start = mapping.original.startLineNumber -| 1;
        } else {
            original_end = mapping.original.endLineNumberExclusive - 1;
        }
        var modified_start = mapping.modified.startLineNumber;
        var modified_end: usize = 0;
        if (mapping.modified.isEmpty()) {
            modified_start = mapping.modified.startLineNumber -| 1;
        } else {
            modified_end = mapping.modified.endLineNumberExclusive - 1;
        }
        return .{
            .originalStartLineNumber = original_start,
            .originalEndLineNumber = original_end,
            .modifiedStartLineNumber = modified_start,
            .modifiedEndLineNumber = modified_end,
        };
    }
};

test "diffEditorViewModel: identical and changed line counts" {
    const allocator = std.testing.allocator;
    var view_model = DiffEditorViewModel.init(
        allocator,
        &.{ "a", "b", "c" },
        &.{ "a", "B", "c" },
        .{},
    );
    defer view_model.deinit();

    try view_model.compute();
    const state = view_model.stateRef().?;
    try std.testing.expect(!state.identical);
    try std.testing.expectEqual(@as(usize, 1), state.mappings.len);
    try std.testing.expectEqual(@as(usize, 2), state.mappings[0].line_range_mapping.original.startLineNumber);
    try std.testing.expect(state.mappings[0].line_range_mapping.inner_changes != null);

    const changes = try view_model.toLineChanges(allocator);
    defer allocator.free(changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(@as(usize, 2), changes[0].modifiedStartLineNumber);
    try std.testing.expectEqual(@as(usize, 2), changes[0].modifiedEndLineNumber);

    var identical = DiffEditorViewModel.init(allocator, &.{"a"}, &.{"a"}, .{});
    defer identical.deinit();
    try identical.compute();
    try std.testing.expect(identical.stateRef().?.identical);
    try std.testing.expectEqual(@as(usize, 0), identical.stateRef().?.mappings.len);
}

test "diffEditorViewModel: insertion and deletion encode empty ranges" {
    const allocator = std.testing.allocator;
    var insertion = DiffEditorViewModel.init(allocator, &.{ "a", "b" }, &.{ "a", "x", "b" }, .{});
    defer insertion.deinit();
    try insertion.compute();
    const insert_change = DiffEditorViewModel.toLineChange(insertion.stateRef().?.mappings[0].line_range_mapping);
    try std.testing.expectEqual(@as(usize, 0), insert_change.originalEndLineNumber);
    try std.testing.expectEqual(@as(usize, 2), insert_change.modifiedStartLineNumber);

    var deletion = DiffEditorViewModel.init(allocator, &.{ "a", "x", "b" }, &.{ "a", "b" }, .{});
    defer deletion.deinit();
    try deletion.compute();
    const delete_change = DiffEditorViewModel.toLineChange(deletion.stateRef().?.mappings[0].line_range_mapping);
    try std.testing.expectEqual(@as(usize, 2), delete_change.originalStartLineNumber);
    try std.testing.expectEqual(@as(usize, 0), delete_change.modifiedEndLineNumber);
}

test "diffEditorViewModel: max column inner ranges are widened to the next line" {
    const allocator = std.testing.allocator;
    var view_model = DiffEditorViewModel.init(allocator, &.{ "abc", "d" }, &.{ "abd", "d" }, .{});
    defer view_model.deinit();
    try view_model.compute();
    const inner = view_model.stateRef().?.mappings[0].line_range_mapping.inner_changes orelse return error.TestUnexpectedResult;
    try std.testing.expect(inner.len > 0);
    // The widened range starts at the following line when it covered the whole
    // line up to its max column.
    try std.testing.expect(inner[0].originalRange.endColumn >= 1);
}
