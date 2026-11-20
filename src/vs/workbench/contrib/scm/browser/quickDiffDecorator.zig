// Port of the decoration subset of
// `src/vs/workbench/contrib/scm/browser/quickDiffDecorator.ts`.
//
// Terminal adaptations:
// - Decorations are applied directly to the `TextModel` with the upstream
//   `dirty-diff-*` class names; there is no editor decorations collection API.
//   The terminal view maps the classes to gutter markers and overview-ruler
//   cells (see `src/tui/editorView.zig`).
// - `minimap` is not represented by the terminal and only contributes to the
//   `scm.diffDecorations=minimap` enablement check (documented in README).
// - A deletion decoration uses the line's max column instead of upstream's
//   `Number.MAX_VALUE`, because ranges are validated integers.
// - The configuration change event is replaced by `setConfig`, called by the
//   terminal `QuickDiffController`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const quick_diff = @import("../common/quickDiff.zig");
const quick_diff_model_mod = @import("./quickDiffModel.zig");
const quick_diff_service_mod = @import("../common/quickDiffService.zig");
const model_mod = @import("../../../../editor/common/model.zig");
const text_model = @import("../../../../editor/common/model/textModel.zig");
const Range = @import("../../../../editor/common/core/range.zig").Range;

pub const ModelDecorationOptions = model_mod.ModelDecorationOptions;
pub const ModelDeltaDecoration = model_mod.ModelDeltaDecoration;
pub const OverviewRulerLane = model_mod.OverviewRulerLane;
pub const TrackedRangeStickiness = model_mod.TrackedRangeStickiness;
pub const TextModel = text_model.TextModel;
pub const QuickDiffModel = quick_diff_model_mod.QuickDiffModel;
pub const QuickDiffService = quick_diff_service_mod.QuickDiffService;
pub const ChangeType = quick_diff.ChangeType;

pub const DecorationsMode = enum {
    none,
    gutter,
    overview,
    minimap,
    all,

    pub fn showsGutter(self: DecorationsMode) bool {
        return self == .all or self == .gutter;
    }

    pub fn showsOverview(self: DecorationsMode) bool {
        return self == .all or self == .overview;
    }

    pub fn showsMinimap(self: DecorationsMode) bool {
        return self == .all or self == .minimap;
    }
};

pub const GutterPattern = struct {
    added: bool = false,
    modified: bool = true,
};

pub const Config = struct {
    decorations: DecorationsMode = .all,
    gutter_pattern: GutterPattern = .{},
    /// `scm.diffDecorationsGutterWidth` (clamped to 1..5 upstream).
    gutter_width: usize = 3,
    gutter_visibility: enum { always, hover } = .always,
};

/// Port of the terminal-visible `QuickDiffDecorator`.
pub const QuickDiffDecorator = struct {
    allocator: Allocator,
    model: *TextModel,
    quick_model: *QuickDiffModel,
    quick_diff_service: *QuickDiffService,
    config: Config,
    owner_id: usize,
    decoration_ids: []u64 = &.{},

    added_options: ModelDecorationOptions,
    added_pattern_options: ModelDecorationOptions,
    added_secondary_options: ModelDecorationOptions,
    added_secondary_pattern_options: ModelDecorationOptions,
    modified_options: ModelDecorationOptions,
    modified_pattern_options: ModelDecorationOptions,
    modified_secondary_options: ModelDecorationOptions,
    modified_secondary_pattern_options: ModelDecorationOptions,
    deleted_options: ModelDecorationOptions,
    deleted_secondary_options: ModelDecorationOptions,

    pub fn init(
        allocator: Allocator,
        model: *TextModel,
        quick_model: *QuickDiffModel,
        quick_diff_service: *QuickDiffService,
        config: Config,
        owner_id: usize,
    ) QuickDiffDecorator {
        var self = QuickDiffDecorator{
            .allocator = allocator,
            .model = model,
            .quick_model = quick_model,
            .quick_diff_service = quick_diff_service,
            .config = config,
            .owner_id = owner_id,
            .added_options = undefined,
            .added_pattern_options = undefined,
            .added_secondary_options = undefined,
            .added_secondary_pattern_options = undefined,
            .modified_options = undefined,
            .modified_pattern_options = undefined,
            .modified_secondary_options = undefined,
            .modified_secondary_pattern_options = undefined,
            .deleted_options = undefined,
            .deleted_secondary_options = undefined,
        };
        self.rebuildOptions();
        return self;
    }

    pub fn deinit(self: *QuickDiffDecorator) void {
        self.detach();
        self.* = undefined;
    }

    /// Removes every decoration owned by this decorator. Used on detach and by
    /// `scm.diffDecorations=none`.
    pub fn detach(self: *QuickDiffDecorator) void {
        const ids = self.model.deltaDecorations(self.decoration_ids, &.{}, self.owner_id) catch {
            self.decoration_ids = &.{};
            return;
        };
        self.allocator.free(ids);
        if (self.decoration_ids.len > 0) self.allocator.free(self.decoration_ids);
        self.decoration_ids = &.{};
    }

    pub fn decorationCount(self: *const QuickDiffDecorator) usize {
        return self.decoration_ids.len;
    }

    pub fn setConfig(self: *QuickDiffDecorator, config: Config) !void {
        // Remove the old decorations before the option structs change: the
        // model assigns each decoration to a tree using the options it saw at
        // insertion time, so rewriting them first would leave stale nodes in
        // the overview-ruler tree.
        self.detach();
        self.config = config;
        self.rebuildOptions();
        try self.update();
    }

    fn rebuildOptions(self: *QuickDiffDecorator) void {
        const gutter = self.config.decorations.showsGutter();
        const overview = self.config.decorations.showsOverview();
        self.added_options = createDecoration(
            "dirty-diff-added primary",
            "Added lines",
            gutter,
            overview,
            quick_diff.overview_added_foreground,
            true,
        );
        self.added_pattern_options = createDecoration(
            "dirty-diff-added primary pattern",
            "Added lines",
            gutter,
            overview,
            quick_diff.overview_added_foreground,
            true,
        );
        self.added_secondary_options = createDecoration(
            "dirty-diff-added secondary",
            "Added lines",
            gutter,
            overview,
            quick_diff.overview_added_foreground,
            true,
        );
        self.added_secondary_pattern_options = createDecoration(
            "dirty-diff-added secondary pattern",
            "Added lines",
            gutter,
            overview,
            quick_diff.overview_added_foreground,
            true,
        );
        self.modified_options = createDecoration(
            "dirty-diff-modified primary",
            "Changed lines",
            gutter,
            overview,
            quick_diff.overview_modified_foreground,
            true,
        );
        self.modified_pattern_options = createDecoration(
            "dirty-diff-modified primary pattern",
            "Changed lines",
            gutter,
            overview,
            quick_diff.overview_modified_foreground,
            true,
        );
        self.modified_secondary_options = createDecoration(
            "dirty-diff-modified secondary",
            "Changed lines",
            gutter,
            overview,
            quick_diff.overview_modified_foreground,
            true,
        );
        self.modified_secondary_pattern_options = createDecoration(
            "dirty-diff-modified secondary pattern",
            "Changed lines",
            gutter,
            overview,
            quick_diff.overview_modified_foreground,
            true,
        );
        self.deleted_options = createDecoration(
            "dirty-diff-deleted primary",
            "Removed lines",
            gutter,
            overview,
            quick_diff.overview_deleted_foreground,
            false,
        );
        self.deleted_secondary_options = createDecoration(
            "dirty-diff-deleted secondary",
            "Removed lines",
            gutter,
            overview,
            quick_diff.overview_deleted_foreground,
            false,
        );
    }

    /// Port of `QuickDiffDecorator.onDidChange`: apply the visible changes as
    /// model decorations, keeping the decoration ids for the next update.
    pub fn update(self: *QuickDiffDecorator) !void {
        if (self.config.decorations == .none) {
            self.detach();
            return;
        }

        var decorations = std.array_list.Managed(ModelDeltaDecoration).init(self.allocator);
        defer decorations.deinit();

        const primary_id = for (self.quick_model.quickDiffs()) |quick| {
            if (quick.kind == .primary) break quick.id;
        } else null;

        for (self.quick_model.changes.items) |change| {
            const quick = findQuickDiff(self.quick_model.quickDiffs(), change.provider_id) orelse continue;
            if (!self.quick_diff_service.isQuickDiffProviderVisible(quick.id)) continue;

            // Only the primary/contributed quick diff paints a change that a
            // secondary one duplicates; `quick_model.changes` already dropped
            // the suppressed secondary changes, this mirrors the upstream guard
            // for changes that share a modified range.
            if (primary_id != null and quick.kind != .primary and
                secondaryOverlapsPrimary(self.quick_model.changes.items, primary_id.?, change))
            {
                continue;
            }

            const change_type = quick_diff.getChangeType(change.change);
            const start_line = change.change.modifiedStartLineNumber;
            const end_line = if (change.change.modifiedEndLineNumber == 0)
                start_line
            else
                change.change.modifiedEndLineNumber;
            const primary = quick.kind == .primary or quick.kind == .contributed;

            switch (change_type) {
                .add => try decorations.append(.{
                    .range = Range.init(start_line, 1, end_line, 1),
                    .options = if (primary)
                        (if (self.config.gutter_pattern.added) &self.added_pattern_options else &self.added_options)
                    else
                        (if (self.config.gutter_pattern.added) &self.added_secondary_pattern_options else &self.added_secondary_options),
                }),
                .delete => {
                    const line = @max(start_line, 1);
                    const column = self.model.getLineMaxColumn(line);
                    try decorations.append(.{
                        .range = Range.init(line, column, line, column),
                        .options = if (primary) &self.deleted_options else &self.deleted_secondary_options,
                    });
                },
                .modify => try decorations.append(.{
                    .range = Range.init(start_line, 1, end_line, 1),
                    .options = if (primary)
                        (if (self.config.gutter_pattern.modified) &self.modified_pattern_options else &self.modified_options)
                    else
                        (if (self.config.gutter_pattern.modified) &self.modified_secondary_pattern_options else &self.modified_secondary_options),
                }),
            }
        }

        const new_ids = try self.model.deltaDecorations(self.decoration_ids, decorations.items, self.owner_id);
        if (self.decoration_ids.len > 0) self.allocator.free(self.decoration_ids);
        self.decoration_ids = new_ids;
    }

    pub fn gutterWidth(self: *const QuickDiffDecorator) usize {
        // Upstream clamps `scm.diffDecorationsGutterWidth` to 1..5 and the
        // terminal maps it to a single marker cell.
        if (self.config.decorations == .none) return 0;
        return 1;
    }
};

fn findQuickDiff(quick_diffs: []const quick_diff.QuickDiff, provider_id: []const u8) ?quick_diff.QuickDiff {
    for (quick_diffs) |quick| {
        if (std.mem.eql(u8, quick.id, provider_id)) return quick;
    }
    return null;
}

fn secondaryOverlapsPrimary(
    changes: []const quick_diff_model_mod.QuickDiffChange,
    primary_id: []const u8,
    change: quick_diff_model_mod.QuickDiffChange,
) bool {
    for (changes) |candidate| {
        if (!std.mem.eql(u8, candidate.provider_id, primary_id)) continue;
        if (candidate.change2.modified.intersectsOrTouches(change.change2.modified)) return true;
    }
    return false;
}

fn createDecoration(
    class_name: []const u8,
    tooltip: []const u8,
    gutter: bool,
    overview: bool,
    overview_color: [3]u8,
    is_whole_line: bool,
) ModelDecorationOptions {
    var options = ModelDecorationOptions.init("dirty-diff-decoration", .AlwaysGrowsWhenTypingAtEdges);
    options.className = class_name;
    options.isWholeLine = is_whole_line;
    if (gutter) {
        options.linesDecorationsClassName = class_name;
        options.linesDecorationsTooltip = tooltip;
    }
    if (overview) {
        options.overviewRuler = .{
            .position = .Left,
            .color = overview_color,
        };
    }
    return options;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_support = @import("../../../../editor/test/common/port/testSupport.zig");
const TestModel = test_support.TestModel;
const Lifecycle = @import("../../../../base/common/lifecycle.zig");
const IDisposable = Lifecycle.IDisposable;

const TestProvider = struct {
    allocator: Allocator,
    base: quick_diff.QuickDiffProvider,
    content: ?[]u8,

    fn init(self: *TestProvider, allocator: Allocator, id: []const u8, kind: quick_diff.QuickDiffProviderKind, content: ?[]const u8) !void {
        self.allocator = allocator;
        self.content = if (content) |value| try allocator.dupe(u8, value) else null;
        self.base = .{
            .context = self,
            .id = id,
            .label = id,
            .kind = kind,
            .get_original_fn = getOriginal,
        };
    }

    fn deinit(self: *TestProvider) void {
        if (self.content) |content| self.allocator.free(content);
    }

    fn getOriginal(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?quick_diff.Original {
        _ = path;
        const self: *TestProvider = @ptrCast(@alignCast(context));
        const content = self.content orelse return null;
        return .{
            .content = try allocator.dupe(u8, content),
            .ref_label = try allocator.dupe(u8, "HEAD"),
        };
    }
};

const Harness = struct {
    allocator: Allocator,
    service: quick_diff_service_mod.QuickDiffService,
    model: TestModel,
    quick_model: QuickDiffModel,
    decorator: QuickDiffDecorator,
    provider: TestProvider,
    disposable: IDisposable,

    fn init(self: *Harness, text: []const u8, original: []const u8) !void {
        self.allocator = testing.allocator;
        self.service = quick_diff_service_mod.QuickDiffService.init(self.allocator, null);
        self.model = try TestModel.init(self.allocator, text, "zig");
        self.quick_model = QuickDiffModel.init(self.allocator, self.model.model, "/repo/file.zig", &self.service, .{});
        try self.provider.init(self.allocator, "git.primary", .primary, original);
        self.disposable = try self.service.addQuickDiffProvider(&self.provider.base);
        try self.quick_model.recompute();
        self.decorator = QuickDiffDecorator.init(
            self.allocator,
            self.model.model,
            &self.quick_model,
            &self.service,
            .{},
            42,
        );
        try self.decorator.update();
    }

    fn deinit(self: *Harness) void {
        self.decorator.deinit();
        self.disposable.dispose();
        self.provider.deinit();
        self.quick_model.deinit();
        self.model.deinit();
        self.service.deinit();
    }

    fn decorations(self: *Harness) ![]model_mod.ModelDecoration {
        return self.model.model.getAllDecorations(42, false);
    }
};

test "quickDiffDecorator: add/modify/delete classes and overview colors" {
    var harness: Harness = undefined;
    try harness.init("a\nB\nc\nd", "a\nb\nc\nd\ne");
    defer harness.deinit();

    const decorations = try harness.decorations();
    defer testing.allocator.free(decorations);
    try testing.expectEqual(@as(usize, 2), decorations.len);

    var found_modify = false;
    var found_delete = false;
    for (decorations) |decoration| {
        if (std.mem.indexOf(u8, decoration.options.className.?, "dirty-diff-modified primary")) |_| {
            found_modify = true;
            try testing.expect(decoration.options.isWholeLine.?);
            try testing.expect(decoration.options.overviewRuler != null);
            try testing.expectEqual(quick_diff.overview_modified_foreground, decoration.options.overviewRuler.?.color.?);
            try testing.expect(decoration.options.linesDecorationsClassName != null);
        }
        if (std.mem.indexOf(u8, decoration.options.className.?, "dirty-diff-deleted primary")) |_| {
            found_delete = true;
            try testing.expect(!decoration.options.isWholeLine.?);
        }
    }
    try testing.expect(found_modify);
    try testing.expect(found_delete);
}

test "quickDiffDecorator: configuration toggles and detach cleanup" {
    var harness: Harness = undefined;
    try harness.init("a\nB", "a\nb");
    defer harness.deinit();

    // Gutter-only mode keeps the line decoration class but no overview entry.
    try harness.decorator.setConfig(.{ .decorations = .gutter });
    var decorations = try harness.decorations();
    defer testing.allocator.free(decorations);
    try testing.expectEqual(@as(usize, 1), decorations.len);
    try testing.expect(decorations[0].options.overviewRuler == null);
    try testing.expect(decorations[0].options.linesDecorationsClassName != null);

    // Overview-only mode has an overview entry and no gutter marker.
    try harness.decorator.setConfig(.{ .decorations = .overview });
    testing.allocator.free(decorations);
    decorations = try harness.decorations();
    try testing.expectEqual(@as(usize, 1), decorations.len);
    try testing.expect(decorations[0].options.overviewRuler != null);
    try testing.expect(decorations[0].options.linesDecorationsClassName == null);

    // `none` detaches every decoration.
    try harness.decorator.setConfig(.{ .decorations = .none });
    const empty = try harness.decorations();
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    try testing.expectEqual(@as(usize, 0), harness.decorator.gutterWidth());
}

test "quickDiffDecorator: gutter pattern variants and invisible providers" {
    var harness: Harness = undefined;
    try harness.init("a\nB", "a\nb");
    defer harness.deinit();

    try harness.decorator.setConfig(.{ .decorations = .all, .gutter_pattern = .{ .added = true, .modified = true } });
    const decorations = try harness.decorations();
    defer testing.allocator.free(decorations);
    try testing.expectEqual(@as(usize, 1), decorations.len);
    try testing.expect(std.mem.indexOf(u8, decorations[0].options.className.?, "pattern") != null);

    harness.service.toggleQuickDiffProviderVisibility("git.primary");
    try harness.decorator.update();
    const hidden = try harness.decorations();
    defer testing.allocator.free(hidden);
    try testing.expectEqual(@as(usize, 0), hidden.len);
}
