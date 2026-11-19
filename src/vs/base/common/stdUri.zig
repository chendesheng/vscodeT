//! Bridge helpers for `std.Uri`, the URI type used by the editor's text
//! models (`TextModel.uri()`).
//!
//! Upstream `src/vs/base/common/uri.ts` has an owned URI class; this port uses
//! Zig's `std.Uri` for editor models and a separate owned `URI` for input
//! data. These helpers centralize the conversions the language-selector and
//! markers code needs so the two URI types do not leak into each other.
//!
//! Components are decoded when used for matching/keying (`raw` form). The JSON
//! form sent over the extension-host RPC keeps the raw components, matching
//! the existing `fileUri` helper in `extensionHostManager.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn scheme(uri: std.Uri) []const u8 {
    return uri.scheme;
}

/// Raw authority (host) component. User/password/port are deliberately not
/// part of the authority used for matching; the editor only deals with local
/// resources in this port.
pub fn authority(uri: std.Uri, arena: Allocator) ![]const u8 {
    if (uri.host) |host| return try host.toRawMaybeAlloc(arena);
    return "";
}

/// Decoded filesystem path, as upstream `URI.fsPath` would expose it.
/// The result may point into `arena`; it must not be freed by the caller.
pub fn fsPath(uri: std.Uri, arena: Allocator) ![]const u8 {
    return try uri.path.toRawMaybeAlloc(arena);
}

pub fn path(uri: std.Uri, arena: Allocator) ![]const u8 {
    return try uri.path.toRawMaybeAlloc(arena);
}

pub fn query(uri: std.Uri, arena: Allocator) ![]const u8 {
    if (uri.query) |query_component| return try query_component.toRawMaybeAlloc(arena);
    return "";
}

pub fn fragment(uri: std.Uri, arena: Allocator) ![]const u8 {
    if (uri.fragment) |fragment_component| return try fragment_component.toRawMaybeAlloc(arena);
    return "";
}

/// Canonical identity key used by the marker service and selector caching.
/// `file:///a/b`, `git:foo/bar`, and authority-qualified schemes are kept
/// distinct, matching upstream `URI.toString()` identity.
pub fn resourceKey(allocator: Allocator, uri: std.Uri) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    return resourceKeyFromComponents(allocator, .{
        .scheme = uri.scheme,
        .authority = try authority(uri, arena),
        .path = try path(uri, arena),
        .query = try query(uri, arena),
        .fragment = try fragment(uri, arena),
    });
}

pub const Components = struct {
    scheme: []const u8,
    authority: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",
    fragment: []const u8 = "",
};

pub fn resourceKeyFromComponents(allocator: Allocator, components: Components) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(components.scheme);
    try out.append(':');
    if (components.authority.len > 0 or std.mem.eql(u8, components.scheme, "file")) {
        try out.appendSlice("//");
        try out.appendSlice(components.authority);
    }
    try out.appendSlice(components.path);
    if (components.query.len > 0) {
        try out.append('?');
        try out.appendSlice(components.query);
    }
    if (components.fragment.len > 0) {
        try out.append('#');
        try out.appendSlice(components.fragment);
    }
    return try out.toOwnedSlice();
}

/// URI components in the `UriComponents` shape accepted by the extension host
/// (`URI.revive`). The `$mid` tag is required by the upstream RPC revival.
pub fn jsonComponents(arena: Allocator, uri: std.Uri) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "$mid", .{ .integer = 1 });
    try object.put(arena, "scheme", .{ .string = try arena.dupe(u8, uri.scheme) });
    try object.put(arena, "authority", .{ .string = try arena.dupe(u8, try authority(uri, arena)) });
    try object.put(arena, "path", .{ .string = try arena.dupe(u8, try path(uri, arena)) });
    try object.put(arena, "query", .{ .string = try arena.dupe(u8, try query(uri, arena)) });
    try object.put(arena, "fragment", .{ .string = try arena.dupe(u8, try fragment(uri, arena)) });
    return .{ .object = object };
}

pub fn componentsFromJson(value: std.json.Value, arena: Allocator) !Components {
    if (value != .object) return error.InvalidUri;
    const object = value.object;
    return .{
        .scheme = try stringField(arena, object, "scheme"),
        .authority = try stringField(arena, object, "authority"),
        .path = try stringField(arena, object, "path"),
        .query = try stringField(arena, object, "query"),
        .fragment = try stringField(arena, object, "fragment"),
    };
}

fn stringField(arena: Allocator, object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return "";
    if (value != .string) return "";
    return try arena.dupe(u8, value.string);
}

test "std.Uri bridge: file resource keys and JSON components" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("file:///tmp/a%20b.json?x=1#f");
    const key = try resourceKey(allocator, uri);
    defer allocator.free(key);
    try std.testing.expectEqualStrings("file:///tmp/a b.json?x=1#f", key);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const json = try jsonComponents(arena.allocator(), uri);
    try std.testing.expectEqualStrings("file", json.object.get("scheme").?.string);
    try std.testing.expectEqualStrings("/tmp/a b.json", json.object.get("path").?.string);
}
