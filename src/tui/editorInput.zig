// TUI adapter for upstream
// `src/vs/workbench/contrib/files/browser/editors/fileEditorInput.ts`.
//
// Upstream a `TextFileEditorInput` owns a text file working copy and creates
// the editor pane from the editor service. In this port the `Editor` already
// owns the text model, undo stack and view state, so the input owns the
// `Editor` directly and exposes its path, dirty state and save operation to
// the ported `EditorGroupModel`. The tab strip and editor-part shell consume
// this input; encoding, file services and external changes remain unported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../vs/base/common/event.zig").Emitter;
const editor_input = @import("../vs/workbench/common/editor/editorInput.zig");
const EditorInput = editor_input.EditorInput;
const GroupIdentifier = editor_input.GroupIdentifier;
const SaveResult = editor_input.SaveResult;
const Editor = @import("./editor.zig").Editor;

pub const FileEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    editor: *Editor,
    dirty_listener: Emitter(void).ListenerId,

    /// Upstream `TextFileEditorInput` type id.
    pub const TYPE_ID = "workbench.editors.files.textFileEditorInput";

    pub fn init(allocator: Allocator, editor: *Editor) !*FileEditorInput {
        const self = try allocator.create(FileEditorInput);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .base = EditorInput.init(allocator, TYPE_ID),
            .editor = editor,
            .dirty_listener = undefined,
        };

        self.base.impl = self;
        self.base.resource = editor.path;
        self.base.name = std.fs.path.basename(editor.path);
        // File inputs are editable by default; upstream returns `None` here,
        // not `Readonly`.
        self.base.capabilities = 0;
        self.base.is_dirty_fn = isDirty;
        self.base.save_fn = save;
        self.base.matches_fn = matches;

        self.dirty_listener = try editor.on_did_change_dirty.listen(self, onEditorDirty);
        return self;
    }

    /// Closes the input and destroys the owned editor. The caller must close
    /// the editor from the group and detach any view first.
    pub fn deinit(self: *FileEditorInput) void {
        self.editor.on_did_change_dirty.unlisten(self.dirty_listener);
        self.base.dispose();
        self.base.deinit();
        self.editor.deinit();
        self.allocator.destroy(self.editor);
        self.allocator.destroy(self);
    }

    pub fn interface(self: *FileEditorInput) *EditorInput {
        return &self.base;
    }

    fn isDirty(base: *const EditorInput) bool {
        const self: *const FileEditorInput = @ptrCast(@alignCast(base.impl.?));
        return self.editor.isDirty();
    }

    fn save(base: *EditorInput, group: GroupIdentifier) anyerror!SaveResult {
        _ = group;
        const self: *FileEditorInput = @ptrCast(@alignCast(base.impl.?));
        try self.editor.save();
        return base;
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        if (base == other) return true;
        if (!std.mem.eql(u8, base.type_id, other.type_id)) return false;

        const left = base.resource orelse return false;
        const right = other.resource orelse return false;
        return std.mem.eql(u8, left, right);
    }

    fn onEditorDirty(_: void, self: *FileEditorInput) anyerror!void {
        try self.base.fireDirty();
    }
};

test "FileEditorInput exposes path and dirty state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const editor_a = try Editor.createFromText(allocator, io, "alpha", "a.txt", 20, 5);
    const input_a = try FileEditorInput.init(allocator, editor_a);
    defer input_a.deinit();

    const editor_b = try Editor.createFromText(allocator, io, "beta", "b.txt", 20, 5);
    const input_b = try FileEditorInput.init(allocator, editor_b);
    defer input_b.deinit();

    try std.testing.expectEqualStrings("a.txt", input_a.base.getName());
    try std.testing.expectEqualStrings("a.txt", input_a.base.resource.?);
    try std.testing.expect(!input_a.base.isDirty());

    try editor_a.insertText("!");
    try std.testing.expect(input_a.base.isDirty());
    try std.testing.expect(!input_b.base.isDirty());

    try std.testing.expect(input_a.base.matches(.{ .input = &input_b.base }) == false);
    const same_path = try FileEditorInput.init(allocator, try Editor.createFromText(allocator, io, "", "a.txt", 20, 5));
    defer same_path.deinit();
    try std.testing.expect(input_a.base.matches(.{ .input = &same_path.base }));
}

test "FileEditorInput drives the editor group model" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const group_mod = @import("../vs/workbench/common/editor/editorGroupModel.zig");

    var group = try group_mod.EditorGroupModel.init(allocator, .{});
    defer group.deinit();

    const editor_a = try Editor.createFromText(allocator, io, "alpha", "a.txt", 30, 6);
    const input_a = try FileEditorInput.init(allocator, editor_a);
    defer input_a.deinit();

    const editor_b = try Editor.createFromText(allocator, io, "beta", "b.txt", 30, 6);
    const input_b = try FileEditorInput.init(allocator, editor_b);
    defer input_b.deinit();

    _ = try group.openEditor(&input_a.base, .{ .pinned = true, .active = true });
    _ = try group.openEditor(&input_b.base, .{ .pinned = true, .active = true });

    try std.testing.expectEqual(@as(usize, 2), group.count());
    try std.testing.expectEqual(&input_b.base, group.activeEditor().?);
    try std.testing.expect(group.isPinned(.{ .editor = &input_a.base }));

    var dirty_events: usize = 0;
    _ = try group.on_did_model_change.listen(&dirty_events, struct {
        fn cb(event: group_mod.GroupModelChangeEvent, count: *usize) anyerror!void {
            if (event == .EDITOR_DIRTY) count.* += 1;
        }
    }.cb);

    try editor_a.insertText("!");
    try std.testing.expectEqual(@as(usize, 1), dirty_events);
    try std.testing.expect(input_a.base.isDirty());

    _ = try group.setActive(&input_a.base);
    try std.testing.expectEqual(&input_a.base, group.activeEditor().?);

    const mru = try group.getEditors(allocator, .MOST_RECENTLY_ACTIVE, false);
    defer allocator.free(mru);
    try std.testing.expectEqual(&input_a.base, mru[0]);
    try std.testing.expectEqual(&input_b.base, mru[1]);

    // Unregister the group's editor listeners before the inputs (and their
    // emitters) are destroyed by the defers below.
    _ = try group.closeEditor(&input_a.base, .UNKNOWN, true);
    _ = try group.closeEditor(&input_b.base, .UNKNOWN, true);
}
