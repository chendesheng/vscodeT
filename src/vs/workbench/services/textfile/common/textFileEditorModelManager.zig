// Port of the file-operation lifecycle in
// `src/vs/workbench/services/textfile/common/textFileEditorModelManager.ts`.
// The registered file service performs native mutations synchronously. The
// model manager captures retained working-copy snapshots before mutation and
// restores the target model before editor-input replacement consumes it.
const std = @import("std");
const files = @import("../../../../platform/files/common/files.zig");
const working = @import("../../workingCopy/common/workingCopyFileService.zig");
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const SignalSubscription = @import("../../../../base/common/event.zig").SignalSubscription;
const TextModel = @import("../../../../editor/common/model/textModel.zig").TextModel;
const uri_util = @import("../../../../base/common/stdUri.zig");
const encoding = @import("encoding.zig");
const Allocator = std.mem.Allocator;
const Uri = std.Uri;

/// Narrow model-access contract for the text-file owner, adapting the native
/// resource model collection without exposing its concrete document to clients.
pub const FileModel = struct {
    context: *anyopaque,
    text: *TextModel,
    is_dirty: *const fn (*anyopaque) bool,
    set_dirty: *const fn (*anyopaque, bool) void,
    get_encoding: *const fn (*anyopaque) encoding.Encoding,
    update: *const fn (*anyopaque, []const u8, encoding.Encoding, bool) anyerror!void,
    set_language: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn dirty(self: FileModel) bool {
        return self.is_dirty(self.context);
    }
    pub fn setDirty(self: FileModel, value: bool) void {
        self.set_dirty(self.context, value);
    }
};
pub const FileModelReference = struct {
    model: FileModel,
    release: Disposable,
    pub fn dispose(self: *FileModelReference) void {
        self.release.dispose();
        self.release = .none;
    }
};
pub const ITextFileModelAccess = struct {
    context: *anyopaque,
    get_models: *const fn (*anyopaque, Allocator) anyerror![]FileModel,
    acquire: *const fn (*anyopaque, Uri) anyerror!?FileModelReference,
    resolve: *const fn (*anyopaque, Uri, []const u8) anyerror!FileModelReference,
};

const RestoreRecord = struct {
    target: Uri,
    language: []const u8,
    encoding: encoding.Encoding,
    snapshot: ?[]const u8,
};
const OperationState = struct {
    arena: std.heap.ArenaAllocator,
    records: std.ArrayList(RestoreRecord) = .empty,
    softened: std.ArrayList(FileModelReference) = .empty,

    fn deinit(self: *OperationState) void {
        for (self.softened.items) |*reference| reference.dispose();
        self.arena.deinit();
    }
};

pub const TextFileEditorModelManager = struct {
    allocator: Allocator,
    file_service: files.IFileService,
    models: ITextFileModelAccess,
    operations: std.AutoHashMapUnmanaged(u64, OperationState) = .empty,
    subscriptions: [3]?SignalSubscription = .{ null, null, null },

    pub fn init(a: Allocator, service: files.IFileService, models: ITextFileModelAccess) TextFileEditorModelManager {
        return .{ .allocator = a, .file_service = service, .models = models };
    }
    pub fn bind(self: *TextFileEditorModelManager, service: working.IWorkingCopyFileService) !void {
        self.subscriptions[0] = try service.on_will_run.listenDisposable(self, onWillRun);
        errdefer self.subscriptions[0].?.dispose();
        self.subscriptions[1] = try service.on_did_fail.listenDisposable(self, onDidFail);
        errdefer self.subscriptions[1].?.dispose();
        self.subscriptions[2] = try service.on_did_run.listenDisposable(self, onDidRun);
    }
    pub fn deinit(self: *TextFileEditorModelManager) void {
        for (self.subscriptions) |maybe| if (maybe) |subscription| subscription.dispose();
        var iterator = self.operations.valueIterator();
        while (iterator.next()) |state| {
            for (state.softened.items) |reference| reference.model.setDirty(true);
            state.deinit();
        }
        self.operations.deinit(self.allocator);
    }

    fn onWillRun(event: working.WorkingCopyFileEvent, self: *TextFileEditorModelManager) !void {
        // Create just reloads existing models. Move/copy snapshot the resolved
        // source models; delete and overwrite operations soft-revert dirty
        // copies while retaining them until the correlated result.
        if (event.operation == .CREATE) return;
        var state: OperationState = .{ .arena = .init(self.allocator) };
        errdefer state.deinit();
        const a = state.arena.allocator();
        const models = try self.models.get_models(self.models.context, a);
        for (models) |model| {
            const resource = model.text.uri();
            var soften = false;
            for (event.files) |pair| {
                const ignore_case = !self.file_service.hasCapability(pair.target, files.FileSystemProviderCapabilities.PathCaseSensitive);
                if (pair.source) |source| {
                    const source_key = try uri_util.resourceKey(a, source);
                    const target_key = try uri_util.resourceKey(a, pair.target);
                    if (std.mem.eql(u8, source_key, target_key)) continue;
                    if (try uri_util.mapMovedResource(a, resource, source, pair.target, ignore_case)) |target| {
                        const snapshot = if (model.dirty()) blk: {
                            var value = try model.text.getValue(.TextDefined, false);
                            defer value.deinit();
                            break :blk try a.dupe(u8, value.items);
                        } else null;
                        try state.records.append(a, .{ .target = target, .language = try a.dupe(u8, model.text.getLanguageId()), .encoding = model.get_encoding(model.context), .snapshot = snapshot });
                        if (event.operation == .MOVE) soften = true;
                    }
                }
                if (try uri_util.isEqualOrParent(resource, pair.target, a, ignore_case)) soften = true;
            }
            if (soften and model.dirty()) {
                if (try self.models.acquire(self.models.context, resource)) |reference| {
                    var held = reference;
                    errdefer held.dispose();
                    try state.softened.append(a, held);
                }
            }
        }
        try self.operations.put(self.allocator, event.correlation_id, state);
        // Mark dirty flags only after all snapshots/leases are captured and
        // the correlation is registered for a failure callback.
        for (state.softened.items) |reference| reference.model.setDirty(false);
    }

    fn onDidFail(event: working.WorkingCopyFileEvent, self: *TextFileEditorModelManager) !void {
        var state = (self.operations.fetchRemove(event.correlation_id) orelse return).value;
        defer state.deinit();
        for (state.softened.items) |reference| reference.model.setDirty(true);
    }

    fn onDidRun(event: working.WorkingCopyFileEvent, self: *TextFileEditorModelManager) !void {
        if (event.operation == .CREATE) {
            for (event.files) |pair| {
                var reference = (try self.models.acquire(self.models.context, pair.target)) orelse continue;
                defer reference.dispose();
                self.reload(reference.model, pair.target, null, reference.model.get_encoding(reference.model.context), false) catch {};
            }
            return;
        }
        var state = (self.operations.fetchRemove(event.correlation_id) orelse return).value;
        defer state.deinit();
        for (state.records.items) |record| self.restore(record) catch {};
    }

    fn reload(self: *TextFileEditorModelManager, model: FileModel, resource: Uri, snapshot: ?[]const u8, source_encoding: encoding.Encoding, dirty: bool) !void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const text = snapshot orelse blk: {
            const bytes = try self.file_service.readFile(a, resource);
            break :blk try encoding.decode(a, bytes, source_encoding);
        };
        try model.update(model.context, text, source_encoding, dirty);
    }
    fn restore(self: *TextFileEditorModelManager, record: RestoreRecord) !void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const content = record.snapshot orelse blk: {
            const bytes = try self.file_service.readFile(a, record.target);
            break :blk try encoding.decode(a, bytes, record.encoding);
        };
        var reference = try self.models.resolve(self.models.context, record.target, content);
        defer reference.dispose();
        try reference.model.update(reference.model.context, content, record.encoding, record.snapshot != null);
        if (!std.mem.eql(u8, record.language, "plaintext") and std.mem.eql(u8, reference.model.text.getLanguageId(), "plaintext")) try reference.model.set_language(reference.model.context, record.language);
    }
};
