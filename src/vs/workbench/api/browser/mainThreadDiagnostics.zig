// Port of `src/vs/workbench/api/browser/mainThreadDiagnostics.ts`.
//
// The terminal workbench has one extension host. `$changeMany`/`$clear` feed
// the shared `MarkerService`; markers from other owners are forwarded back to
// the host through a batched `$acceptMarkersChange`, matching upstream's
// "diagnostics changed" event.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const proxyIdentifier = @import("../../services/extensions/common/proxyIdentifier.zig");
const cancellation = @import("../../../base/common/cancellation.zig");
const CancellationToken = cancellation.CancellationToken;
const std_uri = @import("../../../base/common/stdUri.zig");
const TextModel = @import("../../../editor/common/model/textModel.zig").TextModel;
const position_converter = @import("../common/positionConverter.zig");
const markers = @import("../../../platform/markers/common/markers.zig");
const marker_service_mod = @import("../../../platform/markers/common/markerService.zig");
const MarkerService = marker_service_mod.MarkerService;
const MarkerChangeEvent = marker_service_mod.MarkerChangeEvent;

pub const HostProxy = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque, method: []const u8, args: []const rpc.Arg) anyerror!void,
};

/// Maps a marker resource back to its open text model so the host's UTF-16
/// columns can be converted to the editor's UTF-8 columns.
pub const DocumentProvider = struct {
    context: *anyopaque,
    model_for: *const fn (context: *anyopaque, resource: markers.Resource) ?*TextModel,
};

const Pending = struct {
    key: []u8,
};

pub const MainThreadDiagnostics = struct {
    allocator: Allocator,
    marker_service: *MarkerService,
    proxy: HostProxy,
    active_owners: std.StringHashMap(void),
    pending: std.array_list.Managed(Pending),
    document_provider: ?DocumentProvider = null,
    listener: ?@import("../../../base/common/event.zig").Emitter(MarkerChangeEvent).ListenerId = null,
    ext_host_id: []const u8 = "extHost1",

    pub fn init(allocator: Allocator, marker_service: *MarkerService, proxy: HostProxy, document_provider: ?DocumentProvider) !*MainThreadDiagnostics {
        const self = try allocator.create(MainThreadDiagnostics);
        self.* = .{
            .allocator = allocator,
            .marker_service = marker_service,
            .proxy = proxy,
            .active_owners = std.StringHashMap(void).init(allocator),
            .pending = std.array_list.Managed(Pending).init(allocator),
            .document_provider = document_provider,
        };
        self.listener = try marker_service.on_marker_changed.listen(self, onMarkerChanged);
        return self;
    }

    pub fn deinit(self: *MainThreadDiagnostics) void {
        if (self.listener) |listener| self.marker_service.on_marker_changed.unlisten(listener);
        self.clearOwnMarkers();
        for (self.pending.items) |item| self.allocator.free(item.key);
        self.pending.deinit();
        self.active_owners.deinit();
        self.allocator.destroy(self);
    }

    pub fn invoke(self: *MainThreadDiagnostics, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$changeMany")) return self.changeMany(args, arena);
        if (std.mem.eql(u8, method, "$clear")) {
            if (args.len > 0 and args[0] == .json and args[0].json == .string) {
                try self.marker_service.changeAll(args[0].json.string, &.{});
                if (self.active_owners.fetchRemove(args[0].json.string)) |entry| self.allocator.free(entry.key);
            }
            return .empty;
        }
        if (methodKind(method) == .request) return .{ .err = .{ .name = "Unsupported", .message = method } };
        return .empty;
    }

    fn changeMany(self: *MainThreadDiagnostics, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (args.len < 2 or args[0] != .json or args[0].json != .string) return error.InvalidArguments;
        const owner = args[0].json.string;
        const entries = args[1].json;
        if (entries != .array) return error.InvalidArguments;

        for (entries.array.items) |entry| {
            if (entry != .array or entry.array.items.len < 2) continue;
            const uri_value = entry.array.items[0];
            const marker_values = entry.array.items[1];
            const components = try std_uri.componentsFromJson(uri_value, arena);
            const resource = markers.Resource{
                .scheme = components.scheme,
                .authority = components.authority,
                .path = components.path,
                .query = components.query,
                .fragment = components.fragment,
            };
            const is_truncated = if (entry.array.items.len > 2) blk: {
                const value = entry.array.items[2];
                break :blk value == .bool and value.bool;
            } else false;

            if (marker_values == .null or marker_values != .array) {
                try self.marker_service.changeOne(owner, resource, &.{}, .{ .is_truncated = is_truncated });
            } else {
                const model = if (self.document_provider) |provider| provider.model_for(provider.context, resource) else null;
                var data = std.array_list.Managed(markers.MarkerData).init(arena);
                for (marker_values.array.items) |value| {
                    if (value != .object) continue;
                    try data.append(try markerDataFromJson(value.object, arena, self.ext_host_id, model));
                }
                try self.marker_service.changeOne(owner, resource, data.items, .{ .is_truncated = is_truncated });
            }
            if (self.active_owners.getKey(owner) == null) {
                try self.active_owners.put(try self.allocator.dupe(u8, owner), {});
            }
        }
        return .empty;
    }

    fn onMarkerChanged(event: MarkerChangeEvent, self: *MainThreadDiagnostics) !void {
        for (event.resources) |key| {
            var already = false;
            for (self.pending.items) |item| {
                if (std.mem.eql(u8, item.key, key)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            try self.pending.append(.{ .key = try self.allocator.dupe(u8, key) });
        }
    }

    /// Sends one merged `$acceptMarkersChange` for everything queued since the
    /// previous flush. Called once per TUI pump, reproducing upstream's
    /// microtask batching.
    pub fn flush(self: *MainThreadDiagnostics) !void {
        if (self.pending.items.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        var payload = std.json.Array.init(scratch);
        for (self.pending.items) |item| {
            const resource = try resourceFromKey(scratch, item.key);
            const all = self.marker_service.read(scratch, .{ .resource = resource, .ignore_resource_filters = true }) catch continue;
            var markers_json = std.json.Array.init(scratch);
            for (all) |marker| {
                if (marker.origin) |origin| {
                    if (std.mem.eql(u8, origin, self.ext_host_id)) continue;
                }
                try markers_json.append(try markerToJson(scratch, marker));
            }
            var entry = std.json.Array.init(scratch);
            try entry.append(try componentsJson(scratch, resource));
            try entry.append(.{ .array = markers_json });
            try payload.append(.{ .array = entry });
        }

        if (payload.items.len > 0) {
            var args = [_]rpc.Arg{.{ .json = .{ .array = payload } }};
            self.proxy.notify(self.proxy.context, "$acceptMarkersChange", &args) catch {};
        }
        for (self.pending.items) |item| self.allocator.free(item.key);
        self.pending.clearRetainingCapacity();
    }

    fn clearOwnMarkers(self: *MainThreadDiagnostics) void {
        var owners = self.active_owners.iterator();
        while (owners.next()) |entry| {
            const owner = entry.key_ptr.*;
            const all = self.marker_service.read(self.allocator, .{ .owner = owner }) catch continue;
            defer self.allocator.free(all);
            // Group by resource key and remove only this host's markers.
            var keys = std.StringHashMap(void).init(self.allocator);
            defer keys.deinit();
            for (all) |marker| {
                if (marker.origin) |origin| {
                    if (std.mem.eql(u8, origin, self.ext_host_id)) continue;
                }
                keys.put(marker.key, {}) catch {};
            }
            var iterator = keys.keyIterator();
            while (iterator.next()) |key_ptr| {
                const resource = resourceFromKey(self.allocator, key_ptr.*) catch continue;
                defer {
                    var owned = resource;
                    owned.deinit(self.allocator);
                }
                var data = std.array_list.Managed(markers.MarkerData).init(self.allocator);
                defer data.deinit();
                for (all) |marker| {
                    if (!std.mem.eql(u8, marker.key, key_ptr.*)) continue;
                    if (marker.origin) |origin| {
                        if (std.mem.eql(u8, origin, self.ext_host_id)) continue;
                    }
                    data.append(markerDataFromMarker(marker)) catch {};
                }
                self.marker_service.changeOne(owner, resource, data.items, null) catch {};
            }
        }
        var key_iterator = self.active_owners.keyIterator();
        while (key_iterator.next()) |key_ptr| self.allocator.free(key_ptr.*);
        self.active_owners.clearRetainingCapacity();
    }

    fn methodKind(method: []const u8) protocol.MethodKind {
        for (protocol.MainThreadDiagnostics.methods) |candidate| {
            if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
        }
        return .notification;
    }
};

fn markerDataFromMarker(marker: *const markers.Marker) markers.MarkerData {
    return .{
        .code = if (marker.code) |value| value else null,
        .severity = marker.severity,
        .message = marker.message,
        .source = if (marker.source) |value| value else null,
        .start_line_number = marker.start_line_number,
        .start_column = marker.start_column,
        .end_line_number = marker.end_line_number,
        .end_column = marker.end_column,
        .model_version_id = marker.model_version_id,
        .tags = marker.tags,
        .origin = if (marker.origin) |value| value else null,
    };
}

fn markerDataFromJson(object: std.json.ObjectMap, arena: Allocator, ext_host_id: []const u8, model: ?*TextModel) !markers.MarkerData {
    const start_line: u32 = if (intValue(object.get("startLineNumber"))) |value| @intCast(value) else 1;
    const start_column: u32 = if (intValue(object.get("startColumn"))) |value| @intCast(value) else 1;
    const end_line: u32 = if (intValue(object.get("endLineNumber"))) |value| @intCast(value) else 1;
    const end_column: u32 = if (intValue(object.get("endColumn"))) |value| @intCast(value) else 1;
    var result: markers.MarkerData = .{
        .message = try stringField(arena, object, "message"),
        .severity = if (intValue(object.get("severity"))) |value| @intCast(value) else markers.MarkerSeverity.Error,
        .start_line_number = start_line,
        .start_column = if (model) |value| columnForModel(value, start_line, start_column) else start_column,
        .end_line_number = end_line,
        .end_column = if (model) |value| columnForModel(value, end_line, end_column) else end_column,
        .model_version_id = if (intValue(object.get("modelVersionId"))) |value| @intCast(value) else null,
        .origin = try optionalStringField(arena, object, "origin"),
        .source = try optionalStringField(arena, object, "source"),
    };
    if (result.origin == null) result.origin = try arena.dupe(u8, ext_host_id);
    if (object.get("code")) |code| {
        if (code == .string) {
            result.code = try arena.dupe(u8, code.string);
        } else if (code == .object) {
            if (code.object.get("value")) |value| {
                if (value == .string) result.code = try arena.dupe(u8, value.string);
            }
            if (code.object.get("target")) |target| {
                const components = try std_uri.componentsFromJson(target, arena);
                result.code_target = .{
                    .scheme = components.scheme,
                    .authority = components.authority,
                    .path = components.path,
                    .query = components.query,
                    .fragment = components.fragment,
                };
            }
        }
    }
    if (object.get("tags")) |tags| {
        if (tags == .array) {
            var values = std.array_list.Managed(u32).init(arena);
            for (tags.array.items) |tag| if (tag == .integer) try values.append(@intCast(tag.integer));
            result.tags = try values.toOwnedSlice();
        }
    }
    return result;
}

fn columnForModel(model: *TextModel, line_number: u32, offset: u32) u32 {
    if (line_number < 1 or line_number > model.getLineCount()) return offset;
    var line = model.getLineContent(line_number) catch return offset;
    defer line.deinit();
    return @intCast(position_converter.columnForUtf16Offset(line.items, offset));
}

fn markerToJson(arena: Allocator, marker: *const markers.Marker) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "severity", .{ .integer = @intCast(marker.severity) });
    try object.put(arena, "message", .{ .string = try arena.dupe(u8, marker.message) });
    try object.put(arena, "startLineNumber", .{ .integer = @intCast(marker.start_line_number) });
    try object.put(arena, "startColumn", .{ .integer = @intCast(marker.start_column) });
    try object.put(arena, "endLineNumber", .{ .integer = @intCast(marker.end_line_number) });
    try object.put(arena, "endColumn", .{ .integer = @intCast(marker.end_column) });
    if (marker.source) |source| try object.put(arena, "source", .{ .string = try arena.dupe(u8, source) });
    if (marker.code) |code| try object.put(arena, "code", .{ .string = try arena.dupe(u8, code) });
    if (marker.tags.len > 0) {
        var tags = std.json.Array.init(arena);
        for (marker.tags) |tag| try tags.append(.{ .integer = @intCast(tag) });
        try object.put(arena, "tags", .{ .array = tags });
    }
    return .{ .object = object };
}

fn componentsJson(arena: Allocator, resource: markers.Resource) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "$mid", .{ .integer = 1 });
    try object.put(arena, "scheme", .{ .string = try arena.dupe(u8, resource.scheme) });
    try object.put(arena, "authority", .{ .string = try arena.dupe(u8, resource.authority) });
    try object.put(arena, "path", .{ .string = try arena.dupe(u8, resource.path) });
    try object.put(arena, "query", .{ .string = try arena.dupe(u8, resource.query) });
    try object.put(arena, "fragment", .{ .string = try arena.dupe(u8, resource.fragment) });
    return .{ .object = object };
}

fn resourceFromKey(allocator: Allocator, key: []const u8) !markers.Resource {
    const scheme_end = std.mem.indexOfScalar(u8, key, ':') orelse return error.InvalidUri;
    const scheme = key[0..scheme_end];
    var rest_start = scheme_end + 1;
    var authority: []const u8 = "";
    if (std.mem.startsWith(u8, key[rest_start..], "//")) {
        rest_start += 2;
        const authority_end = std.mem.indexOfAny(u8, key[rest_start..], "/?#") orelse key.len;
        authority = key[rest_start .. rest_start + authority_end];
        rest_start += authority_end;
    }
    var path_end = key.len;
    if (std.mem.indexOfAny(u8, key[rest_start..], "?#")) |offset| path_end = rest_start + offset;
    const path = key[rest_start..path_end];
    var query: []const u8 = "";
    var fragment: []const u8 = "";
    if (std.mem.indexOfScalar(u8, key[path_end..], '?')) |offset| {
        const start = path_end + offset + 1;
        const end = std.mem.indexOfScalar(u8, key[start..], '#') orelse key.len;
        query = key[start .. start + end];
        if (std.mem.indexOfScalar(u8, key[path_end..], '#') != null) {
            const hash = std.mem.indexOfScalarPos(u8, key, start, '#').?;
            fragment = key[hash + 1 ..];
        }
    } else if (std.mem.indexOfScalar(u8, key[path_end..], '#')) |offset| {
        fragment = key[path_end + offset + 1 ..];
    }
    return .{
        .scheme = try allocator.dupe(u8, scheme),
        .authority = try allocator.dupe(u8, authority),
        .path = try allocator.dupe(u8, path),
        .query = try allocator.dupe(u8, query),
        .fragment = try allocator.dupe(u8, fragment),
    };
}

fn stringField(arena: Allocator, object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return (try optionalStringField(arena, object, name)) orelse "";
}

fn optionalStringField(arena: Allocator, object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return try arena.dupe(u8, value.string);
}

fn intValue(value: ?std.json.Value) ?i64 {
    if (value) |item| {
        if (item == .integer) return item.integer;
    }
    return null;
}
