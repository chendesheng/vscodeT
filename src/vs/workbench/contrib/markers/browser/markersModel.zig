// Port of `src/vs/workbench/contrib/markers/browser/markersModel.ts`.
//
// Terminal adaptation: the model borrows the `Marker` records owned by
// `MarkerService` (valid until the next marker change) and rebuilds the grouped
// view from `read()` on each refresh. Upstream owns copies of its `IMarker`
// objects; the terminal avoids a second allocation/ownership layer. Marker
// records are therefore never retained across a refresh. Related information is
// not part of the platform marker port, so the tree/table related-information
// nodes are omitted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const markers = @import("../../../../platform/markers/common/markers.zig");
const MarkerService = @import("../../../../platform/markers/common/markerService.zig").MarkerService;
const common = @import("../common/markers.zig");

pub const ResourceMarkers = struct {
    allocator: Allocator,
    /// Fragment-insensitive comparison key. Owned by this group.
    key: []u8,
    /// Resource used to open a marker. The components are borrowed from the
    /// first marker of the group for the lifetime of this refresh.
    resource: markers.Resource,
    /// Display path and basename, borrowed from `resource.path`.
    path: []const u8,
    name: []const u8,
    markers: std.array_list.Managed(*markers.Marker),

    pub fn init(
        allocator: Allocator,
        key: []u8,
        resource: markers.Resource,
        path: []const u8,
    ) ResourceMarkers {
        var stripped = resource;
        stripped.fragment = "";
        return .{
            .allocator = allocator,
            .key = key,
            .resource = stripped,
            .path = path,
            .name = basename(path),
            .markers = std.array_list.Managed(*markers.Marker).init(allocator),
        };
    }

    pub fn deinit(self: *ResourceMarkers) void {
        self.markers.deinit();
        self.allocator.free(self.key);
        self.* = undefined;
    }

    pub fn total(self: *const ResourceMarkers) usize {
        return self.markers.items.len;
    }
};

pub const MarkersModel = struct {
    allocator: Allocator,
    resources: std.array_list.Managed(*ResourceMarkers),
    _total: usize = 0,

    pub fn init(allocator: Allocator) MarkersModel {
        return .{
            .allocator = allocator,
            .resources = std.array_list.Managed(*ResourceMarkers).init(allocator),
        };
    }

    pub fn deinit(self: *MarkersModel) void {
        self.reset();
        self.resources.deinit();
        self.* = undefined;
    }

    pub fn reset(self: *MarkersModel) void {
        for (self.resources.items) |group| {
            group.deinit();
            self.allocator.destroy(group);
        }
        self.resources.clearRetainingCapacity();
        self._total = 0;
    }

    pub fn total(self: *const MarkersModel) usize {
        return self._total;
    }

    /// Rebuilds the grouped view from the marker service.
    pub fn refresh(self: *MarkersModel, service: *MarkerService) !void {
        self.reset();
        errdefer self.reset();

        const all = try service.read(self.allocator, .{ .severities = common.problems_severities });
        defer self.allocator.free(all);

        var by_key = std.StringHashMap(*ResourceMarkers).init(self.allocator);
        defer by_key.deinit();

        for (all) |marker| {
            if (MarkerService.isUnsupportedScheme(marker.resource.scheme)) continue;
            const key = try marker.resource.comparisonKey(self.allocator);
            const result = by_key.getOrPut(key) catch |err| {
                self.allocator.free(key);
                return err;
            };
            if (result.found_existing) {
                self.allocator.free(key);
            } else {
                const group = self.allocator.create(ResourceMarkers) catch |err| {
                    self.allocator.free(key);
                    return err;
                };
                group.* = ResourceMarkers.init(self.allocator, key, marker.resource, marker.resource.path);
                result.value_ptr.* = group;
                self.resources.append(group) catch |err| {
                    group.deinit();
                    self.allocator.destroy(group);
                    return err;
                };
            }
            try result.value_ptr.*.markers.append(marker);
        }

        for (self.resources.items) |group| {
            std.mem.sort(*markers.Marker, group.markers.items, {}, lessMarker);
            try deduplicateMarkers(group, self.allocator);
            self._total += group.markers.items.len;
        }
        std.mem.sort(*ResourceMarkers, self.resources.items, {}, lessResource);
    }

    pub fn resourceMarkers(self: *const MarkersModel) []*ResourceMarkers {
        return self.resources.items;
    }

    pub fn getResourceMarkers(self: *const MarkersModel, key: []const u8) ?*ResourceMarkers {
        for (self.resources.items) |group| {
            if (std.mem.eql(u8, group.key, key)) return group;
        }
        return null;
    }
};

fn deduplicateMarkers(group: *ResourceMarkers, allocator: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var seen = std.StringHashMap(void).init(scratch);
    defer seen.deinit();

    var write: usize = 0;
    for (group.markers.items) |marker| {
        const key = try dedupeKey(scratch, marker);
        const result = try seen.getOrPut(key);
        if (result.found_existing) continue;
        group.markers.items[write] = marker;
        write += 1;
    }
    group.markers.shrinkRetainingCapacity(write);
}

fn dedupeKey(allocator: Allocator, marker: *const markers.Marker) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{d}\x1f{s}\x1f{d}:{d}:{d}:{d}\x1f{s}", .{
        marker.source orelse "",
        marker.code orelse "",
        marker.severity,
        marker.message,
        marker.start_line_number,
        marker.start_column,
        marker.end_line_number,
        marker.end_column,
        marker.resource.path,
    });
}

fn lessMarker(_: void, a: *markers.Marker, b: *markers.Marker) bool {
    const severity = markers.MarkerSeverity.compare(a.severity, b.severity);
    if (severity != 0) return severity < 0;
    if (a.start_line_number != b.start_line_number) return a.start_line_number < b.start_line_number;
    if (a.start_column != b.start_column) return a.start_column < b.start_column;
    if (a.end_line_number != b.end_line_number) return a.end_line_number < b.end_line_number;
    if (a.end_column != b.end_column) return a.end_column < b.end_column;
    return std.mem.lessThan(u8, a.message, b.message);
}

fn lessResource(_: void, a: *ResourceMarkers, b: *ResourceMarkers) bool {
    const a_marker: ?*markers.Marker = if (a.markers.items.len > 0) a.markers.items[0] else null;
    const b_marker: ?*markers.Marker = if (b.markers.items.len > 0) b.markers.items[0] else null;
    if (a_marker != null and b_marker != null) {
        const severity = markers.MarkerSeverity.compare(a_marker.?.severity, b_marker.?.severity);
        if (severity != 0) return severity < 0;
    }
    if (!std.mem.eql(u8, a.path, b.path)) return std.mem.lessThan(u8, a.path, b.path);
    return std.mem.lessThan(u8, a.name, b.name);
}

fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
    return path[start..end];
}

test "markersModel: groups fragments, sorts and deduplicates" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();

    const resource = markers.Resource{ .scheme = "file", .path = "/a.zig" };
    const same_document = markers.Resource{ .scheme = "file", .path = "/a.zig", .fragment = "2" };
    try service.changeOne("owner1", resource, &.{
        .{ .severity = markers.MarkerSeverity.Warning, .message = "warn", .start_line_number = 3, .start_column = 1, .end_line_number = 3, .end_column = 2 },
        .{ .severity = markers.MarkerSeverity.Error, .message = "error", .start_line_number = 8, .start_column = 1, .end_line_number = 8, .end_column = 2 },
    }, null);
    try service.changeOne("owner2", same_document, &.{
        .{ .severity = markers.MarkerSeverity.Error, .message = "error", .start_line_number = 8, .start_column = 1, .end_line_number = 8, .end_column = 2 },
    }, null);

    var model = MarkersModel.init(allocator);
    defer model.deinit();
    try model.refresh(&service);

    try std.testing.expectEqual(@as(usize, 1), model.resourceMarkers().len);
    try std.testing.expectEqual(@as(usize, 2), model.total());
    const group = model.resourceMarkers()[0];
    try std.testing.expectEqualStrings("a.zig", group.name);
    try std.testing.expectEqual(@as(u32, markers.MarkerSeverity.Error), group.markers.items[0].severity);
    try std.testing.expectEqual(@as(u32, markers.MarkerSeverity.Warning), group.markers.items[1].severity);
}
