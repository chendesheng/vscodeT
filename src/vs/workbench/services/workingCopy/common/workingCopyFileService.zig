// Port of `src/vs/workbench/services/workingCopy/common/workingCopyFileService.ts`.
// File operations use the registered native IFileService providers. The
// current provider mutation contract is synchronous; the before/after/failure
// events run on the same owning dispatcher, not from a render pass.
const std = @import("std");
const files = @import("../../../../platform/files/common/files.zig");
const cancellation = @import("../../../../base/common/cancellation.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const uri_util = @import("../../../../base/common/stdUri.zig");
const ServiceIdentifier = @import("../../../../platform/instantiation/common/instantiation.zig").ServiceIdentifier;
const working_copy = @import("workingCopy.zig");
const WorkingCopyService = @import("workingCopyService.zig").WorkingCopyService;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;

pub const SourceTargetPair = struct { source: ?Uri = null, target: Uri };
pub const IFileOperationUndoRedoInfo = struct { undo_redo_group_id: ?u64 = null, is_undoing: bool = false };
pub const WorkingCopyFileEvent = struct {
    correlation_id: u64,
    operation: files.FileOperation,
    files: []const SourceTargetPair,
    undo_info: IFileOperationUndoRedoInfo,
};
pub const ICreateOperation = struct { resource: Uri, overwrite: bool = false };
pub const ICreateFileOperation = struct { resource: Uri, contents: []const u8 = "", overwrite: bool = false };
pub const IDeleteOperation = struct { resource: Uri, use_trash: bool = false, recursive: bool = false };
pub const IMoveOperation = struct { source: Uri, target: Uri, overwrite: bool = false };
pub const ICopyOperation = IMoveOperation;

pub const Operations = union(enum) {
    create: []const ICreateFileOperation,
    create_folder: []const ICreateOperation,
    move: []const IMoveOperation,
    copy: []const ICopyOperation,
    delete: []const IDeleteOperation,

    fn len(self: Operations) usize {
        return switch (self) {
            inline else => |items| items.len,
        };
    }
    fn kind(self: Operations) files.FileOperation {
        return switch (self) {
            .create, .create_folder => .CREATE,
            .move => .MOVE,
            .copy => .COPY,
            .delete => .DELETE,
        };
    }
};

pub const IWorkingCopyFileService = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, Operations, cancellation.CancellationToken, IFileOperationUndoRedoInfo) anyerror!void,
    on_will_run: *Emitter(WorkingCopyFileEvent),
    on_did_run: *Emitter(WorkingCopyFileEvent),
    on_did_fail: *Emitter(WorkingCopyFileEvent),

    pub fn create(self: @This(), operations: []const ICreateFileOperation, token: cancellation.CancellationToken, info: IFileOperationUndoRedoInfo) !void {
        try self.run(self.context, .{ .create = operations }, token, info);
    }
    pub fn createFolder(self: @This(), operations: []const ICreateOperation, token: cancellation.CancellationToken, info: IFileOperationUndoRedoInfo) !void {
        try self.run(self.context, .{ .create_folder = operations }, token, info);
    }
    pub fn move(self: @This(), operations: []const IMoveOperation, token: cancellation.CancellationToken, info: IFileOperationUndoRedoInfo) !void {
        try self.run(self.context, .{ .move = operations }, token, info);
    }
    pub fn copy(self: @This(), operations: []const ICopyOperation, token: cancellation.CancellationToken, info: IFileOperationUndoRedoInfo) !void {
        try self.run(self.context, .{ .copy = operations }, token, info);
    }
    pub fn delete(self: @This(), operations: []const IDeleteOperation, token: cancellation.CancellationToken, info: IFileOperationUndoRedoInfo) !void {
        try self.run(self.context, .{ .delete = operations }, token, info);
    }
};

pub const working_copy_file_service_id = ServiceIdentifier(IWorkingCopyFileService, "workingCopyFileService");

pub const WorkingCopyFileService = struct {
    allocator: Allocator,
    file_service: files.IFileService,
    working_copies: ?*WorkingCopyService = null,
    correlation_id: u64 = 0,
    on_will_run: Emitter(WorkingCopyFileEvent),
    on_did_run: Emitter(WorkingCopyFileEvent),
    on_did_fail: Emitter(WorkingCopyFileEvent),

    pub fn init(a: Allocator, service: files.IFileService, copies: ?*WorkingCopyService) WorkingCopyFileService {
        return .{ .allocator = a, .file_service = service, .working_copies = copies, .on_will_run = .init(a), .on_did_run = .init(a), .on_did_fail = .init(a) };
    }
    pub fn deinit(self: *WorkingCopyFileService) void {
        self.on_will_run.deinit();
        self.on_did_run.deinit();
        self.on_did_fail.deinit();
    }
    pub fn interface(self: *WorkingCopyFileService) IWorkingCopyFileService {
        return .{ .context = self, .run = run, .on_will_run = &self.on_will_run, .on_did_run = &self.on_did_run, .on_did_fail = &self.on_did_fail };
    }

    /// A folder operation also affects its descendant working copies.
    pub fn getDirty(self: *WorkingCopyFileService, a: Allocator, resource: Uri) ![]const *const working_copy.IWorkingCopy {
        const copies = self.working_copies orelse return a.alloc(*const working_copy.IWorkingCopy, 0);
        const dirty = try copies.dirtyWorkingCopies(a);
        defer a.free(dirty);
        var result: std.ArrayList(*const working_copy.IWorkingCopy) = .empty;
        errdefer result.deinit(a);
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const ignore_case = !self.file_service.hasCapability(resource, files.FileSystemProviderCapabilities.PathCaseSensitive);
        for (dirty) |copy| {
            // IWorkingCopy currently exposes a canonical native path for file
            // working copies; URI identity is evaluated at this shared boundary.
            const copy_resource: Uri = .{ .scheme = "file", .path = .{ .raw = copy.getResource() } };
            if (try uri_util.isEqualOrParent(copy_resource, resource, scratch.allocator(), ignore_case)) try result.append(a, copy);
        }
        return result.toOwnedSlice(a);
    }

    fn run(context: *anyopaque, operations: Operations, token: cancellation.CancellationToken, info: IFileOperationUndoRedoInfo) !void {
        const self: *WorkingCopyFileService = @ptrCast(@alignCast(context));
        if (operations.len() == 0) return;
        try token.throwIfCancellationRequested();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const pairs = try a.alloc(SourceTargetPair, operations.len());
        // Validate the complete operation group before publishing the will-run event.
        switch (operations) {
            .create => |items| for (items, pairs) |item, *pair| {
                try self.validateTarget(item.resource, item.overwrite);
                pair.* = .{ .target = item.resource };
            },
            .create_folder => |items| for (items, pairs) |item, *pair| {
                pair.* = .{ .target = item.resource };
            },
            .move, .copy => |items| for (items, pairs) |item, *pair| {
                _ = try self.file_service.stat(item.source);
                const source_key = try uri_util.resourceKey(a, item.source);
                const target_key = try uri_util.resourceKey(a, item.target);
                if (!std.mem.eql(u8, source_key, target_key)) try self.validateTarget(item.target, item.overwrite);
                pair.* = .{ .source = item.source, .target = item.target };
            },
            .delete => |items| for (items, pairs) |item, *pair| {
                _ = try self.file_service.stat(item.resource);
                pair.* = .{ .target = item.resource };
            },
        }
        const event: WorkingCopyFileEvent = .{ .correlation_id = self.correlation_id, .operation = operations.kind(), .files = pairs, .undo_info = info };
        self.correlation_id += 1;
        self.on_will_run.fire(event) catch |err| {
            self.on_did_fail.fire(event) catch {};
            return err;
        };
        self.perform(operations) catch |err| {
            self.on_did_fail.fire(event) catch {};
            return err;
        };
        self.on_did_run.fire(event) catch {};
    }

    fn validateTarget(self: *WorkingCopyFileService, resource: Uri, overwrite: bool) !void {
        if (overwrite) return;
        if (self.file_service.stat(resource)) |_| return error.FileExists else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    fn perform(self: *WorkingCopyFileService, operations: Operations) !void {
        switch (operations) {
            .create => |items| for (items) |item| try self.file_service.writeFile(item.resource, item.contents, .{ .create = true, .overwrite = item.overwrite }),
            .create_folder => |items| for (items) |item| try self.file_service.createFolder(item.resource),
            .move => |items| for (items) |item| try self.file_service.move(item.source, item.target, item.overwrite),
            .copy => |items| for (items) |item| try self.file_service.copy(item.source, item.target, item.overwrite),
            .delete => |items| for (items) |item| try self.file_service.del(item.resource, .{ .recursive = item.recursive, .useTrash = item.use_trash }),
        }
    }
};
