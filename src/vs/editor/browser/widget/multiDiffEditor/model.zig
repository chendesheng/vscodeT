// Port of `src/vs/editor/browser/widget/multiDiffEditor/model.ts`.
// The workbench resolver supplies retained EditorDocuments and real URIs.
// An absent side is distinct from an existing binary/unresolved resource.
const std = @import("std");
const Allocator = std.mem.Allocator;
const EditorDocument = @import("../codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const Options = @import("../diffEditor/diffEditorOptions.zig").Options;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const std_uri = @import("../../../../base/common/stdUri.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");

/// Owned context-key snapshot for a multi-diff source or individual item.
pub const ContextKeys = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const contextkey.KeyValue,

    pub fn init(allocator: Allocator) ContextKeys {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .entries = &.{} };
    }
    pub fn deinit(self: *ContextKeys) void {
        self.arena.deinit();
    }
    pub fn clone(allocator: Allocator, entries: []const contextkey.KeyValue) !ContextKeys {
        var self = init(allocator);
        errdefer self.deinit();
        const a = self.arena.allocator();
        const owned = try a.alloc(contextkey.KeyValue, entries.len);
        for (entries, owned) |entry, *value| value.* = .{ .key = try a.dupe(u8, entry.key), .value = try copyValue(a, entry.value) };
        self.entries = owned;
        return self;
    }
    pub fn get(self: ContextKeys, name: []const u8) ?contextkey.ContextKeyValue {
        for (self.entries) |entry| if (std.mem.eql(u8, name, entry.key)) return entry.value;
        return null;
    }
    pub fn copyEntries(a: Allocator, entries: []const contextkey.KeyValue) ![]const contextkey.KeyValue {
        const owned = try a.alloc(contextkey.KeyValue, entries.len);
        for (entries, owned) |entry, *value| value.* = .{ .key = try a.dupe(u8, entry.key), .value = try copyValue(a, entry.value) };
        return owned;
    }
    fn copyValue(a: Allocator, value: contextkey.ContextKeyValue) Allocator.Error!contextkey.ContextKeyValue {
        return switch (value) {
            .string => |text| .{ .string = try a.dupe(u8, text) },
            .array => |values| blk: {
                const copy = try a.alloc(contextkey.ContextKeyValue, values.len);
                for (values, copy) |entry, *dst| dst.* = try copyValue(a, entry);
                break :blk .{ .array = copy };
            },
            .object => |values| blk: {
                const copy = try a.create(std.StringHashMap(contextkey.ContextKeyValue));
                copy.* = .init(a);
                var iterator = values.iterator();
                while (iterator.next()) |entry| try copy.put(try a.dupe(u8, entry.key_ptr.*), try copyValue(a, entry.value_ptr.*));
                break :blk .{ .object = copy };
            },
            else => value,
        };
    }
};

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
    context_keys: ContextKeys,
    onContextKeysDidChange: Emitter(void),

    pub fn create(allocator: Allocator, original: ?DiffItemSource, modified: ?DiffItemSource, options: Options) !*IDocumentDiffItem {
        if (original == null and modified == null) return error.MissingDiffResources;
        const self = try allocator.create(IDocumentDiffItem);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = if (original) |source| try source.copy(arena.allocator()) else null;
        errdefer if (a) |source| source.release();
        const b = if (modified) |source| try source.copy(arena.allocator()) else null;
        self.* = .{ .allocator = allocator, .arena = arena, .original = a, .modified = b, .options = options, .hideOriginalLineNumbers = explicitOriginalLineNumbers(options), .onOptionsDidChange = .init(allocator), .context_keys = .init(allocator), .onContextKeysDidChange = .init(allocator) };
        return self;
    }
    fn explicitOriginalLineNumbers(options: Options) ?bool {
        if (options.hide_original_line_numbers_override) |value| return value;
        return if (options.hide_original_line_numbers) true else null;
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
        self.onContextKeysDidChange.deinit();
        self.context_keys.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    pub fn setContextKeys(self: *IDocumentDiffItem, keys: []const contextkey.KeyValue) !void {
        const replacement = try ContextKeys.clone(self.allocator, keys);
        var previous = self.context_keys;
        self.context_keys = replacement;
        defer previous.deinit();
        try self.onContextKeysDidChange.fire({});
    }
    pub fn setHideOriginalLineNumbers(self: *IDocumentDiffItem, value: ?bool) !void {
        if (self.hideOriginalLineNumbers == value) return;
        self.hideOriginalLineNumbers = value;
        try self.onOptionsDidChange.fire({});
    }

    pub fn updateOptions(self: *IDocumentDiffItem, options: Options) !void {
        if (std.meta.eql(self.options, options)) return;
        if (explicitOriginalLineNumbers(self.options) != explicitOriginalLineNumbers(options)) self.hideOriginalLineNumbers = explicitOriginalLineNumbers(options);
        self.options = options;
        try self.onOptionsDidChange.fire({});
    }
};

pub const Documents = union(enum) { loading, items: []const *IDocumentDiffItem };
pub const IMultiDiffEditorModel = struct {
    context: *anyopaque,
    documents: *const fn (*anyopaque) Documents,
    on_did_change_documents: *Emitter(void),
    get_context_key: ?*const fn (*anyopaque, []const u8) ?contextkey.ContextKeyValue = null,
    on_did_change_context_keys: ?*Emitter(void) = null,

    pub fn getContextKey(self: IMultiDiffEditorModel, key: []const u8) ?contextkey.ContextKeyValue {
        return if (self.get_context_key) |get| get(self.context, key) else null;
    }
};

/// An observable document set owned by an input or a source resolver.
pub const MultiDiffEditorModel = struct {
    allocator: Allocator,
    documents: Documents = .loading,
    on_did_change_documents: Emitter(void),
    context_keys: ContextKeys,
    on_did_change_context_keys: Emitter(void),

    pub fn init(allocator: Allocator) MultiDiffEditorModel {
        return .{ .allocator = allocator, .on_did_change_documents = .init(allocator), .context_keys = .init(allocator), .on_did_change_context_keys = .init(allocator) };
    }
    pub fn deinit(self: *MultiDiffEditorModel) void {
        self.releaseDocuments(self.documents);
        self.on_did_change_documents.deinit();
        self.context_keys.deinit();
        self.on_did_change_context_keys.deinit();
    }
    pub fn setContextKeys(self: *MultiDiffEditorModel, keys: []const contextkey.KeyValue) !void {
        const replacement = try ContextKeys.clone(self.allocator, keys);
        var previous = self.context_keys;
        self.context_keys = replacement;
        defer previous.deinit();
        try self.on_did_change_context_keys.fire({});
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
    /// Takes ownership of the allocation, retaining each document. Publication
    /// itself cannot fail before the new list has been installed.
    pub fn setOwnedDocuments(self: *MultiDiffEditorModel, items: []*IDocumentDiffItem) !void {
        for (items) |item| _ = item.retain();
        const previous = self.documents;
        self.documents = .{ .items = items };
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
            fn key(context: *anyopaque, name: []const u8) ?contextkey.ContextKeyValue {
                const actual: *MultiDiffEditorModel = @ptrCast(@alignCast(context));
                return actual.context_keys.get(name);
            }
        };
        return .{ .context = self, .documents = Adapter.get, .on_did_change_documents = &self.on_did_change_documents, .get_context_key = Adapter.key, .on_did_change_context_keys = &self.on_did_change_context_keys };
    }
};
