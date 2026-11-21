// Port of `src/vs/platform/markers/common/markerService.ts`.
//
// Terminal adaptations:
// - resources are canonical key strings plus owned components;
// - `onMarkerChanged` is synchronous (upstream's MicrotaskEmitter merges per
//   tick). `MainThreadDiagnostics` restores batching with an explicit flush;
// - `read` returns borrowed marker pointers valid until the next change. A
//   change retires removed markers and buckets and frees them only after its
//   `onMarkerChanged` listeners return, because upstream listeners may still
//   inspect the replaced markers during that event.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lifecycle = @import("../../../base/common/lifecycle.zig");
const IDisposable = lifecycle.IDisposable;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const markers = @import("markers.zig");
const Marker = markers.Marker;
const MarkerData = markers.MarkerData;
const Resource = markers.Resource;
const ReadOptions = markers.ReadOptions;
const ChangeOptions = markers.ChangeOptions;
const MarkerStatistics = markers.MarkerStatistics;

pub const MarkerChangeEvent = struct {
    /// Canonical resource keys. The slice is only valid while the event fires.
    resources: []const []const u8,
};

const Bucket = struct {
    resource: Resource,
    key: []u8,
    markers: std.array_list.Managed(*Marker),
    truncated_owners: std.StringHashMap(void),
    owners: std.StringHashMap(void),
    retired_next: ?*Bucket = null,
};

const OwnerBucket = struct {
    key: []u8,
    resources: std.StringHashMap(*Bucket),
};

const FilterState = struct {
    resource: Resource,
    key: []u8,
    reasons: std.array_list.Managed([]u8),
    marker: *Marker,
};

const FilterRegistration = struct {
    service: *MarkerService,
    state: *FilterState,
    reason: []u8,
    active: bool = true,
};

pub const MarkerService = struct {
    allocator: Allocator,
    by_resource: std.StringHashMap(*Bucket),
    by_owner: std.StringHashMap(*OwnerBucket),
    filters: std.StringHashMap(*FilterState),
    on_marker_changed: Emitter(MarkerChangeEvent),
    ext_host_id: []const u8 = "workbench",
    /// Markers and buckets removed by the current change. Upstream relies on
    /// garbage collection so a listener can still inspect the old markers
    /// while `onMarkerChanged` fires; the port keeps them on these lists and
    /// frees them only after the listeners return.
    retired_markers: ?*Marker = null,
    retired_buckets: ?*Bucket = null,

    pub fn init(allocator: Allocator) MarkerService {
        return .{
            .allocator = allocator,
            .by_resource = std.StringHashMap(*Bucket).init(allocator),
            .by_owner = std.StringHashMap(*OwnerBucket).init(allocator),
            .filters = std.StringHashMap(*FilterState).init(allocator),
            .on_marker_changed = Emitter(MarkerChangeEvent).init(allocator),
        };
    }

    pub fn deinit(self: *MarkerService) void {
        var resources = self.by_resource.valueIterator();
        while (resources.next()) |bucket_ptr| {
            self.destroyBucket(bucket_ptr.*);
        }
        self.by_resource.deinit();
        var owners = self.by_owner.valueIterator();
        while (owners.next()) |owner_ptr| {
            const owner = owner_ptr.*;
            self.allocator.free(owner.key);
            owner.resources.deinit();
            self.allocator.destroy(owner);
        }
        self.by_owner.deinit();
        var filters = self.filters.valueIterator();
        while (filters.next()) |state_ptr| self.destroyFilter(state_ptr.*);
        self.filters.deinit();
        self.releaseRetired();
        self.on_marker_changed.deinit();
    }

    fn destroyBucket(self: *MarkerService, bucket: *Bucket) void {
        for (bucket.markers.items) |marker| {
            marker.deinit(self.allocator);
            self.allocator.destroy(marker);
        }
        bucket.markers.deinit();
        bucket.truncated_owners.deinit();
        bucket.owners.deinit();
        self.allocator.free(bucket.key);
        var resource = bucket.resource;
        resource.deinit(self.allocator);
        self.allocator.destroy(bucket);
    }

    fn retireMarker(self: *MarkerService, marker: *Marker) void {
        marker.retired_next = self.retired_markers;
        self.retired_markers = marker;
    }

    fn retireBucket(self: *MarkerService, bucket: *Bucket) void {
        for (bucket.markers.items) |marker| self.retireMarker(marker);
        bucket.markers.clearRetainingCapacity();
        bucket.retired_next = self.retired_buckets;
        self.retired_buckets = bucket;
    }

    /// Frees markers and empty buckets whose event has finished firing. Any
    /// listener that retained a `read` pointer must not dereference it after
    /// `onMarkerChanged` returns, matching the `read` lifetime contract.
    fn releaseRetired(self: *MarkerService) void {
        while (self.retired_markers) |marker| {
            self.retired_markers = marker.retired_next;
            marker.retired_next = null;
            marker.deinit(self.allocator);
            self.allocator.destroy(marker);
        }
        while (self.retired_buckets) |bucket| {
            self.retired_buckets = bucket.retired_next;
            bucket.retired_next = null;
            self.destroyBucket(bucket);
        }
    }

    fn destroyFilter(self: *MarkerService, state: *FilterState) void {
        for (state.reasons.items) |reason| self.allocator.free(reason);
        state.reasons.deinit();
        state.marker.deinit(self.allocator);
        self.allocator.destroy(state.marker);
        self.allocator.free(state.key);
        var resource = state.resource;
        resource.deinit(self.allocator);
        self.allocator.destroy(state);
    }

    fn ensureOwner(self: *MarkerService, owner: []const u8) !*OwnerBucket {
        if (self.by_owner.get(owner)) |existing| return existing;
        const bucket = try self.allocator.create(OwnerBucket);
        errdefer self.allocator.destroy(bucket);
        bucket.* = .{
            .key = try self.allocator.dupe(u8, owner),
            .resources = std.StringHashMap(*Bucket).init(self.allocator),
        };
        errdefer self.allocator.free(bucket.key);
        try self.by_owner.put(bucket.key, bucket);
        return bucket;
    }

    fn ensureBucket(self: *MarkerService, resource: Resource) !*Bucket {
        const key = try resource.key(self.allocator);
        errdefer self.allocator.free(key);
        if (self.by_resource.get(key)) |existing| {
            self.allocator.free(key);
            return existing;
        }
        const bucket = try self.allocator.create(Bucket);
        errdefer self.allocator.destroy(bucket);
        bucket.* = .{
            .resource = try cloneResource(self.allocator, resource),
            .key = key,
            .markers = std.array_list.Managed(*Marker).init(self.allocator),
            .truncated_owners = std.StringHashMap(void).init(self.allocator),
            .owners = std.StringHashMap(void).init(self.allocator),
        };
        errdefer {
            var owned = bucket.resource;
            owned.deinit(self.allocator);
            bucket.markers.deinit();
            bucket.owners.deinit();
        }
        try self.by_resource.put(key, bucket);
        return bucket;
    }

    fn cloneResource(allocator: Allocator, resource: Resource) !Resource {
        return .{
            .scheme = try allocator.dupe(u8, resource.scheme),
            .authority = try allocator.dupe(u8, resource.authority),
            .path = try allocator.dupe(u8, resource.path),
            .query = try allocator.dupe(u8, resource.query),
            .fragment = try allocator.dupe(u8, resource.fragment),
        };
    }

    fn removeOwnerFromBucket(self: *MarkerService, bucket: *Bucket, owner: []const u8) void {
        var index: usize = 0;
        while (index < bucket.markers.items.len) {
            if (std.mem.eql(u8, bucket.markers.items[index].owner, owner)) {
                const marker = bucket.markers.orderedRemove(index);
                self.retireMarker(marker);
            } else {
                index += 1;
            }
        }
        _ = bucket.owners.remove(owner);
        _ = bucket.truncated_owners.remove(owner);
        // Keep the owner index consistent even when the bucket survives for
        // other owners. `maybeRemoveBucket` cannot do this later: it only sees
        // the owners still in `bucket.owners`, and this owner has just been
        // removed from that map.
        if (self.by_owner.get(owner)) |owner_bucket| {
            _ = owner_bucket.resources.remove(bucket.key);
        }
    }

    fn maybeRemoveBucket(self: *MarkerService, bucket: *Bucket) void {
        if (bucket.markers.items.len > 0) return;
        _ = self.by_resource.remove(bucket.key);
        self.retireBucket(bucket);
    }

    fn fire(self: *MarkerService, keys: []const []const u8) void {
        if (!self.on_marker_changed.hasListeners()) return;
        self.on_marker_changed.fire(.{ .resources = keys }) catch {};
    }

    pub fn changeOne(self: *MarkerService, owner: []const u8, resource: Resource, data: []const MarkerData, options: ?ChangeOptions) !void {
        const key = try resource.key(self.allocator);
        defer self.allocator.free(key);

        if (data.len == 0) {
            const bucket = self.by_resource.get(key) orelse return;
            var removed = false;
            for (bucket.markers.items) |marker| {
                if (std.mem.eql(u8, marker.owner, owner)) {
                    removed = true;
                    break;
                }
            }
            if (!removed) return;
            self.removeOwnerFromBucket(bucket, owner);
            self.maybeRemoveBucket(bucket);
            const keys = [_][]const u8{key};
            self.fire(&keys);
            self.releaseRetired();
            return;
        }

        const bucket = try self.ensureBucket(resource);
        const owner_bucket = try self.ensureOwner(owner);
        if (!bucket.owners.contains(owner)) {
            try bucket.owners.put(owner_bucket.key, {});
            try owner_bucket.resources.put(bucket.key, bucket);
        }
        self.removeOwnerFromBucket(bucket, owner);
        // Preserve the owner association removed above.
        try bucket.owners.put(owner_bucket.key, {});
        try owner_bucket.resources.put(bucket.key, bucket);
        if (options) |opts| {
            if (opts.is_truncated) try bucket.truncated_owners.put(owner_bucket.key, {}) else _ = bucket.truncated_owners.remove(owner);
        } else {
            _ = bucket.truncated_owners.remove(owner);
        }

        for (data) |item| {
            if (item.message.len == 0) continue;
            const marker = try self.createMarker(owner, bucket, item);
            try bucket.markers.append(marker);
        }

        const keys = [_][]const u8{key};
        self.fire(&keys);
        self.releaseRetired();
    }

    fn createMarker(self: *MarkerService, owner: []const u8, bucket: *Bucket, data: MarkerData) !*Marker {
        const marker = try self.allocator.create(Marker);
        errdefer self.allocator.destroy(marker);
        const tags = try self.allocator.alloc(u32, data.tags.len);
        @memcpy(tags, data.tags);
        marker.* = .{
            .owner = try self.allocator.dupe(u8, owner),
            .resource = bucket.resource,
            .key = bucket.key,
            .code = if (data.code) |value| try self.allocator.dupe(u8, value) else null,
            .code_target = if (data.code_target) |target| try target.key(self.allocator) else null,
            .severity = data.severity,
            .message = try self.allocator.dupe(u8, data.message),
            .source = if (data.source) |value| try self.allocator.dupe(u8, value) else null,
            .start_line_number = if (data.start_line_number > 0) data.start_line_number else 1,
            .start_column = if (data.start_column > 0) data.start_column else 1,
            .end_line_number = 0,
            .end_column = 0,
            .model_version_id = data.model_version_id,
            .tags = tags,
            .origin = if (data.origin) |value| try self.allocator.dupe(u8, value) else null,
        };
        marker.end_line_number = if (data.end_line_number >= marker.start_line_number) data.end_line_number else marker.start_line_number;
        marker.end_column = if (data.end_column > 0) data.end_column else marker.start_column;
        return marker;
    }

    pub fn changeAll(self: *MarkerService, owner: []const u8, data: []const markers.ResourceMarker) !void {
        var changes = std.array_list.Managed([]const u8).init(self.allocator);
        defer changes.deinit();

        if (self.by_owner.get(owner)) |owner_bucket| {
            var keys = std.array_list.Managed([]const u8).init(self.allocator);
            defer keys.deinit();
            var iterator = owner_bucket.resources.keyIterator();
            while (iterator.next()) |key_ptr| try keys.append(key_ptr.*);
            for (keys.items) |key| {
                const bucket = self.by_resource.get(key) orelse continue;
                self.removeOwnerFromBucket(bucket, owner);
                try changes.append(try self.allocator.dupe(u8, key));
                self.maybeRemoveBucket(bucket);
            }
        }

        for (data) |entry| {
            if (entry.marker.message.len == 0) continue;
            const key = try entry.resource.key(self.allocator);
            const already = for (changes.items) |changed| {
                if (std.mem.eql(u8, changed, key)) break true;
            } else false;
            if (!already) try changes.append(try self.allocator.dupe(u8, key));
            self.allocator.free(key);

            const bucket = try self.ensureBucket(entry.resource);
            const owner_bucket = try self.ensureOwner(owner);
            if (!bucket.owners.contains(owner)) {
                try bucket.owners.put(owner_bucket.key, {});
                try owner_bucket.resources.put(bucket.key, bucket);
            }
            const marker = try self.createMarker(owner, bucket, entry.marker);
            try bucket.markers.append(marker);
        }

        self.fire(changes.items);
        self.releaseRetired();
        for (changes.items) |key| self.allocator.free(key);
    }

    pub fn remove(self: *MarkerService, owner: []const u8, resources: []const Resource) !void {
        for (resources) |resource| try self.changeOne(owner, resource, &.{}, null);
    }

    pub fn isSourceTruncated(self: *MarkerService, resource: Resource) bool {
        const key = resource.key(self.allocator) catch return false;
        defer self.allocator.free(key);
        const bucket = self.by_resource.get(key) orelse return false;
        return bucket.truncated_owners.count() > 0;
    }

    pub fn getStatistics(self: *MarkerService) MarkerStatistics {
        var stats: MarkerStatistics = .{};
        var iterator = self.by_resource.valueIterator();
        while (iterator.next()) |bucket_ptr| {
            const bucket = bucket_ptr.*;
            if (isUnsupportedScheme(bucket.resource.scheme)) continue;
            for (bucket.markers.items) |marker| {
                switch (marker.severity) {
                    markers.MarkerSeverity.Error => stats.errors += 1,
                    markers.MarkerSeverity.Warning => stats.warnings += 1,
                    markers.MarkerSeverity.Info => stats.infos += 1,
                    else => stats.unknowns += 1,
                }
            }
        }
        return stats;
    }

    /// Schemes excluded from statistics and the Problems view, matching
    /// upstream `unsupportedSchemas`.
    pub fn isUnsupportedScheme(scheme: []const u8) bool {
        const unsupported = [_][]const u8{
            "inmemory", "vscode-scm", "walkThrough", "walkThroughSnippet", "vscode-chat-code-block", "vscode-terminal",
        };
        for (unsupported) |candidate| {
            if (std.mem.eql(u8, scheme, candidate)) return true;
        }
        return false;
    }

    pub fn read(self: *MarkerService, allocator: Allocator, options: ReadOptions) ![]*Marker {
        var result = std.array_list.Managed(*Marker).init(allocator);
        errdefer result.deinit();
        const take: usize = if (options.take) |value| value else 0;

        if (options.owner != null and options.resource != null) {
            const key = try options.resource.?.key(self.allocator);
            defer self.allocator.free(key);
            if (self.filters.get(key)) |state| {
                if (!options.ignore_resource_filters) {
                    try result.append(state.marker);
                    return result.toOwnedSlice();
                }
            }
            if (self.by_resource.get(key)) |bucket| {
                for (bucket.markers.items) |marker| {
                    if (!std.mem.eql(u8, marker.owner, options.owner.?)) continue;
                    if (!accept(marker, options.severities)) continue;
                    if (take > 0 and result.items.len >= take) break;
                    try result.append(marker);
                }
            }
            return result.toOwnedSlice();
        }

        if (options.resource) |resource| {
            const key = try resource.key(self.allocator);
            defer self.allocator.free(key);
            if (self.filters.get(key)) |state| {
                if (!options.ignore_resource_filters) {
                    try result.append(state.marker);
                    return result.toOwnedSlice();
                }
            }
            if (self.by_resource.get(key)) |bucket| try self.appendBucket(bucket, &result, take, options);
            return result.toOwnedSlice();
        }

        if (options.owner) |owner| {
            if (self.by_owner.get(owner)) |owner_bucket| {
                var iterator = owner_bucket.resources.valueIterator();
                while (iterator.next()) |bucket_ptr| {
                    try self.appendBucket(bucket_ptr.*, &result, take, options);
                    if (take > 0 and result.items.len >= take) break;
                }
            }
            return result.toOwnedSlice();
        }

        var iterator = self.by_resource.valueIterator();
        while (iterator.next()) |bucket_ptr| {
            const bucket = bucket_ptr.*;
            if (self.filters.get(bucket.key)) |state| {
                if (!options.ignore_resource_filters) {
                    try result.append(state.marker);
                    if (take > 0 and result.items.len >= take) break;
                    continue;
                }
            }
            try self.appendBucket(bucket, &result, take, options);
            if (take > 0 and result.items.len >= take) break;
        }
        return result.toOwnedSlice();
    }

    fn appendBucket(self: *MarkerService, bucket: *Bucket, result: *std.array_list.Managed(*Marker), take: usize, options: ReadOptions) !void {
        _ = self;
        for (bucket.markers.items) |marker| {
            if (options.owner) |owner| {
                if (!std.mem.eql(u8, marker.owner, owner)) continue;
            }
            if (!accept(marker, options.severities)) continue;
            if (take > 0 and result.items.len >= take) return;
            try result.append(marker);
        }
    }

    fn accept(marker: *Marker, severities: ?u32) bool {
        if (severities) |mask| return (mask & marker.severity) == marker.severity;
        return true;
    }

    pub fn installResourceFilter(self: *MarkerService, resource: Resource, reason: []const u8) !IDisposable {
        const key = try resource.key(self.allocator);
        errdefer self.allocator.free(key);
        var state = self.filters.get(key);
        if (state == null) {
            const created = try self.allocator.create(FilterState);
            errdefer self.allocator.destroy(created);
            created.* = .{
                .resource = try cloneResource(self.allocator, resource),
                .key = try self.allocator.dupe(u8, key),
                .reasons = std.array_list.Managed([]u8).init(self.allocator),
                .marker = try self.allocator.create(Marker),
            };
            created.marker.* = try self.createFilterMarker(created.resource, "");
            try self.filters.put(created.key, created);
            state = created;
        }
        self.allocator.free(key);
        const state_ptr = state.?;
        try state_ptr.reasons.append(try self.allocator.dupe(u8, reason));
        try self.updateFilterMessage(state_ptr);

        const registration = try self.allocator.create(FilterRegistration);
        registration.* = .{
            .service = self,
            .state = state_ptr,
            .reason = try self.allocator.dupe(u8, reason),
        };
        self.fire(&.{state_ptr.key});
        return .{ .context = registration, .disposeFn = disposeFilter };
    }

    fn createFilterMarker(self: *MarkerService, resource: Resource, message: []const u8) !Marker {
        return .{
            .owner = try self.allocator.dupe(u8, "markersFilter"),
            .resource = resource,
            .key = "",
            .severity = markers.MarkerSeverity.Info,
            .message = try self.allocator.dupe(u8, message),
            .start_line_number = 1,
            .start_column = 1,
            .end_line_number = 1,
            .end_column = 1,
            .model_version_id = null,
            .tags = try self.allocator.alloc(u32, 0),
        };
    }

    fn updateFilterMessage(self: *MarkerService, state: *FilterState) !void {
        self.allocator.free(state.marker.message);
        const count = state.reasons.items.len;
        if (count == 1) {
            state.marker.message = try std.fmt.allocPrint(self.allocator, "Problems are paused because: \"{s}\"", .{state.reasons.items[0]});
        } else {
            state.marker.message = try std.fmt.allocPrint(self.allocator, "Problems are paused because: \"{s}\" and {d} more", .{
                if (count > 0) state.reasons.items[0] else "",
                count - 1,
            });
        }
    }

    fn disposeFilter(context: *anyopaque) void {
        const registration: *FilterRegistration = @ptrCast(@alignCast(context));
        if (!registration.active) return;
        registration.active = false;
        const service = registration.service;
        const state = registration.state;
        var index: usize = 0;
        while (index < state.reasons.items.len) {
            if (std.mem.eql(u8, state.reasons.items[index], registration.reason)) {
                service.allocator.free(state.reasons.orderedRemove(index));
                break;
            }
            index += 1;
        }
        service.allocator.free(registration.reason);
        service.allocator.destroy(registration);

        if (state.reasons.items.len == 0) {
            _ = service.filters.remove(state.key);
            service.fire(&.{state.key});
            service.destroyFilter(state);
        } else {
            service.updateFilterMessage(state) catch {};
            service.fire(&.{state.key});
        }
    }

    pub fn internalStats(self: *MarkerService) struct { resources: usize, owners: usize, markers: usize } {
        var marker_count: usize = 0;
        var iterator = self.by_resource.valueIterator();
        while (iterator.next()) |bucket| marker_count += bucket.*.markers.items.len;
        return .{
            .resources = self.by_resource.count(),
            .owners = self.by_owner.count(),
            .markers = marker_count,
        };
    }
};
