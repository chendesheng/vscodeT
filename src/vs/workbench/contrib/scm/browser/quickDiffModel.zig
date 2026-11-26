// Port of `src/vs/workbench/contrib/scm/browser/quickDiffModel.ts`.
//
// Terminal adaptations:
// - There is no text-file-model service, chat editing, progress service or
//   observables. Original content comes synchronously from the quick-diff
//   provider as `Original { content, ref_label }`; the model diffs line arrays
//   with the ported `LineDiffProvider` on a worker using an owned input.
// - Each model uses a window deadline for its 200 ms ThrottledDelayer.
//   Worker replies wake the window to apply decorations on the UI thread.
// - `getDiffEditorModel` returns the original resource URI, content and ref
//   label. The embedded peek resolves it into a retained original document
//   and shares the working document with the outer editor.
// - Paths replace `URI` values, and suppressed secondary changes stay in
//   `all_changes` (the API-visible list) while `changes` contains the visible
//   primary/contributed and non-overlapping secondary changes, matching the
//   upstream split.
const std = @import("std");
const Allocator = std.mem.Allocator;

const worker_service = @import("../../../../editor/browser/services/editorWorkerService.zig");
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
    resource_uri: ?[]const u8 = null,
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

// The terminal equivalent of editorWorkerService.computeDiff. Workers own
// their input and never access the editor, provider registry or decorations.
const DiffRequest = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    originals: []QuickDiff,
    modified: std.array_list.Managed(u8),
    original_lines: [][][]const u8 = &.{},
    diffs: []?doc_diff.IDocumentDiff = &.{},
    options: QuickDiffModelOptions,
    ignore_trim_whitespace: bool,
    version: u32,
    message: worker_service.Request = .{ .compute = run, .reply = onReply },
    // Only the UI thread accesses this reference. Disposal detaches the reply.
    owner: ?*QuickDiffModel,
    succeeded: bool = false,

    fn run(message: *worker_service.Request) void {
        const self: *DiffRequest = @fieldParentPtr("message", message);
        self.compute() catch return;
        self.succeeded = true;
    }

    fn onReply(message: *worker_service.Request) bool {
        const self: *DiffRequest = @fieldParentPtr("message", message);
        defer self.destroy();
        const owner = self.owner orelse return false;
        owner.pending = null;
        owner.scheduler.schedule(owner.due_at);
        if (!self.succeeded) return false;
        owner.applyDiff(self) catch return false;
        return true;
    }

    fn compute(self: *DiffRequest) !void {
        const arena = self.arena.allocator();
        const modified = try splitLines(arena, self.modified.items);
        self.original_lines = try arena.alloc([][]const u8, self.originals.len);
        self.diffs = try arena.alloc(?doc_diff.IDocumentDiff, self.originals.len);
        @memset(self.diffs, null);
        var provider = doc_diff.LineDiffProvider.init(self.options.algorithm);
        for (self.originals, 0..) |quick, i| {
            self.original_lines[i] = try splitLines(arena, quick.original.content);
            self.diffs[i] = provider.computeDiffFromLines(self.allocator, self.original_lines[i], modified, .{
                .ignoreTrimWhitespace = self.ignore_trim_whitespace,
                .maxComputationTimeMs = self.options.max_computation_time_ms orelse std.math.maxInt(i64),
                .computeMoves = false,
            }) catch null;
        }
    }

    fn destroy(self: *DiffRequest) void {
        for (self.diffs) |*result| if (result.*) |*diff| doc_diff.deinitDiff(self.allocator, diff);
        self.modified.deinit();
        freeQuickDiffsArray(self.allocator, self.originals);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

/// SCM has its own default. Only the explicit inherit setting reads the diff editor option.
pub fn ignoreTrimWhitespace(service: *@import("../../../services/configuration/browser/configurationService.zig").ConfigurationService) bool {
    const value = service.getValue("scm.diffDecorationsIgnoreTrimWhitespace", .{}) orelse return false;
    return switch (value.*) {
        .bool => value.bool, // Legacy terminal settings accepted booleans.
        .string => if (std.mem.eql(u8, value.string, "inherit"))
            service.getBool("diffEditor.ignoreTrimWhitespace", true)
        else
            !std.mem.eql(u8, value.string, "false"),
        else => false,
    };
}

pub const QuickDiffModel = struct {
    allocator: Allocator,
    model: *TextModel,
    path: []const u8,
    service: *QuickDiffService,
    options: QuickDiffModelOptions,
    pending: ?*DiffRequest = null,
    ignore_trim_whitespace: bool = true,

    quick_diffs: []QuickDiff = &.{},
    all_changes: std.array_list.Managed(QuickDiffChange),
    changes: std.array_list.Managed(QuickDiffChange),
    /// Visible-change indices per provider id.
    quick_diff_changes: std.StringHashMap(std.array_list.Managed(usize)),
    changes_version_id: u32,
    on_did_change: Emitter(void),
    due_at: ?i64 = null,
    scheduler: @import("../../../../base/common/windowDispatch.zig").Task = .{},
    worker: ?*worker_service.EditorWorkerService = null,
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
        self.scheduler.schedule(null);
        self.disposed = true;
        if (self.pending) |request| request.owner = null;
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
        if (self.pending == null) self.scheduler.schedule(self.due_at);
    }

    pub fn attachWindow(self: *QuickDiffModel, window: *@import("../../../../base/common/windowDispatch.zig").Queue, worker: *worker_service.EditorWorkerService) void {
        self.worker = worker;
        self.scheduler = .{ .queue = window, .context = self, .run = onDeadline };
    }

    fn onDeadline(context: *anyopaque, now: i64, _: bool) bool {
        const self: *QuickDiffModel = @ptrCast(@alignCast(context));
        return self.runScheduledDiff(self.worker.?, now);
    }

    pub fn runScheduledDiff(self: *QuickDiffModel, worker: *worker_service.EditorWorkerService, now_ms: i64) bool {
        const due = self.due_at orelse return false;
        if (now_ms < due or self.pending != null) return false;
        self.due_at = null;
        const request = self.prepareDiff() catch return false;
        if (request.originals.len == 0) {
            defer request.destroy();
            self.applyDiff(request) catch return false;
            return true;
        }
        self.pending = request;
        worker.computeDiff(&request.message, now_ms);
        return false;
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
                .resource_uri = quick.original.resource_uri,
            };
        }
        return null;
    }

    pub fn findNextClosestChange(self: *const QuickDiffModel, line_number: usize, inclusive: bool, provider_id: ?[]const u8) usize {
        for (self.changes.items, 0..) |change, index| {
            if (provider_id) |id| {
                if (!std.mem.eql(u8, change.provider_id, id)) continue;
            }
            if (!self.service.isQuickDiffProviderVisible(change.provider_id)) continue;
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
            if (!self.service.isQuickDiffProviderVisible(change.provider_id)) continue;
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

    fn prepareDiff(self: *QuickDiffModel) !*DiffRequest {
        const originals: []QuickDiff = if (self.model.isTooLargeForSyncing()) &.{} else try self.service.getQuickDiffs(self.allocator, self.path, self.model.getLanguageId(), true);
        errdefer freeQuickDiffsArray(self.allocator, originals);
        const request = try self.allocator.create(DiffRequest);
        errdefer self.allocator.destroy(request);
        request.* = .{
            .allocator = self.allocator,
            .owner = self,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .originals = originals,
            .modified = if (originals.len == 0) std.array_list.Managed(u8).init(self.allocator) else try self.model.getValue(.LF, false),
            .options = self.options,
            .ignore_trim_whitespace = self.ignore_trim_whitespace,
            .version = self.model.getVersionId(),
        };
        return request;
    }

    /// Synchronous entry point for callers that explicitly await the result.
    pub fn recompute(self: *QuickDiffModel) !void {
        if (self.disposed) return;
        const request = try self.prepareDiff();
        defer request.destroy();
        try request.compute();
        try self.applyDiff(request);
    }

    fn applyDiff(self: *QuickDiffModel, request: *DiffRequest) !void {
        const new_quick_diffs = request.originals;
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
            const diff = request.diffs[quick_index] orelse continue;

            for (diff.changes) |mapping| {
                try all_changes.ensureUnusedCapacity(1);
                all_changes.appendAssumeCapacity(try self.convertMapping(quick, mapping));
                if (quick.kind == .secondary and
                    self.overlapsPrimary(visible_changes.items, new_quick_diffs, request.original_lines, quick_index, mapping)) continue;
                try visible_changes.ensureUnusedCapacity(1);
                visible_changes.appendAssumeCapacity(try self.convertMapping(quick, mapping));
            }
        }

        // Sort both lists by the visible change order used upstream.
        std.mem.sort(QuickDiffChange, all_changes.items, {}, changeLessThan);
        std.mem.sort(QuickDiffChange, visible_changes.items, {}, changeLessThan);

        var by_provider = std.StringHashMap(std.array_list.Managed(usize)).init(self.allocator);
        errdefer {
            var indices = by_provider.valueIterator();
            while (indices.next()) |list| list.deinit();
            by_provider.deinit();
        }
        for (visible_changes.items, 0..) |change, index| {
            const entry = try by_provider.getOrPut(change.provider_id);
            if (!entry.found_existing) entry.value_ptr.* = std.array_list.Managed(usize).init(self.allocator);
            try entry.value_ptr.append(index);
        }

        // Publish the complete result atomically after all allocations succeed.
        self.clearChanges();
        self.freeQuickDiffs();
        self.all_changes.deinit();
        self.changes.deinit();
        self.quick_diff_changes.deinit();
        self.quick_diffs = new_quick_diffs;
        request.originals = &.{};
        self.all_changes = all_changes;
        self.changes = visible_changes;
        self.quick_diff_changes = by_provider;
        self.changes_version_id = request.version;
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
