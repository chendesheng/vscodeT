// Port of `src/vs/platform/markers/common/markers.ts`.
//
// Terminal adaptation: resource identity is a canonical key string plus the
// URI components kept for extension-host forwarding. The editor model uses
// `std.Uri`, while this service needs owned resource values for markers that
// outlive a model.

const std = @import("std");
const Allocator = std.mem.Allocator;
const std_uri = @import("../../../base/common/stdUri.zig");
const severity_mod = @import("../../../base/common/severity.zig");

pub const MarkerSeverity = struct {
    pub const Hint: u32 = 1;
    pub const Info: u32 = 2;
    pub const Warning: u32 = 4;
    pub const Error: u32 = 8;

    pub fn compare(a: u32, b: u32) i32 {
        return @as(i32, @intCast(b)) - @as(i32, @intCast(a));
    }

    pub fn toString(value: u32) []const u8 {
        return switch (value) {
            Error => "Error",
            Warning => "Warning",
            Info => "Info",
            else => "",
        };
    }

    pub fn toStringPlural(value: u32) []const u8 {
        return switch (value) {
            Error => "Errors",
            Warning => "Warnings",
            Info => "Infos",
            else => "",
        };
    }

    pub fn fromSeverity(value: severity_mod.Severity) u32 {
        return switch (value) {
            .Error => Error,
            .Warning => Warning,
            .Info => Info,
            .Ignore => Hint,
        };
    }

    pub fn toSeverity(value: u32) severity_mod.Severity {
        return switch (value) {
            Error => .Error,
            Warning => .Warning,
            Info => .Info,
            else => .Ignore,
        };
    }
};

pub const MarkerTag = struct {
    pub const unnecessary: u32 = 1;
    pub const deprecated: u32 = 2;
};

pub const Resource = struct {
    scheme: []const u8 = "",
    authority: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",
    fragment: []const u8 = "",

    pub fn key(self: Resource, allocator: Allocator) ![]u8 {
        return std_uri.resourceKeyFromComponents(allocator, .{
            .scheme = self.scheme,
            .authority = self.authority,
            .path = self.path,
            .query = self.query,
            .fragment = self.fragment,
        });
    }

    /// Terminal counterpart of `extUri.getComparisonKey(resource, true)`: the
    /// fragment is ignored so markers on different fragments of one document
    /// group together. Path casing is not folded; the terminal workbench has no
    /// URI identity service.
    pub fn comparisonKey(self: Resource, allocator: Allocator) ![]u8 {
        return std_uri.resourceKeyFromComponents(allocator, .{
            .scheme = self.scheme,
            .authority = self.authority,
            .path = self.path,
            .query = self.query,
            .fragment = "",
        });
    }

    pub fn fromUri(allocator: Allocator, uri: std.Uri) !Resource {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        return .{
            .scheme = try allocator.dupe(u8, uri.scheme),
            .authority = try allocator.dupe(u8, try std_uri.authority(uri, scratch)),
            .path = try allocator.dupe(u8, try std_uri.fsPath(uri, scratch)),
            .query = try allocator.dupe(u8, try std_uri.query(uri, scratch)),
            .fragment = try allocator.dupe(u8, try std_uri.fragment(uri, scratch)),
        };
    }

    pub fn clone(self: Resource, allocator: Allocator) !Resource {
        var result: Resource = .{};
        errdefer result.deinit(allocator);
        result.scheme = try allocator.dupe(u8, self.scheme);
        result.authority = try allocator.dupe(u8, self.authority);
        result.path = try allocator.dupe(u8, self.path);
        result.query = try allocator.dupe(u8, self.query);
        result.fragment = try allocator.dupe(u8, self.fragment);
        return result;
    }

    pub fn deinit(self: *Resource, allocator: Allocator) void {
        allocator.free(self.scheme);
        allocator.free(self.authority);
        allocator.free(self.path);
        allocator.free(self.query);
        allocator.free(self.fragment);
    }
};

/// Related locations can refer to a model which has not been loaded yet.
/// Their columns retain the upstream UTF-16 coordinates until reveal.
pub const RelatedInformation = struct {
    resource: Resource,
    message: []const u8,
    start_line_number: u32,
    start_column: u32,
    end_line_number: u32,
    end_column: u32,

    pub fn cloneAll(allocator: Allocator, items: []const RelatedInformation) ![]RelatedInformation {
        const owned = try allocator.alloc(RelatedInformation, items.len);
        var count: usize = 0;
        errdefer deinitAll(allocator, owned, count);
        for (items, owned) |item, *target| {
            var resource = try item.resource.clone(allocator);
            errdefer resource.deinit(allocator);
            target.* = item;
            target.resource = resource;
            target.message = try allocator.dupe(u8, item.message);
            count += 1;
        }
        return owned;
    }

    pub fn deinitAll(allocator: Allocator, items: []RelatedInformation, count: usize) void {
        for (items[0..count]) |*item| {
            item.resource.deinit(allocator);
            allocator.free(item.message);
        }
        allocator.free(items);
    }
};

pub const MarkerData = struct {
    code: ?[]const u8 = null,
    code_target: ?Resource = null,
    severity: u32 = MarkerSeverity.Error,
    message: []const u8 = "",
    source: ?[]const u8 = null,
    start_line_number: u32 = 1,
    start_column: u32 = 1,
    end_line_number: u32 = 1,
    end_column: u32 = 1,
    model_version_id: ?u32 = null,
    tags: []const u32 = &.{},
    related_information: []const RelatedInformation = &.{},
    origin: ?[]const u8 = null,
};

pub const Marker = struct {
    owner: []u8,
    resource: Resource,
    key: []const u8,
    code: ?[]u8 = null,
    code_target: ?Resource = null,
    severity: u32,
    message: []u8,
    source: ?[]u8 = null,
    start_line_number: u32,
    start_column: u32,
    end_line_number: u32,
    end_column: u32,
    model_version_id: ?u32,
    tags: []u32,
    related_information: []RelatedInformation = &.{},
    origin: ?[]u8 = null,
    /// Internal link used by `MarkerService` to keep removed markers alive
    /// until its `onMarkerChanged` listeners return. Not marker data.
    retired_next: ?*Marker = null,

    pub fn deinit(self: *Marker, allocator: Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.message);
        if (self.code) |value| allocator.free(value);
        if (self.code_target) |*value| value.deinit(allocator);
        if (self.source) |value| allocator.free(value);
        if (self.origin) |value| allocator.free(value);
        if (self.tags.len > 0) allocator.free(self.tags);
        RelatedInformation.deinitAll(allocator, self.related_information, self.related_information.len);
    }
};

pub const ResourceMarker = struct {
    resource: Resource,
    marker: MarkerData,
};

pub const ReadOptions = struct {
    owner: ?[]const u8 = null,
    resource: ?Resource = null,
    severities: ?u32 = null,
    take: ?usize = null,
    ignore_resource_filters: bool = false,
};

pub const ChangeOptions = struct {
    is_truncated: bool = false,
};

pub const MarkerStatistics = struct {
    errors: usize = 0,
    warnings: usize = 0,
    infos: usize = 0,
    unknowns: usize = 0,
};
