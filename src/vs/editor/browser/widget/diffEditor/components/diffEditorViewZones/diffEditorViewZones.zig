// Port of `src/vs/editor/browser/widget/diffEditor/components/diffEditorViewZones/diffEditorViewZones.ts`.
// Terminal adaptation: alignment heights are in cells, with a solid theme
// background substituting for the CSS diagonal-fill image. Both side-by-side
// and inline modes use real model ranges, with viewport-windowed deleted code
// constructed by renderLines.zig.
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
const render_lines = @import("./renderLines.zig");
const TerminalViewHost = @import("../../../codeEditor/terminalViewHost.zig").TerminalViewHost;
const ViewLine = @import("../../../../viewParts/viewLines/viewLine.zig").ViewLine;
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
    mode: Mode = .disabled,
    modified_host: *TerminalViewHost,
    style_fn: ViewLine.PartStyleFn,
    decoration_bits_fn: *const fn ([]const u8) u32,
    render_indicators: bool,
    updating: bool = false,
    syncing_scroll: bool = false,
    batch_depth: usize = 0,
    colors: Colors = .{},

    pub const Mode = enum { disabled, side_by_side, inline_view };
    pub const Colors = struct {
        filler: ui.Color = .{ .r = 40, .g = 42, .b = 44 },
        removed_line: ui.Color = .{ .r = 75, .g = 24, .b = 24 },
        removed_text: ui.Color = .{ .r = 92, .g = 30, .b = 30 },
        indicator: ui.Color = .{ .r = 158, .g = 93, .b = 80 },
    };

    const DeletedSpec = struct {
        range: LineRange,
        diff_index: usize,
        options: render_lines.RenderOptions,
    };
    const ZoneSpec = struct {
        after_line_number: usize,
        height: usize,
        min_width: usize = 0,
        deleted: ?DeletedSpec = null,
    };
    const DeletedData = struct {
        owner: *DiffEditorViewZones,
        spec: DeletedSpec,
        measurement: render_lines.RenderLinesResult,
    };
    const ZoneRecord = struct { spec: ZoneSpec, id: []const u8, deleted: ?*DeletedData = null };

    const Pane = struct {
        owner: *DiffEditorViewZones,
        editor: *Editor,
        view_zones: *ZoneView.ViewZones,
        handler: ViewEventHandler = .{},
        records: std.ArrayList(ZoneRecord) = .empty,
    };

    pub fn init(self: *DiffEditorViewZones, allocator: Allocator, original: *Editor, original_zones: *ZoneView.ViewZones, modified: *Editor, modified_zones: *ZoneView.ViewZones, modified_host: *TerminalViewHost, style_fn: ViewLine.PartStyleFn, decoration_bits_fn: *const fn ([]const u8) u32, render_indicators: bool, mappings: []const diff_model.DiffMapping) void {
        self.* = .{
            .allocator = allocator,
            .original = .{ .owner = self, .editor = original, .view_zones = original_zones },
            .modified = .{ .owner = self, .editor = modified, .view_zones = modified_zones },
            .mappings = mappings,
            .modified_host = modified_host,
            .style_fn = style_fn,
            .decoration_bits_fn = decoration_bits_fn,
            .render_indicators = render_indicators,
        };
        for ([_]*Pane{ &self.original, &self.modified }) |pane| {
            pane.handler = ViewEventHandler.init(pane, .{
                .onLineMappingChanged = onLineMappingChanged,
                .onConfigurationChanged = onConfigurationChanged,
                .onZonesChanged = onZonesChanged,
                .onScrollChanged = onScrollChanged,
                .onTokensChanged = onTokensChanged,
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

    pub fn setMode(self: *DiffEditorViewZones, mode: Mode) void {
        if (self.mode == mode) return;
        self.mode = mode;
        self.updateAfterEvent();
    }

    pub fn setColors(self: *DiffEditorViewZones, colors: Colors) void {
        if (std.meta.eql(self.colors, colors)) return;
        self.colors = colors;
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

    fn onConfigurationChanged(context: *anyopaque, _: *const events.ViewConfigurationChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        if (pane.owner.mode == .inline_view) pane.owner.updateAfterEvent();
        return false;
    }

    fn onTokensChanged(context: *anyopaque, _: *const events.ViewTokensChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        const self = pane.owner;
        if (self.mode != .inline_view or pane != &self.original) return false;
        for (self.modified.records.items) |record| {
            if (record.deleted != null) self.modified.view_zones.invalidateZoneContent(record.id);
        }
        return false;
    }

    fn onScrollChanged(context: *anyopaque, event: *const events.ViewScrollChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        const self = pane.owner;
        if (self.mode == .disabled or self.updating or self.syncing_scroll or self.batch_depth > 0 or !event.scrollTopChanged) return false;
        if (self.mode == .inline_view and pane == &self.original) return false;
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
        if (self.mode != .disabled) {
            const original_ignored = try self.ids(&self.original);
            defer self.allocator.free(original_ignored);
            const modified_ignored = try self.ids(&self.modified);
            defer self.allocator.free(modified_ignored);
            const alignments = try computeRangeAlignment(self.allocator, self.original.editor, self.modified.editor, self.mappings, original_ignored, modified_ignored, self.mode == .side_by_side);
            defer self.allocator.free(alignments);
            const options = self.renderOptions();
            for (alignments) |alignment| {
                if (self.mode == .inline_view and alignment.diff_index != null) {
                    if (!alignment.original_range.isEmpty()) {
                        var measurement = try render_lines.measure(self.allocator, self.original.editor.model, alignment.original_range, &self.modified.editor.view_lines.classifier, options);
                        defer measurement.deinit();
                        try modified_specs.append(self.allocator, .{
                            .after_line_number = alignment.modified_range.startLineNumber - 1,
                            .height = measurement.height_in_lines,
                            .min_width = measurement.min_width,
                            .deleted = .{ .range = alignment.original_range, .diff_index = alignment.diff_index.?, .options = options },
                        });
                        for (0..alignment.original_range.length()) |index| {
                            const count = measurement.viewLineCount(index);
                            if (count > 1) try original_specs.append(self.allocator, .{
                                .after_line_number = alignment.original_range.startLineNumber + index,
                                .height = count - 1,
                            });
                        }
                    }
                    if (alignment.modified_height > 0) try original_specs.append(self.allocator, .{
                        .after_line_number = alignment.original_range.endLineNumberExclusive - 1,
                        .height = alignment.modified_height,
                    });
                    continue;
                }
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

    fn renderOptions(self: *DiffEditorViewZones) render_lines.RenderOptions {
        var options = render_lines.RenderOptions.fromEditor(self.modified.editor);
        options.render_whitespace = self.modified_host.options.get(.renderWhitespace);
        options.render_control_characters = self.modified_host.options.get(.renderControlCharacters);
        options.stop_rendering_line_after = self.modified_host.options.get(.stopRenderingLineAfter);
        return options;
    }

    fn delegate(self: *DiffEditorViewZones, spec: ZoneSpec, deleted: ?*DeletedData) ZoneView.IViewZone {
        if (deleted) |data| return .{
            .after_line_number = spec.after_line_number,
            .height_in_lines = spec.height,
            .min_width = spec.min_width,
            .show_in_hidden_areas = true,
            .clip_to_viewport = true,
            .context = data,
            .build = buildDeleted,
            .build_margin = buildDeletedMargin,
        };
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
        node.setStyle(.{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .background = self.colors.filler });
        return node;
    }

    fn buildDeleted(context: ?*anyopaque, doc: *ui.Document, info: ZoneView.IViewZone.RenderInfo) anyerror!*ui.Node {
        const data: *DeletedData = @ptrCast(@alignCast(context.?));
        const self = data.owner;
        const mapping = self.mappings[data.spec.diff_index].line_range_mapping;
        return render_lines.renderLines(self.allocator, doc, self.original.editor.model, data.spec.range, mapping.inner_changes orelse &.{}, &data.measurement, &self.modified.editor.view_lines.classifier, data.spec.options, .{
            .colors = .{ .line_background = self.colors.removed_line, .text_background = self.colors.removed_text },
            .style_fn = self.style_fn,
            .decoration_bits_fn = self.decoration_bits_fn,
        }, info);
    }

    fn buildDeletedMargin(context: ?*anyopaque, doc: *ui.Document, info: ZoneView.IViewZone.RenderInfo) anyerror!*ui.Node {
        const data: *DeletedData = @ptrCast(@alignCast(context.?));
        return render_lines.renderMargin(doc, info, data.owner.render_indicators, data.owner.colors.indicator);
    }

    fn createDeletedData(self: *DiffEditorViewZones, spec: DeletedSpec) !*DeletedData {
        const data = try self.allocator.create(DeletedData);
        errdefer self.allocator.destroy(data);
        data.* = .{
            .owner = self,
            .spec = spec,
            .measurement = try render_lines.measure(self.allocator, self.original.editor.model, spec.range, &self.modified.editor.view_lines.classifier, spec.options),
        };
        return data;
    }

    fn freeDeletedData(self: *DiffEditorViewZones, data: ?*DeletedData) void {
        if (data) |deleted| {
            deleted.measurement.deinit();
            self.allocator.destroy(deleted);
        }
    }

    fn apply(self: *DiffEditorViewZones, pane: *Pane, desired: []const ZoneSpec, relayout_only: bool) !void {
        if (relayout_only) {
            const Transaction = struct {
                owner: *DiffEditorViewZones,
                pane: *Pane,
                fn run(tx: @This(), accessor: ZoneView.IViewZoneChangeAccessor) anyerror!void {
                    for (tx.pane.records.items) |record| try accessor.layoutZone(record.id, tx.owner.delegate(record.spec, record.deleted));
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
                    const record = tx.pane.records.items[tx.pane.records.items.len - 1];
                    try accessor.removeZone(record.id);
                    _ = tx.pane.records.pop();
                    tx.owner.freeDeletedData(record.deleted);
                }
                for (tx.desired) |spec| {
                    const data = if (spec.deleted) |deleted| try tx.owner.createDeletedData(deleted) else null;
                    errdefer tx.owner.freeDeletedData(data);
                    const id = try accessor.addZone(tx.owner.delegate(spec, data));
                    tx.pane.records.appendAssumeCapacity(.{ .id = id, .spec = spec, .deleted = data });
                }
            }
        };
        try pane.view_zones.changeViewZones(Transaction{ .owner = self, .pane = pane, .desired = desired }, Transaction.run);
    }

    fn relayout(self: *DiffEditorViewZones, pane: *Pane) !void {
        try self.apply(pane, &.{}, true);
    }
};

// Tests for the real range-alignment algorithm. The terminal integration
// cases also assert the actual installed whitespace and model line numbers.
const testing = std.testing;
const test_support = @import("../../../../../test/common/port/testSupport.zig");
const doc_diff = @import("../../../../../common/diff/documentDiffProvider.zig");

fn compute(allocator: Allocator, original_lines: []const []const u8, modified_lines: []const []const u8) ![]ILineRangeAlignment {
    const text = try std.mem.join(allocator, "\n", original_lines);
    defer allocator.free(text);
    var original_model = try test_support.TestModel.init(allocator, text, "plaintext");
    defer original_model.deinit();
    var provider = doc_diff.LineDiffProvider.init(.advanced);
    var diff = try provider.computeDiffFromLines(allocator, original_lines, modified_lines, .{ .ignoreTrimWhitespace = false, .maxComputationTimeMs = 0, .computeMoves = false });
    defer doc_diff.deinitDiff(allocator, &diff);
    const mappings = try allocator.alloc(diff_model.DiffMapping, diff.changes.len);
    defer allocator.free(mappings);
    for (mappings, diff.changes) |*mapping, change| mapping.* = .{ .line_range_mapping = change };
    return computeRangeAlignmentFromHeights(allocator, original_model.model, mappings, &.{}, &.{}, true);
}

test "viewZones: unequal changed blocks use the required alignment heights" {
    const allocator = testing.allocator;
    const alignments = try compute(allocator, &.{ "a", "b", "c", "d" }, &.{ "a", "B1", "B2", "c", "d", "e" });
    defer allocator.free(alignments);
    try testing.expectEqual(@as(usize, 2), alignments.len);
    try testing.expectEqual(LineRange.init(2, 3), alignments[0].original_range);
    try testing.expectEqual(LineRange.init(2, 4), alignments[0].modified_range);
    try testing.expectEqual(@as(usize, 1), alignments[0].original_height);
    try testing.expectEqual(@as(usize, 2), alignments[0].modified_height);
    try testing.expectEqual(@as(usize, 0), alignments[1].original_height);
    try testing.expectEqual(@as(usize, 1), alignments[1].modified_height);
}

test "viewZones: middle insertion and deletion keep both sides aligned" {
    const allocator = testing.allocator;
    const insert = try compute(allocator, &.{ "a", "b", "c" }, &.{ "a", "x", "b", "c" });
    defer allocator.free(insert);
    try testing.expectEqual(@as(usize, 1), insert.len);
    try testing.expectEqual(LineRange.init(2, 2), insert[0].original_range);
    try testing.expectEqual(@as(usize, 0), insert[0].original_height);
    try testing.expectEqual(@as(usize, 1), insert[0].modified_height);
    const deleted = try compute(allocator, &.{ "a", "x", "b", "c" }, &.{ "a", "b", "c" });
    defer allocator.free(deleted);
    try testing.expectEqual(@as(usize, 1), deleted.len);
    try testing.expectEqual(LineRange.init(2, 2), deleted[0].modified_range);
    try testing.expectEqual(@as(usize, 1), deleted[0].original_height);
    try testing.expectEqual(@as(usize, 0), deleted[0].modified_height);
}

test "viewZones: top-of-file insertion anchors before the first original line" {
    const allocator = testing.allocator;
    const insert = try compute(allocator, &.{ "a", "b" }, &.{ "x", "y", "a", "b" });
    defer allocator.free(insert);
    try testing.expectEqual(@as(usize, 1), insert.len);
    try testing.expectEqual(@as(usize, 0), insert[0].original_range.endLineNumberExclusive - 1);
    try testing.expectEqual(@as(usize, 2), insert[0].modified_height - insert[0].original_height);
}

test "viewZones: top-of-file deletion anchors before the first modified line" {
    const allocator = testing.allocator;
    const deleted = try compute(allocator, &.{ "x", "a", "b" }, &.{ "a", "b" });
    defer allocator.free(deleted);
    try testing.expectEqual(@as(usize, 1), deleted.len);
    try testing.expectEqual(@as(usize, 0), deleted[0].modified_range.endLineNumberExclusive - 1);
    try testing.expectEqual(@as(usize, 1), deleted[0].original_height - deleted[0].modified_height);
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
