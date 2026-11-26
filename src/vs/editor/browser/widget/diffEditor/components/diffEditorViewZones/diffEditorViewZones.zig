// Port of `src/vs/editor/browser/widget/diffEditor/components/diffEditorViewZones/diffEditorViewZones.ts`.
// Terminal adaptation: alignment heights are in cells, with a solid theme
// background substituting for the CSS diagonal-fill image. The side-by-side
// editor uses the real model/view-zone pipeline. The old display-row helpers
// below remain only for the transitional inline/decorations tests.
const std = @import("std");
const Allocator = std.mem.Allocator;

const range_mapping = @import("../../../../../common/diff/rangeMapping.zig");
const LineRange = @import("../../../../../common/core/ranges/lineRange.zig").LineRange;

pub const DetailedLineRangeMapping = range_mapping.DetailedLineRangeMapping;

const diff_model = @import("../../diffEditorViewModel.zig");
const Editor = @import("../../../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextModel = @import("../../../../../common/model/textModel.zig").TextModel;

/// Upstream range alignment includes line wrapping and foreign view zones.
/// Heights are whole terminal rows; a diff index refers to a mapping from
/// the diff view-model state. Unchanged wrapped lines have no diff index.
pub const ILineRangeAlignment = struct {
    original_range: LineRange,
    modified_range: LineRange,
    original_height: usize,
    modified_height: usize,
    diff_index: ?usize = null,
};

pub const AdditionalLineHeightInfo = struct {
    line_number: usize,
    height: usize,
};

pub fn getAdditionalLineHeights(allocator: Allocator, editor: *Editor, ignored_zone_ids: []const []const u8) ![]AdditionalLineHeightInfo {
    var result: std.ArrayList(AdditionalLineHeightInfo) = .empty;
    errdefer result.deinit(allocator);
    if (editor.wrap_mode != .off) {
        for (1..editor.model.getLineCount() + 1) |line| {
            const count = editor.view_lines.getModelLineViewLineCount(line);
            if (count > 1) try result.append(allocator, .{ .line_number = line, .height = count - 1 });
        }
    }
    var ignored: std.StringHashMapUnmanaged(void) = .empty;
    defer ignored.deinit(allocator);
    try ignored.ensureTotalCapacity(allocator, @intCast(ignored_zone_ids.len));
    for (ignored_zone_ids) |id| ignored.putAssumeCapacity(id, {});
    const whitespaces = try editor.viewLayout().getWhitespaces(allocator);
    defer allocator.free(whitespaces);
    for (whitespaces) |whitespace| {
        if (ignored.contains(whitespace.id) or whitespace.height <= 0) continue;
        const model_line = if (whitespace.afterLineNumber == 0) 0 else editor.modelLineNumber(@min(whitespace.afterLineNumber, editor.viewLineCount()));
        try result.append(allocator, .{ .line_number = model_line, .height = @intFromFloat(whitespace.height) });
    }
    std.mem.sort(AdditionalLineHeightInfo, result.items, {}, struct {
        fn lessThan(_: void, left: AdditionalLineHeightInfo, right: AdditionalLineHeightInfo) bool {
            return left.line_number < right.line_number;
        }
    }.lessThan);
    var write: usize = 0;
    for (result.items) |value| {
        if (write > 0 and result.items[write - 1].line_number == value.line_number) {
            result.items[write - 1].height += value.height;
        } else {
            result.items[write] = value;
            write += 1;
        }
    }
    result.shrinkRetainingCapacity(write);
    return result.toOwnedSlice(allocator);
}

pub fn computeRangeAlignment(allocator: Allocator, original: *Editor, modified: *Editor, diffs: []const diff_model.DiffMapping, original_ignored: []const []const u8, modified_ignored: []const []const u8, inner_hunk_alignment: bool) ![]ILineRangeAlignment {
    const original_heights = try getAdditionalLineHeights(allocator, original, original_ignored);
    defer allocator.free(original_heights);
    const modified_heights = try getAdditionalLineHeights(allocator, modified, modified_ignored);
    defer allocator.free(modified_heights);
    return computeRangeAlignmentFromHeights(allocator, original.model, diffs, original_heights, modified_heights, inner_hunk_alignment);
}

const HeightQueue = struct {
    items: []const AdditionalLineHeightInfo,

    fn peekBefore(self: HeightQueue, until: usize) ?AdditionalLineHeightInfo {
        if (self.items.len == 0 or self.items[0].line_number >= until) return null;
        return self.items[0];
    }
    fn pop(self: *HeightQueue) void {
        self.items = self.items[1..];
    }
    fn takeHeightBefore(self: *HeightQueue, until: usize) usize {
        var result: usize = 0;
        while (self.peekBefore(until)) |next| {
            result += next.height;
            self.pop();
        }
        return result;
    }
};

const AlignmentBuilder = struct {
    allocator: Allocator,
    original: HeightQueue,
    modified: HeightQueue,
    result: std.ArrayList(ILineRangeAlignment) = .empty,
    last_original: usize = 0,
    last_modified: usize = 0,

    fn handleAlignmentsOutsideOfDiffs(self: *AlignmentBuilder, until_original: usize, until_modified: usize) !void {
        while (true) {
            var original_next = self.original.peekBefore(until_original);
            var modified_next = self.modified.peekBefore(until_modified);
            if (original_next == null and modified_next == null) break;
            const original_distance = if (original_next) |next| next.line_number -| self.last_original else std.math.maxInt(usize);
            const modified_distance = if (modified_next) |next| next.line_number -| self.last_modified else std.math.maxInt(usize);
            if (original_distance < modified_distance) {
                self.original.pop();
                modified_next = .{ .line_number = self.last_modified + original_distance, .height = 0 };
            } else if (original_distance > modified_distance) {
                self.modified.pop();
                original_next = .{ .line_number = self.last_original + modified_distance, .height = 0 };
            } else {
                self.original.pop();
                self.modified.pop();
            }
            try self.result.append(self.allocator, .{
                .original_range = LineRange.ofLength(original_next.?.line_number, 1),
                .modified_range = LineRange.ofLength(modified_next.?.line_number, 1),
                .original_height = 1 + original_next.?.height,
                .modified_height = 1 + modified_next.?.height,
            });
        }
    }

    const DiffAlignment = struct {
        builder: *AlignmentBuilder,
        diff_index: usize,
        first: bool = true,
        last_original: usize,
        last_modified: usize,

        fn emit(self: *DiffAlignment, original_end: usize, modified_end: usize, force: bool) !void {
            if (original_end < self.last_original or modified_end < self.last_modified) return;
            if (self.first) {
                self.first = false;
            } else if (!force and (original_end == self.last_original or modified_end == self.last_modified)) {
                return;
            }
            const original_range = LineRange.init(self.last_original, original_end);
            const modified_range = LineRange.init(self.last_modified, modified_end);
            if (original_range.isEmpty() and modified_range.isEmpty()) return;
            const original_height = original_range.length() + self.builder.original.takeHeightBefore(original_end);
            const modified_height = modified_range.length() + self.builder.modified.takeHeightBefore(modified_end);
            try self.builder.result.append(self.builder.allocator, .{
                .original_range = original_range,
                .modified_range = modified_range,
                .original_height = original_height,
                .modified_height = modified_height,
                .diff_index = self.diff_index,
            });
            self.last_original = original_end;
            self.last_modified = modified_end;
        }
    };
};

pub fn computeRangeAlignmentFromHeights(allocator: Allocator, original_model: *TextModel, diffs: []const diff_model.DiffMapping, original_heights: []const AdditionalLineHeightInfo, modified_heights: []const AdditionalLineHeightInfo, inner_hunk_alignment: bool) ![]ILineRangeAlignment {
    var builder = AlignmentBuilder{
        .allocator = allocator,
        .original = .{ .items = original_heights },
        .modified = .{ .items = modified_heights },
    };
    errdefer builder.result.deinit(allocator);
    for (diffs, 0..) |mapping, index| {
        const change = mapping.line_range_mapping;
        try builder.handleAlignmentsOutsideOfDiffs(change.original.startLineNumber, change.modified.startLineNumber);
        var alignment = AlignmentBuilder.DiffAlignment{
            .builder = &builder,
            .diff_index = index,
            .last_original = change.original.startLineNumber,
            .last_modified = change.modified.startLineNumber,
        };
        if (inner_hunk_alignment) for (change.inner_changes orelse &.{}) |inner| {
            const original = inner.originalRange;
            const modified = inner.modifiedRange;
            if (original.startColumn > 1 and modified.startColumn > 1) {
                try alignment.emit(original.startLineNumber, modified.startLineNumber, false);
            }
            const max_column = if (original.endLineNumber <= original_model.getLineCount()) original_model.getLineMaxColumn(original.endLineNumber) else std.math.maxInt(usize);
            if (original.endColumn < max_column) {
                try alignment.emit(original.endLineNumber, modified.endLineNumber, false);
            }
        };
        try alignment.emit(change.original.endLineNumberExclusive, change.modified.endLineNumberExclusive, true);
        builder.last_original = change.original.endLineNumberExclusive;
        builder.last_modified = change.modified.endLineNumberExclusive;
    }
    try builder.handleAlignmentsOutsideOfDiffs(std.math.maxInt(usize), std.math.maxInt(usize));
    return builder.result.toOwnedSlice(allocator);
}

const ui = @import("ui");
const ZoneView = @import("../../../../viewParts/viewZones/viewZones.zig");
const ViewEventHandler = @import("../../../../../common/viewEventHandler.zig").ViewEventHandler;
const events = @import("../../../../../common/viewEvents.zig");

/// Owns the alignment zones installed into the two real code editors. The
/// upstream observable derivation is driven by the corresponding view events;
/// own zone ids are excluded so an alignment transaction cannot feed back
/// into the next alignment calculation.
pub const DiffEditorViewZones = struct {
    allocator: Allocator,
    original: Pane,
    modified: Pane,
    mappings: []const diff_model.DiffMapping,
    enabled: bool = false,
    updating: bool = false,
    syncing_scroll: bool = false,
    batch_depth: usize = 0,
    filler_color: ui.Color = .{ .r = 40, .g = 42, .b = 44 },

    const ZoneSpec = struct { after_line_number: usize, height: usize };
    const ZoneRecord = struct { spec: ZoneSpec, id: []const u8 };

    const Pane = struct {
        owner: *DiffEditorViewZones,
        editor: *Editor,
        view_zones: *ZoneView.ViewZones,
        handler: ViewEventHandler = .{},
        records: std.ArrayList(ZoneRecord) = .empty,
    };

    pub fn init(self: *DiffEditorViewZones, allocator: Allocator, original: *Editor, original_zones: *ZoneView.ViewZones, modified: *Editor, modified_zones: *ZoneView.ViewZones, mappings: []const diff_model.DiffMapping) void {
        self.* = .{
            .allocator = allocator,
            .original = .{ .owner = self, .editor = original, .view_zones = original_zones },
            .modified = .{ .owner = self, .editor = modified, .view_zones = modified_zones },
            .mappings = mappings,
        };
        for ([_]*Pane{ &self.original, &self.modified }) |pane| {
            pane.handler = ViewEventHandler.init(pane, .{
                .onLineMappingChanged = onLineMappingChanged,
                .onZonesChanged = onZonesChanged,
                .onScrollChanged = onScrollChanged,
            });
            pane.editor.addViewEventHandler(&pane.handler);
        }
    }

    pub fn deinit(self: *DiffEditorViewZones) void {
        self.original.editor.removeViewEventHandler(&self.original.handler);
        self.modified.editor.removeViewEventHandler(&self.modified.handler);
        self.updating = true;
        self.apply(&self.original, &.{}, false) catch {};
        self.apply(&self.modified, &.{}, false) catch {};
        self.original.records.deinit(self.allocator);
        self.modified.records.deinit(self.allocator);
    }

    pub fn beginBatch(self: *DiffEditorViewZones) void {
        self.batch_depth += 1;
    }

    pub fn endBatch(self: *DiffEditorViewZones) void {
        std.debug.assert(self.batch_depth > 0);
        self.batch_depth -= 1;
        if (self.batch_depth == 0) self.updateAfterEvent();
    }

    pub fn setEnabled(self: *DiffEditorViewZones, enabled: bool) void {
        if (self.enabled == enabled) return;
        self.enabled = enabled;
        self.updateAfterEvent();
    }

    pub fn setFillerColor(self: *DiffEditorViewZones, color: ui.Color) void {
        if (std.meta.eql(self.filler_color, color)) return;
        self.filler_color = color;
        self.updating = true;
        defer self.updating = false;
        self.relayout(&self.original) catch {};
        self.relayout(&self.modified) catch {};
    }

    fn updateAfterEvent(self: *DiffEditorViewZones) void {
        if (self.updating or self.batch_depth > 0) return;
        self.recompute() catch |err| self.modified.editor.setMessage("diff view zones: {s}", .{@errorName(err)});
    }

    fn onLineMappingChanged(context: *anyopaque, _: *const events.ViewLineMappingChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        pane.owner.updateAfterEvent();
        return false;
    }

    fn onZonesChanged(context: *anyopaque, _: *const events.ViewZonesChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        pane.owner.updateAfterEvent();
        return false;
    }

    fn onScrollChanged(context: *anyopaque, event: *const events.ViewScrollChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        const self = pane.owner;
        if (!self.enabled or self.updating or self.syncing_scroll or self.batch_depth > 0 or !event.scrollTopChanged) return false;
        self.syncing_scroll = true;
        defer self.syncing_scroll = false;
        const other = if (pane == &self.original) &self.modified else &self.original;
        _ = other.editor.setScrollTop(pane.editor.scrollTop());
        return false;
    }

    pub fn recompute(self: *DiffEditorViewZones) !void {
        if (self.updating or self.batch_depth > 0) return;
        self.updating = true;
        defer self.updating = false;
        var original_specs: std.ArrayList(ZoneSpec) = .empty;
        defer original_specs.deinit(self.allocator);
        var modified_specs: std.ArrayList(ZoneSpec) = .empty;
        defer modified_specs.deinit(self.allocator);
        if (self.enabled) {
            const original_ignored = try self.ids(&self.original);
            defer self.allocator.free(original_ignored);
            const modified_ignored = try self.ids(&self.modified);
            defer self.allocator.free(modified_ignored);
            const alignments = try computeRangeAlignment(self.allocator, self.original.editor, self.modified.editor, self.mappings, original_ignored, modified_ignored, true);
            defer self.allocator.free(alignments);
            for (alignments) |alignment| {
                if (alignment.original_height < alignment.modified_height) {
                    try original_specs.append(self.allocator, .{
                        .after_line_number = alignment.original_range.endLineNumberExclusive - 1,
                        .height = alignment.modified_height - alignment.original_height,
                    });
                } else if (alignment.original_height > alignment.modified_height) {
                    try modified_specs.append(self.allocator, .{
                        .after_line_number = alignment.modified_range.endLineNumberExclusive - 1,
                        .height = alignment.original_height - alignment.modified_height,
                    });
                }
            }
        }
        try self.apply(&self.original, original_specs.items, false);
        try self.apply(&self.modified, modified_specs.items, false);
    }

    fn ids(self: *DiffEditorViewZones, pane: *const Pane) ![][]const u8 {
        const result = try self.allocator.alloc([]const u8, pane.records.items.len);
        for (pane.records.items, result) |record, *id| id.* = record.id;
        return result;
    }

    fn delegate(self: *DiffEditorViewZones, spec: ZoneSpec) ZoneView.IViewZone {
        return .{
            .after_line_number = spec.after_line_number,
            .height_in_lines = spec.height,
            .show_in_hidden_areas = true,
            .suppress_mouse_down = true,
            .context = self,
            .build = buildFiller,
        };
    }

    fn buildFiller(context: ?*anyopaque, doc: *ui.Document, _: ZoneView.IViewZone.RenderInfo) anyerror!*ui.Node {
        const self: *DiffEditorViewZones = @ptrCast(@alignCast(context.?));
        const node = try doc.createElement(.div);
        node.setStyle(.{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .background = self.filler_color });
        return node;
    }

    fn apply(self: *DiffEditorViewZones, pane: *Pane, desired: []const ZoneSpec, relayout_only: bool) !void {
        if (relayout_only) {
            const Transaction = struct {
                owner: *DiffEditorViewZones,
                pane: *Pane,
                fn run(tx: @This(), accessor: ZoneView.IViewZoneChangeAccessor) anyerror!void {
                    for (tx.pane.records.items) |record| try accessor.layoutZone(record.id, tx.owner.delegate(record.spec));
                }
            };
            try pane.view_zones.changeViewZones(Transaction{ .owner = self, .pane = pane }, Transaction.run);
            return;
        }
        // Retain a matching zone list, including its nodes and opaque IDs.
        // When the derived list changes, replace it in one transaction.
        if (pane.records.items.len == desired.len) {
            var equal = true;
            for (pane.records.items, desired) |record, spec| {
                if (!std.meta.eql(record.spec, spec)) {
                    equal = false;
                    break;
                }
            }
            if (equal) return;
        }
        try pane.records.ensureTotalCapacity(self.allocator, desired.len);
        const Transaction = struct {
            owner: *DiffEditorViewZones,
            pane: *Pane,
            desired: []const ZoneSpec,
            fn run(tx: @This(), accessor: ZoneView.IViewZoneChangeAccessor) anyerror!void {
                while (tx.pane.records.items.len > 0) {
                    try accessor.removeZone(tx.pane.records.items[tx.pane.records.items.len - 1].id);
                    _ = tx.pane.records.pop();
                }
                for (tx.desired) |spec| {
                    const id = try accessor.addZone(tx.owner.delegate(spec));
                    tx.pane.records.appendAssumeCapacity(.{ .id = id, .spec = spec });
                }
            }
        };
        try pane.view_zones.changeViewZones(Transaction{ .owner = self, .pane = pane, .desired = desired }, Transaction.run);
    }

    fn relayout(self: *DiffEditorViewZones, pane: *Pane) !void {
        try self.apply(pane, &.{}, true);
    }
};

/// One changed block in display coordinates. `original`/`modified` are
/// exclusive line ranges over the aligned display rows and include fillers.
pub const AlignedMapping = struct {
    original: LineRange,
    modified: LineRange,
    /// The real (un-aligned) mapping, borrowed from the view model state.
    source: DetailedLineRangeMapping,
};

pub const AlignedRows = struct {
    allocator: Allocator,
    /// Index 0 is display row 1; a value is the real line number, `null` is a
    /// filler row.
    original: []?usize,
    modified: []?usize,
    mappings: []AlignedMapping,
    /// Real line number -> display row (1-based), or null when the real line is
    /// not present in the display text.
    original_to_display: []?usize,
    modified_to_display: []?usize,

    pub fn deinit(self: *AlignedRows) void {
        self.allocator.free(self.original);
        self.allocator.free(self.modified);
        self.allocator.free(self.mappings);
        self.allocator.free(self.original_to_display);
        self.allocator.free(self.modified_to_display);
        self.* = undefined;
    }

    pub fn lineCount(self: *const AlignedRows) usize {
        return self.original.len;
    }

    pub fn displayRowForOriginal(self: *const AlignedRows, real_line: usize) ?usize {
        if (real_line == 0 or real_line > self.original_to_display.len) return null;
        return self.original_to_display[real_line - 1];
    }

    pub fn displayRowForModified(self: *const AlignedRows, real_line: usize) ?usize {
        if (real_line == 0 or real_line > self.modified_to_display.len) return null;
        return self.modified_to_display[real_line - 1];
    }

    /// Display line number map for a snapshot editor (1-based view line ->
    /// display number). Fillers map to `null`.
    pub fn originalLineNumberMap(self: *const AlignedRows) []const ?usize {
        return self.original;
    }

    pub fn modifiedLineNumberMap(self: *const AlignedRows) []const ?usize {
        return self.modified;
    }
};

pub fn computeAlignedRows(
    allocator: Allocator,
    original_line_count: usize,
    modified_line_count: usize,
    changes: []const DetailedLineRangeMapping,
) !AlignedRows {
    var original = std.array_list.Managed(?usize).init(allocator);
    errdefer original.deinit();
    var modified = std.array_list.Managed(?usize).init(allocator);
    errdefer modified.deinit();
    var mappings = std.array_list.Managed(AlignedMapping).init(allocator);
    errdefer mappings.deinit();

    var original_cursor: usize = 1;
    var modified_cursor: usize = 1;

    for (changes) |change| {
        // Unchanged segment before the changed block. Insertions have an empty
        // original range at the insertion point, so the segment length is zero
        // on both sides there.
        const original_unchanged = change.original.startLineNumber -| original_cursor;
        const modified_unchanged = change.modified.startLineNumber -| modified_cursor;
        const unchanged = @min(original_unchanged, modified_unchanged);
        var index: usize = 0;
        while (index < unchanged) : (index += 1) {
            try original.append(original_cursor + index);
            try modified.append(modified_cursor + index);
        }
        original_cursor += unchanged;
        modified_cursor += unchanged;

        const original_start_display = original.items.len + 1;
        const modified_start_display = modified.items.len + 1;

        const original_length = change.original.length();
        const modified_length = change.modified.length();
        const height = @max(original_length, modified_length);

        // Top-of-file pure insert/delete uses leading fillers, matching the
        // upstream leading filler rows. Other blocks pad at the end.
        const top_of_file = original_cursor == 1 and modified_cursor == 1 and
            (original_length == 0 or modified_length == 0);

        if (top_of_file) {
            try appendFillers(&original, height -| original_length);
            try appendFillers(&modified, height -| modified_length);
            index = 0;
            while (index < original_length) : (index += 1) try original.append(original_cursor + index);
            index = 0;
            while (index < modified_length) : (index += 1) try modified.append(modified_cursor + index);
        } else {
            index = 0;
            while (index < original_length) : (index += 1) try original.append(original_cursor + index);
            try appendFillers(&original, height -| original_length);
            index = 0;
            while (index < modified_length) : (index += 1) try modified.append(modified_cursor + index);
            try appendFillers(&modified, height -| modified_length);
        }

        try mappings.append(.{
            .original = LineRange.ofLength(original_start_display, height),
            .modified = LineRange.ofLength(modified_start_display, height),
            .source = change,
        });

        original_cursor += original_length;
        modified_cursor += modified_length;
    }

    // Trailing unchanged segment.
    const original_remaining = original_line_count -| (original_cursor - 1);
    const modified_remaining = modified_line_count -| (modified_cursor - 1);
    const remaining = @min(original_remaining, modified_remaining);
    var index: usize = 0;
    while (index < remaining) : (index += 1) {
        try original.append(original_cursor + index);
        try modified.append(modified_cursor + index);
    }

    const original_rows = try original.toOwnedSlice();
    errdefer allocator.free(original_rows);
    const modified_rows = try modified.toOwnedSlice();
    errdefer allocator.free(modified_rows);
    const aligned_mappings = try mappings.toOwnedSlice();
    errdefer allocator.free(aligned_mappings);

    if (original_rows.len != modified_rows.len) return error.AlignmentMismatch;

    const original_to_display = try allocator.alloc(?usize, original_line_count);
    errdefer allocator.free(original_to_display);
    @memset(original_to_display, null);
    for (original_rows, 0..) |row, display_index| {
        if (row) |line| {
            if (line <= original_line_count) original_to_display[line - 1] = display_index + 1;
        }
    }

    const modified_to_display = try allocator.alloc(?usize, modified_line_count);
    errdefer allocator.free(modified_to_display);
    @memset(modified_to_display, null);
    for (modified_rows, 0..) |row, display_index| {
        if (row) |line| {
            if (line <= modified_line_count) modified_to_display[line - 1] = display_index + 1;
        }
    }

    return .{
        .allocator = allocator,
        .original = original_rows,
        .modified = modified_rows,
        .mappings = aligned_mappings,
        .original_to_display = original_to_display,
        .modified_to_display = modified_to_display,
    };
}

fn appendFillers(list: *std.array_list.Managed(?usize), count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try list.append(null);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_support = @import("../../../../../test/common/port/testSupport.zig");
const TestModel = test_support.TestModel;
const doc_diff = @import("../../../../../common/diff/documentDiffProvider.zig");
const LineDiffProvider = doc_diff.LineDiffProvider;
const deinitDiff = doc_diff.deinitDiff;

fn compute(allocator: Allocator, original_lines: []const []const u8, modified_lines: []const []const u8) !struct {
    diff: doc_diff.IDocumentDiff,
    rows: AlignedRows,
} {
    var provider = LineDiffProvider.init(.advanced);
    var diff = try provider.computeDiffFromLines(allocator, original_lines, modified_lines, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    errdefer deinitDiff(allocator, &diff);
    const rows = try computeAlignedRows(allocator, original_lines.len, modified_lines.len, diff.changes);
    return .{ .diff = diff, .rows = rows };
}

test "viewZones: equal row counts and aligned block starts" {
    const allocator = testing.allocator;
    const original = [_][]const u8{ "a", "b", "c", "d" };
    const modified = [_][]const u8{ "a", "B1", "B2", "c", "d", "e" };
    var result = try compute(allocator, &original, &modified);
    defer {
        result.rows.deinit();
        deinitDiff(allocator, &result.diff);
    }

    try testing.expectEqual(result.rows.original.len, result.rows.modified.len);
    // One changed line that becomes two, plus a trailing inserted line.
    try testing.expectEqual(@as(usize, 2), result.rows.mappings.len);
    for (result.rows.mappings) |mapping| {
        try testing.expectEqual(mapping.original.startLineNumber, mapping.modified.startLineNumber);
        try testing.expectEqual(mapping.original.length(), mapping.modified.length());
    }
    // Each changed block pads the shorter original side with one filler, so the
    // following unchanged lines stay aligned.
    try testing.expectEqual(@as(usize, 2), countFillers(result.rows.original));

    const original_c = result.rows.displayRowForOriginal(3).?;
    const modified_c = result.rows.displayRowForModified(4).?;
    try testing.expectEqual(original_c, modified_c);
}

test "viewZones: middle insertion and deletion keep both sides aligned" {
    const allocator = testing.allocator;

    const original_insert = [_][]const u8{ "a", "b", "c" };
    const modified_insert = [_][]const u8{ "a", "x", "b", "c" };
    var insert = try compute(allocator, &original_insert, &modified_insert);
    defer {
        insert.rows.deinit();
        deinitDiff(allocator, &insert.diff);
    }
    try testing.expectEqual(insert.rows.original.len, insert.rows.modified.len);
    try testing.expectEqual(@as(usize, 1), countFillers(insert.rows.original));
    try testing.expectEqual(@as(usize, 0), countFillers(insert.rows.modified));

    const original_delete = [_][]const u8{ "a", "x", "b", "c" };
    const modified_delete = [_][]const u8{ "a", "b", "c" };
    var deleted = try compute(allocator, &original_delete, &modified_delete);
    defer {
        deleted.rows.deinit();
        deinitDiff(allocator, &deleted.diff);
    }
    try testing.expectEqual(deleted.rows.original.len, deleted.rows.modified.len);
    try testing.expectEqual(@as(usize, 0), countFillers(deleted.rows.original));
    try testing.expectEqual(@as(usize, 1), countFillers(deleted.rows.modified));
}

test "viewZones: top-of-file insertion uses leading fillers" {
    const allocator = testing.allocator;
    const original = [_][]const u8{ "a", "b" };
    const modified = [_][]const u8{ "x", "y", "a", "b" };
    var result = try compute(allocator, &original, &modified);
    defer {
        result.rows.deinit();
        deinitDiff(allocator, &result.diff);
    }

    try testing.expectEqual(result.rows.original.len, result.rows.modified.len);
    try testing.expectEqual(@as(?usize, null), result.rows.original[0]);
    try testing.expectEqual(@as(?usize, null), result.rows.original[1]);
    try testing.expectEqual(@as(?usize, 1), result.rows.original[2]);
    try testing.expectEqual(@as(?usize, 1), result.rows.modified[0]);
    try testing.expectEqual(@as(?usize, 2), result.rows.modified[1]);
    // The unchanged 'a' line is aligned after the leading block.
    try testing.expectEqual(result.rows.displayRowForOriginal(1), result.rows.displayRowForModified(3));
}

test "viewZones: top-of-file deletion uses leading fillers" {
    const allocator = testing.allocator;
    const original = [_][]const u8{ "x", "a", "b" };
    const modified = [_][]const u8{ "a", "b" };
    var result = try compute(allocator, &original, &modified);
    defer {
        result.rows.deinit();
        deinitDiff(allocator, &result.diff);
    }

    try testing.expectEqual(result.rows.original.len, result.rows.modified.len);
    try testing.expectEqual(@as(?usize, null), result.rows.modified[0]);
    try testing.expectEqual(@as(?usize, 1), result.rows.modified[1]);
    // The unchanged lines after the deleted top line stay aligned.
    try testing.expectEqual(result.rows.displayRowForOriginal(2), result.rows.displayRowForModified(1));
}

test "viewZones: line number maps expose fillers" {
    const allocator = testing.allocator;
    const original = [_][]const u8{ "a", "c" };
    const modified = [_][]const u8{ "a", "b", "c" };
    var result = try compute(allocator, &original, &modified);
    defer {
        result.rows.deinit();
        deinitDiff(allocator, &result.diff);
    }

    const map = result.rows.originalLineNumberMap();
    try testing.expectEqual(@as(usize, 3), map.len);
    try testing.expectEqual(@as(?usize, 1), map[0]);
    try testing.expectEqual(@as(?usize, null), map[1]);
    try testing.expectEqual(@as(?usize, 2), map[2]);
    const modified_map = result.rows.modifiedLineNumberMap();
    try testing.expectEqual(@as(?usize, 2), modified_map[1]);
}

fn countFillers(rows: []const ?usize) usize {
    var count: usize = 0;
    for (rows) |row| {
        if (row == null) count += 1;
    }
    return count;
}

test "diffEditorWidget: range alignment accounts for wrapping and foreign whitespace outside and inside changes" {
    const allocator = testing.allocator;
    var original = try test_support.TestModel.init(allocator, "a\nb\nc\nd\ne\nf", "plaintext");
    defer original.deinit();
    const mapping = diff_model.DiffMapping{ .line_range_mapping = .{
        .original = LineRange.init(3, 4),
        .modified = LineRange.init(3, 5),
        .inner_changes = null,
    } };
    const alignments = try computeRangeAlignmentFromHeights(allocator, original.model, &.{mapping}, &.{
        .{ .line_number = 0, .height = 2 },
        .{ .line_number = 2, .height = 3 },
        .{ .line_number = 3, .height = 1 },
        .{ .line_number = 5, .height = 4 },
    }, &.{
        .{ .line_number = 2, .height = 1 },
        .{ .line_number = 4, .height = 2 },
        .{ .line_number = 6, .height = 1 },
    }, true);
    defer allocator.free(alignments);
    try testing.expectEqual(@as(usize, 4), alignments.len);
    try testing.expectEqual(ILineRangeAlignment{ .original_range = LineRange.init(0, 1), .modified_range = LineRange.init(0, 1), .original_height = 3, .modified_height = 1 }, alignments[0]);
    try testing.expectEqual(ILineRangeAlignment{ .original_range = LineRange.init(2, 3), .modified_range = LineRange.init(2, 3), .original_height = 4, .modified_height = 2 }, alignments[1]);
    try testing.expectEqual(ILineRangeAlignment{ .original_range = LineRange.init(3, 4), .modified_range = LineRange.init(3, 5), .original_height = 2, .modified_height = 4, .diff_index = 0 }, alignments[2]);
    try testing.expectEqual(ILineRangeAlignment{ .original_range = LineRange.init(5, 6), .modified_range = LineRange.init(6, 7), .original_height = 5, .modified_height = 2 }, alignments[3]);
}

test "diffEditorWidget: inner hunk alignment splits at the unchanged line content" {
    const allocator = testing.allocator;
    var original = try test_support.TestModel.init(allocator, "a\nabc\ndef\nghi\nz", "plaintext");
    defer original.deinit();
    const Range = @import("../../../../../common/core/range.zig").Range;
    const mapping = diff_model.DiffMapping{ .line_range_mapping = .{
        .original = LineRange.init(2, 5),
        .modified = LineRange.init(2, 6),
        .inner_changes = &.{.{
            .originalRange = Range.init(3, 2, 3, 3),
            .modifiedRange = Range.init(4, 2, 4, 3),
        }},
    } };
    const alignments = try computeRangeAlignmentFromHeights(allocator, original.model, &.{mapping}, &.{}, &.{}, true);
    defer allocator.free(alignments);
    try testing.expectEqual(@as(usize, 2), alignments.len);
    try testing.expectEqual(ILineRangeAlignment{ .original_range = LineRange.init(2, 3), .modified_range = LineRange.init(2, 4), .original_height = 1, .modified_height = 2, .diff_index = 0 }, alignments[0]);
    try testing.expectEqual(ILineRangeAlignment{ .original_range = LineRange.init(3, 5), .modified_range = LineRange.init(4, 6), .original_height = 2, .modified_height = 2, .diff_index = 0 }, alignments[1]);
}
