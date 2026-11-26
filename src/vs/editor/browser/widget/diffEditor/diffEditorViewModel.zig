// Port of the compute/state and unchanged-region subset of
// `src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts`.
//
// Terminal adaptations:
// - The view model borrows the two real text models. Native worker results
//   enter through applyComputedDiff; direct provider computation is synchronous.
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
const model_mod = @import("../../../common/model.zig");
const diff_provider = @import("diffProviderFactoryService.zig");
const Worker = @import("../../services/editorWorkerService.zig").EditorWorkerService;
const WindowTask = @import("../../../../base/common/windowDispatch.zig").Task;
const WindowQueue = @import("../../../../base/common/windowDispatch.zig").Queue;
const time = @import("../../../../base/common/timeCompat.zig");
const InternalModelContentChangeEvent = @import("../../../common/textModelEvents.zig").InternalModelContentChangeEvent;
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

pub const RevealPreference = enum { from_closer_side, from_top, from_bottom };
pub const UnchangedRegionsChange = enum { replaced, visibility };

/// Port of UnchangedRegion in diffEditorViewModel.ts. The line ranges are
/// in the two real model coordinate systems, not the aligned display rows.
pub const UnchangedRegion = struct {
    original_line_number: usize,
    modified_line_number: usize,
    line_count: usize,
    visible_line_count_top: usize = 0,
    visible_line_count_bottom: usize = 0,
    is_dragged: ?enum { bottom, top } = null,

    pub fn fromDiffs(allocator: Allocator, changes: []const range_mapping.LineRangeMapping, original_line_count: usize, modified_line_count: usize, min_hidden_line_count: usize, min_context: usize) ![]UnchangedRegion {
        const inverse = try range_mapping.LineRangeMapping.inverse(allocator, changes, original_line_count, modified_line_count);
        defer allocator.free(inverse);
        var result = std.array_list.Managed(UnchangedRegion).init(allocator);
        errdefer result.deinit();
        for (inverse) |mapping| {
            var original_start = mapping.original.startLineNumber;
            var modified_start = mapping.modified.startLineNumber;
            var length = mapping.original.length();
            const at_start = original_start == 1 and modified_start == 1;
            const at_end = original_start + length == original_line_count + 1 and modified_start + length == modified_line_count + 1;
            if ((at_start or at_end) and length >= min_context +| min_hidden_line_count) {
                if (at_start and !at_end) length -= min_context;
                if (at_end and !at_start) {
                    original_start += min_context;
                    modified_start += min_context;
                    length -= min_context;
                }
            } else if (length >= min_context *| 2 +| min_hidden_line_count) {
                original_start += min_context;
                modified_start += min_context;
                length -= min_context * 2;
            } else continue;
            try result.append(.{ .original_line_number = original_start, .modified_line_number = modified_start, .line_count = length });
        }
        return result.toOwnedSlice();
    }

    pub fn originalUnchangedRange(self: UnchangedRegion) LineRange {
        return .ofLength(self.original_line_number, self.line_count);
    }

    pub fn modifiedUnchangedRange(self: UnchangedRegion) LineRange {
        return .ofLength(self.modified_line_number, self.line_count);
    }

    pub fn getHiddenOriginalRange(self: UnchangedRegion) LineRange {
        return .ofLength(self.original_line_number + self.visible_line_count_top, self.line_count - self.visible_line_count_top - self.visible_line_count_bottom);
    }

    pub fn getHiddenModifiedRange(self: UnchangedRegion) LineRange {
        return .ofLength(self.modified_line_number + self.visible_line_count_top, self.line_count - self.visible_line_count_top - self.visible_line_count_bottom);
    }

    pub fn setHiddenModifiedRange(self: *UnchangedRegion, range: LineRange) void {
        self.setState(range.startLineNumber -| self.modified_line_number, self.modified_line_number + self.line_count -| range.endLineNumberExclusive);
    }

    pub fn setState(self: *UnchangedRegion, top: usize, bottom: usize) void {
        self.visible_line_count_top = @min(top, self.line_count);
        self.visible_line_count_bottom = @min(bottom, self.line_count - self.visible_line_count_top);
    }

    pub fn getMaxVisibleLineCountTop(self: UnchangedRegion) usize {
        return self.line_count - self.visible_line_count_bottom;
    }

    pub fn getMaxVisibleLineCountBottom(self: UnchangedRegion) usize {
        return self.line_count - self.visible_line_count_top;
    }

    pub fn shouldHideControls(self: UnchangedRegion) bool {
        return self.getHiddenModifiedRange().isEmpty() and self.is_dragged == null;
    }

    pub fn showMoreAbove(self: *UnchangedRegion, count: usize) void {
        self.visible_line_count_top = @min(self.visible_line_count_top +| count, self.getMaxVisibleLineCountTop());
    }

    pub fn showMoreBelow(self: *UnchangedRegion, count: usize) void {
        self.visible_line_count_bottom = @min(self.visible_line_count_bottom +| count, self.getMaxVisibleLineCountBottom());
    }

    pub fn showAll(self: *UnchangedRegion) void {
        self.visible_line_count_bottom = self.getMaxVisibleLineCountBottom();
    }

    pub fn collapseAll(self: *UnchangedRegion) void {
        self.setState(0, 0);
    }

    pub fn showModifiedLine(self: *UnchangedRegion, line_number: usize, preference: RevealPreference) void {
        const hidden = self.getHiddenModifiedRange();
        if (!hidden.contains(line_number)) return;
        const top = line_number + 1 - hidden.startLineNumber;
        const bottom = hidden.endLineNumberExclusive - line_number;
        if ((preference == .from_closer_side and top < bottom) or preference == .from_top) self.showMoreAbove(top) else self.showMoreBelow(bottom);
    }

    pub fn showOriginalLine(self: *UnchangedRegion, line_number: usize, preference: RevealPreference) void {
        if (!self.getHiddenOriginalRange().contains(line_number)) return;
        const top = line_number - self.original_line_number;
        const bottom = self.original_line_number + self.line_count - line_number;
        // The pinned upstream uses the difference of the distances here.
        if ((preference == .from_closer_side and top < bottom) or preference == .from_top) {
            self.visible_line_count_top = @min(self.visible_line_count_top +| bottom -| top, self.getMaxVisibleLineCountTop());
        } else {
            self.visible_line_count_bottom = @min(self.visible_line_count_bottom +| top -| bottom, self.getMaxVisibleLineCountBottom());
        }
    }

    pub fn setVisibleRanges(self: *UnchangedRegion, allocator: Allocator, visible_ranges: []const range_mapping.LineRangeMapping) ![]UnchangedRegion {
        var visible = @import("../../../common/core/ranges/lineRange.zig").LineRangeSet.empty(allocator);
        defer visible.deinit();
        for (visible_ranges) |range| try visible.addRange(range.modified);
        var hidden = try visible.subtractFrom(self.modifiedUnchangedRange());
        defer hidden.deinit();
        if (hidden.ranges().len == 0) {
            self.showAll();
            return allocator.dupe(UnchangedRegion, &.{self.*});
        }
        const result = try allocator.alloc(UnchangedRegion, hidden.ranges().len);
        var original_start = self.original_line_number;
        var modified_start = self.modified_line_number;
        const end = modified_start + self.line_count;
        for (hidden.ranges(), 0..) |range, i| {
            const length = (if (i + 1 == result.len) end else range.endLineNumberExclusive) - modified_start;
            result[i] = .{ .original_line_number = original_start, .modified_line_number = modified_start, .line_count = length };
            result[i].setHiddenModifiedRange(range);
            original_start += length;
            modified_start += length;
        }
        return result;
    }
};

pub const DiffEditorViewModel = struct {
    allocator: Allocator,
    model: struct { original: *doc_diff.TextModel, modified: *doc_diff.TextModel },
    options: Options,
    provider: doc_diff.LineDiffProvider,
    state: ?DiffState = null,
    on_did_change: Emitter(void),
    tracked_regions: []UnchangedRegion = &.{},
    hide_unchanged_regions: bool = false,
    original_region_ids: []u64 = &.{},
    modified_region_ids: []u64 = &.{},
    region_track_options: model_mod.ModelDecorationOptions = model_mod.ModelDecorationOptions.init("unchanged", .AlwaysGrowsWhenTypingAtEdges),
    on_did_change_unchanged_regions: Emitter(UnchangedRegionsChange),
    on_did_change_active_move: Emitter(void),
    moved_text_to_compare: ?usize = null,
    active_moved_text_from_cursor: ?usize = null,
    hovered_moved_text: ?usize = null,
    computed_once: bool = false,
    is_diff_up_to_date: bool = false,
    worker: ?*Worker = null,
    cache: ?*diff_provider.Cache = null,
    compute_task: WindowTask = .{},
    pending_request: ?*diff_provider.WorkerBasedDocumentDiffProvider.Request = null,
    original_content_listener: ?usize = null,
    modified_content_listener: ?usize = null,
    last_compute_error: ?anyerror = null,

    pub fn init(
        allocator: Allocator,
        original: *doc_diff.TextModel,
        modified: *doc_diff.TextModel,
        options: Options,
    ) DiffEditorViewModel {
        return .{
            .allocator = allocator,
            .model = .{ .original = original, .modified = modified },
            .options = options,
            .provider = doc_diff.LineDiffProvider.init(options.diff_algorithm),
            .on_did_change = Emitter(void).init(allocator),
            .on_did_change_unchanged_regions = Emitter(UnchangedRegionsChange).init(allocator),
            .on_did_change_active_move = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *DiffEditorViewModel) void {
        self.cancelPendingComputation();
        if (self.original_content_listener) |id| self.model.original.removeDidChangeContentListener(id);
        if (self.modified_content_listener) |id| self.model.modified.removeDidChangeContentListener(id);
        if (self.state) |*state| state.deinit(self.allocator);
        self.on_did_change.deinit();
        self.on_did_change_unchanged_regions.deinit();
        self.on_did_change_active_move.deinit();
        self.clearRegionDecorations();
        self.allocator.free(self.tracked_regions);
        self.* = undefined;
    }

    /// The model owns content listeners and outstanding diff work. Production
    /// supplies the shared window worker; small isolated editor tests can
    /// compute immediately through the document provider.
    pub fn startListening(self: *DiffEditorViewModel) !void {
        if (self.original_content_listener != null) return;
        self.original_content_listener = try self.model.original.onDidChangeContentWithContextId(self, onContentChanged);
        errdefer {
            self.model.original.removeDidChangeContentListener(self.original_content_listener.?);
            self.original_content_listener = null;
        }
        self.modified_content_listener = try self.model.modified.onDidChangeContentWithContextId(self, onContentChanged);
    }

    pub fn attachWorker(self: *DiffEditorViewModel, worker: *Worker, cache: ?*diff_provider.Cache, queue: *WindowQueue) void {
        if (self.worker == worker) return;
        self.cancelPendingComputation();
        self.worker = worker;
        self.cache = cache;
        self.compute_task = .{ .queue = queue, .context = self, .run = onComputeDeadline };
        if (!self.is_diff_up_to_date) self.requestRecompute(0);
    }

    fn onContentChanged(_: InternalModelContentChangeEvent, self: *DiffEditorViewModel) anyerror!void {
        self.requestRecompute(200);
    }

    pub fn cancelPendingComputation(self: *DiffEditorViewModel) void {
        self.compute_task.schedule(null);
        if (self.pending_request) |request| request.cancel();
        self.pending_request = null;
    }

    pub fn requestRecompute(self: *DiffEditorViewModel, delay_ms: i64) void {
        self.cancelPendingComputation();
        self.is_diff_up_to_date = false;
        self.last_compute_error = null;
        if (self.worker != null) {
            self.compute_task.schedule(time.milliTimestamp() + delay_ms);
        } else {
            self.compute() catch |err| {
                self.last_compute_error = err;
            };
        }
    }

    fn onComputeDeadline(context: *anyopaque, now: i64, _: bool) bool {
        const self: *DiffEditorViewModel = @ptrCast(@alignCast(context));
        self.startWorkerComputation(now) catch |err| {
            self.last_compute_error = err;
            return true;
        };
        return false;
    }

    fn startWorkerComputation(self: *DiffEditorViewModel, now: i64) !void {
        var original = try self.model.original.getValue(null, true);
        defer original.deinit();
        var modified = try self.model.modified.getValue(null, true);
        defer modified.deinit();
        self.pending_request = try diff_provider.WorkerBasedDocumentDiffProvider.computeDiff(
            self.worker.?,
            self.cache,
            original.items,
            modified.items,
            .{
                .ignore_trim_whitespace = self.options.ignore_trim_whitespace,
                .max_computation_time_ms = self.options.max_computation_time_ms,
                .diff_algorithm = self.options.diff_algorithm,
                .show_moves = self.options.show_moves,
            },
            .{ .context = self, .run = completeWorkerComputation },
            now,
        );
    }

    fn completeWorkerComputation(context: *anyopaque, request: *diff_provider.WorkerBasedDocumentDiffProvider.Request, result: ?IDocumentDiff) bool {
        const self: *DiffEditorViewModel = @ptrCast(@alignCast(context));
        if (self.pending_request != request) return false;
        self.pending_request = null;
        if (result) |diff| {
            self.applyComputedDiff(diff) catch |err| {
                self.last_compute_error = err;
            };
        } else self.last_compute_error = request.failure orelse error.DiffUnavailable;
        return true;
    }

    pub fn swapModels(self: *DiffEditorViewModel) void {
        self.cancelPendingComputation();
        std.mem.swap(*doc_diff.TextModel, &self.model.original, &self.model.modified);
        std.mem.swap(?usize, &self.original_content_listener, &self.modified_content_listener);
        std.mem.swap([]u64, &self.original_region_ids, &self.modified_region_ids);
        for (self.tracked_regions) |*region| std.mem.swap(usize, &region.original_line_number, &region.modified_line_number);
    }

    pub fn compute(self: *DiffEditorViewModel) !void {
        var result = try self.provider.interface().computeDiff(
            self.allocator,
            self.model.original,
            self.model.modified,
            .{
                .ignoreTrimWhitespace = self.options.ignore_trim_whitespace,
                .maxComputationTimeMs = self.options.max_computation_time_ms,
                .computeMoves = self.options.show_moves,
            },
            doc_diff.CancellationToken.None,
        );
        defer doc_diff.deinitDiff(self.allocator, &result);

        try self.applyComputedDiff(result);
    }

    pub fn applyComputedDiff(self: *DiffEditorViewModel, result: IDocumentDiff) !void {
        const normalized = try self.normalizeDocumentDiff(result);
        var previous = self.state;
        defer if (previous) |*state| state.deinit(self.allocator);
        const previous_compare = if (self.moved_text_to_compare) |index|
            if (previous) |state| if (index < state.moved_texts.len) state.moved_texts[index].lineRangeMapping.modified else null else null
        else
            null;
        self.cancelPendingComputation();
        self.state = normalized;
        self.computed_once = true;
        self.is_diff_up_to_date = true;
        self.moved_text_to_compare = null;
        self.active_moved_text_from_cursor = null;
        self.hovered_moved_text = null;
        if (previous_compare) |range| {
            for (normalized.moved_texts, 0..) |move, index| {
                if (move.lineRangeMapping.modified.intersect(range) != null) {
                    self.moved_text_to_compare = index;
                    break;
                }
            }
        }
        // Keep the old mapping allocation alive until the synchronous
        // derived consumers have installed the new state.
        try self.on_did_change.fire({});
    }

    pub fn activeMovedText(self: *const DiffEditorViewModel) ?usize {
        return self.moved_text_to_compare orelse self.hovered_moved_text orelse self.active_moved_text_from_cursor;
    }

    pub fn setMovedTextFromCursor(self: *DiffEditorViewModel, index: ?usize) void {
        const previous = self.activeMovedText();
        const compare = self.moved_text_to_compare;
        if (compare != index) self.moved_text_to_compare = null;
        self.active_moved_text_from_cursor = index;
        if (previous != self.activeMovedText() or compare != self.moved_text_to_compare) self.on_did_change_active_move.fire({}) catch {};
    }

    pub fn setHoveredMovedText(self: *DiffEditorViewModel, index: ?usize) void {
        const previous = self.activeMovedText();
        self.hovered_moved_text = index;
        if (previous != self.activeMovedText()) self.on_did_change_active_move.fire({}) catch {};
    }

    pub fn setMovedTextToCompare(self: *DiffEditorViewModel, index: ?usize) void {
        if (self.moved_text_to_compare == index) return;
        self.moved_text_to_compare = index;
        self.on_did_change_active_move.fire({}) catch {};
    }

    pub fn unchangedRegions(self: *DiffEditorViewModel) []UnchangedRegion {
        return if (self.hide_unchanged_regions) self.tracked_regions else &.{};
    }

    pub fn initializeUnchangedRegions(self: *DiffEditorViewModel, enabled: bool, minimum: usize, context: usize) !void {
        const state = self.stateRef() orelse return;
        const changes = try self.allocator.alloc(range_mapping.LineRangeMapping, state.mappings.len);
        defer self.allocator.free(changes);
        for (state.mappings, changes) |mapping, *change| change.* = mapping.line_range_mapping.toLineRangeMapping();
        // The upstream model tracks regions even while the option is off;
        // only its public unchangedRegions projection becomes empty.
        const was_enabled = self.hide_unchanged_regions;
        if (was_enabled and !enabled) {
            for (self.tracked_regions) |*region| region.collapseAll();
        }
        self.hide_unchanged_regions = enabled;
        const regions = try UnchangedRegion.fromDiffs(self.allocator, changes, self.model.original.getLineCount(), self.model.modified.getLineCount(), minimum, context);
        defer self.allocator.free(regions);
        const visible = if (self.tracked_regions.len > 0) try self.previousVisibleRegions() else null;
        defer if (visible) |ranges| self.allocator.free(ranges);
        var restored: std.ArrayList(UnchangedRegion) = .empty;
        defer restored.deinit(self.allocator);
        for (regions) |*region| {
            if (visible) |ranges| {
                var intersecting: std.ArrayList(range_mapping.LineRangeMapping) = .empty;
                defer intersecting.deinit(self.allocator);
                for (ranges) |range| {
                    if (range.original.intersectsStrict(region.originalUnchangedRange()) and range.modified.intersectsStrict(region.modifiedUnchangedRange())) try intersecting.append(self.allocator, range);
                }
                const restored_regions = try region.setVisibleRanges(self.allocator, intersecting.items);
                defer self.allocator.free(restored_regions);
                try restored.appendSlice(self.allocator, restored_regions);
            } else try restored.append(self.allocator, region.*);
        }
        const new_regions = try restored.toOwnedSlice(self.allocator);
        self.trackRegions(new_regions) catch |err| {
            self.allocator.free(new_regions);
            return err;
        };
        self.allocator.free(self.tracked_regions);
        self.tracked_regions = new_regions;
        _ = try self.collapseTouchingUnchangedRanges();
        if (enabled or was_enabled) try self.on_did_change_unchanged_regions.fire(.replaced);
    }

    fn previousVisibleRegions(self: *DiffEditorViewModel) ![]range_mapping.LineRangeMapping {
        var hidden: std.ArrayList(range_mapping.LineRangeMapping) = .empty;
        defer hidden.deinit(self.allocator);
        var previous: ?UnchangedRegion = null;
        for (self.tracked_regions, 0..) |old, index| {
            if (index >= self.original_region_ids.len or index >= self.modified_region_ids.len) continue;
            const original = LineRange.fromRangeInclusive(self.model.original.getDecorationRange(self.original_region_ids[index]) orelse continue);
            const modified = LineRange.fromRangeInclusive(self.model.modified.getDecorationRange(self.modified_region_ids[index]) orelse continue);
            var region: UnchangedRegion = .{ .original_line_number = original.startLineNumber, .modified_line_number = modified.startLineNumber, .line_count = original.length() };
            region.setState(old.visible_line_count_top, old.visible_line_count_bottom);
            if (previous) |before| {
                if (region.original_line_number < before.original_line_number + before.line_count or region.modified_line_number < before.modified_line_number + before.line_count) continue;
            }
            previous = region;
            try hidden.append(self.allocator, .{ .original = region.getHiddenOriginalRange(), .modified = region.getHiddenModifiedRange() });
        }
        const clipped = try range_mapping.LineRangeMapping.clip(self.allocator, hidden.items, LineRange.ofLength(1, self.model.original.getLineCount()), LineRange.ofLength(1, self.model.modified.getLineCount()));
        defer self.allocator.free(clipped);
        return range_mapping.LineRangeMapping.inverse(self.allocator, clipped, self.model.original.getLineCount(), self.model.modified.getLineCount());
    }

    fn trackRegions(self: *DiffEditorViewModel, regions: []const UnchangedRegion) !void {
        const original = try self.allocator.alloc(model_mod.ModelDeltaDecoration, regions.len);
        defer self.allocator.free(original);
        const modified = try self.allocator.alloc(model_mod.ModelDeltaDecoration, regions.len);
        defer self.allocator.free(modified);
        for (regions, original, modified) |region, *a, *b| {
            a.* = .{ .range = region.originalUnchangedRange().toInclusiveRange().?, .options = &self.region_track_options };
            b.* = .{ .range = region.modifiedUnchangedRange().toInclusiveRange().?, .options = &self.region_track_options };
        }
        const original_ids = try self.model.original.deltaDecorations(self.original_region_ids, original, 1004);
        self.allocator.free(self.original_region_ids);
        self.original_region_ids = original_ids;
        const modified_ids = try self.model.modified.deltaDecorations(self.modified_region_ids, modified, 1005);
        self.allocator.free(self.modified_region_ids);
        self.modified_region_ids = modified_ids;
    }

    fn clearRegionDecorations(self: *DiffEditorViewModel) void {
        if (self.original_region_ids.len > 0) {
            const removed = self.model.original.deltaDecorations(self.original_region_ids, &.{}, 1004) catch &.{};
            self.allocator.free(removed);
        }
        if (self.modified_region_ids.len > 0) {
            const removed = self.model.modified.deltaDecorations(self.modified_region_ids, &.{}, 1005) catch &.{};
            self.allocator.free(removed);
        }
        self.allocator.free(self.original_region_ids);
        self.allocator.free(self.modified_region_ids);
    }

    pub fn ensureLineVisible(self: *DiffEditorViewModel, original: bool, line: usize) bool {
        return self.ensureLineVisibleWithPreference(original, line, .from_closer_side);
    }

    pub fn ensureLineVisibleWithPreference(self: *DiffEditorViewModel, original: bool, line: usize, preference: RevealPreference) bool {
        if (self.stateRef()) |state| if (state.mappings.len == 0) return false;
        for (self.tracked_regions) |*region| {
            const old = region.*;
            if (original) region.showOriginalLine(line, preference) else region.showModifiedLine(line, preference);
            if (old.visible_line_count_top != region.visible_line_count_top or old.visible_line_count_bottom != region.visible_line_count_bottom) return true;
        }
        return false;
    }

    /// Merge adjacent hidden ranges using their model-tracked coordinates.
    /// A disclosure drag retains its own region until the gesture ends.
    fn collapseTouchingUnchangedRanges(self: *DiffEditorViewModel) !bool {
        if (self.tracked_regions.len < 2) return false;
        for (self.tracked_regions) |region| if (region.is_dragged != null) return false;
        var updated: std.ArrayList(UnchangedRegion) = .empty;
        defer updated.deinit(self.allocator);
        var changed = false;
        for (self.tracked_regions, 0..) |old, index| {
            if (index >= self.original_region_ids.len or index >= self.modified_region_ids.len) continue;
            const original = LineRange.fromRangeInclusive(self.model.original.getDecorationRange(self.original_region_ids[index]) orelse continue);
            const modified = LineRange.fromRangeInclusive(self.model.modified.getDecorationRange(self.modified_region_ids[index]) orelse continue);
            var region: UnchangedRegion = .{ .original_line_number = original.startLineNumber, .modified_line_number = modified.startLineNumber, .line_count = original.length() };
            region.setState(old.visible_line_count_top, old.visible_line_count_bottom);
            if (updated.items.len > 0) {
                const before = &updated.items[updated.items.len - 1];
                if (before.getHiddenModifiedRange().endLineNumberExclusive == region.getHiddenModifiedRange().startLineNumber) {
                    before.line_count += region.line_count;
                    before.setState(before.visible_line_count_top, region.visible_line_count_bottom);
                    changed = true;
                    continue;
                }
            }
            try updated.append(self.allocator, region);
        }
        if (!changed) return false;
        const replacement = try updated.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(replacement);
        try self.trackRegions(replacement);
        self.allocator.free(self.tracked_regions);
        self.tracked_regions = replacement;
        return true;
    }

    pub fn notifyUnchangedRegions(self: *DiffEditorViewModel) !void {
        const replaced = try self.collapseTouchingUnchangedRanges();
        if (self.hide_unchanged_regions) try self.on_did_change_unchanged_regions.fire(if (replaced) .replaced else .visibility);
    }

    pub const SerializedState = struct {
        collapsedRegions: ?[]CollapsedRegion = null,
        pub const CollapsedRegion = struct { range: [2]usize };

        pub fn deinit(self: *SerializedState, allocator: Allocator) void {
            if (self.collapsedRegions) |regions| allocator.free(regions);
            self.collapsedRegions = null;
        }
    };

    pub fn serializeState(self: *const DiffEditorViewModel, allocator: Allocator) !SerializedState {
        const regions = try allocator.alloc(SerializedState.CollapsedRegion, self.tracked_regions.len);
        for (self.tracked_regions, regions) |region, *entry| entry.* = .{ .range = region.getHiddenModifiedRange().serialize() };
        return .{ .collapsedRegions = regions };
    }

    pub fn restoreSerializedState(self: *DiffEditorViewModel, serialized: SerializedState) !void {
        const ranges = serialized.collapsedRegions orelse return;
        for (self.tracked_regions) |*region| {
            for (ranges) |entry| {
                if (entry.range[0] > entry.range[1]) continue;
                const range = LineRange.deserialize(entry.range);
                if (region.modifiedUnchangedRange().intersect(range) != null) {
                    region.setHiddenModifiedRange(range);
                    break;
                }
            }
        }
        try self.notifyUnchangedRegions();
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
            original_range.endColumn == lineMaxColumn(self.model.original, original_line) and
            modified_range.endColumn == lineMaxColumn(self.model.modified, modified_line) and
            original_line < self.model.original.getLineCount() and
            modified_line < self.model.modified.getLineCount())
        {
            original_range = Range.init(original_range.startLineNumber, original_range.startColumn, original_line + 1, 1);
            modified_range = Range.init(modified_range.startLineNumber, modified_range.startColumn, modified_line + 1, 1);
        }
        return .{ .originalRange = original_range, .modifiedRange = modified_range };
    }

    fn lineMaxColumn(model: *doc_diff.TextModel, line_number: usize) usize {
        if (line_number == 0 or line_number > model.getLineCount()) return 1;
        return model.getLineMaxColumn(line_number);
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
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var original = try TestModel.init(allocator, "a\nb\nc", "nullLanguage");
    defer original.deinit();
    var modified = try TestModel.init(allocator, "a\nB\nc", "nullLanguage");
    defer modified.deinit();
    var view_model = DiffEditorViewModel.init(allocator, original.model, modified.model, .{});
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

    var identical = DiffEditorViewModel.init(allocator, original.model, original.model, .{});
    defer identical.deinit();
    try identical.compute();
    try std.testing.expect(identical.stateRef().?.identical);
    try std.testing.expectEqual(@as(usize, 0), identical.stateRef().?.mappings.len);
}

test "diffEditorViewModel: insertion and deletion encode empty ranges" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var original = try TestModel.init(allocator, "a\nb", "nullLanguage");
    defer original.deinit();
    var modified = try TestModel.init(allocator, "a\nx\nb", "nullLanguage");
    defer modified.deinit();
    var insertion = DiffEditorViewModel.init(allocator, original.model, modified.model, .{});
    defer insertion.deinit();
    try insertion.compute();
    const insert_change = DiffEditorViewModel.toLineChange(insertion.stateRef().?.mappings[0].line_range_mapping);
    try std.testing.expectEqual(@as(usize, 0), insert_change.originalEndLineNumber);
    try std.testing.expectEqual(@as(usize, 2), insert_change.modifiedStartLineNumber);

    var deletion = DiffEditorViewModel.init(allocator, modified.model, original.model, .{});
    defer deletion.deinit();
    try deletion.compute();
    const delete_change = DiffEditorViewModel.toLineChange(deletion.stateRef().?.mappings[0].line_range_mapping);
    try std.testing.expectEqual(@as(usize, 2), delete_change.originalStartLineNumber);
    try std.testing.expectEqual(@as(usize, 0), delete_change.modifiedEndLineNumber);
}

test "diffEditorViewModel: max column inner ranges are widened to the next line" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var original = try TestModel.init(allocator, "abc\nd", "nullLanguage");
    defer original.deinit();
    var modified = try TestModel.init(allocator, "abd\nd", "nullLanguage");
    defer modified.deinit();
    var view_model = DiffEditorViewModel.init(allocator, original.model, modified.model, .{});
    defer view_model.deinit();
    try view_model.compute();
    const inner = view_model.stateRef().?.mappings[0].line_range_mapping.inner_changes orelse return error.TestUnexpectedResult;
    try std.testing.expect(inner.len > 0);
    // The widened range starts at the following line when it covered the whole
    // line up to its max column.
    try std.testing.expect(inner[0].originalRange.endColumn >= 1);
}

test "diffEditorViewModel: adjacent tracked hidden ranges merge after drag finishes" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var original = try TestModel.init(allocator, "a\nb\nc\nd\ne", "nullLanguage");
    defer original.deinit();
    var modified = try TestModel.init(allocator, "a\nb\nc\nd\ne", "nullLanguage");
    defer modified.deinit();
    var model = DiffEditorViewModel.init(allocator, original.model, modified.model, .{});
    defer model.deinit();
    model.hide_unchanged_regions = true;
    model.tracked_regions = try allocator.dupe(UnchangedRegion, &.{
        .{ .original_line_number = 1, .modified_line_number = 1, .line_count = 2, .is_dragged = .top },
        .{ .original_line_number = 3, .modified_line_number = 3, .line_count = 3 },
    });
    try model.trackRegions(model.tracked_regions);
    try model.notifyUnchangedRegions();
    try std.testing.expectEqual(@as(usize, 2), model.unchangedRegions().len);
    model.tracked_regions[0].is_dragged = null;
    try model.notifyUnchangedRegions();
    try std.testing.expectEqual(@as(usize, 1), model.unchangedRegions().len);
    try std.testing.expectEqual(LineRange.ofLength(1, 5), model.unchangedRegions()[0].getHiddenModifiedRange());
    try std.testing.expectEqual(@as(usize, 1), model.original_region_ids.len);
    try std.testing.expectEqual(@as(usize, 1), model.modified_region_ids.len);
}
