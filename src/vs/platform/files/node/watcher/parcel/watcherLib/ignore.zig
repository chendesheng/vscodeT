// Port of `src/Glob.hh`/`Glob.cc` and the ignore handling from `Watcher` in
// `@parcel/watcher` v2.5.6 (external package).
//
// Upstream compiles `ignore` globs with picomatch and matches them against the
// path relative to the watched root. The terminal uses the repository's glob
// matcher instead. Non-glob entries are resolved to absolute paths and matched
// as prefixes, like upstream `ignorePaths`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glob = @import("../../../../../../base/common/glob.zig");
const files = @import("../../../../common/files.zig");

pub const Ignore = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    paths: []const []const u8,
    expression: ?glob.Expression,

    pub fn init(allocator: Allocator, root: []const u8, patterns: []const []const u8) !Ignore {
        var self = Ignore{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .paths = &.{},
            .expression = null,
        };
        errdefer self.arena.deinit();

        const arena = self.arena.allocator();
        var paths = std.array_list.Managed([]const u8).init(arena);
        var sources = std.array_list.Managed(glob.Source).init(arena);

        for (patterns) |pattern| {
            if (isGlob(pattern)) {
                try sources.append(.{ .relative = .{
                    .base = try arena.dupe(u8, root),
                    .pattern = try arena.dupe(u8, pattern),
                } });
            } else {
                const resolved = if (std.fs.path.isAbsolute(pattern))
                    try arena.dupe(u8, pattern)
                else
                    try std.fs.path.join(arena, &.{ root, pattern });
                try paths.append(resolved);
            }
        }

        self.paths = try paths.toOwnedSlice();
        if (sources.items.len > 0) {
            self.expression = try glob.Expression.initSources(arena, sources.items, .{});
        }
        return self;
    }

    pub fn deinit(self: *Ignore) void {
        self.arena.deinit();
    }

    pub fn isIgnored(self: *const Ignore, path: []const u8) bool {
        for (self.paths) |ignored| {
            if (std.mem.eql(u8, path, ignored)) return true;
            if (files.isParent(path, ignored, false)) return true;
        }
        if (self.expression) |expression| {
            if (expression.matches(path)) return true;
        }
        return false;
    }
};

pub fn isGlob(value: []const u8) bool {
    for (value) |ch| {
        switch (ch) {
            '*', '?', '[', ']', '{', '}' => return true,
            else => {},
        }
    }
    return false;
}

test "Ignore: paths and globs" {
    if (std.fs.path.sep != '/') return;
    var ignore = try Ignore.init(std.testing.allocator, "/root", &.{ "build", "**/node_modules/**" });
    defer ignore.deinit();
    try std.testing.expect(ignore.isIgnored("/root/build"));
    try std.testing.expect(ignore.isIgnored("/root/build/out"));
    try std.testing.expect(ignore.isIgnored("/root/pkg/node_modules/x"));
    try std.testing.expect(!ignore.isIgnored("/root/src/main.zig"));
}
