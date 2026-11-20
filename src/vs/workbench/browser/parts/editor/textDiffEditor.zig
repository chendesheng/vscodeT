// Port of the terminal workbench diff pane in
// `src/vs/workbench/browser/parts/editor/textDiffEditor.ts`.
//
// Terminal adaptations:
// - `DiffEditorModel` carries the two snapshot texts and labels instead of a
//   pair of text models; the diff widget builds aligned display snapshots.
// - `SnapshotEditorInput` is a terminal workbench input with no upstream
//   counterpart. It gives `HEAD`/index/working variants distinct resource keys
//   so they do not collide in the editor group, and it can never save or
//   revert. Its read-only editor is the diff widget's snapshot editor, owned by
//   the widget (not duplicated in the input).
// - The diff input has no serializer, so session save skips diff tabs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui");
const widget_mod = @import("../../../../editor/browser/widget/diffEditor/diffEditorWidget.zig");
const diff_editor_input = @import("../../../common/editor/diffEditorInput.zig");
const editor_input = @import("../../../common/editor/editorInput.zig");
const editor_mod = @import("../../../common/editor.zig");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../../../tui/editorView.zig").View;

pub const DiffEditorWidget = widget_mod.DiffEditorWidget;
pub const Options = widget_mod.Options;

pub const SnapshotEditorInput = struct {
    allocator: Allocator,
    base: editor_input.EditorInput,
    key: []u8,
    name: []u8,

    pub const TYPE_ID = "workbench.editors.textDiffSnapshot";

    pub fn init(allocator: Allocator, path: []const u8, label: []const u8, key: []const u8) !*SnapshotEditorInput {
        const self = try allocator.create(SnapshotEditorInput);
        errdefer allocator.destroy(self);
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        const name_copy = try allocator.dupe(u8, std.fs.path.basename(path));
        errdefer allocator.free(name_copy);

        self.* = .{
            .allocator = allocator,
            .base = editor_input.EditorInput.init(allocator, TYPE_ID),
            .key = key_copy,
            .name = name_copy,
        };
        self.base.impl = self;
        self.base.resource = self.key;
        self.base.name = self.name;
        self.base.description = label;
        self.base.capabilities = editor_mod.EditorInputCapabilities.Readonly;
        self.base.is_dirty_fn = alwaysClean;
        self.base.save_fn = saveNoop;
        self.base.revert_fn = revertNoop;
        self.base.matches_fn = matches;
        return self;
    }

    pub fn destroy(self: *SnapshotEditorInput) void {
        self.base.dispose();
        self.base.deinit();
        self.allocator.free(self.key);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn interface(self: *SnapshotEditorInput) *editor_input.EditorInput {
        return &self.base;
    }

    fn alwaysClean(_: *const editor_input.EditorInput) bool {
        return false;
    }

    fn saveNoop(base: *editor_input.EditorInput, _: editor_input.GroupIdentifier) anyerror!editor_input.SaveResult {
        return base;
    }

    fn revertNoop(_: *editor_input.EditorInput, _: editor_input.GroupIdentifier) anyerror!void {}

    fn matches(base: *editor_input.EditorInput, other: *editor_input.EditorInput) bool {
        if (base == other) return true;
        if (!std.mem.eql(u8, base.type_id, other.type_id)) return false;
        const left = base.resource orelse return false;
        const right = other.resource orelse return false;
        return std.mem.eql(u8, left, right);
    }
};

pub const DiffEditorModel = struct {
    original_path: []const u8,
    modified_path: []const u8,
    original_text: []const u8,
    modified_text: []const u8,
    original_label: []const u8,
    modified_label: []const u8,
};

/// The terminal diff pane: the diff widget plus the snapshot/diff inputs.
pub const DiffView = struct {
    allocator: Allocator,
    io: Io,
    model: DiffEditorModel,
    widget: *DiffEditorWidget,
    original_input: *SnapshotEditorInput,
    modified_input: *SnapshotEditorInput,
    diff_input: *diff_editor_input.DiffEditorInput,
    owned_original_text: ?[]u8 = null,
    owned_modified_text: ?[]u8 = null,

    pub fn create(
        allocator: Allocator,
        io: Io,
        model: DiffEditorModel,
        width: usize,
        height: usize,
        options: Options,
    ) !*DiffView {
        const self = try allocator.create(DiffView);
        errdefer allocator.destroy(self);

        const widget = try DiffEditorWidget.create(
            allocator,
            io,
            model.original_path,
            model.modified_path,
            model.original_text,
            model.modified_text,
            model.original_label,
            model.modified_label,
            width,
            height,
            options,
        );
        errdefer widget.destroy();

        const original_key = try std.fmt.allocPrint(
            allocator,
            "{s}::{s}::original",
            .{ model.original_path, model.original_label },
        );
        defer allocator.free(original_key);
        const modified_key = try std.fmt.allocPrint(
            allocator,
            "{s}::{s}::modified",
            .{ model.modified_path, model.modified_label },
        );
        defer allocator.free(modified_key);

        const original_input = try SnapshotEditorInput.init(allocator, model.original_path, model.original_label, original_key);
        errdefer original_input.destroy();
        const modified_input = try SnapshotEditorInput.init(allocator, model.modified_path, model.modified_label, modified_key);
        errdefer modified_input.destroy();

        const basename = std.fs.path.basename(model.modified_path);
        const title = try std.fmt.allocPrint(
            allocator,
            "{s} ({s} \u{2194} {s})",
            .{ basename, model.original_label, model.modified_label },
        );
        defer allocator.free(title);
        const diff_input = try diff_editor_input.DiffEditorInput.init(
            allocator,
            title,
            null,
            &original_input.base,
            &modified_input.base,
        );
        errdefer diff_input.destroy();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .model = model,
            .widget = widget,
            .original_input = original_input,
            .modified_input = modified_input,
            .diff_input = diff_input,
        };
        return self;
    }

    pub fn destroy(self: *DiffView) void {
        const allocator = self.allocator;
        self.diff_input.destroy();
        self.original_input.destroy();
        self.modified_input.destroy();
        self.widget.destroy();
        if (self.owned_original_text) |text| allocator.free(text);
        if (self.owned_modified_text) |text| allocator.free(text);
        allocator.destroy(self);
    }

    /// Replaces the snapshot texts in place, recreating the diff widget with
    /// the new content while keeping the input identity/tab.
    pub fn replace(self: *DiffView, original_text: []const u8, modified_text: []const u8, width: usize, height: usize, options: Options) !void {
        const original_copy = try self.allocator.dupe(u8, original_text);
        errdefer self.allocator.free(original_copy);
        const modified_copy = try self.allocator.dupe(u8, modified_text);
        errdefer self.allocator.free(modified_copy);

        const widget = try DiffEditorWidget.create(
            self.allocator,
            self.io,
            self.model.original_path,
            self.model.modified_path,
            original_copy,
            modified_copy,
            self.model.original_label,
            self.model.modified_label,
            width,
            height,
            options,
        );
        errdefer widget.destroy();

        self.widget.destroy();
        self.widget = widget;
        if (self.owned_original_text) |text| self.allocator.free(text);
        if (self.owned_modified_text) |text| self.allocator.free(text);
        self.owned_original_text = original_copy;
        self.owned_modified_text = modified_copy;
    }

    pub fn paint(self: *DiffView, frame: *ui.Frame, x: usize, y: usize, w: usize, h: usize) !void {
        try self.widget.paint(frame, x, y, w, h);
    }

    pub fn layout(self: *DiffView, width: usize, height: usize) void {
        self.widget.layout(width, height);
    }

    pub fn cursorCell(self: *DiffView) ?struct { row: usize, col: usize } {
        const cell = self.widget.cursorCell() orelse return null;
        return .{ .row = cell.row, .col = cell.col };
    }

    pub fn focus(self: *DiffView) void {
        self.widget.setFocus(.modified);
    }

    pub fn handleKey(self: *DiffView, event: *ui.KeyEvent) bool {
        return self.widget.dispatchKey(event);
    }

    pub fn handleMouse(self: *DiffView, event: *ui.MouseEvent) !bool {
        return self.widget.dispatchMouse(event);
    }

    pub fn nextChange(self: *DiffView) bool {
        return self.widget.nextChange();
    }

    pub fn previousChange(self: *DiffView) bool {
        return self.widget.previousChange();
    }

    pub fn swapSides(self: *DiffView) void {
        self.widget.swapSides();
    }

    pub fn input(self: *DiffView) *editor_input.EditorInput {
        return &self.diff_input.base;
    }

    /// Whether this diff view shows the same path/ref pair. Used by the
    /// workbench to refresh an existing diff tab instead of opening a new one.
    pub fn matches(self: *const DiffView, path: []const u8, left_label: []const u8, right_label: []const u8) bool {
        return std.mem.eql(u8, self.model.original_path, path) and
            std.mem.eql(u8, self.model.modified_path, path) and
            std.mem.eql(u8, self.model.original_label, left_label) and
            std.mem.eql(u8, self.model.modified_label, right_label);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "SnapshotEditorInput: identity, read-only and no dirty state" {
    const allocator = testing.allocator;
    const original = try SnapshotEditorInput.init(allocator, "/repo/a.zig", "HEAD", "/repo/a.zig::HEAD::original");
    defer original.destroy();
    const modified = try SnapshotEditorInput.init(allocator, "/repo/a.zig", "Working Tree", "/repo/a.zig::working::modified");
    defer modified.destroy();

    try testing.expectEqualStrings("a.zig", original.base.getName());
    try testing.expectEqualStrings("HEAD", original.base.getDescription(.SHORT).?);
    try testing.expect(original.base.isReadonly());
    try testing.expect(!original.base.isDirty());
    try testing.expect(original.base.matches(.{ .input = &original.base }));
    try testing.expect(!original.base.matches(.{ .input = &modified.base }));
    try testing.expect((try original.base.save(0)) != null);
}

test "DiffView: opens a diff tab input with distinct snapshot keys" {
    const allocator = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const view = try DiffView.create(
        allocator,
        io,
        .{
            .original_path = "/repo/a.zig",
            .modified_path = "/repo/a.zig",
            .original_text = "a\nb",
            .modified_text = "a\nB",
            .original_label = "HEAD",
            .modified_label = "Working Tree",
        },
        80,
        10,
        .{},
    );
    defer view.destroy();

    try testing.expect(std.mem.indexOf(u8, view.input().getName(), "HEAD") != null);
    try testing.expect(std.mem.indexOf(u8, view.input().getName(), "Working Tree") != null);
    try testing.expect(view.widget.changeCount() == 1);
    try testing.expect(view.widget.modified_editor.isReadOnly());
    try testing.expect(view.widget.original_editor.isReadOnly());

    try view.replace("a\nb\nc", "a\nB", 80, 10, .{});
    try testing.expectEqual(@as(usize, 1), view.widget.changeCount());
}
