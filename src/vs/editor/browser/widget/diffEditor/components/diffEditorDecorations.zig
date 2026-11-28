// Port of
// `src/vs/editor/browser/widget/diffEditor/components/diffEditorDecorations.ts`.
//
// Terminal adaptation: model decorations retain their real model ranges.
// Whole-line and character classes are resolved through the editor's
// cell compositor; alignment filler and inline deleted text are view zones
// owned by DiffEditorViewZones, never fake model decorations.
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_model = @import("../diffEditorViewModel.zig");
const model_mod = @import("../../../../common/model.zig");
const text_model = @import("../../../../common/model/textModel.zig");
const range_mapping = @import("../../../../common/diff/rangeMapping.zig");
const Range = @import("../../../../common/core/range.zig").Range;
const zones = @import("./diffEditorViewZones/diffEditorViewZones.zig");
const registrations = @import("../registrations.contribution.zig");

pub const ModelDecorationOptions = model_mod.ModelDecorationOptions;
pub const ModelDeltaDecoration = model_mod.ModelDeltaDecoration;
pub const OverviewRulerLane = model_mod.OverviewRulerLane;
pub const TextModel = text_model.TextModel;
pub const DiffState = view_model.DiffState;
pub const RangeMapping = range_mapping.RangeMapping;

pub const Config = struct {
    render_indicators: bool = true,
    render_overview_ruler: bool = true,
    show_empty_decorations: bool = true,
    use_true_inline_view: bool = false,
};

/// Terminal defaults for `diffEditor.insertedLineBackground`/
/// `removedLineBackground`/`insertedTextBackground`/`removedTextBackground`
/// composited over the dark editor background (cells have no alpha).
pub const inserted_line_background = [3]u8{ 55, 61, 41 };
pub const removed_line_background = [3]u8{ 75, 24, 24 };
pub const inserted_text_background = [3]u8{ 74, 84, 45 };
pub const removed_text_background = [3]u8{ 92, 30, 30 };

pub const DiffEditorDecorations = struct {
    allocator: Allocator,
    original_model: *TextModel,
    modified_model: *TextModel,
    original_owner: usize,
    modified_owner: usize,
    config: Config,
    original_ids: []u64 = &.{},
    modified_ids: []u64 = &.{},
    injected_options: std.ArrayList(*ModelDecorationOptions) = .empty,

    line_insert: ModelDecorationOptions,
    line_delete: ModelDecorationOptions,
    char_insert: ModelDecorationOptions,
    char_delete: ModelDecorationOptions,
    whole_line_char_insert: ModelDecorationOptions,
    whole_line_char_delete: ModelDecorationOptions,
    char_insert_empty: ModelDecorationOptions,
    char_delete_empty: ModelDecorationOptions,
    moved_original: ModelDecorationOptions,
    moved_modified: ModelDecorationOptions,
    moved_original_active: ModelDecorationOptions,
    moved_modified_active: ModelDecorationOptions,

    pub fn init(
        allocator: Allocator,
        original_model: *TextModel,
        modified_model: *TextModel,
        original_owner: usize,
        modified_owner: usize,
        config: Config,
    ) DiffEditorDecorations {
        var self = DiffEditorDecorations{
            .allocator = allocator,
            .original_model = original_model,
            .modified_model = modified_model,
            .original_owner = original_owner,
            .modified_owner = modified_owner,
            .config = config,
            .line_insert = undefined,
            .line_delete = undefined,
            .char_insert = undefined,
            .char_delete = undefined,
            .whole_line_char_insert = undefined,
            .whole_line_char_delete = undefined,
            .char_insert_empty = undefined,
            .char_delete_empty = undefined,
            .moved_original = undefined,
            .moved_modified = undefined,
            .moved_original_active = undefined,
            .moved_modified_active = undefined,
        };
        self.buildOptions();
        return self;
    }

    pub fn deinit(self: *DiffEditorDecorations) void {
        self.detach();
        self.* = undefined;
    }

    pub fn detach(self: *DiffEditorDecorations) void {
        const new_original = self.applyTo(self.original_model, self.original_owner, self.original_ids, &.{}) catch &.{};
        if (new_original.len > 0) self.allocator.free(new_original);
        if (self.original_ids.len > 0) self.allocator.free(self.original_ids);
        self.original_ids = &.{};

        const new_modified = self.applyTo(self.modified_model, self.modified_owner, self.modified_ids, &.{}) catch &.{};
        if (new_modified.len > 0) self.allocator.free(new_modified);
        if (self.modified_ids.len > 0) self.allocator.free(self.modified_ids);
        self.modified_ids = &.{};
        self.freeInjectedOptions(&self.injected_options);
    }

    pub fn setConfig(self: *DiffEditorDecorations, config: Config, state: *const DiffState, show_moves: bool) !void {
        try self.setConfigWithMoveState(config, state, show_moves, null, null);
    }

    pub fn setConfigWithMoveState(self: *DiffEditorDecorations, config: Config, state: *const DiffState, show_moves: bool, active: ?usize, compare: ?usize) !void {
        if (!std.meta.eql(self.config, config)) {
            // Remove before rewriting the option values: the model buckets
            // decorations by the options it saw at insertion time.
            self.detach();
            self.config = config;
            self.buildOptions();
        }
        try self.updateWithMoveState(state, show_moves, active, compare);
    }

    fn buildOptions(self: *DiffEditorDecorations) void {
        self.line_insert = if (self.config.render_indicators)
            registrations.diffLineAddDecorationBackgroundWithIndicator(self.config.render_overview_ruler)
        else
            registrations.diffLineAddDecorationBackground(self.config.render_overview_ruler);
        self.line_delete = if (self.config.render_indicators)
            registrations.diffLineDeleteDecorationBackgroundWithIndicator(self.config.render_overview_ruler)
        else
            registrations.diffLineDeleteDecorationBackground(self.config.render_overview_ruler);
        self.char_insert = registrations.diffAddDecoration;
        self.char_delete = registrations.diffDeleteDecoration;
        self.whole_line_char_insert = registrations.diffWholeLineAddDecoration;
        self.whole_line_char_delete = registrations.diffWholeLineDeleteDecoration;
        self.char_insert_empty = registrations.diffAddDecorationEmpty;
        self.char_delete_empty = registrations.diffDeleteDecorationEmpty;
        self.moved_original = createMovedBlock("movedOriginal");
        self.moved_modified = createMovedBlock("movedModified");
        self.moved_original_active = createMovedBlock("movedOriginal currentMove");
        self.moved_modified_active = createMovedBlock("movedModified currentMove");
    }

    fn freeInjectedOptions(self: *DiffEditorDecorations, options: *std.ArrayList(*ModelDecorationOptions)) void {
        for (options.items) |option| {
            self.allocator.free(option.before.?.content);
            self.allocator.destroy(option);
        }
        options.deinit(self.allocator);
        options.* = .empty;
    }

    fn createInjectedOption(self: *DiffEditorDecorations, original_range: Range) !*ModelDecorationOptions {
        const option = try self.allocator.create(ModelDecorationOptions);
        errdefer self.allocator.destroy(option);
        var deleted = try self.original_model.getValueInRange(original_range, null);
        defer deleted.deinit();
        const content = try self.allocator.dupe(u8, deleted.items);
        option.* = ModelDecorationOptions.init("deleted-text", .AlwaysGrowsWhenTypingAtEdges);
        option.before = .{
            .content = content,
            .inlineClassName = "inline-deleted-text",
            .inlineClassNameAffectsLetterSpacing = false,
            .attachedData = null,
            .cursorStops = null,
        };
        option.zIndex = 100000;
        option.showIfCollapsed = true;
        return option;
    }

    /// The real-model decoration path. Alignment whitespace belongs to
    /// DiffEditorViewZones, never to either text model.
    pub fn update(self: *DiffEditorDecorations, state: *const DiffState, show_moves: bool) !void {
        try self.updateWithMoveState(state, show_moves, null, null);
    }

    pub fn updateWithMoveState(self: *DiffEditorDecorations, state: *const DiffState, show_moves: bool, active: ?usize, compare: ?usize) !void {
        var original_decorations = std.array_list.Managed(ModelDeltaDecoration).init(self.allocator);
        defer original_decorations.deinit();
        var modified_decorations = std.array_list.Managed(ModelDeltaDecoration).init(self.allocator);
        defer modified_decorations.deinit();
        var injected: std.ArrayList(*ModelDecorationOptions) = .empty;
        errdefer self.freeInjectedOptions(&injected);
        if (compare) |index| {
            for (state.moved_texts[index].changes) |change| {
                if (change.original.toInclusiveRange()) |range| try original_decorations.append(.{ .range = range, .options = &self.line_delete });
                if (change.modified.toInclusiveRange()) |range| try modified_decorations.append(.{ .range = range, .options = &self.line_insert });
                for (change.inner_changes orelse &.{}) |inner| {
                    try original_decorations.append(.{ .range = inner.originalRange, .options = &self.char_delete });
                    try modified_decorations.append(.{ .range = inner.modifiedRange, .options = &self.char_insert });
                }
            }
        } else for (state.mappings) |mapping| {
            const change = mapping.line_range_mapping;
            if (change.original.toInclusiveRange()) |range| try original_decorations.append(.{ .range = range, .options = &self.line_delete });
            if (change.modified.toInclusiveRange()) |range| try modified_decorations.append(.{ .range = range, .options = &self.line_insert });
            if (change.original.isEmpty() or change.modified.isEmpty()) {
                if (change.original.toInclusiveRange()) |range| try original_decorations.append(.{ .range = range, .options = &self.whole_line_char_delete });
                if (change.modified.toInclusiveRange()) |range| try modified_decorations.append(.{ .range = range, .options = &self.whole_line_char_insert });
                continue;
            }
            const use_inline = self.config.use_true_inline_view and zones.allowsTrueInlineDiffRendering(change);
            for (change.inner_changes orelse &.{}) |inner| {
                if (change.original.contains(inner.originalRange.startLineNumber)) {
                    const option = if (inner.originalRange.isEmpty() and self.config.show_empty_decorations) &self.char_delete_empty else &self.char_delete;
                    try original_decorations.append(.{ .range = inner.originalRange, .options = option });
                }
                if (change.modified.contains(inner.modifiedRange.startLineNumber)) {
                    const option = if (inner.modifiedRange.isEmpty() and self.config.show_empty_decorations and !use_inline) &self.char_insert_empty else &self.char_insert;
                    try modified_decorations.append(.{ .range = inner.modifiedRange, .options = option });
                }
                if (use_inline) {
                    try injected.ensureUnusedCapacity(self.allocator, 1);
                    const option = try self.createInjectedOption(inner.originalRange);
                    injected.appendAssumeCapacity(option);
                    try modified_decorations.append(.{ .range = inner.modifiedRange, .options = option });
                }
            }
        }
        if (show_moves) for (state.moved_texts, 0..) |moved, index| {
            if (moved.lineRangeMapping.original.toInclusiveRange()) |range| try original_decorations.append(.{ .range = range, .options = if (active == index) &self.moved_original_active else &self.moved_original });
            if (moved.lineRangeMapping.modified.toInclusiveRange()) |range| try modified_decorations.append(.{ .range = range, .options = if (active == index) &self.moved_modified_active else &self.moved_modified });
        };
        const new_original = try self.applyTo(self.original_model, self.original_owner, self.original_ids, original_decorations.items);
        self.allocator.free(self.original_ids);
        self.original_ids = new_original;
        const new_modified = try self.applyTo(self.modified_model, self.modified_owner, self.modified_ids, modified_decorations.items);
        self.allocator.free(self.modified_ids);
        self.modified_ids = new_modified;
        self.freeInjectedOptions(&self.injected_options);
        self.injected_options = injected;
    }

    fn applyTo(
        self: *DiffEditorDecorations,
        model: *TextModel,
        owner: usize,
        old_ids: []const u64,
        decorations: []const ModelDeltaDecoration,
    ) ![]u64 {
        _ = self;
        return model.deltaDecorations(old_ids, decorations, owner);
    }

    pub fn originalDecorationCount(self: *const DiffEditorDecorations) usize {
        return self.original_ids.len;
    }

    pub fn modifiedDecorationCount(self: *const DiffEditorDecorations) usize {
        return self.modified_ids.len;
    }
};

fn createMovedBlock(class_name: []const u8) ModelDecorationOptions {
    var options = ModelDecorationOptions.init("moved", .AlwaysGrowsWhenTypingAtEdges);
    options.blockClassName = class_name;
    options.blockPadding = .{ 1, 0, 1, 1 };
    return options;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const diff_provider = @import("../../../../common/diff/documentDiffProvider.zig");
const LineDiffProvider = diff_provider.LineDiffProvider;

fn createModels(
    allocator: Allocator,
    original: []const u8,
    modified: []const u8,
) !struct {
    original: TestModel,
    modified: TestModel,
    diff: diff_provider.IDocumentDiff,
    state: DiffState,
} {
    var original_model = try TestModel.init(allocator, original, "plaintext");
    errdefer original_model.deinit();
    var modified_model = try TestModel.init(allocator, modified, "plaintext");
    errdefer modified_model.deinit();

    var provider = LineDiffProvider.init(.advanced);
    var original_lines = try original_model.model.getLinesContent();
    defer {
        for (original_lines.items) |*line| line.deinit();
        original_lines.deinit();
    }
    var modified_lines = try modified_model.model.getLinesContent();
    defer {
        for (modified_lines.items) |*line| line.deinit();
        modified_lines.deinit();
    }
    const original_views = try allocator.alloc([]const u8, original_lines.items.len);
    defer allocator.free(original_views);
    for (original_lines.items, 0..) |line, index| original_views[index] = line.items;
    const modified_views = try allocator.alloc([]const u8, modified_lines.items.len);
    defer allocator.free(modified_views);
    for (modified_lines.items, 0..) |line, index| modified_views[index] = line.items;

    var diff = try provider.computeDiffFromLines(allocator, original_views, modified_views, .{
        .ignoreTrimWhitespace = false,
        .io = std.testing.io,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    errdefer diff_provider.deinitDiff(allocator, &diff);
    var state = try diffEditorState(allocator, diff);
    errdefer state.deinit(allocator);

    return .{
        .original = original_model,
        .modified = modified_model,
        .diff = diff,
        .state = state,
    };
}

fn diffEditorState(allocator: Allocator, diff: diff_provider.IDocumentDiff) !DiffState {
    const mappings = try allocator.alloc(view_model.DiffMapping, diff.changes.len);
    for (diff.changes, 0..) |change, index| {
        const inner = if (change.inner_changes) |values| try allocator.dupe(RangeMapping, values) else null;
        mappings[index] = .{ .line_range_mapping = .{
            .original = change.original,
            .modified = change.modified,
            .inner_changes = inner,
        } };
    }
    const moves = try allocator.alloc(view_model.MovedText, diff.moves.len);
    var initialized_moves: usize = 0;
    errdefer for (moves[0..initialized_moves]) |*moved| moved.deinit(allocator);
    for (diff.moves, 0..) |source, index| {
        const changes = try allocator.alloc(view_model.DetailedLineRangeMapping, source.changes.len);
        for (source.changes, 0..) |change, change_index| {
            const inner = if (change.inner_changes) |values| try allocator.dupe(RangeMapping, values) else null;
            changes[change_index] = .{
                .original = change.original,
                .modified = change.modified,
                .inner_changes = inner,
            };
        }
        moves[index] = .{
            .lineRangeMapping = source.lineRangeMapping,
            .changes = changes,
        };
        initialized_moves = index + 1;
    }
    return .{
        .mappings = mappings,
        .moved_texts = moves,
        .identical = diff.identical,
        .quit_early = diff.quitEarly,
    };
}

test "diffEditorDecorations: real line and char classes without filler model decorations" {
    const allocator = testing.allocator;
    var fixture = try createModels(allocator, "a\nb\nc", "a\nB1\nB2\nc");
    defer {
        fixture.state.deinit(allocator);
        diff_provider.deinitDiff(allocator, &fixture.diff);
        fixture.modified.deinit();
        fixture.original.deinit();
    }

    var decorations = DiffEditorDecorations.init(allocator, fixture.original.model, fixture.modified.model, 100, 101, .{});
    defer decorations.deinit();
    try decorations.update(&fixture.state, false);

    try testing.expect(decorations.originalDecorationCount() > 0);
    try testing.expect(decorations.modifiedDecorationCount() > 0);

    const modified = try fixture.modified.model.getAllDecorations(101, false);
    defer allocator.free(modified);
    var has_line_insert = false;
    var has_char_insert = false;
    for (modified) |decoration| {
        const class_name = decoration.options.className orelse continue;
        if (std.mem.eql(u8, class_name, "line-insert")) has_line_insert = true;
        if (std.mem.eql(u8, class_name, "char-insert")) has_char_insert = true;
    }
    try testing.expect(has_line_insert);
    try testing.expect(has_char_insert);

    const original = try fixture.original.model.getAllDecorations(100, false);
    defer allocator.free(original);
    var has_delete = false;
    for (original) |decoration| {
        const class_name = decoration.options.className orelse continue;
        try testing.expect(!std.mem.eql(u8, class_name, "diff-filler"));
        if (std.mem.eql(u8, class_name, "line-delete")) has_delete = true;
    }
    try testing.expect(has_delete);
}

test "diffEditorDecorations: detach clears both sides" {
    const allocator = testing.allocator;
    var fixture = try createModels(allocator, "a\nb", "a\nB");
    defer {
        fixture.state.deinit(allocator);
        diff_provider.deinitDiff(allocator, &fixture.diff);
        fixture.modified.deinit();
        fixture.original.deinit();
    }

    var decorations = DiffEditorDecorations.init(allocator, fixture.original.model, fixture.modified.model, 200, 201, .{});
    defer decorations.deinit();
    try decorations.update(&fixture.state, false);
    try testing.expect(decorations.modifiedDecorationCount() > 0);

    decorations.detach();
    try testing.expectEqual(@as(usize, 0), decorations.originalDecorationCount());
    try testing.expectEqual(@as(usize, 0), decorations.modifiedDecorationCount());

    const original = try fixture.original.model.getAllDecorations(200, false);
    defer allocator.free(original);
    try testing.expectEqual(@as(usize, 0), original.len);
}

test "diffEditorDecorations: pure insertion and deletion have both whole-line variants" {
    const allocator = testing.allocator;
    for ([_]bool{ true, false }) |insert| {
        var fixture = try createModels(allocator, if (insert) "a\nc" else "a\nb\nc", if (insert) "a\nb\nc" else "a\nc");
        defer {
            fixture.state.deinit(allocator);
            diff_provider.deinitDiff(allocator, &fixture.diff);
            fixture.modified.deinit();
            fixture.original.deinit();
        }
        var decorations = DiffEditorDecorations.init(allocator, fixture.original.model, fixture.modified.model, 200, 201, .{});
        defer decorations.deinit();
        try decorations.update(&fixture.state, false);
        const actual = if (insert) try fixture.modified.model.getAllDecorations(201, false) else try fixture.original.model.getAllDecorations(200, false);
        defer allocator.free(actual);
        try testing.expectEqual(@as(usize, 2), actual.len);
        var line = false;
        var char = false;
        for (actual) |decoration| {
            try testing.expect(decoration.options.isWholeLine orelse false);
            const name = decoration.options.className.?;
            if (std.mem.eql(u8, name, if (insert) "line-insert" else "line-delete")) {
                line = true;
                try testing.expect(decoration.options.linesDecorationsClassName != null);
            }
            if (std.mem.eql(u8, name, if (insert) "char-insert" else "char-delete")) {
                char = true;
                try testing.expect(decoration.options.inlineClassName == null);
            }
        }
        try testing.expect(line and char);
        try testing.expectEqual(@as(usize, 0), if (insert) decorations.originalDecorationCount() else decorations.modifiedDecorationCount());
    }
    try testing.expect(registrations.diffAddDecoration.shouldFillLineOnLineBreak orelse false);
    try testing.expect(registrations.diffDeleteDecoration.shouldFillLineOnLineBreak orelse false);
    try testing.expect(registrations.diffAddDecorationEmpty.showIfCollapsed orelse false);
}
