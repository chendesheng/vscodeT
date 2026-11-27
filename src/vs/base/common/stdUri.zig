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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Copy all URI components into the caller's arena without changing the
/// original raw/percent-encoded representation. Useful for retaining the
/// identity independently of a text model's lifetime.
pub fn clone(allocator: Allocator, uri: std.Uri) !std.Uri {
    return .{
        .scheme = try allocator.dupe(u8, uri.scheme),
        .user = if (uri.user) |c| try cloneComponent(allocator, c) else null,
        .password = if (uri.password) |c| try cloneComponent(allocator, c) else null,
        .host = if (uri.host) |c| try cloneComponent(allocator, c) else null,
        .port = uri.port,
        .path = try cloneComponent(allocator, uri.path),
        .query = if (uri.query) |c| try cloneComponent(allocator, c) else null,
        .fragment = if (uri.fragment) |c| try cloneComponent(allocator, c) else null,
    };
}

fn cloneComponent(allocator: Allocator, component: std.Uri.Component) !std.Uri.Component {
    return switch (component) {
        .raw => |value| .{ .raw = try allocator.dupe(u8, value) },
        .percent_encoded => |value| .{ .percent_encoded = try allocator.dupe(u8, value) },
    };
}

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
    const raw = try uri.path.toRawMaybeAlloc(arena);
    if (!std.mem.eql(u8, uri.scheme, "file") or builtin.os.tag != .windows) return raw;

    // `URI.fsPath` strips the leading slash before a drive letter and uses
    // native separators. Model URIs store the native path already, while a URI
    // parsed from text carries `/C:/...`; both spellings must map back to the
    // same filesystem path.
    const host = try authority(uri, arena);
    var out = std.array_list.Managed(u8).init(arena);
    errdefer out.deinit();
    if (host.len > 0) {
        try out.appendSlice("\\\\");
        try out.appendSlice(host);
    }
    var body = raw;
    if (body.len > 0 and body[0] == '/') {
        if (body.len >= 3 and body[2] == ':' and std.ascii.isAlphabetic(body[1])) {
            body = body[1..];
        }
    }
    for (body) |byte| try out.append(if (byte == '/') '\\' else byte);
    return try out.toOwnedSlice();
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

/// Resource parent comparison from upstream resources.ExtUri. The caller
/// supplies its filesystem provider's path casing policy.
pub fn isEqualOrParent(resource: std.Uri, root: std.Uri, arena: Allocator, ignore_path_case: bool) !bool {
    if (!std.mem.eql(u8, resource.scheme, root.scheme)) return false;
    if (!std.ascii.eqlIgnoreCase(try authority(resource, arena), try authority(root, arena))) return false;
    if (!std.mem.eql(u8, try query(resource, arena), try query(root, arena))) return false;
    if (!std.mem.eql(u8, try fragment(resource, arena), try fragment(root, arena))) return false;
    const is_file = std.mem.eql(u8, resource.scheme, "file");
    const resource_path = if (is_file) try fsPath(resource, arena) else try path(resource, arena);
    const parent = if (is_file) try fsPath(root, arena) else try path(root, arena);
    const separators = if (is_file and builtin.os.tag == .windows) "/\\" else "/";
    const trimmed = std.mem.trimEnd(u8, parent, separators);
    if (pathEquals(resource_path, parent, ignore_path_case) or pathEquals(resource_path, trimmed, ignore_path_case)) return true;
    if (resource_path.len <= trimmed.len or !pathEquals(resource_path[0..trimmed.len], trimmed, ignore_path_case)) return false;
    return std.mem.indexOfScalar(u8, separators, resource_path[trimmed.len]) != null;
}

fn pathEquals(a: []const u8, b: []const u8, ignore_case: bool) bool {
    return if (ignore_case) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

/// Serializes a model URI without mistaking a native drive path for the
/// authority component. File models use native paths, while serialized URIs
/// use slash-separated absolute paths and percent-encoded components.
pub fn encodedResource(allocator: Allocator, uri: std.Uri) ![]u8 {
    if (!std.mem.eql(u8, uri.scheme, "file")) return std.fmt.allocPrint(allocator, "{f}", .{uri});
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const raw = try path(uri, a);
    var normalized: std.ArrayList(u8) = .empty;
    var host = try authority(uri, a);
    if (raw.len >= 2 and raw[0] == '\\' and raw[1] == '\\' and host.len == 0) {
        const rest = raw[2..];
        const separator = std.mem.indexOfAny(u8, rest, "/\\") orelse rest.len;
        host = rest[0..separator];
        for (rest[separator..]) |byte| try normalized.append(a, if (byte == '\\') '/' else byte);
    } else {
        if (raw.len == 0 or raw[0] != '/') try normalized.append(a, '/');
        for (raw) |byte| try normalized.append(a, if (raw.len > 0 and raw[0] != '/' and byte == '\\') '/' else byte);
    }
    const canonical: std.Uri = .{
        .scheme = uri.scheme,
        .host = .{ .raw = host },
        .path = .{ .raw = normalized.items },
        .query = if (uri.query != null) .{ .raw = try query(uri, a) } else null,
        .fragment = if (uri.fragment != null) .{ .raw = try fragment(uri, a) } else null,
    };
    return std.fmt.allocPrint(allocator, "{f}", .{canonical});
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
    const is_file = std.mem.eql(u8, components.scheme, "file");
    if (components.authority.len > 0 or is_file) {
        try out.appendSlice("//");
        try out.appendSlice(components.authority);
    }
    if (is_file and components.authority.len == 0) {
        try appendFilePath(&out, components.path);
    } else {
        try out.appendSlice(components.path);
    }
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

/// Appends a local filesystem path as the path component of a `file:` URI.
/// A native Windows drive path (`C:\dir`) would otherwise become the URI
/// authority, where `C:` parses as an invalid port. URI paths always start with
/// `/` and use `/` separators.
fn appendFilePath(out: *std.array_list.Managed(u8), file_path: []const u8) !void {
    if (file_path.len == 0) return;
    if (file_path[0] == '/') {
        try out.appendSlice(file_path);
        return;
    }
    if (file_path[0] != '\\') try out.append('/');
    for (file_path) |byte| try out.append(if (byte == '\\') '/' else byte);
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

/// Revive decoded UriComponents without treating literal '#' or '?' in
/// the path as delimiters. The caller owns the encoded backing string.
pub fn encodedResourceFromJson(allocator: Allocator, value: std.json.Value) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const components = try componentsFromJson(value, scratch.allocator());
    var uri = try @import("uri.zig").URI.from(scratch.allocator(), .{
        .scheme = components.scheme,
        .authority = components.authority,
        .path = components.path,
        .query = components.query,
        .fragment = components.fragment,
    }, false);
    defer uri.deinit();
    return uri.toStringEncoded(allocator);
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

test "std.Uri bridge: native Windows file paths serialize as parseable URIs" {
    const allocator = std.testing.allocator;
    const key = try resourceKeyFromComponents(allocator, .{
        .scheme = "file",
        .path = "C:\\Users\\me\\a b.zig",
    });
    defer allocator.free(key);
    try std.testing.expectEqualStrings("file:///C:/Users/me/a b.zig", key);

    // The old serialization (`file://C:\...`) put the drive in the authority,
    // where `C:` fails to parse as a port.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.Uri.parse(key);
    try std.testing.expect(parsed.host == null);
    try std.testing.expectEqualStrings("/C:/Users/me/a b.zig", try path(parsed, arena.allocator()));
}

test "std.Uri bridge: file fsPath maps URI and native spellings to the native path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.Uri.parse("file:///C:/Users/me/a%20b.zig");
    try std.testing.expectEqualStrings("C:\\Users\\me\\a b.zig", try fsPath(parsed, allocator));

    const native = std.Uri{
        .scheme = "file",
        .user = null,
        .password = null,
        .host = .{ .raw = "" },
        .port = null,
        .path = .{ .raw = "C:\\Users\\me\\a.zig" },
        .query = null,
        .fragment = null,
    };
    try std.testing.expectEqualStrings("C:\\Users\\me\\a.zig", try fsPath(native, allocator));

    const unc = try std.Uri.parse("file://server/share/a.zig");
    try std.testing.expectEqualStrings("\\\\server\\share\\a.zig", try fsPath(unc, allocator));
}

test "stdUri: encoded model resource normalizes a native drive without losing reserved characters" {
    const a = std.testing.allocator;
    const uri: std.Uri = .{ .scheme = "file", .path = .{ .raw = "C:\\repo\\a #b.txt" } };
    const encoded = try encodedResource(a, uri);
    defer a.free(encoded);
    const parsed = try std.Uri.parse(encoded);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectEqualStrings("/C:/repo/a #b.txt", try path(parsed, arena.allocator()));
    try std.testing.expectEqualStrings("", try authority(parsed, arena.allocator()));
}

/// Maps a resource affected by a file/folder move to its corresponding
/// target. Equality/parent checks and native path spelling are shared by the
/// editor-input and text-file working-copy owners.
pub fn mapMovedResource(allocator: Allocator, resource: std.Uri, source: std.Uri, target: std.Uri, ignore_case: bool) !?std.Uri {
    if (!try isEqualOrParent(resource, source, allocator, ignore_case)) return null;
    const is_file = std.mem.eql(u8, source.scheme, "file");
    const source_path = if (is_file) try fsPath(source, allocator) else try path(source, allocator);
    const resource_path = if (is_file) try fsPath(resource, allocator) else try path(resource, allocator);
    const separators = if (is_file and builtin.os.tag == .windows) "/\\" else "/";
    const trimmed = std.mem.trimEnd(u8, source_path, separators);
    if (pathEquals(resource_path, trimmed, ignore_case) or pathEquals(resource_path, source_path, ignore_case)) return try clone(allocator, target);
    const relative = std.mem.trimStart(u8, resource_path[trimmed.len..], separators);
    var result = try clone(allocator, target);
    if (std.mem.eql(u8, target.scheme, "file")) {
        result.path = .{ .raw = try std.fs.path.join(allocator, &.{ try fsPath(target, allocator), relative }) };
        // Native paths include a UNC authority in their path spelling.
        if (builtin.os.tag == .windows) result.host = null;
    } else {
        const base_path = std.mem.trimEnd(u8, try path(target, allocator), "/");
        result.path = .{ .raw = try std.mem.concat(allocator, u8, &.{ base_path, "/", relative }) };
    }
    return result;
}
