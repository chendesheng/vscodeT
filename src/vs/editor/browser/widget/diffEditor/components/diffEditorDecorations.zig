// Port of the decoration subset of
// `src/vs/editor/browser/widget/diffEditor/components/diffEditorDecorations.ts`.
//
// Terminal adaptations:
// - Decorations are applied to the two aligned snapshot models. Whole-line
//   `line-insert`/`line-delete` classes paint row backgrounds in
//   `src/tui/editorView.zig`; `diff-filler` marks the padded rows.
// - Character decorations set both `className` and `inlineClassName` (the same
//   pattern the find/word decorations use) so the inline ranges flow through
//   `ViewLine` and `decorationBits`.
// - Moved-block lines, the true-inline deleted-text injection and the gutter
//   indicator glyphs are outside the read-only terminal scope. The overview
//   ruler entries are per-side model decorations, which the existing editor
//   scrollbar renders.
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_zones = @import("./diffEditorViewZones.zig");
const view_model = @import("../diffEditorViewModel.zig");
const model_mod = @import("../../../../common/model.zig");
const text_model = @import("../../../../common/model/textModel.zig");
const range_mapping = @import("../../../../common/diff/rangeMapping.zig");
const Range = @import("../../../../common/core/range.zig").Range;
const overview_feature = @import("../features/overviewRulerFeature.zig");

pub const ModelDecorationOptions = model_mod.ModelDecorationOptions;
pub const ModelDeltaDecoration = model_mod.ModelDeltaDecoration;
pub const OverviewRulerLane = model_mod.OverviewRulerLane;
pub const TextModel = text_model.TextModel;
pub const AlignedRows = view_zones.AlignedRows;
pub const DiffState = view_model.DiffState;
pub const RangeMapping = range_mapping.RangeMapping;

pub const Config = struct {
    render_indicators: bool = true,
    render_overview_ruler: bool = true,
    show_empty_decorations: bool = false,
};

/// Terminal defaults for `diffEditor.insertedLineBackground`/
/// `removedLineBackground`/`insertedTextBackground`/`removedTextBackground`
/// composited over the dark editor background (cells have no alpha).
pub const inserted_line_background = [3]u8{ 55, 61, 41 };
pub const removed_line_background = [3]u8{ 75, 24, 24 };
pub const inserted_text_background = [3]u8{ 74, 84, 45 };
pub const removed_text_background = [3]u8{ 92, 30, 30 };
pub const filler_background = [3]u8{ 40, 42, 44 };

pub const DiffEditorDecorations = struct {
    allocator: Allocator,
    original_model: *TextModel,
    modified_model: *TextModel,
    original_owner: usize,
    modified_owner: usize,
    config: Config,
    original_ids: []u64 = &.{},
    modified_ids: []u64 = &.{},

    line_insert: ModelDecorationOptions,
    line_delete: ModelDecorationOptions,
    filler: ModelDecorationOptions,
    char_insert: ModelDecorationOptions,
    char_delete: ModelDecorationOptions,
    char_insert_empty: ModelDecorationOptions,
    char_delete_empty: ModelDecorationOptions,
    moved_original: ModelDecorationOptions,
    moved_modified: ModelDecorationOptions,

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
            .filler = undefined,
            .char_insert = undefined,
            .char_delete = undefined,
            .char_insert_empty = undefined,
            .char_delete_empty = undefined,
            .moved_original = undefined,
            .moved_modified = undefined,
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
    }

    pub fn setConfig(self: *DiffEditorDecorations, config: Config, aligned: *const AlignedRows, state: *const DiffState) !void {
        // Remove before rewriting the option values: the model buckets
        // decorations by the options it saw at insertion time.
        self.detach();
        self.config = config;
        self.buildOptions();
        try self.update(aligned, state);
    }

    fn buildOptions(self: *DiffEditorDecorations) void {
        self.line_insert = createWholeLine("line-insert", overview_feature.inserted_foreground, self.config.render_overview_ruler);
        self.line_delete = createWholeLine("line-delete", overview_feature.removed_foreground, self.config.render_overview_ruler);
        self.line_insert.marginClassName = "gutter-insert";
        self.line_delete.marginClassName = "gutter-delete";
        if (self.config.render_indicators) {
            self.line_insert.linesDecorationsClassName = "insert-sign codicon codicon-diff-insert";
            self.line_delete.linesDecorationsClassName = "delete-sign codicon codicon-diff-remove";
        }
        self.filler = createWholeLine("diff-filler", filler_background, false);
        self.char_insert = createRange("char-insert");
        self.char_delete = createRange("char-delete");
        self.char_insert_empty = createRange("char-insert diff-range-empty");
        self.char_delete_empty = createRange("char-delete diff-range-empty");
        self.moved_original = createMovedBlock("movedOriginal");
        self.moved_modified = createMovedBlock("movedModified");
    }

    /// Rebuilds both decoration sets from the aligned rows and the diff state.
    pub fn update(self: *DiffEditorDecorations, aligned: *const AlignedRows, state: *const DiffState) !void {
        var original_decorations = std.array_list.Managed(ModelDeltaDecoration).init(self.allocator);
        defer original_decorations.deinit();
        var modified_decorations = std.array_list.Managed(ModelDeltaDecoration).init(self.allocator);
        defer modified_decorations.deinit();

        for (aligned.mappings) |mapping| {
            try appendSideDecorations(
                &original_decorations,
                aligned.original,
                mapping.original,
                false,
                &self.line_delete,
                &self.filler,
                &self.char_delete,
                &self.char_delete_empty,
                aligned,
                mapping.source,
                self.config.show_empty_decorations,
            );
            try appendSideDecorations(
                &modified_decorations,
                aligned.modified,
                mapping.modified,
                true,
                &self.line_insert,
                &self.filler,
                &self.char_insert,
                &self.char_insert_empty,
                aligned,
                mapping.source,
                self.config.show_empty_decorations,
            );
        }

        for (state.moved_texts) |moved| {
            const original_start = moved.lineRangeMapping.original.startLineNumber;
            const original_end = moved.lineRangeMapping.original.endLineNumberExclusive;
            if (original_end > original_start) {
                const first = aligned.displayRowForOriginal(original_start) orelse continue;
                const last = aligned.displayRowForOriginal(original_end - 1) orelse continue;
                try original_decorations.append(.{
                    .range = Range.init(first, 1, last, 1),
                    .options = &self.moved_original,
                });
            }
            const modified_start = moved.lineRangeMapping.modified.startLineNumber;
            const modified_end = moved.lineRangeMapping.modified.endLineNumberExclusive;
            if (modified_end > modified_start) {
                const first = aligned.displayRowForModified(modified_start) orelse continue;
                const last = aligned.displayRowForModified(modified_end - 1) orelse continue;
                try modified_decorations.append(.{
                    .range = Range.init(first, 1, last, 1),
                    .options = &self.moved_modified,
                });
            }
        }

        const new_original = try self.applyTo(self.original_model, self.original_owner, self.original_ids, original_decorations.items);
        if (self.original_ids.len > 0) self.allocator.free(self.original_ids);
        self.original_ids = new_original;

        const new_modified = try self.applyTo(self.modified_model, self.modified_owner, self.modified_ids, modified_decorations.items);
        if (self.modified_ids.len > 0) self.allocator.free(self.modified_ids);
        self.modified_ids = new_modified;
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

fn appendSideDecorations(
    decorations: *std.array_list.Managed(ModelDeltaDecoration),
    display_rows: []const ?usize,
    display_range: @import("../../../../common/core/ranges/lineRange.zig").LineRange,
    is_modified: bool,
    line_option: *const ModelDecorationOptions,
    filler_option: *const ModelDecorationOptions,
    char_option: *const ModelDecorationOptions,
    empty_option: *const ModelDecorationOptions,
    aligned: *const AlignedRows,
    source: view_model.DetailedLineRangeMapping,
    show_empty: bool,
) !void {
    var row = display_range.startLineNumber;
    const end = display_range.endLineNumberExclusive;
    // One decoration per contiguous range, not per padded line. Real
    // changes and filler rows have disjoint ranges so margin indicators do
    // not appear on the blank alignment rows.
    while (row < end and row <= display_rows.len) {
        const first = row;
        const filler = display_rows[row - 1] == null;
        row += 1;
        while (row < end and row <= display_rows.len and (display_rows[row - 1] == null) == filler) : (row += 1) {}
        try decorations.append(.{
            .range = Range.init(first, 1, row - 1, 1),
            .options = @constCast(if (filler) filler_option else line_option),
        });
    }

    // Inner character ranges, mapped from real line numbers to display rows.
    const real_range = if (is_modified) source.modified else source.original;
    if (real_range.isEmpty()) return;
    const inner = source.inner_changes orelse return;
    for (inner) |entry| {
        const range = if (is_modified) entry.modifiedRange else entry.originalRange;
        const row_start = if (is_modified)
            aligned.displayRowForModified(range.startLineNumber)
        else
            aligned.displayRowForOriginal(range.startLineNumber);
        const row_end = if (is_modified)
            aligned.displayRowForModified(range.endLineNumber)
        else
            aligned.displayRowForOriginal(range.endLineNumber);
        const start_row = row_start orelse continue;
        const end_row = row_end orelse start_row;
        // Keep the range ordered: the model validator does not swap a reversed
        // range, and a reversed range corrupts the decoration interval tree.
        if (end_row < start_row) continue;
        if (end_row == start_row and range.endColumn < range.startColumn) continue;
        const option = if (range.isEmpty() and show_empty) empty_option else char_option;
        try decorations.append(.{
            .range = Range.init(start_row, range.startColumn, end_row, range.endColumn),
            .options = @constCast(option),
        });
    }
}

fn createMovedBlock(class_name: []const u8) ModelDecorationOptions {
    var options = ModelDecorationOptions.init("moved", .AlwaysGrowsWhenTypingAtEdges);
    options.blockClassName = class_name;
    options.blockPadding = .{ 1, 0, 1, 1 };
    return options;
}

fn createWholeLine(class_name: []const u8, color: [3]u8, overview: bool) ModelDecorationOptions {
    var options = ModelDecorationOptions.init(class_name, .AlwaysGrowsWhenTypingAtEdges);
    options.className = class_name;
    options.isWholeLine = true;
    if (overview) {
        options.overviewRuler = .{ .position = .Left, .color = color };
    }
    return options;
}

fn createRange(class_name: []const u8) ModelDecorationOptions {
    var options = ModelDecorationOptions.init(class_name, .AlwaysGrowsWhenTypingAtEdges);
    options.className = class_name;
    options.inlineClassName = class_name;
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
    rows: AlignedRows,
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
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    errdefer diff_provider.deinitDiff(allocator, &diff);
    const rows = try view_zones.computeAlignedRows(allocator, original_views.len, modified_views.len, diff.changes);
    errdefer {
        var mutable = rows;
        mutable.deinit();
    }

    var state = try diffEditorState(allocator, diff);
    errdefer state.deinit(allocator);

    return .{
        .original = original_model,
        .modified = modified_model,
        .diff = diff,
        .rows = rows,
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

test "diffEditorDecorations: line, filler and char classes" {
    const allocator = testing.allocator;
    var fixture = try createModels(allocator, "a\nb\nc", "a\nB1\nB2\nc");
    defer {
        fixture.state.deinit(allocator);
        fixture.rows.deinit();
        diff_provider.deinitDiff(allocator, &fixture.diff);
        fixture.modified.deinit();
        fixture.original.deinit();
    }

    var decorations = DiffEditorDecorations.init(allocator, fixture.original.model, fixture.modified.model, 100, 101, .{});
    defer decorations.deinit();
    try decorations.update(&fixture.rows, &fixture.state);

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
    var has_filler = false;
    for (original) |decoration| {
        const class_name = decoration.options.className orelse continue;
        if (std.mem.eql(u8, class_name, "diff-filler")) has_filler = true;
    }
    try testing.expect(has_filler);
}

test "diffEditorDecorations: detach clears both sides" {
    const allocator = testing.allocator;
    var fixture = try createModels(allocator, "a\nb", "a\nB");
    defer {
        fixture.state.deinit(allocator);
        fixture.rows.deinit();
        diff_provider.deinitDiff(allocator, &fixture.diff);
        fixture.modified.deinit();
        fixture.original.deinit();
    }

    var decorations = DiffEditorDecorations.init(allocator, fixture.original.model, fixture.modified.model, 200, 201, .{});
    defer decorations.deinit();
    try decorations.update(&fixture.rows, &fixture.state);
    try testing.expect(decorations.modifiedDecorationCount() > 0);

    decorations.detach();
    try testing.expectEqual(@as(usize, 0), decorations.originalDecorationCount());
    try testing.expectEqual(@as(usize, 0), decorations.modifiedDecorationCount());

    const original = try fixture.original.model.getAllDecorations(200, false);
    defer allocator.free(original);
    try testing.expectEqual(@as(usize, 0), original.len);
}
