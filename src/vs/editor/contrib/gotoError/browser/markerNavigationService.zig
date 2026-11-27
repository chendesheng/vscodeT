// Port of `src/vs/editor/contrib/gotoError/browser/markerNavigationService.ts`.
// Published marker lists own snapshots because the native marker service
// retires replaced objects after its synchronous change event.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const marker_types = @import("../../../../platform/markers/common/markers.zig");
const Marker = marker_types.Marker;
const Resource = marker_types.Resource;
const Severity = marker_types.MarkerSeverity;
const MarkerService = @import("../../../../platform/markers/common/markerService.zig").MarkerService;
const IConfigurationService = @import("../../../../platform/configuration/common/configuration.zig").IConfigurationService;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const range_mod = @import("../../../common/core/range.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const uri_util = @import("../../../../base/common/stdUri.zig");

pub const MarkerCoordinate = struct { marker: *const Marker, index: usize, total: usize };

pub fn markerRange(marker: *const Marker) Range {
    return Range.init(marker.start_line_number, marker.start_column, marker.end_line_number, marker.end_column);
}

pub fn cloneMarker(a: Allocator, marker: *const Marker) !Marker {
    var result = marker.*;
    result.owner = try a.dupe(u8, marker.owner);
    result.resource = try marker.resource.clone(a);
    result.key = try a.dupe(u8, marker.key);
    result.code = if (marker.code) |code| try a.dupe(u8, code) else null;
    result.code_target = if (marker.code_target) |target| try target.clone(a) else null;
    result.message = try a.dupe(u8, marker.message);
    result.source = if (marker.source) |source| try a.dupe(u8, source) else null;
    result.origin = if (marker.origin) |origin| try a.dupe(u8, origin) else null;
    result.tags = try a.dupe(u32, marker.tags);
    result.related_information = try marker_types.RelatedInformation.cloneAll(a, marker.related_information);
    result.retired_next = null;
    return result;
}

pub const MarkerList = struct {
    allocator: Allocator,
    marker_service: *MarkerService,
    resource_filter: ?Resource,
    resource_key: ?[]u8,
    sort_order: SortOrder,
    arena: std.heap.ArenaAllocator,
    markers: []Marker = &.{},
    next_idx: ?usize = null,
    on_did_change: Emitter(void),
    listener: ?usize = null,

    pub const SortOrder = enum { position, severity };

    pub fn create(allocator: Allocator, marker_service: *MarkerService, resource: ?Resource, sort_order: SortOrder) !*MarkerList {
        const self = try allocator.create(MarkerList);
        errdefer allocator.destroy(self);
        var filter = if (resource) |value| try value.clone(allocator) else null;
        errdefer if (filter) |*value| value.deinit(allocator);
        const key = if (filter) |value| try value.key(allocator) else null;
        errdefer if (key) |value| allocator.free(value);
        self.* = .{ .allocator = allocator, .marker_service = marker_service, .resource_filter = filter, .resource_key = key, .sort_order = sort_order, .arena = .init(allocator), .on_did_change = .init(allocator) };
        errdefer self.arena.deinit();
        errdefer self.on_did_change.deinit();
        _ = try self.updateMarkers();
        self.listener = try marker_service.on_marker_changed.listen(self, markerChanged);
        return self;
    }

    pub fn deinit(self: *MarkerList) void {
        if (self.listener) |id| self.marker_service.on_marker_changed.unlisten(id);
        self.on_did_change.deinit();
        self.arena.deinit();
        if (self.resource_filter) |*filter| filter.deinit(self.allocator);
        if (self.resource_key) |key| self.allocator.free(key);
        self.allocator.destroy(self);
    }

    fn markerChanged(event: @import("../../../../platform/markers/common/markerService.zig").MarkerChangeEvent, self: *MarkerList) !void {
        if (self.resource_key) |key| {
            for (event.resources) |resource| {
                if (std.mem.eql(u8, key, resource)) break;
            } else return;
        }
        if (try self.updateMarkers()) {
            self.resetIndex();
            try self.on_did_change.fire({});
        }
    }

    fn compareMarkers(order: SortOrder, a: *const Marker, b: *const Marker) bool {
        const resource_order = std.mem.order(u8, a.key, b.key);
        if (resource_order != .eq) return resource_order == .lt;
        const left = markerRange(a);
        const right = markerRange(b);
        const positions = range_mod.compareRangesUsingStarts(&left, &right);
        const severity = Severity.compare(a.severity, b.severity);
        return switch (order) {
            .position => if (positions != 0) positions < 0 else severity < 0,
            .severity => if (severity != 0) severity < 0 else positions < 0,
        };
    }

    fn updateMarkers(self: *MarkerList) !bool {
        const incoming = try self.marker_service.read(self.allocator, .{ .resource = self.resource_filter, .severities = Severity.Error | Severity.Warning | Severity.Info });
        defer self.allocator.free(incoming);
        std.mem.sort(*Marker, incoming, self.sort_order, struct {
            fn less(order: SortOrder, a: *Marker, b: *Marker) bool {
                return compareMarkers(order, a, b);
            }
        }.less);
        if (incoming.len == self.markers.len) {
            for (incoming, self.markers) |item, old| {
                if (!std.mem.eql(u8, item.key, old.key) or !std.meta.eql(markerRange(item), markerRange(&old)) or item.severity != old.severity or !std.mem.eql(u8, item.message, old.message)) break;
            } else return false;
        }
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const owned = try arena.allocator().alloc(Marker, incoming.len);
        for (incoming, owned) |item, *target| target.* = try cloneMarker(arena.allocator(), item);
        self.arena.deinit();
        self.arena = arena;
        self.markers = owned;
        return true;
    }

    pub fn matches(self: *const MarkerList, resource: ?[]const u8) bool {
        if (self.resource_key) |key| return if (resource) |value| std.mem.eql(u8, value, key) else false;
        return resource == null;
    }

    pub fn selected(self: *const MarkerList) ?MarkerCoordinate {
        const index = self.next_idx orelse return null;
        if (index >= self.markers.len) return null;
        return .{ .marker = &self.markers[index], .index = index + 1, .total = self.markers.len };
    }

    fn initIdx(self: *MarkerList, model: *TextModel, key: []const u8, position: Position, fwd: bool) void {
        var first: ?usize = null;
        for (self.markers, 0..) |item, index| if (std.mem.eql(u8, item.key, key)) {
            first = index;
            break;
        };
        if (first == null) {
            // Binary lower bound of the missing resource in sorted URI order.
            var low: usize = 0;
            var high = self.markers.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (std.mem.order(u8, self.markers[mid].key, key) == .lt) low = mid + 1 else high = mid;
            }
            self.next_idx = if (fwd) low else (self.markers.len + low - 1) % self.markers.len;
            return;
        }
        for (self.markers[first.?..], first.?..) |marker, index| {
            var range = markerRange(&marker);
            if (range.isEmpty()) if (model.getWordAtPosition(range.getStartPosition())) |word| {
                var owned_word = word;
                defer owned_word.deinit();
                range = Range.init(range.startLineNumber, word.startColumn, range.startLineNumber, word.endColumn);
            };
            const contains = range.containsPosition(&position);
            if (contains or position.isBeforeOrEqual(range.getStartPosition())) {
                self.next_idx = if (!contains and !fwd) (self.markers.len + index - 1) % self.markers.len else index;
                return;
            }
            if (!std.mem.eql(u8, marker.key, key)) break;
        }
        self.next_idx = if (fwd) 0 else self.markers.len - 1;
    }

    pub fn resetIndex(self: *MarkerList) void {
        self.next_idx = null;
    }

    pub fn move(self: *MarkerList, fwd: bool, model: *TextModel, position: Position) !bool {
        if (self.markers.len == 0) return false;
        const previous = self.next_idx;
        if (previous) |index| {
            self.next_idx = if (fwd) (index + 1) % self.markers.len else (index + self.markers.len - 1) % self.markers.len;
        } else {
            const key = try uri_util.resourceKey(self.allocator, model.uri());
            defer self.allocator.free(key);
            self.initIdx(model, key, position, fwd);
        }
        return previous != self.next_idx;
    }

    pub fn find(self: *const MarkerList, resource_key: []const u8, position: Position) ?MarkerCoordinate {
        var found = false;
        for (self.markers, 0..) |*marker, index| {
            if (!found) found = std.mem.eql(u8, marker.key, resource_key);
            if (found and markerRange(marker).containsPosition(&position)) return .{ .marker = marker, .index = index + 1, .total = self.markers.len };
        }
        return null;
    }
};

pub const IMarkerListProvider = struct {
    context: *anyopaque,
    get_marker_list: *const fn (*anyopaque, ?Resource) anyerror!?*MarkerList,
};

pub const IMarkerNavigationService = struct {
    context: *anyopaque,
    get_marker_list: *const fn (*anyopaque, ?Resource) anyerror!*MarkerList,
    register_provider: *const fn (*anyopaque, IMarkerListProvider) anyerror!Disposable,

    pub fn getMarkerList(self: IMarkerNavigationService, resource: ?Resource) !*MarkerList {
        return self.get_marker_list(self.context, resource);
    }
    pub fn registerProvider(self: IMarkerNavigationService, provider: IMarkerListProvider) !Disposable {
        return self.register_provider(self.context, provider);
    }
};
pub const marker_navigation_service_id = @import("../../../../platform/instantiation/common/instantiation.zig").ServiceIdentifier(IMarkerNavigationService, "IMarkerNavigationService");

pub const MarkerNavigationService = struct {
    allocator: Allocator,
    markers: *MarkerService,
    configuration: IConfigurationService,
    providers: std.ArrayList(*Registration) = .empty,

    pub fn interface(self: *MarkerNavigationService) IMarkerNavigationService {
        return .{ .context = self, .get_marker_list = getMarkerListAdapter, .register_provider = registerProviderAdapter };
    }

    fn getMarkerListAdapter(context: *anyopaque, resource: ?Resource) !*MarkerList {
        const self: *MarkerNavigationService = @ptrCast(@alignCast(context));
        return self.getMarkerList(resource);
    }
    fn registerProviderAdapter(context: *anyopaque, provider: IMarkerListProvider) !Disposable {
        const self: *MarkerNavigationService = @ptrCast(@alignCast(context));
        return self.registerProvider(provider);
    }

    const Registration = struct {
        owner: *MarkerNavigationService,
        provider: IMarkerListProvider,
        fn dispose(self: *Registration) void {
            const owner = self.owner;
            for (owner.providers.items, 0..) |entry, index| if (entry == self) {
                _ = owner.providers.orderedRemove(index);
                break;
            };
            owner.allocator.destroy(self);
        }
    };

    pub fn deinit(self: *MarkerNavigationService) void {
        while (self.providers.items.len != 0) self.providers.items[0].dispose();
        self.providers.deinit(self.allocator);
    }

    pub fn registerProvider(self: *MarkerNavigationService, provider: IMarkerListProvider) !Disposable {
        const registration = try self.allocator.create(Registration);
        errdefer self.allocator.destroy(registration);
        registration.* = .{ .owner = self, .provider = provider };
        try self.providers.insert(self.allocator, 0, registration);
        return Disposable.from(Registration, registration, Registration.dispose);
    }

    pub fn getMarkerList(self: *MarkerNavigationService, resource: ?Resource) !*MarkerList {
        for (self.providers.items) |registration| {
            const provider = registration.provider;
            if (try provider.get_marker_list(provider.context, resource)) |list| return list;
        }
        const order: MarkerList.SortOrder = if (std.mem.eql(u8, self.configuration.getString("problems.sortOrder") orelse "severity", "position")) .position else .severity;
        return MarkerList.create(self.allocator, self.markers, resource, order);
    }
};
