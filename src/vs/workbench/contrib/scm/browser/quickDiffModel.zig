// Port of `src/vs/workbench/contrib/scm/browser/quickDiffModel.ts`.
//
// Terminal adaptations:
// - There is no text-file-model service, chat editing, progress service or
//   observables. Original content comes synchronously from the quick-diff
//   provider as `Original { content, ref_label }`; the model diffs line arrays
//   with the ported `LineDiffProvider`.
// - The 200 ms `ThrottledDelayer` becomes `triggerDiff(now)` + `poll(now)`,
//   driven by the workbench main loop.
// - `getDiffEditorModel` returns the original content/ref label instead of two
//   text models; diff snapshots are built by the workbench.
// - Paths replace `URI` values, and suppressed secondary changes stay in
//   `all_changes` (the API-visible list) while `changes` contains the visible
//   primary/contributed and non-overlapping secondary changes, matching the
//   upstream split.
const std = @import("std");
const Allocator = std.mem.Allocator;

const quick_diff = @import("../common/quickDiff.zig");
const quick_diff_service_mod = @import("../common/quickDiffService.zig");
const doc_diff = @import("../../../../editor/common/diff/documentDiffProvider.zig");
const text_model = @import("../../../../editor/common/model/textModel.zig");
const range_mapping = @import("../../../../editor/common/diff/rangeMapping.zig");
const line_range = @import("../../../../editor/common/core/ranges/lineRange.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const QuickDiff = quick_diff.QuickDiff;
pub const QuickDiffProviderKind = quick_diff.QuickDiffProviderKind;
pub const IChange = quick_diff.IChange;
pub const ChangeType = quick_diff.ChangeType;
pub const QuickDiffResult = quick_diff.QuickDiffResult;
pub const QuickDiffService = quick_diff_service_mod.QuickDiffService;
pub const DiffAlgorithmName = doc_diff.DiffAlgorithmName;
pub const DetailedLineRangeMapping = range_mapping.DetailedLineRangeMapping;
pub const LineRangeMapping = range_mapping.LineRangeMapping;
pub const LineRange = line_range.LineRange;
pub const RangeMapping = range_mapping.RangeMapping;
pub const TextModel = text_model.TextModel;

pub const QuickDiffModelOptions = struct {
    algorithm: DiffAlgorithmName = .advanced,
    max_computation_time_ms: ?i64 = 1000,
};

pub const DiffEditorModel = struct {
    original_content: []const u8,
    ref_label: []const u8,
};

/// A terminal quick-diff change. `change2` owns its inner-change array; the
/// provider/path slices are borrowed from the model's quick-diff list.
pub const QuickDiffChange = struct {
    provider_id: []const u8,
    original_path: []const u8,
    modified_path: []const u8,
    change: IChange,
    change2: DetailedLineRangeMapping,

    pub fn deinit(self: *QuickDiffChange, allocator: Allocator) void {
        self.change2.deinit(allocator);
        self.* = undefined;
    }
};

pub const QuickDiffModel = struct {
    allocator: Allocator,
    model: *TextModel,
    path: []const u8,
    service: *QuickDiffService,
    options: QuickDiffModelOptions,
    provider: doc_diff.LineDiffProvider,
    ignore_trim_whitespace: bool = true,

    quick_diffs: []QuickDiff = &.{},
    all_changes: std.array_list.Managed(QuickDiffChange),
    changes: std.array_list.Managed(QuickDiffChange),
    /// Visible-change indices per provider id.
    quick_diff_changes: std.StringHashMap(std.array_list.Managed(usize)),
    changes_version_id: u32,
    on_did_change: Emitter(void),
    due_at: ?i64 = null,
    disposed: bool = false,

    pub fn init(
        allocator: Allocator,
        model: *TextModel,
        path: []const u8,
        service: *QuickDiffService,
        options: QuickDiffModelOptions,
    ) QuickDiffModel {
        var self = QuickDiffModel{
            .allocator = allocator,
            .model = model,
            .path = path,
            .service = service,
            .options = options,
            .provider = doc_diff.LineDiffProvider.init(options.algorithm),
            .all_changes = std.array_list.Managed(QuickDiffChange).init(allocator),
            .changes = std.array_list.Managed(QuickDiffChange).init(allocator),
            .quick_diff_changes = std.StringHashMap(std.array_list.Managed(usize)).init(allocator),
            .changes_version_id = model.getVersionId(),
            .on_did_change = Emitter(void).init(allocator),
        };
        self.triggerDiff(0);
        return self;
    }

    pub fn deinit(self: *QuickDiffModel) void {
        self.disposed = true;
        self.clearChanges();
        self.all_changes.deinit();
        self.changes.deinit();
        var iterator = self.quick_diff_changes.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit();
        self.quick_diff_changes.deinit();
        self.freeQuickDiffs();
        self.on_did_change.deinit();
        self.* = undefined;
    }

    pub fn setIgnoreTrimWhitespace(self: *QuickDiffModel, ignore: bool) void {
        if (self.ignore_trim_whitespace == ignore) return;
        self.ignore_trim_whitespace = ignore;
        self.triggerDiff(0);
    }

    /// Debounced recompute trigger (upstream `ThrottledDelayer(200)`).
    pub fn triggerDiff(self: *QuickDiffModel, now_ms: i64) void {
        if (self.disposed) return;
        self.due_at = now_ms + 200;
    }

    /// Recomputes when the debounce expires. Returns true when the changes were
    /// replaced and the decorations should be refreshed.
    pub fn poll(self: *QuickDiffModel, now_ms: i64) bool {
        const due = self.due_at orelse return false;
        if (now_ms < due) return false;
        self.due_at = null;
        self.recompute() catch return false;
        return true;
    }

    pub fn quickDiffs(self: *const QuickDiffModel) []const QuickDiff {
        return self.quick_diffs;
    }

    pub fn getQuickDiffResults(self: *QuickDiffModel, allocator: Allocator) ![]QuickDiffResult {
        var results = std.array_list.Managed(QuickDiffResult).init(allocator);
        errdefer {
            for (results.items) |*result| freeResult(allocator, result);
            results.deinit();
        }
        for (self.quick_diffs) |quick| {
            var changes = std.array_list.Managed(IChange).init(allocator);
            defer changes.deinit();
            var changes2 = std.array_list.Managed(LineRangeMapping).init(allocator);
            defer changes2.deinit();
            for (self.all_changes.items) |change| {
                if (!std.mem.eql(u8, change.provider_id, quick.id)) continue;
                try changes.append(change.change);
                try changes2.append(change.change2.toLineRangeMapping());
            }
            try results.append(.{
                .provider_id = quick.id,
                .provider_kind = quick.kind,
                .original_path = self.path,
                .modified_path = self.path,
                .changes = try changes.toOwnedSlice(),
                .changes2 = try changes2.toOwnedSlice(),
            });
        }
        return results.toOwnedSlice();
    }

    pub fn freeQuickDiffResults(allocator: Allocator, results: []QuickDiffResult) void {
        for (results) |*result| freeResult(allocator, result);
        allocator.free(results);
    }

    fn freeResult(allocator: Allocator, result: *QuickDiffResult) void {
        allocator.free(result.changes);
        allocator.free(result.changes2);
    }

    pub fn getDiffEditorModel(self: *const QuickDiffModel, provider_id: []const u8) ?DiffEditorModel {
        for (self.quick_diffs) |quick| {
            if (!std.mem.eql(u8, quick.id, provider_id)) continue;
            return .{
                .original_content = quick.original.content,
                .ref_label = quick.original.ref_label,
            };
        }
        return null;
    }

    pub fn findNextClosestChange(self: *const QuickDiffModel, line_number: usize, inclusive: bool, provider_id: ?[]const u8) usize {
        for (self.changes.items, 0..) |change, index| {
            if (provider_id) |id| {
                if (!std.mem.eql(u8, change.provider_id, id)) continue;
            }
            if (inclusive) {
                if (quick_diff.getModifiedEndLineNumber(change.change) >= line_number) return index;
            } else if (change.change.modifiedStartLineNumber > line_number) {
                return index;
            }
        }
        return 0;
    }

    pub fn findPreviousClosestChange(self: *const QuickDiffModel, line_number: usize, inclusive: bool, provider_id: ?[]const u8) usize {
        var index = self.changes.items.len;
        while (index > 0) {
            index -= 1;
            const change = self.changes.items[index];
            if (provider_id) |id| {
                if (!std.mem.eql(u8, change.provider_id, id)) continue;
            }
            if (inclusive) {
                if (change.change.modifiedStartLineNumber <= line_number) return index;
            } else if (quick_diff.getModifiedEndLineNumber(change.change) < line_number) {
                return index;
            }
        }
        return if (self.changes.items.len == 0) 0 else self.changes.items.len - 1;
    }

    fn clearChanges(self: *QuickDiffModel) void {
        for (self.all_changes.items) |*change| change.deinit(self.allocator);
        self.all_changes.clearRetainingCapacity();
        for (self.changes.items) |*change| change.deinit(self.allocator);
        self.changes.clearRetainingCapacity();
        var iterator = self.quick_diff_changes.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit();
        self.quick_diff_changes.clearRetainingCapacity();
    }

    fn freeQuickDiffs(self: *QuickDiffModel) void {
        for (self.quick_diffs) |*quick| {
            quick.deinit(self.allocator);
        }
        if (self.quick_diffs.len > 0) self.allocator.free(self.quick_diffs);
        self.quick_diffs = &.{};
    }

    /// Synchronous replacement of the upstream async `diff()`.
    pub fn recompute(self: *QuickDiffModel) !void {
        if (self.disposed) return;
        const version_id = self.model.getVersionId();

        const new_quick_diffs = try self.service.getQuickDiffs(
            self.allocator,
            self.path,
            self.model.getLanguageId(),
            true,
        );
        var new_quick_diffs_owned = true;
        errdefer if (new_quick_diffs_owned) freeQuickDiffsArray(self.allocator, new_quick_diffs);

        if (new_quick_diffs.len == 0) {
            self.replaceState(new_quick_diffs, &.{}, &.{}, version_id);
            new_quick_diffs_owned = false;
            return;
        }

        var modified_lines = try self.model.getLinesContent();
        defer {
            for (modified_lines.items) |*line| line.deinit();
            modified_lines.deinit();
        }
        const modified_views = try self.allocator.alloc([]const u8, modified_lines.items.len);
        defer self.allocator.free(modified_views);
        for (modified_lines.items, 0..) |line, index| modified_views[index] = line.items;

        // Per-provider original lines, used for the secondary overlap check.
        const original_lines = try self.allocator.alloc([][]const u8, new_quick_diffs.len);
        defer {
            for (original_lines) |lines| self.allocator.free(lines);
            self.allocator.free(original_lines);
        }
        for (new_quick_diffs, 0..) |quick, index| {
            original_lines[index] = try splitLines(self.allocator, quick.original.content);
        }

        var all_changes = std.array_list.Managed(QuickDiffChange).init(self.allocator);
        errdefer {
            for (all_changes.items) |*change| change.deinit(self.allocator);
            all_changes.deinit();
        }
        var visible_changes = std.array_list.Managed(QuickDiffChange).init(self.allocator);
        errdefer {
            for (visible_changes.items) |*change| change.deinit(self.allocator);
            visible_changes.deinit();
        }

        for (new_quick_diffs, 0..) |quick, quick_index| {
            var diff = self.provider.computeDiffFromLines(
                self.allocator,
                original_lines[quick_index],
                modified_views,
                .{
                    .ignoreTrimWhitespace = self.ignore_trim_whitespace,
                    .maxComputationTimeMs = self.options.max_computation_time_ms orelse std.math.maxInt(i64),
                    .computeMoves = false,
                },
            ) catch continue;
            defer doc_diff.deinitDiff(self.allocator, &diff);

            for (diff.changes) |mapping| {
                const change = try self.convertMapping(quick, mapping);
                errdefer {
                    var owned = change;
                    owned.deinit(self.allocator);
                }
                var owned = change;
                const suppress = quick.kind == .secondary and
                    self.overlapsPrimary(visible_changes.items, new_quick_diffs, original_lines, quick_index, mapping);
                if (suppress) {
                    // API-visible but not painted.
                    owned.deinit(self.allocator);
                    owned = try self.convertMapping(quick, mapping);
                    try all_changes.append(owned);
                    continue;
                }
                try all_changes.append(owned);
                var visible = try self.convertMapping(quick, mapping);
                errdefer visible.deinit(self.allocator);
                try visible_changes.append(visible);
            }
        }

        // Sort both lists by the visible change order used upstream.
        std.mem.sort(QuickDiffChange, all_changes.items, {}, changeLessThan);
        std.mem.sort(QuickDiffChange, visible_changes.items, {}, changeLessThan);

        self.replaceState(new_quick_diffs, all_changes.items, visible_changes.items, version_id);
        new_quick_diffs_owned = false;
        // Ownership moved into the model; release only the temporary lists.
        all_changes.deinit();
        visible_changes.deinit();
    }

    fn replaceState(
        self: *QuickDiffModel,
        new_quick_diffs: []QuickDiff,
        new_all_changes: []const QuickDiffChange,
        new_visible_changes: []const QuickDiffChange,
        version_id: u32,
    ) void {
        self.clearChanges();
        self.freeQuickDiffs();

        self.quick_diffs = new_quick_diffs;
        for (new_all_changes) |change| self.all_changes.append(change) catch {};
        for (new_visible_changes) |change| self.changes.append(change) catch {};

        for (self.changes.items, 0..) |change, index| {
            const entry = self.quick_diff_changes.getOrPut(change.provider_id) catch continue;
            if (!entry.found_existing) {
                entry.value_ptr.* = std.array_list.Managed(usize).init(self.allocator);
            }
            entry.value_ptr.append(index) catch {};
        }

        self.changes_version_id = version_id;
        self.on_did_change.fire({}) catch {};
    }

    fn overlapsPrimary(
        self: *QuickDiffModel,
        visible: []const QuickDiffChange,
        quick_diffs: []const QuickDiff,
        original_lines: []const [][]const u8,
        secondary_index: usize,
        mapping: DetailedLineRangeMapping,
    ) bool {
        _ = self;
        for (visible) |existing| {
            if (existing.change2.modified.startLineNumber != mapping.modified.startLineNumber or
                existing.change2.modified.endLineNumberExclusive != mapping.modified.endLineNumberExclusive or
                existing.change2.original.length() != mapping.original.length())
            {
                continue;
            }
            // The primary original text must match the secondary original text.
            const primary_index = for (quick_diffs, 0..) |quick, index| {
                if (std.mem.eql(u8, quick.id, existing.provider_id)) break index;
            } else continue;
            if (lineRangeTextEquals(
                original_lines[primary_index],
                existing.change2.original,
                original_lines[secondary_index],
                mapping.original,
            )) return true;
        }
        return false;
    }

    fn convertMapping(self: *QuickDiffModel, quick: QuickDiff, mapping: DetailedLineRangeMapping) !QuickDiffChange {
        const change = quick_diff_change_from_mapping(mapping);
        const inner = if (mapping.inner_changes) |values| try self.allocator.dupe(RangeMapping, values) else null;
        return .{
            .provider_id = quick.id,
            .original_path = self.path,
            .modified_path = self.path,
            .change = change,
            .change2 = .{
                .original = mapping.original,
                .modified = mapping.modified,
                .inner_changes = inner,
            },
        };
    }
};

fn changeLessThan(_: void, a: QuickDiffChange, b: QuickDiffChange) bool {
    return quick_diff.compareChanges(a.change, b.change) < 0;
}

fn quick_diff_change_from_mapping(mapping: DetailedLineRangeMapping) IChange {
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

fn splitLines(allocator: Allocator, content: []const u8) ![][]const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    errdefer lines.deinit();
    var iterator = std.mem.splitScalar(u8, content, '\n');
    while (iterator.next()) |line| {
        // A trailing newline produces a final empty line in the model; the
        // split already yields it, so keep every element.
        try lines.append(line);
    }
    return lines.toOwnedSlice();
}

fn lineRangeTextEquals(a_lines: []const []const u8, a_range: LineRange, b_lines: []const []const u8, b_range: LineRange) bool {
    if (a_range.length() != b_range.length()) return false;
    var index: usize = 0;
    while (index < a_range.length()) : (index += 1) {
        const a_index = a_range.startLineNumber - 1 + index;
        const b_index = b_range.startLineNumber - 1 + index;
        if (a_index >= a_lines.len or b_index >= b_lines.len) return false;
        if (!std.mem.eql(u8, a_lines[a_index], b_lines[b_index])) return false;
    }
    return true;
}

fn freeQuickDiffsArray(allocator: Allocator, quick_diffs: []QuickDiff) void {
    for (quick_diffs) |*quick| quick.deinit(allocator);
    allocator.free(quick_diffs);
}
