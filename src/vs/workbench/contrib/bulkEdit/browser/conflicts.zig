// Port of `src/vs/workbench/contrib/bulkEdit/browser/conflicts.ts`.
// Version checks and model/file change events invalidate preview resources;
// the native registry's removal event detaches listeners before a model dies.
const std = @import("std");
const languages = @import("../../../../editor/common/languages.zig");
const files = @import("../../../../platform/files/common/files.zig");
const model_service = @import("../../../../editor/common/services/modelService.zig");
const resolver = @import("../../../../editor/common/services/resolverService.zig");
const TextModel = @import("../../../../editor/common/model/textModel.zig").TextModel;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const uri_util = @import("../../../../base/common/stdUri.zig");
const ModelContentEvent = @import("../../../../editor/common/textModelEvents.zig").InternalModelContentChangeEvent;

pub const ConflictDetector = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    files: files.IFileService,
    models: model_service.IModelService,
    resources: std.StringHashMapUnmanaged(*Resource) = .empty,
    conflicts: std.ArrayList(std.Uri) = .empty,
    on_did_conflict: Emitter(void),
    file_listener: ?usize = null,
    added_listener: ?usize = null,
    removed_listener: ?usize = null,

    const Resource = struct {
        owner: *ConflictDetector,
        uri: std.Uri,
        encoded: []const u8,
        legacy: []const u8,
        model: ?*TextModel = null,
        listener: ?usize = null,
        conflicting: bool = false,

        fn onModelChange(_: ModelContentEvent, self: *Resource) !void {
            try self.owner.mark(self);
        }
        fn detach(self: *Resource) void {
            if (self.model) |model| if (self.listener) |id| model.removeDidChangeContentListener(id);
            self.listener = null;
            self.model = null;
        }
        fn attach(self: *Resource, model: *TextModel) !void {
            if (self.model == model) return;
            self.detach();
            self.listener = try model.onDidChangeContentWithContextId(self, onModelChange);
            self.model = model;
        }
    };

    pub fn create(a: std.mem.Allocator, file_service: files.IFileService, models: model_service.IModelService, edits: []const languages.WorkspaceResourceEdit) !*ConflictDetector {
        const self = try a.create(ConflictDetector);
        self.* = .{ .allocator = a, .arena = .init(a), .files = file_service, .models = models, .on_did_conflict = .init(a) };
        errdefer self.dispose();
        for (edits) |edit| switch (edit) {
            .text => |text| {
                const resource = try self.add(text.resource);
                if (text.version_id) |version| if (models.getModel(text.resource)) |model| {
                    if (model.textEditorModel.getVersionId() != version) try self.mark(resource);
                };
            },
            .file => |file| if (file.new_resource orelse file.old_resource) |uri| {
                _ = try self.add(uri);
            },
        };
        self.file_listener = try file_service.on_did_files_change.listen(self, onFilesChanged);
        self.added_listener = try models.on_model_added.listen(self, onModelAdded);
        self.removed_listener = try models.on_model_removed.listen(self, onModelRemoved);
        var iter = self.resources.valueIterator();
        while (iter.next()) |entry| if (models.getModel(entry.*.uri)) |model| try entry.*.attach(model.textEditorModel);
        return self;
    }

    pub fn dispose(self: *ConflictDetector) void {
        if (self.file_listener) |id| self.files.on_did_files_change.unlisten(id);
        if (self.added_listener) |id| self.models.on_model_added.unlisten(id);
        if (self.removed_listener) |id| self.models.on_model_removed.unlisten(id);
        var iterator = self.resources.valueIterator();
        while (iterator.next()) |resource| resource.*.detach();
        self.on_did_conflict.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn add(self: *ConflictDetector, uri: std.Uri) !*Resource {
        const a = self.arena.allocator();
        const key = try uri_util.resourceKey(a, uri);
        if (self.resources.get(key)) |resource| return resource;
        const encoded = try uri_util.encodedResource(a, uri);
        const resource = try a.create(Resource);
        resource.* = .{ .owner = self, .uri = try std.Uri.parse(encoded), .encoded = encoded, .legacy = try std.fmt.allocPrint(a, "{s}:{s}", .{ uri.scheme, try uri_util.fsPath(uri, a) }) };
        try self.resources.put(a, key, resource);
        return resource;
    }

    fn get(self: *ConflictDetector, uri: std.Uri) ?*Resource {
        const key = uri_util.resourceKey(self.allocator, uri) catch return null;
        defer self.allocator.free(key);
        return self.resources.get(key);
    }
    fn mark(self: *ConflictDetector, resource: *Resource) !void {
        if (!resource.conflicting) {
            try self.conflicts.append(self.arena.allocator(), resource.uri);
            resource.conflicting = true;
        }
        try self.on_did_conflict.fire({});
    }
    fn onFilesChanged(event: files.FileChangesEvent, self: *ConflictDetector) !void {
        var iter = self.resources.valueIterator();
        while (iter.next()) |entry| {
            const resource = entry.*;
            if (resource.model != null) continue;
            if (event.contains(resource.encoded, &.{}) or event.contains(resource.legacy, &.{})) {
                try self.mark(resource);
                break;
            }
        }
    }
    fn onModelAdded(model: resolver.IResolvedTextEditorModel, self: *ConflictDetector) !void {
        if (self.get(model.textEditorModel.uri())) |resource| try resource.attach(model.textEditorModel);
    }
    fn onModelRemoved(model: resolver.IResolvedTextEditorModel, self: *ConflictDetector) !void {
        if (self.get(model.textEditorModel.uri())) |resource| if (resource.model == model.textEditorModel) resource.detach();
    }
    pub fn hasConflicts(self: *const ConflictDetector) bool {
        return self.conflicts.items.len > 0;
    }
    pub fn list(self: *const ConflictDetector) []const std.Uri {
        return self.conflicts.items;
    }
};
