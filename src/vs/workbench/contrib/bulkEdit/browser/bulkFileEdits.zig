// Port of `src/vs/workbench/contrib/bulkEdit/browser/bulkFileEdits.ts`.
// File edit groups retain inverse operations and raw file contents; the
// shared workspace undo service owns those operations independently of the
// editor/model lifetimes. The native file provider mutation boundary is
// synchronous, so each group completes before the next edit group begins.
const std = @import("std");
const languages = @import("../../../../editor/common/languages.zig");
const bulk = @import("../../../../editor/browser/services/bulkEditService.zig");
const cancellation = @import("../../../../base/common/cancellation.zig");
const uri_util = @import("../../../../base/common/stdUri.zig");
const files = @import("../../../../platform/files/common/files.zig");
const undo = @import("../../../../platform/undoRedo/common/undoRedo.zig");
const UndoRedoService = @import("../../../../platform/undoRedo/common/undoRedoService.zig").UndoRedoService;
const EditStackElement = @import("../../../../editor/common/model/editStack.zig").EditStackElement;
const working = @import("../../../services/workingCopy/common/workingCopyFileService.zig");
const text_file = @import("../../../services/textfile/common/textFileService.zig");
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const Allocator = std.mem.Allocator;
const Uri = std.Uri;

pub const Services = struct {
    files: files.IFileService,
    working_copies: working.IWorkingCopyFileService,
    undo_redo: *UndoRedoService,
    configuration_service: ?configuration.IConfigurationService = null,
};
const Kind = enum { rename, copy, create, delete };
const FileEdit = struct {
    old: ?Uri = null,
    new: ?Uri = null,
    options: languages.WorkspaceFileEditOptions = .{},
    undoes_create: bool = false,

    fn kind(self: FileEdit) Kind {
        if (self.old != null) {
            if (self.new == null) return .delete;
            return if (self.options.copy) .copy else .rename;
        }
        return .create;
    }
    fn clone(self: FileEdit, a: Allocator) !FileEdit {
        var result = self;
        if (self.old) |uri| result.old = try uri_util.clone(a, uri);
        if (self.new) |uri| result.new = try uri_util.clone(a, uri);
        if (self.options.contents) |contents| result.options.contents = try a.dupe(u8, contents);
        return result;
    }
};

/// Native value representation of the upstream Rename/Copy/Create/Delete
/// operation classes. Each operation owns its inverse URIs and bytes.
const Operation = struct {
    arena: std.heap.ArenaAllocator,
    edits: []FileEdit = &.{},

    fn init(allocator: Allocator, edits: []const FileEdit) !Operation {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned = try a.alloc(FileEdit, edits.len);
        for (edits, owned) |edit, *destination| destination.* = try edit.clone(a);
        return .{ .arena = arena, .edits = owned };
    }
    fn deinit(self: *Operation) void {
        self.arena.deinit();
    }

    const Result = struct { inverse: Operation, count: usize };

    fn perform(allocator: Allocator, edits: []const FileEdit, services: Services, token: cancellation.CancellationToken, info: working.IFileOperationUndoRedoInfo) !Result {
        if (edits.len == 0) return .{ .inverse = try init(allocator, &.{}), .count = 0 };
        try token.throwIfCancellationRequested();
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var undoes: std.ArrayList(FileEdit) = .empty;
        var count: usize = 0;
        switch (edits[0].kind()) {
            .rename => {
                var moves: std.ArrayList(working.IMoveOperation) = .empty;
                for (edits) |edit| {
                    const source = edit.old.?;
                    const target = edit.new.?;
                    if (try skipTarget(services.files, target, edit.options)) continue;
                    try moves.append(a, .{ .source = source, .target = target, .overwrite = edit.options.overwrite orelse false });
                    try undoes.append(a, .{ .old = target, .new = source, .options = edit.options });
                }
                try services.working_copies.move(moves.items, token, info);
                count = moves.items.len;
            },
            .copy => {
                var copies: std.ArrayList(working.ICopyOperation) = .empty;
                for (edits) |edit| {
                    const source = edit.old.?;
                    const target = edit.new.?;
                    if (try skipTarget(services.files, target, edit.options)) continue;
                    const source_stat = try services.files.stat(source);
                    try copies.append(a, .{ .source = source, .target = target, .overwrite = edit.options.overwrite orelse false });
                    var options = edit.options;
                    options.recursive = true;
                    options.folder = options.folder or files.FileType.isDirectory(source_stat.type);
                    try undoes.append(a, .{ .old = target, .options = options });
                }
                try services.working_copies.copy(copies.items, token, info);
                count = copies.items.len;
            },
            .create => {
                var folders: std.ArrayList(working.ICreateOperation) = .empty;
                var creates: std.ArrayList(working.ICreateFileOperation) = .empty;
                for (edits) |edit| {
                    const target = edit.new.?;
                    if (std.mem.eql(u8, target.scheme, "untitled")) continue;
                    if (try skipTarget(services.files, target, edit.options)) continue;
                    if (edit.options.folder) {
                        try folders.append(a, .{ .resource = target });
                    } else {
                        const contents = edit.options.contents orelse try text_file.getEncodedReadable(a, services.configuration_service);
                        try creates.append(a, .{ .resource = target, .contents = contents, .overwrite = edit.options.overwrite orelse false });
                    }
                    try undoes.append(a, .{ .old = target, .options = edit.options, .undoes_create = !edit.options.folder and edit.options.contents == null });
                }
                try services.working_copies.createFolder(folders.items, token, info);
                try services.working_copies.create(creates.items, token, info);
                count = creates.items.len + folders.items.len;
            },
            .delete => {
                var deletes: std.ArrayList(working.IDeleteOperation) = .empty;
                for (edits) |edit| {
                    const source = edit.old.?;
                    const stat = services.files.stat(source) catch |err| {
                        if (edit.options.ignore_if_not_exists) continue;
                        return err;
                    };
                    const trash_enabled = if (services.configuration_service) |config| config.getBool("files.enableTrash", true) else true;
                    try deletes.append(a, .{ .resource = source, .recursive = edit.options.recursive, .use_trash = !edit.options.skip_trash_bin and trash_enabled and services.files.hasCapability(source, files.FileSystemProviderCapabilities.Trash) });
                    // Unknown/non-regular files are deleted, but have no
                    // recoverable inverse. Preserve byte contents for files,
                    // not decoded text, exactly as upstream.
                    if (!files.FileType.isFile(stat.type) and !files.FileType.isDirectory(stat.type)) continue;
                    var contents: ?[]const u8 = null;
                    if (!edit.undoes_create and !edit.options.folder) {
                        if (edit.options.max_size) |maximum| if (stat.size > maximum) continue;
                        contents = services.files.readFile(a, source) catch null;
                    }
                    var options = edit.options;
                    options.contents = contents;
                    try undoes.append(a, .{ .new = source, .options = options });
                }
                try services.working_copies.delete(deletes.items, token, info);
                count = deletes.items.len;
            },
        }
        return .{ .inverse = try init(allocator, undoes.items), .count = count };
    }

    fn skipTarget(service: files.IFileService, target: Uri, options: languages.WorkspaceFileEditOptions) !bool {
        if (options.overwrite != null or !options.ignore_if_exists) return false;
        if (service.stat(target)) |_| return true else |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    }
};

const FileUndoRedoElement = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    services: Services,
    label: []const u8,
    code: []const u8,
    confirm_before_undo: bool,
    operations: std.ArrayList(Operation) = .empty,
    resources: std.ArrayList(Uri) = .empty,

    fn create(a: Allocator, services: Services, options: bulk.IBulkEditOptions) !*FileUndoRedoElement {
        const self = try a.create(FileUndoRedoElement);
        errdefer a.destroy(self);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const label = try arena.allocator().dupe(u8, options.label orelse "Workspace Edit");
        const code = try arena.allocator().dupe(u8, options.code orelse "undoredo.workspaceEdit");
        self.* = .{ .allocator = a, .arena = arena, .services = services, .label = label, .code = code, .confirm_before_undo = options.confirm_before_undo };
        return self;
    }
    fn dispose(context: *anyopaque) void {
        const self: *FileUndoRedoElement = @ptrCast(@alignCast(context));
        for (self.operations.items) |*op| op.deinit();
        self.operations.deinit(self.allocator);
        self.resources.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn reverse(context: *anyopaque) !void {
        const self: *FileUndoRedoElement = @ptrCast(@alignCast(context));
        // Each inverse operation becomes its own inverse after running.
        // The native contract mirrors upstream FileUndoRedoElement._reverse.
        for (self.operations.items) |*op| {
            const result = try Operation.perform(self.allocator, op.edits, self.services, .None, .{ .is_undoing = true });
            op.deinit();
            op.* = result.inverse;
        }
    }
    fn append(self: *FileUndoRedoElement, op: Operation) !void {
        const a = self.arena.allocator();
        for (op.edits) |edit| {
            if (edit.new) |uri| try self.resources.append(self.allocator, try uri_util.clone(a, uri));
            if (edit.old) |uri| try self.resources.append(self.allocator, try uri_util.clone(a, uri));
        }
        try self.operations.append(self.allocator, op);
    }
    fn interface(self: *FileUndoRedoElement) undo.IWorkspaceUndoRedoElement {
        return .{ .allocator = self.allocator, .context = self, .resources = self.resources.items, .label = self.label, .code = self.code, .confirmBeforeUndo = self.confirm_before_undo, .undo_fn = reverse, .redo_fn = reverse, .dispose_fn = dispose };
    }
};

pub const BulkFileEdits = struct {
    pub fn apply(allocator: Allocator, services: Services, edits: []const bulk.ResourceEdit, options: bulk.IBulkEditOptions, group: *undo.UndoRedoGroup) !bulk.IBulkEditResult {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var file_edits: std.ArrayList(FileEdit) = .empty;
        for (edits) |edit| {
            const file = switch (edit) {
                .file => |value| value,
                else => return error.InvalidFileEditGroup,
            };
            if (file.old_resource == null and file.new_resource == null) continue;
            try file_edits.append(a, .{ .old = file.old_resource, .new = file.new_resource, .options = file.options });
        }
        if (file_edits.items.len == 0) return .{ .is_applied = false };
        const element = try FileUndoRedoElement.create(allocator, services, options);
        errdefer FileUndoRedoElement.dispose(element);
        var count: usize = 0;
        var start: usize = 0;
        while (start < file_edits.items.len) {
            if (options.token.isCancellationRequested()) break;
            const kind = file_edits.items[start].kind();
            var end = start + 1;
            while (end < file_edits.items.len and file_edits.items[end].kind() == kind) end += 1;
            var result = try Operation.perform(allocator, file_edits.items[start..end], services, options.token, .{ .undo_redo_group_id = group.id });
            errdefer result.inverse.deinit();
            try element.append(result.inverse);
            count += result.count;
            start = end;
        }
        const stack_entry = try allocator.create(EditStackElement);
        errdefer allocator.destroy(stack_entry);
        stack_entry.* = .{ .workspace = element.interface() };
        const resource_count = element.resources.items.len;
        try services.undo_redo.pushElement(stack_entry, group, options.undo_redo_source);
        return .{ .is_applied = count != 0, .edited_resources = resource_count, .edit_count = count };
    }
};
