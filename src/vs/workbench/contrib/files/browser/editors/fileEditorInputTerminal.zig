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
const Emitter = @import("../../../../../base/common/event.zig").Emitter;
const editor_input = @import("../../../../common/editor/editorInput.zig");
const EditorInput = editor_input.EditorInput;
const GroupIdentifier = editor_input.GroupIdentifier;
const SaveResult = editor_input.SaveResult;
const editor_factory = @import("../../../../common/editor/editorFactory.zig");
const IEditorSerializer = editor_factory.IEditorSerializer;
const Editor = @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

pub const FileEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    editor: *Editor,
    refs: usize = 1,
    dirty_listener: Emitter(void).ListenerId,

    /// Upstream `FILE_EDITOR_INPUT_ID`.
    pub const TYPE_ID = "workbench.editors.files.fileEditorInput";

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
        self.base.editor_id = "default";
        self.base.resource = editor.path;
        self.base.name = std.fs.path.basename(editor.path);
        // File inputs are editable by default; upstream returns `None` here,
        // not `Readonly`.
        self.base.capabilities = 0;
        self.base.is_dirty_fn = isDirty;
        self.base.save_fn = save;
        self.base.revert_fn = revert;
        self.base.rename_fn = rename;
        self.base.matches_fn = matches;

        self.dirty_listener = try editor.on_did_change_dirty.listen(self, onEditorDirty);
        return self;
    }

    /// A Markdown panel can keep its source document and scroll event source
    /// alive after the file's tab closes.
    pub fn retain(self: *FileEditorInput) *FileEditorInput {
        self.refs += 1;
        return self;
    }

    /// Closes the input and destroys the owned editor. The caller must close
    /// the editor from the group and detach any view first.
    pub fn deinit(self: *FileEditorInput) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.editor.on_did_change_dirty.unlisten(self.dirty_listener);
        self.base.dispose();
        self.base.deinit();
        self.editor.deinit();
        self.allocator.destroy(self.editor);
        self.allocator.destroy(self);
    }

    /// Terminal adaptation of upstream `EditorInput.copy()`. Upstream returns
    /// the same input because a `TextFileEditorInput` does not own the editor
    /// pane; here the input owns a text-editor view, so a split copy needs a
    /// new view over the shared `EditorDocument`.
    pub fn copyInput(self: *FileEditorInput) !*FileEditorInput {
        const editor = try Editor.createViewFromEditor(
            self.editor,
            self.editor.screen_width,
            self.editor.screen_height,
        );
        errdefer {
            editor.deinit();
            self.allocator.destroy(editor);
        }
        return FileEditorInput.init(self.allocator, editor);
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

    fn revert(base: *EditorInput, group: GroupIdentifier) anyerror!void {
        _ = group;
        const self: *FileEditorInput = @ptrCast(@alignCast(base.impl.?));
        try self.editor.reloadFromDisk();
    }

    fn rename(_: *EditorInput, _: GroupIdentifier, target: std.Uri) !?@import("../../../../common/editor/editorInput.zig").MoveResult {
        return .{ .resource = target };
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

/// Serializer for file inputs. Upstream `FileEditorInputSerializer` persists
/// the resource, preferred resource/name/description/encoding/language id; the
/// terminal editor has no separate preferred state yet, so the canonical path
/// is the serialized value. Dirty buffers are not persisted (upstream restores
/// those through working-copy backups, which are not ported).
pub const FileEditorSerializer = struct {
    undo_store: ?*@import("../../../../../editor/common/services/modelService.zig").ModelUndoRedoStore = null,
    allocator: Allocator,
    io: std.Io,
    width: usize,
    height: usize,
    resolved_documents: std.ArrayList(*@import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument) = .empty,

    pub fn init(allocator: Allocator, io: std.Io, width: usize, height: usize) FileEditorSerializer {
        return .{
            .allocator = allocator,
            .io = io,
            .width = @max(width, 1),
            .height = @max(height, 1),
        };
    }

    /// During group restoration, inputs in different groups and in a diff
    /// resolve the same actual workspace resource to one document. The cache
    /// holds only a reference for the restore transaction, not a pane.
    pub fn clearResolvedDocuments(self: *FileEditorSerializer) void {
        for (self.resolved_documents.items) |document| document.release();
        self.resolved_documents.clearRetainingCapacity();
    }

    pub fn deinit(self: *FileEditorSerializer) void {
        self.clearResolvedDocuments();
        self.resolved_documents.deinit(self.allocator);
    }

    pub fn interface(self: *FileEditorSerializer) IEditorSerializer {
        return .{
            .context = self,
            .canSerialize = canSerialize,
            .serialize = serialize,
            .deserialize = deserialize,
            .discard_deserialized = discardDeserialized,
        };
    }

    fn discardDeserialized(_: *anyopaque, input: *EditorInput) void {
        const file: *FileEditorInput = @ptrCast(@alignCast(input.impl.?));
        file.deinit();
    }

    fn canSerialize(_: *anyopaque, input: *EditorInput) bool {
        return std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID);
    }

    fn serialize(_: *anyopaque, input: *EditorInput, allocator: Allocator) anyerror!?[]const u8 {
        const resource = input.resource orelse return null;
        return try allocator.dupe(u8, resource);
    }

    fn deserialize(context: *anyopaque, data: []const u8) anyerror!?*EditorInput {
        const self: *FileEditorSerializer = @ptrCast(@alignCast(context));
        const text_files = @import("../../../../services/textfile/common/textFileService.zig");
        const editor = blk: {
            for (self.resolved_documents.items) |document| {
                if (text_files.samePath(self.allocator, self.io, document.path, data)) {
                    break :blk Editor.createViewFromDocument(document, self.width, self.height, .{ .reserve_scrollbar = true }) catch return null;
                }
            }
            const created = Editor.createWithOptions(self.allocator, self.io, data, self.width, self.height, .{ .reserve_scrollbar = true, .undo_store = self.undo_store }) catch return null;
            self.resolved_documents.append(self.allocator, created.document) catch |err| {
                created.deinit();
                self.allocator.destroy(created);
                return err;
            };
            created.document.retain();
            break :blk created;
        };
        const input = FileEditorInput.init(self.allocator, editor) catch |err| {
            editor.deinit();
            self.allocator.destroy(editor);
            return err;
        };
        return &input.base;
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
    const group_mod = @import("../../../../common/editor/editorGroupModel.zig");

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

test "FileEditorSerializer round-trips a path" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var serializer = FileEditorSerializer.init(allocator, io, 20, 5);
    defer serializer.deinit();
    const ser = serializer.interface();

    const editor = try Editor.createFromText(allocator, io, "alpha", "serialized.txt", 20, 5);
    const input = try FileEditorInput.init(allocator, editor);
    defer input.deinit();

    try std.testing.expect(ser.canSerialize(ser.context, &input.base));
    const value = (try ser.serialize(ser.context, &input.base, allocator)).?;
    defer allocator.free(@constCast(value));
    try std.testing.expectEqualStrings("serialized.txt", value);

    const restored = (try ser.deserialize(ser.context, value)).?;
    const restored_file: *FileEditorInput = @ptrCast(@alignCast(restored.impl.?));
    defer restored_file.deinit();
    try std.testing.expectEqualStrings("serialized.txt", restored_file.base.resource.?);
    try std.testing.expect(!restored_file.base.isDirty());
}
