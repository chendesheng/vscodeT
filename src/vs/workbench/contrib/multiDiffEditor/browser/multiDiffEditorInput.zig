// Port of `src/vs/workbench/contrib/multiDiffEditor/browser/multiDiffEditorInput.ts`.
// The input owns the resolved resource references and its lazily created
// MultiDiffEditorViewModel. Native file inputs provide shared working-copy
// save, revert and dirty events; resource-only/binary entries have no file
// input. Resolution callbacks publish a complete document set atomically.
const std = @import("std");
const Allocator = std.mem.Allocator;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const editor_input = @import("../../../common/editor/editorInput.zig");
const editor_common = @import("../../../common/editor.zig");
const SideInput = @import("../../../browser/parts/editor/textDiffEditor.zig").SideInput;
const model = @import("../../../../editor/browser/widget/multiDiffEditor/model.zig");
const view_model = @import("../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorViewModel.zig");
const DiffOptions = @import("../../../../editor/browser/widget/diffEditor/diffEditorOptions.zig").Options;
const source_mod = @import("multiDiffSourceResolverService.zig");
const SignalSubscription = @import("../../../../base/common/event.zig").SignalSubscription;
const std_uri = @import("../../../../base/common/stdUri.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");

pub const ID = "workbench.input.multiDiffEditor";
pub const ResolvedSide = struct {
    uri: std.Uri,
    input: ?SideInput = null,
};
pub const ResolvedItem = struct {
    original: ?ResolvedSide = null,
    modified: ?ResolvedSide = null,
    go_to_file_uri: ?std.Uri = null,
    go_to_file_title: ?[]const u8 = null,
    options: DiffOptions = .{},
};

pub const MultiDiffEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    source_uri: []u8,
    label: []u8,
    has_explicit_label: bool,
    name: []u8,
    is_transient: bool,
    document_set: model.MultiDiffEditorModel,
    vm: ?*view_model.MultiDiffEditorViewModel = null,
    entries: []Entry = &.{},
    refs: usize = 1,
    source_binding: ?SourceBinding = null,
    resolved_source: ?source_mod.IResolvedMultiDiffSource = null,
    source_resources_listener: ?SignalSubscription = null,
    source_label_listener: ?SignalSubscription = null,
    resolved_label: ?[]u8 = null,
    resolved_resource_count: ?usize = null,
    initial_resources_arena: ?std.heap.ArenaAllocator = null,
    initial_resources: ?[]const source_mod.MultiDiffEditorItem = null,

    pub const SourceBinding = struct {
        context: *anyopaque,
        resolve_resources: *const fn (*anyopaque, []const source_mod.MultiDiffEditorItem) anyerror!void,
        report_failure: ?*const fn (*anyopaque, anyerror) void = null,
        dispose: *const fn (*anyopaque) void,
    };

    /// The input owns the resolved source and subscribes to both its resource
    /// and label observables. Native text resolution is a separate callback.
    /// Consumes the source and binding on success or failure.
    pub fn attachResolvedSource(self: *MultiDiffEditorInput, source: source_mod.IResolvedMultiDiffSource, binding: SourceBinding) !void {
        self.detachSource();
        self.source_binding = binding;
        self.resolved_source = source;
        errdefer self.detachSource();
        self.source_resources_listener = try source.on_did_change_resources.listenDisposable(self, onSourceResourcesChanged);
        if (source.on_did_change_label) |changed| self.source_label_listener = try changed.listenDisposable(self, onSourceLabelChanged);
        try self.publishSourceResources();
    }

    pub fn detachSource(self: *MultiDiffEditorInput) void {
        if (self.source_resources_listener) |listener| listener.dispose();
        if (self.source_label_listener) |listener| listener.dispose();
        self.source_resources_listener = null;
        self.source_label_listener = null;
        if (self.source_binding) |binding| {
            self.source_binding = null;
            binding.dispose(binding.context);
        }
        if (self.resolved_source) |source| {
            self.resolved_source = null;
            source.dispose(source.context);
        }
    }

    fn onSourceResourcesChanged(_: void, self: *MultiDiffEditorInput) !void {
        self.publishSourceResources() catch |err| {
            if (self.source_binding) |binding| if (binding.report_failure) |report| report(binding.context, err);
        };
    }
    fn onSourceLabelChanged(_: void, self: *MultiDiffEditorInput) !void {
        try self.updateSourceName();
    }
    fn publishSourceResources(self: *MultiDiffEditorInput) !void {
        const source = self.resolved_source orelse return;
        if (!source.isReady()) return;
        if (source.failure()) |failure| return failure;
        try self.updateSourceName();
        const binding = self.source_binding orelse return;
        try binding.resolve_resources(binding.context, source.resources(source.context));
    }

    fn formatName(self: *const MultiDiffEditorInput, label: []const u8, count: ?usize) ![]u8 {
        if (count) |number| return std.fmt.allocPrint(self.allocator, "{s} ({d} {s})", .{ label, number, if (number == 1) "file" else "files" });
        return self.allocator.dupe(u8, label);
    }
    fn updateSourceName(self: *MultiDiffEditorInput) !void {
        const source = self.resolved_source orelse return;
        if (!source.isReady()) return;
        const count = source.resources(source.context).len;
        const label = if (source.label) |get| try self.allocator.dupe(u8, get(source.context)) else null;
        errdefer if (label) |name| self.allocator.free(name);
        const name = try self.formatName(label orelse self.label, count);
        if (self.resolved_label) |previous| self.allocator.free(previous);
        self.resolved_label = label;
        self.resolved_resource_count = count;
        if (std.mem.eql(u8, name, self.name)) {
            self.allocator.free(name);
            return;
        }
        const previous = self.name;
        self.name = name;
        self.base.name = name;
        defer self.allocator.free(previous);
        self.base.fireLabel() catch {};
    }

    pub const Entry = struct {
        item: *model.IDocumentDiffItem,
        original: ?SideInput = null,
        modified: ?SideInput = null,
        go_to_file_uri: ?[]u8 = null,
        go_to_file_title: ?[]u8 = null,
        original_dirty: ?SignalSubscription = null,
        modified_dirty: ?SignalSubscription = null,

        fn release(self: *Entry, allocator: Allocator) void {
            if (self.original_dirty) |subscription| subscription.dispose();
            if (self.modified_dirty) |subscription| subscription.dispose();
            self.item.release();
            if (self.original) |input| input.destroy();
            if (self.modified) |input| input.destroy();
            if (self.go_to_file_uri) |key| allocator.free(key);
            if (self.go_to_file_title) |title| allocator.free(title);
        }
    };
    pub fn create(allocator: Allocator, source_uri: []const u8, label: ?[]const u8, transient: bool) !*MultiDiffEditorInput {
        const self = try allocator.create(MultiDiffEditorInput);
        errdefer allocator.destroy(self);
        const uri = try allocator.dupe(u8, source_uri);
        errdefer allocator.free(uri);
        const owned_label = try allocator.dupe(u8, label orelse "Multi Diff Editor");
        errdefer allocator.free(owned_label);
        const name = try allocator.dupe(u8, owned_label);
        errdefer allocator.free(name);
        self.* = .{
            .allocator = allocator,
            .base = EditorInput.init(allocator, ID),
            .source_uri = uri,
            .label = owned_label,
            .has_explicit_label = label != null,
            .name = name,
            .is_transient = transient,
            .document_set = .init(allocator),
        };
        self.base.impl = self;
        self.base.resource = self.source_uri;
        self.base.name = self.name;
        self.base.editor_id = "default";
        self.base.capabilities = editor_common.EditorInputCapabilities.Readonly;
        self.base.matches_fn = matches;
        self.base.is_dirty_fn = isDirty;
        self.base.save_fn = save;
        self.base.revert_fn = revert;
        self.base.close_handler = .{ .context = self, .show_confirm = showConfirm };
        return self;
    }
    pub fn setInitialResources(self: *MultiDiffEditorInput, source_resources: []const source_mod.MultiDiffEditorItem) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const copy = try source_mod.StaticResolvedMultiDiffSource.cloneItems(arena.allocator(), source_resources);
        if (self.initial_resources_arena) |*old| old.deinit();
        self.initial_resources_arena = arena;
        self.initial_resources = copy;
    }

    pub fn resolveSource(self: *MultiDiffEditorInput, resolver: source_mod.IMultiDiffSourceResolverService) !source_mod.IResolvedMultiDiffSource {
        if (self.initial_resources) |resources| return source_mod.StaticResolvedMultiDiffSource.create(self.allocator, resources);
        return (try resolver.resolve(try std.Uri.parse(self.source_uri))) orelse try source_mod.StaticResolvedMultiDiffSource.create(self.allocator, &.{});
    }

    pub fn retain(self: *MultiDiffEditorInput) *MultiDiffEditorInput {
        self.refs += 1;
        return self;
    }
    pub fn destroy(self: *MultiDiffEditorInput) void {
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        self.detachSource();
        if (self.initial_resources_arena) |*arena| arena.deinit();
        self.base.dispose();
        if (self.vm) |value| value.destroy();
        self.document_set.deinit();
        self.releaseEntries(self.entries);
        self.base.deinit();
        self.allocator.free(self.source_uri);
        self.allocator.free(self.label);
        if (self.resolved_label) |name| self.allocator.free(name);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
    pub fn interface(self: *MultiDiffEditorInput) *EditorInput {
        return &self.base;
    }
    fn showConfirm(_: *anyopaque) bool {
        return false;
    }
    fn matches(base: *EditorInput, other: *EditorInput) bool {
        if (base == other) return true;
        if (!std.mem.eql(u8, other.type_id, ID)) return false;
        const self: *MultiDiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        const candidate: *MultiDiffEditorInput = @ptrCast(@alignCast(other.impl.?));
        return std.mem.eql(u8, self.source_uri, candidate.source_uri);
    }
    pub fn is(base: *EditorInput) ?*MultiDiffEditorInput {
        if (!std.mem.eql(u8, base.type_id, ID)) return null;
        return @ptrCast(@alignCast(base.impl.?));
    }
    pub fn getViewModel(self: *MultiDiffEditorInput, io: std.Io, queue: *dispatch.Queue, worker: ?view_model.WorkerServices) !*view_model.MultiDiffEditorViewModel {
        if (self.vm) |value| return value;
        self.vm = try view_model.MultiDiffEditorViewModel.create(self.allocator, io, self.document_set.interface(), queue, worker);
        return self.vm.?;
    }
    fn sideInput(source: ?ResolvedSide) ?SideInput {
        if (source) |value| if (value.input) |input| return switch (input) {
            .file => |file| .{ .file = file.retain() },
            .resource => |resource| .{ .resource = resource.retain() },
        };
        return null;
    }
    fn diffSource(source: ?ResolvedSide) ?model.DiffItemSource {
        const value = source orelse return null;
        return .{ .uri = value.uri, .textModel = if (value.input) |input| input.resolve() else null };
    }
    fn itemKey(allocator: Allocator, original: ?model.DiffItemSource, modified: ?model.DiffItemSource) ![]u8 {
        const resource: source_mod.MultiDiffEditorItem = .{
            .originalUri = if (original) |value| value.uri else null,
            .modifiedUri = if (modified) |value| value.uri else null,
        };
        return resource.getKey(allocator);
    }
    fn sameDocument(a: ?model.DiffItemSource, b: ?model.DiffItemSource) bool {
        const previous = a orelse return b == null;
        const next = b orelse return false;
        return previous.textModel == next.textModel;
    }
    fn createEntry(self: *MultiDiffEditorInput, value: ResolvedItem, existing: ?*model.IDocumentDiffItem) !Entry {
        const a = sideInput(value.original);
        errdefer if (a) |input| input.destroy();
        const b = sideInput(value.modified);
        errdefer if (b) |input| input.destroy();
        var options = value.options;
        options.original_editable = if (a) |input| !input.interface().isReadonly() else false;
        options.read_only = if (b) |input| input.interface().isReadonly() else true;
        const item = if (existing) |previous| previous.retain() else try model.IDocumentDiffItem.create(self.allocator, diffSource(value.original), diffSource(value.modified), options);
        errdefer item.release();
        const go_to = if (value.go_to_file_uri) |uri| try std.fmt.allocPrint(self.allocator, "{f}", .{uri}) else null;
        errdefer if (go_to) |key| self.allocator.free(key);
        const title = if (value.go_to_file_title) |name| try self.allocator.dupe(u8, name) else null;
        errdefer if (title) |name| self.allocator.free(name);
        const original_dirty = if (a) |input| try input.interface().on_did_change_dirty.listenDisposable(self, onSideDirty) else null;
        errdefer if (original_dirty) |subscription| subscription.dispose();
        const modified_dirty = if (b) |input| try input.interface().on_did_change_dirty.listenDisposable(self, onSideDirty) else null;
        errdefer if (modified_dirty) |subscription| subscription.dispose();
        if (existing != null) try item.updateOptions(options);
        return .{ .item = item, .original = a, .modified = b, .go_to_file_uri = go_to, .go_to_file_title = title, .original_dirty = original_dirty, .modified_dirty = modified_dirty };
    }
    pub const FoundItem = struct { entry: *const Entry, is_original: bool };
    pub fn findDocumentDiffItem(self: *const MultiDiffEditorInput, uri: std.Uri) !?FoundItem {
        const key = try std_uri.resourceKey(self.allocator, uri);
        defer self.allocator.free(key);
        for (self.entries) |*entry| {
            for ([_]?model.DiffItemSource{ entry.item.modified, entry.item.original }, 0..) |maybe_side, index| {
                const side = maybe_side orelse continue;
                const side_key = try std_uri.resourceKey(self.allocator, side.uri);
                defer self.allocator.free(side_key);
                if (std.mem.eql(u8, key, side_key)) return .{ .entry = entry, .is_original = index == 1 };
            }
        }
        return null;
    }

    fn releaseEntries(self: *MultiDiffEditorInput, entries: []Entry) void {
        for (entries) |*entry| entry.release(self.allocator);
        self.allocator.free(entries);
    }
    pub fn setResolvedItems(self: *MultiDiffEditorInput, values: []const ResolvedItem) !void {
        const entries = try self.allocator.alloc(Entry, values.len);
        var count: usize = 0;
        var adopted = false;
        errdefer if (!adopted) {
            for (entries[0..count]) |*entry| entry.release(self.allocator);
            self.allocator.free(entries);
        };
        const documents = try self.allocator.alloc(*model.IDocumentDiffItem, values.len);
        errdefer if (!adopted) self.allocator.free(documents);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var cache: std.StringHashMap(std.ArrayList(*model.IDocumentDiffItem)) = .init(a);
        for (self.entries) |previous| {
            const key = try itemKey(a, previous.item.original, previous.item.modified);
            const bucket = try cache.getOrPut(key);
            if (!bucket.found_existing) bucket.value_ptr.* = .empty;
            try bucket.value_ptr.append(a, previous.item);
        }
        for (values, entries, documents) |value, *entry, *document| {
            var existing: ?*model.IDocumentDiffItem = null;
            const original = diffSource(value.original);
            const modified = diffSource(value.modified);
            if (cache.getPtr(try itemKey(a, original, modified))) |bucket| {
                for (bucket.items, 0..) |previous, index| {
                    if (sameDocument(previous.original, original) and sameDocument(previous.modified, modified)) {
                        existing = previous;
                        _ = bucket.orderedRemove(index);
                        break;
                    }
                }
            }
            entry.* = try self.createEntry(value, existing);
            count += 1;
            document.* = entry.item;
        }
        const name = try self.formatName(self.resolved_label orelse self.label, self.resolved_resource_count orelse entries.len);
        const previous = self.entries;
        const previous_name = self.name;
        self.entries = entries;
        self.name = name;
        self.base.name = name;
        adopted = true;
        defer {
            self.releaseEntries(previous);
            self.allocator.free(previous_name);
        }
        try self.document_set.setOwnedDocuments(documents);
        if (!std.mem.eql(u8, previous_name, name)) try self.base.fireLabel();
        try self.base.fireDirty();
    }
    fn onSideDirty(_: void, self: *MultiDiffEditorInput) !void {
        try self.base.fireDirty();
    }
    fn isDirty(base: *const EditorInput) bool {
        const self: *const MultiDiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        for (self.entries) |entry| {
            if (entry.original) |input| if (input.interface().isDirty()) return true;
            if (entry.modified) |input| if (input.interface().isDirty()) return true;
        }
        return false;
    }
    fn save(base: *EditorInput, group: editor_input.GroupIdentifier) !editor_input.SaveResult {
        const self: *MultiDiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        for (self.entries) |entry| {
            if (entry.original) |input| if (input.fileInput() != null and input.interface().isDirty()) {
                _ = try input.interface().save(group);
            };
            if (entry.modified) |input| if (input.fileInput() != null and input.interface().isDirty()) {
                _ = try input.interface().save(group);
            };
        }
        return base;
    }
    fn revert(base: *EditorInput, group: editor_input.GroupIdentifier) !void {
        const self: *MultiDiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        for (self.entries) |entry| {
            if (entry.original) |input| if (input.fileInput() != null and input.interface().isDirty()) try input.interface().revert(group);
            if (entry.modified) |input| if (input.fileInput() != null and input.interface().isDirty()) try input.interface().revert(group);
        }
    }
    pub fn getResourceItems(self: *MultiDiffEditorInput, allocator: Allocator) ![]source_mod.MultiDiffEditorItem {
        const result = try allocator.alloc(source_mod.MultiDiffEditorItem, self.entries.len);
        for (self.entries, result) |entry, *value| value.* = .{
            .originalUri = if (entry.item.original) |source| source.uri else null,
            .modifiedUri = if (entry.item.modified) |source| source.uri else null,
        };
        return result;
    }
};

/// Port of MultiDiffEditorSerializer. Only the original resource declaration
/// is persisted, never the resolved contents or live SCM resource snapshot.
pub const MultiDiffEditorSerializer = struct {
    allocator: Allocator,
    const factory = @import("../../../common/editor/editorFactory.zig");
    const SerializedResource = struct {
        originalUri: ?[]const u8 = null,
        modifiedUri: ?[]const u8 = null,
        goToFileUri: ?[]const u8 = null,
    };
    const SerializedInput = struct {
        multiDiffSourceUri: []const u8,
        label: ?[]const u8 = null,
        resources: ?[]const SerializedResource = null,
    };

    pub fn init(allocator: Allocator) MultiDiffEditorSerializer {
        return .{ .allocator = allocator };
    }
    pub fn interface(self: *MultiDiffEditorSerializer) factory.IEditorSerializer {
        return .{ .context = self, .canSerialize = canSerialize, .serialize = serialize, .deserialize = deserialize, .discard_deserialized = discard };
    }
    fn canSerialize(_: *anyopaque, base: *EditorInput) bool {
        const input = MultiDiffEditorInput.is(base) orelse return false;
        return !input.is_transient;
    }
    fn encodeUri(allocator: Allocator, uri: ?std.Uri) !?[]const u8 {
        return if (uri) |value| try std.fmt.allocPrint(allocator, "{f}", .{value}) else null;
    }
    fn serialize(context: *anyopaque, base: *EditorInput, allocator: Allocator) !?[]const u8 {
        if (!canSerialize(context, base)) return null;
        const input = MultiDiffEditorInput.is(base).?;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const resources: ?[]const SerializedResource = if (input.initial_resources) |items| blk: {
            const values = try a.alloc(SerializedResource, items.len);
            for (items, values) |item, *value| {
                value.* = .{
                    .originalUri = try encodeUri(a, item.originalUri),
                    .modifiedUri = try encodeUri(a, item.modifiedUri),
                    .goToFileUri = try encodeUri(a, item.goToFileUri),
                };
            }
            break :blk values;
        } else null;
        return try std.json.Stringify.valueAlloc(allocator, SerializedInput{ .multiDiffSourceUri = input.source_uri, .label = if (input.has_explicit_label) input.label else null, .resources = resources }, .{ .emit_null_optional_fields = false });
    }
    fn decodeUri(value: ?[]const u8) !?std.Uri {
        return if (value) |encoded| try std.Uri.parse(encoded) else null;
    }
    fn deserialize(context: *anyopaque, data: []const u8) !?*EditorInput {
        const self: *MultiDiffEditorSerializer = @ptrCast(@alignCast(context));
        const parsed = std.json.parseFromSlice(SerializedInput, self.allocator, data, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        const value = parsed.value;
        _ = std.Uri.parse(value.multiDiffSourceUri) catch return null;
        const input = try MultiDiffEditorInput.create(self.allocator, value.multiDiffSourceUri, value.label, false);
        var owned = true;
        defer if (owned) input.destroy();
        if (value.resources) |resources| {
            const items = try self.allocator.alloc(source_mod.MultiDiffEditorItem, resources.len);
            defer self.allocator.free(items);
            for (resources, items) |resource, *item| {
                item.* = .{
                    .originalUri = decodeUri(resource.originalUri) catch return null,
                    .modifiedUri = decodeUri(resource.modifiedUri) catch return null,
                    .goToFileUri = decodeUri(resource.goToFileUri) catch return null,
                };
                item.validate() catch return null;
            }
            try input.setInitialResources(items);
        }
        owned = false;
        return input.interface();
    }
    fn discard(_: *anyopaque, base: *EditorInput) void {
        if (MultiDiffEditorInput.is(base)) |input| input.destroy();
    }
};
