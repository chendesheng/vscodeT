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
        if (self.authority.len > 0 or
            std.mem.eql(u8, self.scheme, "file") or
            std.mem.eql(u8, self.scheme, "http") or
            std.mem.eql(u8, self.scheme, "https"))
        {
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

    pub fn equals(a: *const URI, b: *const URI) bool {
        return std.ascii.eqlIgnoreCase(a.scheme, b.scheme) and
            std.mem.eql(u8, a.authority, b.authority) and
            std.mem.eql(u8, a.path, b.path) and
            std.mem.eql(u8, a.query, b.query) and
            std.mem.eql(u8, a.fragment, b.fragment);
    }
};

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

pub fn make(allocator: Allocator, components: Components, strict: bool) !URI {
    var scheme = components.scheme;
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
    return make(allocator, .{ .scheme = "file", .path = normalized.items }, true);
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
    return make(allocator, .{
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
    try std.testing.expectError(error.InvalidScheme, make(allocator, .{ .scheme = "bad scheme" }, true));
    try std.testing.expectError(error.InvalidPath, make(allocator, .{ .scheme = "file", .authority = "host", .path = "relative" }, true));
}
