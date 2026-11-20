// Terminal quick-diff controller: attaches a `QuickDiffModel` and a
// `QuickDiffDecorator` to each open file editor, polls the model's 200 ms
// debounce from the workbench main loop, and applies the quick-diff gutter
// width to the editor.
//
// There is no observable/autorun system in the port; the workbench calls
// `poll`/`refreshAll` from `Workbench.pollGit` and on git status changes.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Editor = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const quick_diff_service = @import("../vs/workbench/contrib/scm/common/quickDiffService.zig");
const quick_diff_model_mod = @import("../vs/workbench/contrib/scm/browser/quickDiffModel.zig");
const quick_diff_decorator_mod = @import("../vs/workbench/contrib/scm/browser/quickDiffDecorator.zig");

pub const QuickDiffService = quick_diff_service.QuickDiffService;
pub const QuickDiffModel = quick_diff_model_mod.QuickDiffModel;
pub const QuickDiffDecorator = quick_diff_decorator_mod.QuickDiffDecorator;
pub const Config = quick_diff_decorator_mod.Config;
pub const DecorationsMode = quick_diff_decorator_mod.DecorationsMode;

/// Owner id for quick-diff model decorations. The editor view uses 1..5 for
/// find/bracket/word/hover/search, so 6 is free.
pub const decoration_owner: usize = 6;

pub const Entry = struct {
    editor: *Editor,
    path: []u8,
    model: QuickDiffModel,
    decorator: QuickDiffDecorator,
    last_version: u32,
};

pub const Controller = struct {
    allocator: Allocator,
    service: *QuickDiffService,
    entries: std.array_list.Managed(*Entry),
    config: Config = .{},
    ignore_trim_whitespace: bool = true,
    enabled: bool = true,

    pub fn init(allocator: Allocator, service: *QuickDiffService) Controller {
        return .{
            .allocator = allocator,
            .service = service,
            .entries = std.array_list.Managed(*Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Controller) void {
        for (self.entries.items) |entry| self.destroyEntry(entry);
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Controller) usize {
        return self.entries.items.len;
    }

    pub fn contains(self: *const Controller, editor: *Editor) bool {
        for (self.entries.items) |entry| {
            if (entry.editor == editor) return true;
        }
        return false;
    }

    /// Attaches quick diff to a file editor. Diff snapshot editors are skipped
    /// by the workbench (they are read-only and never passed here).
    pub fn attach(self: *Controller, editor: *Editor, path: []const u8) !void {
        if (!self.enabled) return;
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
            .last_version = editor.model.getVersionId(),
        };
        errdefer entry.model.deinit();
        entry.model.setIgnoreTrimWhitespace(self.ignore_trim_whitespace);
        entry.model.recompute() catch {};
        entry.decorator = QuickDiffDecorator.init(
            self.allocator,
            editor.model,
            &entry.model,
            self.service,
            self.config,
            decoration_owner,
        );
        errdefer entry.decorator.deinit();
        entry.decorator.update() catch {};

        try self.entries.append(entry);
        self.applyEditorState(entry);
    }

    pub fn detach(self: *Controller, editor: *Editor) void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.editor != editor) continue;
            _ = self.entries.orderedRemove(index);
            self.destroyEntry(entry);
            return;
        }
    }

    /// Recomputes every entry immediately (git status/provider change).
    pub fn refreshAll(self: *Controller) bool {
        var changed = false;
        for (self.entries.items) |entry| {
            entry.model.recompute() catch continue;
            entry.decorator.update() catch {};
            entry.last_version = entry.editor.model.getVersionId();
            self.applyEditorState(entry);
            changed = true;
        }
        return changed;
    }

    /// Polls the per-editor debounce and returns true when decorations changed.
    pub fn poll(self: *Controller, now_ms: i64) bool {
        var changed = false;
        for (self.entries.items) |entry| {
            const version = entry.editor.model.getVersionId();
            if (version != entry.last_version) {
                entry.model.triggerDiff(now_ms);
                entry.last_version = version;
            }
            if (!entry.model.poll(now_ms)) continue;
            entry.decorator.update() catch {};
            self.applyEditorState(entry);
            changed = true;
        }
        return changed;
    }

    pub fn setConfig(self: *Controller, config: Config) void {
        self.config = config;
        self.enabled = config.decorations != .none;
        for (self.entries.items) |entry| {
            entry.decorator.setConfig(config) catch {};
            self.applyEditorState(entry);
        }
    }

    pub fn setIgnoreTrimWhitespace(self: *Controller, ignore: bool) void {
        self.ignore_trim_whitespace = ignore;
        for (self.entries.items) |entry| {
            entry.model.setIgnoreTrimWhitespace(ignore);
            entry.model.recompute() catch continue;
            entry.decorator.update() catch {};
        }
    }

    fn applyEditorState(self: *Controller, entry: *Entry) void {
        _ = self;
        const width: usize = if (entry.decorator.gutterWidth() > 0) 1 else 0;
        entry.editor.setLineDecorationsWidth(width);
    }

    fn destroyEntry(self: *Controller, entry: *Entry) void {
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
const quick_diff = @import("../vs/workbench/contrib/scm/common/quickDiff.zig");
const TestModel = @import("../vs/editor/test/common/port/testSupport.zig").TestModel;
const EditorMod = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");

test "quickDiffController: attach, apply gutter width and detach" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var service = QuickDiffService.init(allocator, null);
    defer service.deinit();

    var provider = TestProvider{};
    provider.init(allocator, "git.primary");
    defer provider.deinit();
    const disposable = try service.addQuickDiffProvider(&provider.base);
    defer disposable.dispose();

    const editor = try EditorMod.Editor.createFromText(allocator, io, "a\nB", "test.zig", 60, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var controller = Controller.init(allocator, &service);
    defer controller.deinit();

    try controller.attach(editor, "/repo/test.zig");
    try testing.expectEqual(@as(usize, 1), controller.count());
    try testing.expectEqual(@as(usize, 1), editor.lineDecorationsWidth());
    try testing.expect(editor.decorationGeneration() > 0);

    controller.detach(editor);
    try testing.expectEqual(@as(usize, 0), controller.count());
    try testing.expectEqual(@as(usize, 0), editor.lineDecorationsWidth());
}

test "quickDiffController: poll updates after an edit and config disables decorations" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var service = QuickDiffService.init(allocator, null);
    defer service.deinit();

    var provider = TestProvider{};
    provider.init(allocator, "git.primary");
    defer provider.deinit();
    const disposable = try service.addQuickDiffProvider(&provider.base);
    defer disposable.dispose();

    const editor = try EditorMod.Editor.createFromText(allocator, io, "a\nb", "test.zig", 60, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var controller = Controller.init(allocator, &service);
    defer controller.deinit();
    try controller.attach(editor, "/repo/test.zig");

    try editor.typeCharacter("x");
    try testing.expect(!controller.poll(100));
    try testing.expect(controller.poll(5000));

    controller.setConfig(.{ .decorations = .none });
    try testing.expectEqual(@as(usize, 0), editor.lineDecorationsWidth());
}

const TestProvider = struct {
    base: quick_diff.QuickDiffProvider = undefined,
    content: []u8 = &.{},

    fn init(self: *TestProvider, allocator: Allocator, id: []const u8) void {
        self.content = allocator.dupe(u8, "a\nb") catch &.{};
        self.base = .{
            .context = self,
            .id = id,
            .label = id,
            .kind = .primary,
            .get_original_fn = getOriginal,
        };
    }

    fn deinit(self: *TestProvider) void {
        if (self.content.len > 0) testing.allocator.free(self.content);
    }

    fn getOriginal(context: *anyopaque, allocator: Allocator, _: []const u8) anyerror!?quick_diff.Original {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        return .{
            .content = try allocator.dupe(u8, self.content),
            .ref_label = try allocator.dupe(u8, "HEAD"),
        };
    }
};
