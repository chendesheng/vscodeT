// Port of the core `URI` component model from `src/vs/base/common/uri.ts`.
//
// Terminal adaptations: components are UTF-8 byte slices, percent-encoding is
// preserved verbatim (no decode/encode round-trip), and the URI owns an arena
// for its components. Capabilities outside the editor-input needs
// (`UriComponents` marshalling, path encoders) are not ported.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Components = struct {
    scheme: []const u8 = "",
    authority: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",
    fragment: []const u8 = "",
};

pub const URI = struct {
    allocator: Allocator,
    arena: *std.heap.ArenaAllocator,
    scheme: []const u8,
    authority: []const u8,
    path: []const u8,
    query: []const u8,
    fragment: []const u8,

    pub fn deinit(self: *URI) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    pub fn file(allocator: Allocator, path: []const u8) !URI {
        return filePath(allocator, path);
    }

    pub fn parse(allocator: Allocator, text: []const u8, strict: bool) !URI {
        return parseText(allocator, text, strict);
    }

    pub fn fsPath(self: *const URI) []const u8 {
        return self.path;
    }

    pub fn toString(self: *const URI, allocator: Allocator) ![]u8 {
        var out = std.array_list.Managed(u8).init(allocator);
        errdefer out.deinit();
        if (self.scheme.len > 0) {
            try out.appendSlice(self.scheme);
            try out.append(':');
        }
        if (self.authority.len > 0 or std.mem.eql(u8, self.scheme, "file")) {
            try out.appendSlice("//");
            try out.appendSlice(self.authority);
        }
        try out.appendSlice(self.path);
        if (self.query.len > 0) {
            try out.append('?');
            try out.appendSlice(self.query);
        }
        if (self.fragment.len > 0) {
            try out.append('#');
            try out.appendSlice(self.fragment);
        }
        return out.toOwnedSlice();
    }

    pub fn with(self: *const URI, allocator: Allocator, changes: Components) !URI {
        return make(allocator, .{
            .scheme = if (changes.scheme.len > 0) changes.scheme else self.scheme,
            .authority = if (changes.authority.len > 0) changes.authority else self.authority,
            .path = if (changes.path.len > 0) changes.path else self.path,
            .query = if (changes.query.len > 0) changes.query else self.query,
            .fragment = if (changes.fragment.len > 0) changes.fragment else self.fragment,
        }, false);
    }

    pub fn joinPath(self: *const URI, allocator: Allocator, segments: []const []const u8) !URI {
        if (self.path.len == 0) return error.UriWithoutPath;
        var path = std.array_list.Managed(u8).init(allocator);
        defer path.deinit();
        try path.appendSlice(self.path);
        for (segments) |segment| {
            if (path.items.len > 0 and path.items[path.items.len - 1] != '/') try path.append('/');
            try path.appendSlice(segment);
        }
        const changes = Components{ .path = path.items };
        return self.with(allocator, changes);
    }

    pub fn make(allocator: Allocator, components: Components, strict: bool) !URI {
        return makeComponents(allocator, components, strict);
    }

    pub fn from(allocator: Allocator, components: Components, strict: bool) !URI {
        return makeComponents(allocator, components, strict);
    }

    pub fn revive(allocator: Allocator, components: Components) !URI {
        return makeComponents(allocator, components, false);
    }

    pub fn isUri(value: anytype) bool {
        const T = @TypeOf(value);
        if (T != URI and T != *const URI and T != *URI) return false;
        return true;
    }

    pub fn equals(a: *const URI, b: *const URI) bool {
        return std.ascii.eqlIgnoreCase(a.scheme, b.scheme) and
            std.mem.eql(u8, a.authority, b.authority) and
            std.mem.eql(u8, a.path, b.path) and
            std.mem.eql(u8, a.query, b.query) and
            std.mem.eql(u8, a.fragment, b.fragment);
    }
};

/// `path.posix.dirname`-compatible directory part.
fn pathDirname(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    if (std.mem.eql(u8, path, "/")) return "/";
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return ".";
    if (slash == 0) return "/";
    return path[0..slash];
}

fn pathBasename(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/');
    return if (slash) |index| path[index + 1 .. end] else path[0..end];
}

fn pathExtname(path: []const u8) []const u8 {
    const base = pathBasename(path);
    if (base.len == 0) return "";
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot == 0) return "";
    return base[dot..];
}

pub fn dirname(uri: *const URI, allocator: Allocator) !URI {
    return URI.make(allocator, .{
        .scheme = uri.scheme,
        .authority = uri.authority,
        .path = pathDirname(uri.path),
        .query = uri.query,
        .fragment = uri.fragment,
    }, true);
}

pub fn basename(uri: *const URI) []const u8 {
    return pathBasename(uri.path);
}

pub fn extname(uri: *const URI) []const u8 {
    return pathExtname(uri.path);
}

pub fn uriToFsPath(uri: *const URI) []const u8 {
    return uri.path;
}

pub fn isUriComponents(value: Components) bool {
    return std.mem.indexOfAny(u8, value.scheme, " \t") == null;
}

fn schemeValid(scheme: []const u8) bool {
    if (scheme.len == 0) return false;
    for (scheme, 0..) |ch, index| {
        if (index == 0) {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        } else if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '+' and ch != '-' and ch != '.') {
            return false;
        }
    }
    return true;
}

fn referenceResolution(scheme: []const u8, path: []const u8, allocator: Allocator) ![]const u8 {
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https") and !std.mem.eql(u8, scheme, "file")) return allocator.dupe(u8, path);
    if (path.len == 0) return allocator.dupe(u8, "/");
    if (path[0] != '/') {
        const result = try allocator.alloc(u8, path.len + 1);
        result[0] = '/';
        @memcpy(result[1..], path);
        return result;
    }
    return allocator.dupe(u8, path);
}

fn makeComponents(allocator: Allocator, components: Components, strict: bool) !URI {
    var scheme = components.scheme;
    if (scheme.len == 0 and strict) return error.MissingScheme;
    if (scheme.len == 0 and !strict) scheme = "file";
    if (scheme.len > 0 and !schemeValid(scheme)) return error.InvalidScheme;
    if (components.path.len > 0) {
        if (components.authority.len > 0 and components.path[0] != '/') return error.InvalidPath;
        if (components.authority.len == 0 and components.path.len > 1 and components.path[0] == '/' and components.path[1] == '/') return error.InvalidPath;
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const path = try referenceResolution(scheme, components.path, arena_allocator);
    return .{
        .allocator = allocator,
        .arena = arena,
        .scheme = try arena_allocator.dupe(u8, scheme),
        .authority = try arena_allocator.dupe(u8, components.authority),
        .path = path,
        .query = try arena_allocator.dupe(u8, components.query),
        .fragment = try arena_allocator.dupe(u8, components.fragment),
    };
}

fn filePath(allocator: Allocator, path: []const u8) !URI {
    var normalized = std.array_list.Managed(u8).init(allocator);
    defer normalized.deinit();
    for (path) |ch| try normalized.append(if (ch == '\\') '/' else ch);
    return makeComponents(allocator, .{ .scheme = "file", .path = normalized.items }, true);
}

fn parseText(allocator: Allocator, text: []const u8, strict: bool) !URI {
    var rest = text;
    var scheme: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        const candidate = rest[0..colon];
        if (schemeValid(candidate)) {
            scheme = candidate;
            rest = rest[colon + 1 ..];
        }
    }
    var authority: []const u8 = "";
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        authority = rest[0..end];
        rest = rest[end..];
    }
    var path = rest;
    var query: []const u8 = "";
    var fragment: []const u8 = "";
    if (std.mem.indexOfScalar(u8, path, '#')) |hash| {
        fragment = path[hash + 1 ..];
        path = path[0..hash];
    }
    if (std.mem.indexOfScalar(u8, path, '?')) |question| {
        query = path[question + 1 ..];
        path = path[0..question];
    }
    return makeComponents(allocator, .{
        .scheme = scheme,
        .authority = authority,
        .path = path,
        .query = query,
        .fragment = fragment,
    }, strict);
}

test "URI file, parse and toString" {
    const allocator = std.testing.allocator;
    var uri = try URI.file(allocator, "/foo/bar");
    defer uri.deinit();
    try std.testing.expectEqualStrings("file", uri.scheme);
    try std.testing.expectEqualStrings("/foo/bar", uri.path);
    const text = try uri.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("file:///foo/bar", text);

    var parsed = try URI.parse(allocator, "https://example.com/a/b?q=1#frag", true);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https", parsed.scheme);
    try std.testing.expectEqualStrings("example.com", parsed.authority);
    try std.testing.expectEqualStrings("/a/b", parsed.path);
    try std.testing.expectEqualStrings("q=1", parsed.query);
    try std.testing.expectEqualStrings("frag", parsed.fragment);
    const parsed_text = try parsed.toString(allocator);
    defer allocator.free(parsed_text);
    try std.testing.expectEqualStrings("https://example.com/a/b?q=1#frag", parsed_text);
}

test "URI joinPath, with and equality" {
    const allocator = std.testing.allocator;
    var base = try URI.file(allocator, "/foo");
    defer base.deinit();
    var joined = try base.joinPath(allocator, &.{ "bar", "baz" });
    defer joined.deinit();
    try std.testing.expectEqualStrings("/foo/bar/baz", joined.path);

    var changed = try joined.with(allocator, .{ .scheme = "untitled" });
    defer changed.deinit();
    try std.testing.expectEqualStrings("untitled", changed.scheme);

    var same = try URI.file(allocator, "/foo/bar/baz");
    defer same.deinit();
    try std.testing.expect(URI.equals(&joined, &same));
    try std.testing.expect(!URI.equals(&joined, &changed));
}

test "URI rejects invalid schemes and paths" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidScheme, makeComponents(allocator, .{ .scheme = "bad scheme" }, true));
    try std.testing.expectError(error.InvalidPath, URI.make(allocator, .{ .scheme = "file", .authority = "host", .path = "relative" }, true));
}

test "URI dirname, basename and extname" {
    const allocator = std.testing.allocator;
    var uri = try URI.file(allocator, "/foo/bar.txt");
    defer uri.deinit();
    try std.testing.expectEqualStrings("bar.txt", basename(&uri));
    try std.testing.expectEqualStrings(".txt", extname(&uri));
    var parent = try dirname(&uri, allocator);
    defer parent.deinit();
    try std.testing.expectEqualStrings("/foo", parent.path);
    var root = try URI.file(allocator, "/foo");
    defer root.deinit();
    var root_parent = try dirname(&root, allocator);
    defer root_parent.deinit();
    try std.testing.expectEqualStrings("/", root_parent.path);
    var top = try URI.file(allocator, "/");
    defer top.deinit();
    var top_parent = try dirname(&top, allocator);
    defer top_parent.deinit();
    try std.testing.expectEqualStrings("/", top_parent.path);
}

test "URI components round-trip" {
    const allocator = std.testing.allocator;
    const components = Components{ .scheme = "untitled", .path = "/Untitled-1" };
    try std.testing.expect(isUriComponents(components));
    var uri = try URI.from(allocator, components, true);
    defer uri.deinit();
    try std.testing.expect(URI.isUri(uri));
    const text = try uri.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("untitled:/Untitled-1", text);
}

test "URI parse defaults to file and strict validates missing schemes" {
    const allocator = std.testing.allocator;
    var parsed = try URI.parse(allocator, "foo/bar", false);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("file", parsed.scheme);
    try std.testing.expectEqualStrings("/foo/bar", parsed.path);
    try std.testing.expectError(error.MissingScheme, URI.parse(allocator, "foo/bar", true));
}

test "URI revive preserves components" {
    const allocator = std.testing.allocator;
    var revived = try URI.revive(allocator, .{ .scheme = "vscode-test", .authority = "host", .path = "/p", .query = "q", .fragment = "f" });
    defer revived.deinit();
    const text = try revived.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("vscode-test://host/p?q#f", text);
    try std.testing.expectEqualStrings("/p", uriToFsPath(&revived));
}

test "URI with changes updates components" {
    const allocator = std.testing.allocator;
    var base = try URI.parse(allocator, "before:some/file/path", false);
    defer base.deinit();
    var changed = try base.with(allocator, .{ .scheme = "after" });
    defer changed.deinit();
    const changed_text = try changed.toString(allocator);
    defer allocator.free(changed_text);
    try std.testing.expectEqualStrings("after:some/file/path", changed_text);

    var empty = try URI.from(allocator, .{ .scheme = "s" }, true);
    defer empty.deinit();
    var http = try empty.with(allocator, .{ .scheme = "http", .path = "/api/files/test.me", .query = "t=1234" });
    defer http.deinit();
    const http_text = try http.toString(allocator);
    defer allocator.free(http_text);
    try std.testing.expectEqualStrings("http:/api/files/test.me?t=1234", http_text);
}
