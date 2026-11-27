// Port of `src/vs/workbench/contrib/bulkEdit/browser/preview/bulkEditPreview.ts`.
// The immutable edit array is the identity source instead of JavaScript
// object keys; category/file rows borrow indexed edits for the whole session.
const std = @import("std");
const languages = @import("../../../../../editor/common/languages.zig");
const files = @import("../../../../../platform/files/common/files.zig");
const uri_util = @import("../../../../../base/common/stdUri.zig");
const Emitter = @import("../../../../../base/common/event.zig").Emitter;
const IModelService = @import("../../../../../editor/common/services/modelService.zig").IModelService;
const ConflictDetector = @import("../conflicts.zig").ConflictDetector;
const Range = @import("../../../../../editor/common/core/range.zig").Range;
const Allocator = std.mem.Allocator;
const ResourceEdit = languages.WorkspaceResourceEdit;
const Metadata = languages.WorkspaceEditMetadata;

pub const CheckedStates = struct {
    allocator: Allocator,
    states: []?bool,
    checked_count: usize = 0,
    on_did_change: Emitter(usize),

    fn init(a: Allocator, len: usize) !CheckedStates {
        const values = try a.alloc(?bool, len);
        @memset(values, null);
        return .{ .allocator = a, .states = values, .on_did_change = .init(a) };
    }
    fn deinit(self: *CheckedStates) void {
        self.on_did_change.deinit();
        self.allocator.free(self.states);
    }
    pub fn isChecked(self: *const CheckedStates, index: usize) bool {
        return if (index < self.states.len) self.states[index] orelse false else false;
    }
    pub fn updateChecked(self: *CheckedStates, index: usize, value: bool) void {
        const previous = self.states[index];
        if (previous == value) return;
        if (previous orelse false) self.checked_count -= 1;
        if (value) self.checked_count += 1;
        self.states[index] = value;
        self.on_did_change.fire(index) catch {};
    }
};

pub const BulkFileOperationType = enum(u8) { TextEdit = 1, Create = 2, Delete = 4, Rename = 8 };
pub const BulkTextEdit = struct { index: usize, text_edit: languages.WorkspaceTextEdit };
pub const BulkFileOperation = struct {
    uri: std.Uri,
    key: []const u8,
    type_mask: u8 = 0,
    original_edits: std.ArrayList(usize) = .empty,
    text_edits: std.ArrayList(BulkTextEdit) = .empty,
    new_uri: ?std.Uri = null,

    fn addEdit(self: *BulkFileOperation, a: Allocator, index: usize, kind: BulkFileOperationType, edit: ResourceEdit) !void {
        self.type_mask |= @backingInt(kind);
        try self.original_edits.append(a, index);
        switch (edit) {
            .text => |text| try self.text_edits.append(a, .{ .index = index, .text_edit = text }),
            .file => |file| if (kind == .Rename) {
                self.new_uri = file.new_resource;
            },
        }
    }
    pub fn needsConfirmation(self: *const BulkFileOperation, checked: *const CheckedStates) bool {
        for (self.original_edits.items) |index| if (!checked.isChecked(index)) return true;
        return false;
    }
};

pub const BulkCategory = struct {
    key: []const u8,
    metadata: Metadata,
    file_operations: std.ArrayList(*BulkFileOperation) = .empty,

    pub fn keyOf(metadata: ?Metadata) []const u8 {
        if (metadata) |value| if (value.label.len > 0) return value.label;
        return "<default>";
    }
};

pub const BulkFileOperations = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    edits: []const ResourceEdit,
    checked: CheckedStates,
    file_operations: std.ArrayList(*BulkFileOperation) = .empty,
    categories: std.ArrayList(*BulkCategory) = .empty,
    new_to_old_uri: std.StringHashMapUnmanaged(std.Uri) = .empty,
    conflicts: ?*ConflictDetector = null,

    pub fn create(a: Allocator, file_service: files.IFileService, models: ?IModelService, edits: []const ResourceEdit) !*BulkFileOperations {
        const self = try a.create(BulkFileOperations);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .arena = .init(a), .edits = edits, .checked = try CheckedStates.init(a, edits.len) };
        errdefer {
            self.checked.deinit();
            self.arena.deinit();
        }
        try self.initialize(file_service);
        if (models) |service| self.conflicts = try ConflictDetector.create(a, file_service, service, edits);
        return self;
    }

    pub fn dispose(self: *BulkFileOperations) void {
        if (self.conflicts) |detector| detector.dispose();
        self.checked.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn insert(self: *BulkFileOperations, operations: *std.ArrayList(*BulkFileOperation), original_uri: std.Uri, index: usize, kind: BulkFileOperationType) !void {
        const a = self.arena.allocator();
        var uri = original_uri;
        var key = try uri_util.resourceKey(a, uri);
        for (operations.items) |operation| if (std.mem.eql(u8, operation.key, key)) return operation.addEdit(a, index, kind, self.edits[index]);
        if (self.new_to_old_uri.get(key)) |old| {
            uri = old;
            key = try uri_util.resourceKey(a, old);
            for (operations.items) |operation| if (std.mem.eql(u8, operation.key, key)) return operation.addEdit(a, index, kind, self.edits[index]);
        }
        const operation = try a.create(BulkFileOperation);
        operation.* = .{ .uri = uri, .key = key };
        try operations.append(a, operation);
        try operation.addEdit(a, index, kind, self.edits[index]);
    }

    fn findCategory(self: *BulkFileOperations, metadata: ?Metadata) !*BulkCategory {
        const key = BulkCategory.keyOf(metadata);
        for (self.categories.items) |category| if (std.mem.eql(u8, key, category.key)) return category;
        const a = self.arena.allocator();
        const category = try a.create(BulkCategory);
        category.* = .{ .key = key, .metadata = metadata orelse .{ .label = "Other" } };
        try self.categories.append(a, category);
        return category;
    }

    fn initialize(self: *BulkFileOperations, file_service: files.IFileService) !void {
        const a = self.arena.allocator();
        for (self.edits, 0..) |edit, index| {
            const metadata = switch (edit) {
                .text => |text| text.metadata,
                .file => |file| file.metadata,
            };
            self.checked.updateChecked(index, if (metadata) |value| !value.needs_confirmation else true);
            var resource: std.Uri = undefined;
            var kind: BulkFileOperationType = undefined;
            switch (edit) {
                .text => |text| {
                    resource = text.resource;
                    kind = .TextEdit;
                },
                .file => |file| {
                    if (file.old_resource) |old| {
                        resource = old;
                        if (file.new_resource) |new| {
                            kind = .Rename;
                            if (!file.options.overwrite and file.options.ignore_if_exists and exists(file_service, old)) continue;
                            try self.new_to_old_uri.put(a, try uri_util.resourceKey(a, new), old);
                        } else {
                            kind = .Delete;
                            if (file.options.ignore_if_not_exists and !exists(file_service, old)) continue;
                        }
                    } else if (file.new_resource) |new| {
                        resource = new;
                        kind = .Create;
                        if (!file.options.overwrite and file.options.ignore_if_exists and exists(file_service, new)) continue;
                    } else continue;
                },
            }
            try self.insert(&self.file_operations, resource, index, kind);
            const category = try self.findCategory(metadata);
            try self.insert(&category.file_operations, resource, index, kind);
        }
        // The unchecked create/rename/delete must disable its dependent text
        // edits even when the provider forgot to mark them for confirmation.
        for (self.file_operations.items) |operation| {
            if (operation.type_mask == @backingInt(BulkFileOperationType.TextEdit)) continue;
            var allowed = true;
            for (operation.original_edits.items) |index| {
                if (self.edits[index] == .file and !self.checked.isChecked(index)) allowed = false;
            }
            if (!allowed) for (operation.original_edits.items) |index| self.checked.updateChecked(index, false);
        }
        std.mem.sort(*BulkCategory, self.categories.items, {}, struct {
            fn less(_: void, lhs: *BulkCategory, rhs: *BulkCategory) bool {
                if (lhs.metadata.needs_confirmation != rhs.metadata.needs_confirmation) return lhs.metadata.needs_confirmation;
                return std.mem.order(u8, lhs.metadata.label, rhs.metadata.label) == .lt;
            }
        }.less);
    }

    fn exists(file_service: files.IFileService, resource: std.Uri) bool {
        _ = file_service.stat(resource) catch return false;
        return true;
    }

    pub const WorkspaceSelection = struct { edits: []const ResourceEdit, owned: bool };

    pub fn getWorkspaceEdit(self: *const BulkFileOperations, a: Allocator) !WorkspaceSelection {
        if (self.checked.checked_count == self.edits.len) return .{ .edits = self.edits, .owned = false };
        var result: std.ArrayList(ResourceEdit) = .empty;
        errdefer result.deinit(a);
        for (self.edits, 0..) |edit, index| if (self.checked.isChecked(index)) try result.append(a, edit);
        return .{ .edits = try result.toOwnedSlice(a), .owned = true };
    }

    pub fn getUriOfEdit(self: *const BulkFileOperations, index: usize) ?std.Uri {
        for (self.file_operations.items) |operation| for (operation.original_edits.items) |candidate| {
            if (candidate == index) return operation.uri;
        };
        return null;
    }

    pub fn getFileEdits(self: *const BulkFileOperations, a: Allocator, uri: std.Uri) ![]languages.WorkspaceTextEdit {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const key = try uri_util.resourceKey(scratch.allocator(), uri);
        for (self.file_operations.items) |file| {
            if (!std.mem.eql(u8, file.key, key)) continue;
            var result: std.ArrayList(languages.WorkspaceTextEdit) = .empty;
            errdefer result.deinit(a);
            for (file.original_edits.items) |index| switch (self.edits[index]) {
                .file => |edit| if (edit.options.contents) |contents| {
                    try result.append(a, .{ .resource = uri, .range = Range.init(1, 1, std.math.maxInt(usize), 1), .text = contents });
                },
                .text => |edit| if (self.checked.isChecked(index)) {
                    try result.append(a, edit);
                },
            };
            std.mem.sort(languages.WorkspaceTextEdit, result.items, {}, struct {
                fn less(_: void, lhs: languages.WorkspaceTextEdit, rhs: languages.WorkspaceTextEdit) bool {
                    if (lhs.range == null) return rhs.range != null;
                    if (rhs.range == null) return false;
                    const ranges = @import("../../../../../editor/common/core/range.zig");
                    return ranges.compareRangesUsingStarts(&lhs.range.?, &rhs.range.?) < 0;
                }
            }.less);
            return result.toOwnedSlice(a);
        }
        return a.alloc(languages.WorkspaceTextEdit, 0);
    }
};

const resolver = @import("../../../../../editor/common/services/resolverService.zig");
const model_types = @import("../../../../../editor/common/model.zig");
const TextModel = @import("../../../../../editor/common/model/textModel.zig").TextModel;
const String = @import("../../../../../base/common/strings.zig").String;
const snippet_parser = @import("../../../../../editor/contrib/snippet/browser/snippetParser.zig");
const dispatch = @import("../../../../../base/common/windowDispatch.zig");
const Disposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;
const MultiDiffResource = @import("../../../../common/editor.zig").IMultiDiffEditorResource;

/// The preview models are genuine, URI-addressable read-only text models.
/// Checked-state events undo and reapply the selected edits in place, so the
/// existing multi-diff editor sees content changes through its model events.
pub const BulkEditPreviewProvider = struct {
    pub const Schema = "vscode-bulkeditpreview-editor";
    pub const empty_preview: std.Uri = .{ .scheme = Schema, .path = .{ .raw = "" }, .fragment = .{ .raw = "empty" } };
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    operations: *BulkFileOperations,
    text_service: resolver.ITextModelService,
    models: IModelService,
    slots: []Slot = &.{},
    empty: ?resolver.ModelReference = null,
    registration: ?resolver.ContentProviderRegistration = null,
    checked_listener: ?usize = null,
    update_task: dispatch.Task = .{},
    instance_id: []const u8,
    remaining: usize = 0,
    ready: bool = false,
    starting: bool = true,
    failure: ?anyerror = null,
    on_did_ready: Emitter(void),

    const Slot = struct {
        owner: *BulkEditPreviewProvider,
        operation: *BulkFileOperation,
        uri: std.Uri,
        original: ?resolver.ModelReference = null,
        preview: ?resolver.ModelReference = null,
        undo: ?std.array_list.Managed(model_types.ValidEditOperation) = null,
        pending: ?resolver.ModelReferenceRequest = null,
        done: bool = false,
        changed: bool = false,

        fn dispose(self: *Slot) void {
            if (self.pending) |pending| pending.cancel();
            self.pending = null;
            self.clearUndo();
            if (self.preview) |*reference| reference.dispose();
            if (self.original) |*reference| reference.dispose();
            self.preview = null;
            self.original = null;
        }
        fn clearUndo(self: *Slot) void {
            if (self.undo) |*undo| {
                for (undo.items) |*edit| edit.deinit();
                undo.deinit();
            }
            self.undo = null;
        }
        fn sourceReady(context: *anyopaque, reply: resolver.ModelReferenceResult) void {
            const self: *Slot = @ptrCast(@alignCast(context));
            self.pending = null;
            self.done = true;
            switch (reply) {
                .resolved => |reference| self.original = reference,
                .failure => {},
            }
            self.createPreview() catch |err| {
                self.owner.failure = err;
            };
            self.owner.remaining -= 1;
            if (!self.owner.starting and self.owner.remaining == 0) self.owner.finishReady();
        }
        fn createPreview(self: *Slot) !void {
            const service = self.owner.text_service;
            const a = self.owner.arena.allocator();
            const path = try uri_util.fsPath(self.operation.uri, a);
            if (self.original) |reference| {
                const source = reference.object.textEditorModel;
                var value = try source.getValue(null, false);
                defer value.deinit();
                self.preview = try service.createModelFromText(self.uri, path, value.items, source.getLanguageId(), true);
            } else self.preview = try service.createModelFromText(self.uri, path, "", null, true);
            try self.applyTextEdits();
            self.changed = false;
        }
        fn applyTextEdits(self: *Slot) !void {
            const model = (self.preview orelse return).object.textEditorModel;
            var scratch = std.heap.ArenaAllocator.init(self.owner.allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            if (self.undo) |undo| {
                const inverse = try a.alloc(model_types.IdentifiedSingleEditOperation, undo.items.len);
                for (undo.items, inverse) |item, *edit| edit.* = .init(item.range, if (item.text) |text| String.initBorrowed(text.items()) else null);
                _ = try model.applyEdits(inverse, false);
                self.clearUndo();
            }
            const selected = try self.owner.operations.getFileEdits(a, self.operation.uri);
            var edits: std.ArrayList(model_types.IdentifiedSingleEditOperation) = .empty;
            for (selected) |edit| {
                const range = edit.range orelse continue;
                const converted = if (edit.column_encoding == .utf16) try @import("../bulkTextEdits.zig").convertRange(model, range) else range;
                const text = if (edit.insert_as_snippet) try snippet_parser.asInsertText(a, edit.text) else edit.text;
                var operation = model_types.IdentifiedSingleEditOperation.init(model.validateRange(converted), String.initBorrowed(text));
                operation.forceMoveMarkers = true;
                try edits.append(a, operation);
            }
            self.undo = try model.applyEdits(edits.items, true);
        }
    };

    pub fn create(a: Allocator, operations: *BulkFileOperations, text_service: resolver.ITextModelService, models: IModelService, queue: *dispatch.Queue) !*BulkEditPreviewProvider {
        const self = try a.create(BulkEditPreviewProvider);
        self.* = .{ .allocator = a, .arena = .init(a), .operations = operations, .text_service = text_service, .models = models, .instance_id = "", .on_did_ready = .init(a) };
        errdefer self.dispose();
        self.update_task = .{ .queue = queue, .context = self, .run = onUpdate };
        const arena = self.arena.allocator();
        var id: [16]u8 = undefined;
        queue.io.random(&id);
        self.instance_id = try arena.dupe(u8, &std.fmt.bytesToHex(id, .lower));
        self.registration = try text_service.registerTextModelContentProvider(Schema, .{ .context = self, .request_content = requestContent });
        self.empty = try text_service.createModelFromText(empty_preview, "", "", null, true);
        const slots = try arena.alloc(Slot, operations.file_operations.items.len);
        for (operations.file_operations.items, slots) |operation, *slot| {
            slot.* = .{ .owner = self, .operation = operation, .uri = empty_preview };
        }
        self.slots = slots;
        for (self.slots) |*slot| slot.uri = try self.asPreviewUri(slot.operation.uri);
        self.remaining = self.slots.len;
        self.checked_listener = try operations.checked.on_did_change.listen(self, onChecked);
        for (self.slots) |*slot| {
            const pending = text_service.createModelReference(slot.operation.uri, .{ .context = slot, .complete = Slot.sourceReady }) catch |err| {
                Slot.sourceReady(slot, .{ .failure = err });
                continue;
            };
            if (!slot.done) slot.pending = pending;
        }
        self.starting = false;
        if (self.remaining == 0) self.finishReady();
        return self;
    }

    pub fn dispose(self: *BulkEditPreviewProvider) void {
        self.update_task.schedule(null);
        if (self.checked_listener) |id| self.operations.checked.on_did_change.unlisten(id);
        if (self.registration) |registration| registration.dispose();
        for (self.slots) |*slot| slot.dispose();
        if (self.empty) |*reference| reference.dispose();
        self.on_did_ready.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn asPreviewUri(self: *BulkEditPreviewProvider, original: std.Uri) !std.Uri {
        const a = self.arena.allocator();
        const path = try uri_util.path(original, a);
        const encoded = try uri_util.encodedResource(a, original);
        return .{ .scheme = Schema, .host = .{ .raw = self.instance_id }, .path = .{ .raw = if (std.mem.eql(u8, original.scheme, "untitled")) try std.fmt.allocPrint(a, "/{s}", .{path}) else path }, .query = .{ .raw = encoded } };
    }

    fn requestContent(context: *anyopaque, uri: std.Uri, listener: resolver.TextContentListener) !Disposable {
        const self: *BulkEditPreviewProvider = @ptrCast(@alignCast(context));
        if (self.models.getModel(uri)) |reference| {
            var value = try reference.textEditorModel.getValue(null, false);
            defer value.deinit();
            listener.complete(listener.context, value.items);
        } else listener.complete(listener.context, null);
        return .none;
    }

    fn finishReady(self: *BulkEditPreviewProvider) void {
        self.ready = self.failure == null;
        self.on_did_ready.fire({}) catch {};
    }

    fn onChecked(index: usize, self: *BulkEditPreviewProvider) !void {
        const uri = self.operations.getUriOfEdit(index) orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const key = try uri_util.resourceKey(scratch.allocator(), uri);
        for (self.slots) |*slot| if (std.mem.eql(u8, key, slot.operation.key)) {
            slot.changed = true;
            self.update_task.post();
            break;
        };
    }

    fn onUpdate(context: *anyopaque, _: i64, _: bool) bool {
        const self: *BulkEditPreviewProvider = @ptrCast(@alignCast(context));
        for (self.slots) |*slot| {
            if (!slot.changed or slot.preview == null) continue;
            slot.changed = false;
            slot.applyTextEdits() catch |err| {
                self.failure = err;
            };
        }
        return false;
    }

    pub fn resourceFor(self: *const BulkEditPreviewProvider, operation: *const BulkFileOperation) ?MultiDiffResource {
        for (self.slots) |*slot| if (slot.operation == operation) {
            if (slot.preview == null) return null;
            if (operation.type_mask & @backingInt(BulkFileOperationType.Delete) != 0) return .{ .original = slot.uri, .modified = null, .goToFileResource = operation.uri };
            const original = if (slot.original != null) operation.uri else empty_preview;
            return .{ .original = original, .modified = slot.uri, .goToFileResource = original };
        };
        return null;
    }

    pub fn resources(self: *const BulkEditPreviewProvider, a: Allocator) ![]MultiDiffResource {
        if (!self.ready) return self.failure orelse error.PreviewNotReady;
        var result: std.ArrayList(MultiDiffResource) = .empty;
        errdefer result.deinit(a);
        const sorted = try a.dupe(*BulkFileOperation, self.operations.file_operations.items);
        defer a.free(sorted);
        std.mem.sort(*BulkFileOperation, sorted, {}, struct {
            fn less(_: void, left: *BulkFileOperation, right: *BulkFileOperation) bool {
                return std.mem.order(u8, left.key, right.key) == .lt;
            }
        }.less);
        for (sorted) |operation| if (self.resourceFor(operation)) |resource| try result.append(a, resource);
        return result.toOwnedSlice(a);
    }
};
