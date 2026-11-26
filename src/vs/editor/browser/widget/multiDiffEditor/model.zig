// Port of `src/vs/editor/browser/widget/multiDiffEditor/model.ts`.
// The workbench resolver supplies retained EditorDocuments and real URIs.
// An absent side is distinct from an existing binary/unresolved resource.
const std = @import("std");
const Allocator = std.mem.Allocator;
const EditorDocument = @import("../codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const Options = @import("../diffEditor/diffEditorOptions.zig").Options;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const std_uri = @import("../../../../base/common/stdUri.zig");

pub const DiffItemSource = struct {
    uri: std.Uri,
    textModel: ?*EditorDocument = null,

    fn copy(self: DiffItemSource, arena: Allocator) !DiffItemSource {
        const uri: std.Uri = .{
            .scheme = try arena.dupe(u8, self.uri.scheme),
            .host = if (self.uri.host != null) .{ .raw = try arena.dupe(u8, try std_uri.authority(self.uri, arena)) } else null,
            .path = .{ .raw = try arena.dupe(u8, try std_uri.path(self.uri, arena)) },
            .query = if (self.uri.query != null) .{ .raw = try arena.dupe(u8, try std_uri.query(self.uri, arena)) } else null,
            .fragment = if (self.uri.fragment != null) .{ .raw = try arena.dupe(u8, try std_uri.fragment(self.uri, arena)) } else null,
        };
        if (self.textModel) |model| model.retain();
        return .{ .uri = uri, .textModel = self.textModel };
    }

    fn release(self: DiffItemSource) void {
        if (self.textModel) |model| model.release();
    }
};

pub const IDocumentDiffItem = struct {
    allocator: Allocator,
    refs: usize = 1,
    arena: std.heap.ArenaAllocator,
    original: ?DiffItemSource,
    modified: ?DiffItemSource,
    options: Options,
    hideOriginalLineNumbers: ?bool = null,
    onOptionsDidChange: Emitter(void),

    pub fn create(allocator: Allocator, original: ?DiffItemSource, modified: ?DiffItemSource, options: Options) !*IDocumentDiffItem {
        if (original == null and modified == null) return error.MissingDiffResources;
        const self = try allocator.create(IDocumentDiffItem);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = if (original) |source| try source.copy(arena.allocator()) else null;
        errdefer if (a) |source| source.release();
        const b = if (modified) |source| try source.copy(arena.allocator()) else null;
        self.* = .{ .allocator = allocator, .arena = arena, .original = a, .modified = b, .options = options, .hideOriginalLineNumbers = if (options.hide_original_line_numbers) true else null, .onOptionsDidChange = .init(allocator) };
        return self;
    }
    pub fn retain(self: *IDocumentDiffItem) *IDocumentDiffItem {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *IDocumentDiffItem) void {
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.original) |source| source.release();
        if (self.modified) |source| source.release();
        self.onOptionsDidChange.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    pub fn setHideOriginalLineNumbers(self: *IDocumentDiffItem, value: ?bool) !void {
        if (self.hideOriginalLineNumbers == value) return;
        self.hideOriginalLineNumbers = value;
        try self.onOptionsDidChange.fire({});
    }

    pub fn updateOptions(self: *IDocumentDiffItem, options: Options) !void {
        if (std.meta.eql(self.options, options)) return;
        if (self.options.hide_original_line_numbers != options.hide_original_line_numbers) self.hideOriginalLineNumbers = options.hide_original_line_numbers;
        self.options = options;
        try self.onOptionsDidChange.fire({});
    }
};

pub const Documents = union(enum) { loading, items: []const *IDocumentDiffItem };
pub const IMultiDiffEditorModel = struct {
    context: *anyopaque,
    documents: *const fn (*anyopaque) Documents,
    on_did_change_documents: *Emitter(void),
};

/// An observable document set owned by an input or a source resolver.
pub const MultiDiffEditorModel = struct {
    allocator: Allocator,
    documents: Documents = .loading,
    on_did_change_documents: Emitter(void),

    pub fn init(allocator: Allocator) MultiDiffEditorModel {
        return .{ .allocator = allocator, .on_did_change_documents = .init(allocator) };
    }
    pub fn deinit(self: *MultiDiffEditorModel) void {
        self.releaseDocuments(self.documents);
        self.on_did_change_documents.deinit();
    }
    pub fn setDocuments(self: *MultiDiffEditorModel, documents_value: Documents) !void {
        const previous = self.documents;
        self.documents = switch (documents_value) {
            .loading => .loading,
            .items => |items| blk: {
                const owned = try self.allocator.alloc(*IDocumentDiffItem, items.len);
                for (owned, items) |*dst, src| dst.* = src.retain();
                break :blk .{ .items = owned };
            },
        };
        defer self.releaseDocuments(previous);
        try self.on_did_change_documents.fire({});
    }
    fn releaseDocuments(self: *MultiDiffEditorModel, documents_value: Documents) void {
        if (documents_value == .items) {
            for (documents_value.items) |item| item.release();
            self.allocator.free(documents_value.items);
        }
    }
    pub fn interface(self: *MultiDiffEditorModel) IMultiDiffEditorModel {
        const Adapter = struct {
            fn get(context: *anyopaque) Documents {
                const actual: *MultiDiffEditorModel = @ptrCast(@alignCast(context));
                return actual.documents;
            }
        };
        return .{ .context = self, .documents = Adapter.get, .on_did_change_documents = &self.on_did_change_documents };
    }
};
