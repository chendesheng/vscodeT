// Port of `src/vs/workbench/contrib/bulkEdit/browser/preview/bulkEditPreview.ts`.
// The immutable edit array is the identity source instead of JavaScript
// object keys; category/file rows borrow indexed edits for the whole session.
const std = @import("std");
const languages = @import("../../../../../editor/common/languages.zig");
const files = @import("../../../../../platform/files/common/files.zig");
const uri_util = @import("../../../../../base/common/stdUri.zig");
const Emitter = @import("../../../../../base/common/event.zig").Emitter;
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

    pub fn create(a: Allocator, file_service: files.IFileService, edits: []const ResourceEdit) !*BulkFileOperations {
        const self = try a.create(BulkFileOperations);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .arena = .init(a), .edits = edits, .checked = try CheckedStates.init(a, edits.len) };
        errdefer {
            self.checked.deinit();
            self.arena.deinit();
        }
        try self.initialize(file_service);
        return self;
    }

    pub fn dispose(self: *BulkFileOperations) void {
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

    pub fn getWorkspaceEdit(self: *const BulkFileOperations, a: Allocator) !struct { edits: []const ResourceEdit, owned: bool } {
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
