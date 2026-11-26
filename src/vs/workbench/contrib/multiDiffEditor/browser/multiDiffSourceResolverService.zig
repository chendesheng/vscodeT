// Port of `src/vs/workbench/contrib/multiDiffEditor/browser/multiDiffSourceResolverService.ts`.
// Resolvers expose ordered resource changes through the same event contract;
// native text resolution is a separate input/model operation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const std_uri = @import("../../../../base/common/stdUri.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const ModelContextKeys = @import("../../../../editor/browser/widget/multiDiffEditor/model.zig").ContextKeys;
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");

pub const multi_diff_source_resolver_service_id = instantiation.ServiceIdentifier(IMultiDiffSourceResolverService, "multiDiffSourceResolverService");

pub const MultiDiffEditorItem = struct {
    originalUri: ?std.Uri = null,
    modifiedUri: ?std.Uri = null,
    goToFileUri: ?std.Uri = null,
    goToFileEditorTitle: ?[]const u8 = null,
    contextKeys: []const contextkey.KeyValue = &.{},

    pub fn validate(self: MultiDiffEditorItem) !void {
        if (self.originalUri == null and self.modifiedUri == null) return error.MissingDiffResources;
    }
    pub fn getKey(self: MultiDiffEditorItem, allocator: Allocator) ![]u8 {
        try self.validate();
        const modified = if (self.modifiedUri) |uri| try std_uri.resourceKey(allocator, uri) else null;
        defer if (modified) |key| allocator.free(key);
        const original = if (self.originalUri) |uri| try std_uri.resourceKey(allocator, uri) else null;
        defer if (original) |key| allocator.free(key);
        return std.json.Stringify.valueAlloc(allocator, [2]?[]const u8{ modified, original }, .{});
    }
};

pub const IResolvedMultiDiffSource = struct {
    context: *anyopaque,
    resources: *const fn (*anyopaque) []const MultiDiffEditorItem,
    on_did_change_resources: *Emitter(void),
    label: ?*const fn (*anyopaque) []const u8 = null,
    on_did_change_label: ?*Emitter(void) = null,
    /// A pending source is returned immediately; completion is delivered by
    /// on_did_change_resources even for an empty initial resource set.
    is_ready: ?*const fn (*anyopaque) bool = null,
    get_failure: ?*const fn (*anyopaque) ?anyerror = null,
    get_context_keys: ?*const fn (*anyopaque) ContextKeys = null,
    dispose: *const fn (*anyopaque) void,

    pub const ContextKeys = struct {
        scmResourceGroup: ?[]const u8 = null,
        scmProvider: ?[]const u8 = null,
        additional: []const contextkey.KeyValue = &.{},
        pub fn pairs(self: ContextKeys, allocator: Allocator) ![]contextkey.KeyValue {
            const count = self.additional.len + @as(usize, @intFromBool(self.scmResourceGroup != null)) + @as(usize, @intFromBool(self.scmProvider != null));
            const result = try allocator.alloc(contextkey.KeyValue, count);
            @memcpy(result[0..self.additional.len], self.additional);
            var index = self.additional.len;
            if (self.scmResourceGroup) |group| {
                result[index] = .{ .key = "scmResourceGroup", .value = .{ .string = group } };
                index += 1;
            }
            if (self.scmProvider) |provider| result[index] = .{ .key = "scmProvider", .value = .{ .string = provider } };
            return result;
        }
    };
    pub fn isReady(self: IResolvedMultiDiffSource) bool {
        return if (self.is_ready) |ready| ready(self.context) else true;
    }
    pub fn failure(self: IResolvedMultiDiffSource) ?anyerror {
        return if (self.get_failure) |get| get(self.context) else null;
    }
};

pub const IMultiDiffSourceResolver = struct {
    context: *anyopaque,
    can_handle_uri: *const fn (*anyopaque, std.Uri) bool,
    resolve_diff_source: *const fn (*anyopaque, std.Uri) anyerror!IResolvedMultiDiffSource,
};

pub const IMultiDiffSourceResolverService = struct {
    context: *anyopaque,
    register_resolver: *const fn (*anyopaque, IMultiDiffSourceResolver) anyerror!Registration,
    resolve_fn: *const fn (*anyopaque, std.Uri) anyerror!?IResolvedMultiDiffSource,

    pub fn registerResolver(self: IMultiDiffSourceResolverService, resolver: IMultiDiffSourceResolver) !Registration {
        return self.register_resolver(self.context, resolver);
    }
    pub fn resolve(self: IMultiDiffSourceResolverService, uri: std.Uri) !?IResolvedMultiDiffSource {
        return self.resolve_fn(self.context, uri);
    }
};

pub const Registration = struct {
    service: *MultiDiffSourceResolverService,
    id: usize,
    pub fn dispose(self: Registration) void {
        for (self.service.resolvers.items, 0..) |entry, i| {
            if (entry.id == self.id) {
                _ = self.service.resolvers.orderedRemove(i);
                return;
            }
        }
    }
};

pub const MultiDiffSourceResolverService = struct {
    allocator: Allocator,
    resolvers: std.ArrayList(Entry) = .empty,
    next_id: usize = 0,
    const Entry = struct { id: usize, resolver: IMultiDiffSourceResolver };

    pub fn init(allocator: Allocator) MultiDiffSourceResolverService {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *MultiDiffSourceResolverService) void {
        self.resolvers.deinit(self.allocator);
    }
    pub fn registerResolver(self: *MultiDiffSourceResolverService, resolver: IMultiDiffSourceResolver) !Registration {
        for (self.resolvers.items) |entry| {
            if (entry.resolver.context == resolver.context and entry.resolver.resolve_diff_source == resolver.resolve_diff_source) return error.DuplicateResolver;
        }
        const id = self.next_id;
        self.next_id += 1;
        try self.resolvers.append(self.allocator, .{ .id = id, .resolver = resolver });
        return .{ .service = self, .id = id };
    }
    pub fn resolve(self: *MultiDiffSourceResolverService, uri: std.Uri) !?IResolvedMultiDiffSource {
        for (self.resolvers.items) |entry| {
            const resolver = entry.resolver;
            if (resolver.can_handle_uri(resolver.context, uri)) return try resolver.resolve_diff_source(resolver.context, uri);
        }
        return null;
    }
    pub fn interface(self: *MultiDiffSourceResolverService) IMultiDiffSourceResolverService {
        const Adapter = struct {
            fn register(context: *anyopaque, resolver: IMultiDiffSourceResolver) !Registration {
                const actual: *MultiDiffSourceResolverService = @ptrCast(@alignCast(context));
                return actual.registerResolver(resolver);
            }
            fn resolveUri(context: *anyopaque, uri: std.Uri) !?IResolvedMultiDiffSource {
                const actual: *MultiDiffSourceResolverService = @ptrCast(@alignCast(context));
                return actual.resolve(uri);
            }
        };
        return .{ .context = self, .register_resolver = Adapter.register, .resolve_fn = Adapter.resolveUri };
    }
};

pub const StaticResolvedMultiDiffSource = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    items: []const MultiDiffEditorItem,
    changed: Emitter(void),

    pub fn cloneItems(arena: Allocator, items: []const MultiDiffEditorItem) ![]const MultiDiffEditorItem {
        const copy = try arena.alloc(MultiDiffEditorItem, items.len);
        for (copy, items) |*dst, src| {
            try src.validate();
            dst.* = .{
                .originalUri = try cloneUri(arena, src.originalUri),
                .modifiedUri = try cloneUri(arena, src.modifiedUri),
                .goToFileUri = try cloneUri(arena, src.goToFileUri),
                .goToFileEditorTitle = if (src.goToFileEditorTitle) |title| try arena.dupe(u8, title) else null,
                .contextKeys = try ModelContextKeys.copyEntries(arena, src.contextKeys),
            };
        }
        return copy;
    }
    fn cloneUri(arena: Allocator, value: ?std.Uri) !?std.Uri {
        const uri = value orelse return null;
        return try std.Uri.parse(try std_uri.encodedResource(arena, uri));
    }
    pub fn create(allocator: Allocator, items: []const MultiDiffEditorItem) !IResolvedMultiDiffSource {
        const self = try allocator.create(StaticResolvedMultiDiffSource);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const copy = try cloneItems(arena.allocator(), items);
        self.* = .{ .allocator = allocator, .arena = arena, .items = copy, .changed = Emitter(void).init(allocator) };
        return self.interface();
    }
    fn resources(context: *anyopaque) []const MultiDiffEditorItem {
        const self: *StaticResolvedMultiDiffSource = @ptrCast(@alignCast(context));
        return self.items;
    }
    fn dispose(context: *anyopaque) void {
        const self: *StaticResolvedMultiDiffSource = @ptrCast(@alignCast(context));
        self.changed.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    pub fn interface(self: *StaticResolvedMultiDiffSource) IResolvedMultiDiffSource {
        return .{ .context = self, .resources = resources, .on_did_change_resources = &self.changed, .dispose = dispose };
    }
};
