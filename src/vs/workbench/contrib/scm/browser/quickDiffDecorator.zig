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
// - Model debounce and worker replies are dispatched on the terminal UI thread.
const std = @import("std");
const Allocator = std.mem.Allocator;
const time = @import("../../../../base/common/timeCompat.zig");
const EditorWorkerService = @import("../../../../editor/browser/services/editorWorkerService.zig").EditorWorkerService;
const ResourceEvent = @import("../../../../base/common/event.zig").Emitter(void);
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const EditorService = @import("../../../services/editor/browser/editorService.zig").EditorService;
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;

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
        return @intFromBool(self.config.decorations.showsGutter());
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

/// Owner id for quick-diff model decorations. The editor view uses 1..5 for
/// find/bracket/word/hover/search, so 6 is free.
pub const decoration_owner: usize = 6;

pub const Entry = struct {
    editor: *Editor,
    path: []u8,
    model: QuickDiffModel,
    decorator: QuickDiffDecorator,
    content_listener: usize = undefined,
    provider_listener: usize = undefined,
    diff_listener: usize = undefined,
    resource_listener: ?usize = null,

    fn onDiffChanged(_: void, self: *Entry) !void {
        try self.decorator.update();
    }

    fn onContent(_: @import("../../../../editor/common/textModelEvents.zig").InternalModelContentChangeEvent, self: *Entry) !void {
        self.model.triggerDiff(time.milliTimestamp());
    }

    fn onResources(_: void, self: *Entry) !void {
        self.model.triggerDiff(time.milliTimestamp());
    }
};

pub const QuickDiffWorkbenchController = struct {
    allocator: Allocator,
    service: *QuickDiffService,
    worker: EditorWorkerService,
    entries: std.array_list.Managed(*Entry),
    resources_changed: ?*ResourceEvent = null,
    config: Config = .{},
    ignore_trim_whitespace: bool = false,
    editors: ?EditorService = null,
    visible_listener: ?usize = null,
    configuration_service: ?*ConfigurationService = null,
    configuration_listener: ?usize = null,

    pub fn init(allocator: Allocator, service: *QuickDiffService) QuickDiffWorkbenchController {
        return .{
            .allocator = allocator,
            .service = service,
            .worker = EditorWorkerService.init(),
            .entries = std.array_list.Managed(*Entry).init(allocator),
        };
    }

    pub fn deinit(self: *QuickDiffWorkbenchController) void {
        self.detachConfiguration();
        if (self.visible_listener) |id| self.editors.?.onDidVisibleEditorsChange().unlisten(id);
        for (self.entries.items) |entry| self.destroyEntry(entry);
        self.entries.deinit();
        self.worker.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const QuickDiffWorkbenchController) usize {
        return self.entries.items.len;
    }

    pub fn contains(self: *const QuickDiffWorkbenchController, editor: *Editor) bool {
        for (self.entries.items) |entry| {
            if (entry.editor == editor) return true;
        }
        return false;
    }

    /// Attaches quick diff to a file editor. Diff snapshot editors are skipped
    /// by the workbench (they are read-only and never passed here).
    pub fn attach(self: *QuickDiffWorkbenchController, editor: *Editor, path: []const u8) !void {
        if (self.config.decorations == .none) return;
        if (self.contains(editor)) return;
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        entry.* = .{
            .editor = editor,
            .path = path_copy,
            .model = QuickDiffModel.init(
                self.allocator,
                editor.model,
                path_copy,
                self.service,
                .{ .algorithm = .advanced, .max_computation_time_ms = 1000 },
            ),
            .decorator = undefined,
        };
        errdefer entry.model.deinit();
        entry.model.setIgnoreTrimWhitespace(self.ignore_trim_whitespace);
        entry.model.triggerDiff(time.milliTimestamp());
        entry.content_listener = try editor.model.onDidChangeContentWithContextId(entry, Entry.onContent);
        errdefer editor.model.removeDidChangeContentListener(entry.content_listener);
        entry.provider_listener = try self.service.on_did_change_providers.listen(entry, Entry.onResources);
        errdefer self.service.on_did_change_providers.unlisten(entry.provider_listener);
        if (self.resources_changed) |source| entry.resource_listener = try source.listen(entry, Entry.onResources);
        errdefer if (entry.resource_listener) |id| self.resources_changed.?.unlisten(id);
        entry.decorator = QuickDiffDecorator.init(
            self.allocator,
            editor.model,
            &entry.model,
            self.service,
            self.config,
            decoration_owner,
        );
        errdefer entry.decorator.deinit();
        entry.diff_listener = try entry.model.on_did_change.listen(entry, Entry.onDiffChanged);
        errdefer entry.model.on_did_change.unlisten(entry.diff_listener);
        try entry.decorator.update();

        try self.entries.append(entry);
        self.applyEditorState(entry);
    }

    pub fn detach(self: *QuickDiffWorkbenchController, editor: *Editor) void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.editor != editor) continue;
            _ = self.entries.orderedRemove(index);
            self.destroyEntry(entry);
            if (self.entries.items.len == 0) self.worker.stopWorker();
            return;
        }
    }

    pub fn poll(self: *QuickDiffWorkbenchController, now_ms: i64) bool {
        var changed = self.worker.dispatchReplies();
        for (self.entries.items) |entry| {
            if (entry.model.runScheduledDiff(&self.worker, now_ms)) changed = true;
        }
        self.worker.checkStopIdleWorker(now_ms);
        return changed;
    }

    pub fn start(self: *QuickDiffWorkbenchController, editors: EditorService, config: ?*ConfigurationService) !void {
        self.editors = editors;
        if (config != null) try self.setConfiguration(config) else try self.setConfig(.{});
    }

    fn onEditorsChanged(_: void, self: *QuickDiffWorkbenchController) !void {
        const editors = self.editors orelse return;
        // Drop stale pointers even if creating a decorator for a new editor fails.
        defer self.removeHiddenDecorators(editors);
        var visible = editors.visibleEditorPanes();
        while (visible.next()) |pane| {
            if (pane.file_input != null) try self.attach(pane.editor, pane.editor.path);
        }
    }

    fn removeHiddenDecorators(self: *QuickDiffWorkbenchController, editors: EditorService) void {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const editor = self.entries.items[i].editor;
            var visible = editors.visibleEditorPanes();
            while (visible.next()) |pane| {
                if (pane.file_input != null and pane.editor == editor) break;
            } else {
                self.detach(editor);
            }
        }
    }

    pub fn detachConfiguration(self: *QuickDiffWorkbenchController) void {
        if (self.configuration_listener) |id| self.configuration_service.?.unlistenConfigurationChange(id);
        self.configuration_listener = null;
        self.configuration_service = null;
    }

    pub fn setConfiguration(self: *QuickDiffWorkbenchController, service: ?*ConfigurationService) !void {
        self.detachConfiguration();
        self.configuration_service = service;
        if (service) |config| {
            self.configuration_listener = try config.listenConfigurationChange(self, onDidChangeConfiguration);
            try self.applyDecorationSettings(config);
            self.setIgnoreTrimWhitespace(quick_diff_model_mod.ignoreTrimWhitespace(config));
        }
    }

    fn onDidChangeConfiguration(change: configuration.Change, self: *QuickDiffWorkbenchController) !void {
        const config = self.configuration_service.?;
        if (configuration.affectsConfiguration(change, "scm.diffDecorations") or
            configuration.affectsConfiguration(change, "scm.diffDecorationsGutterPattern"))
            try self.applyDecorationSettings(config);
        if (configuration.affectsConfiguration(change, "scm.diffDecorationsIgnoreTrimWhitespace") or
            configuration.affectsConfiguration(change, "diffEditor.ignoreTrimWhitespace"))
            self.setIgnoreTrimWhitespace(quick_diff_model_mod.ignoreTrimWhitespace(config));
    }

    fn applyDecorationSettings(self: *QuickDiffWorkbenchController, service: *ConfigurationService) !void {
        var config = Config{};
        if (service.getValue("scm.diffDecorations", .{})) |v| {
            if (v.* == .string) config.decorations = std.meta.stringToEnum(DecorationsMode, v.string) orelse .all;
        }
        config.gutter_pattern.added = service.getBool("scm.diffDecorationsGutterPattern.added", false);
        config.gutter_pattern.modified = service.getBool("scm.diffDecorationsGutterPattern.modified", true);
        try self.setConfig(config);
    }

    pub fn setConfig(self: *QuickDiffWorkbenchController, config: Config) !void {
        self.config = config;
        if (config.decorations == .none) {
            if (self.visible_listener) |id| self.editors.?.onDidVisibleEditorsChange().unlisten(id);
            self.visible_listener = null;
            while (self.entries.getLastOrNull()) |entry| self.detach(entry.editor);
            return;
        }
        for (self.entries.items) |entry| {
            try entry.decorator.setConfig(config);
            self.applyEditorState(entry);
        }
        if (self.editors) |editors| {
            if (self.visible_listener == null) self.visible_listener = try editors.onDidVisibleEditorsChange().listen(self, onEditorsChanged);
            try onEditorsChanged({}, self);
        }
    }

    pub fn setIgnoreTrimWhitespace(self: *QuickDiffWorkbenchController, ignore: bool) void {
        if (self.ignore_trim_whitespace == ignore) return;
        self.ignore_trim_whitespace = ignore;
        for (self.entries.items) |entry| {
            entry.model.setIgnoreTrimWhitespace(ignore);
            entry.model.triggerDiff(time.milliTimestamp());
        }
    }

    fn applyEditorState(self: *QuickDiffWorkbenchController, entry: *Entry) void {
        _ = self;
        const width: usize = if (entry.decorator.gutterWidth() > 0) 1 else 0;
        entry.editor.setLineDecorationsWidth(width);
    }

    fn destroyEntry(self: *QuickDiffWorkbenchController, entry: *Entry) void {
        entry.editor.model.removeDidChangeContentListener(entry.content_listener);
        self.service.on_did_change_providers.unlisten(entry.provider_listener);
        if (entry.resource_listener) |id| self.resources_changed.?.unlisten(id);
        entry.model.on_did_change.unlisten(entry.diff_listener);
        entry.decorator.deinit();
        entry.model.deinit();
        entry.editor.setLineDecorationsWidth(0);
        self.allocator.free(entry.path);
        self.allocator.destroy(entry);
    }
};

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
