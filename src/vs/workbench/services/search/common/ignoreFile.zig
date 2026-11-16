// Port of `src/vs/workbench/services/search/common/ignoreFile.ts`.
//
// `IgnoreFile` parses the contents of one `.gitignore`-shaped file and decides
// whether a path is excluded. Each directory in a workspace can contribute an
// `IgnoreFile`; `parent` links to the enclosing directory's file, so a nested
// `.gitignore` inherits and can re-include (`!pattern`) paths ignored higher
// up, like git and ripgrep.
//
// Upstream returns a closure from `parseIgnoreFile` and stores it in
// `isPathIgnored`. The closure is kept here as the `isPathIgnored` method over
// the four parsed expressions that upstream builds inside the closure
// (`isFileIgnored`, `isFileIncluded`, `isDirIgnored`, `isDirIncluded`).
// Upstream throws on malformed paths; the Zig port returns
// `error.UnexpectedPathFormat` instead, and `init` takes the optional parent
// as a pointer whose lifetime has to outlive the child.

const std = @import("std");
const Allocator = std.mem.Allocator;

const glob = @import("../../../../base/common/glob.zig");
const strings = @import("../../../../base/common/strings.zig");

/// Names of the ignore files a workspace walker reads, in the order git and
/// ripgrep apply them: `.gitignore` first, `.ignore` on top.
pub const ignore_file_names = [_][]const u8{ ".gitignore", ".ignore" };

pub const IgnoreFile = struct {
    allocator: Allocator,
    /// Owns the parsed expressions; reset by `updateContents`.
    arena: std.heap.ArenaAllocator,
    /// Directory of the ignore file, always ending with `/`. Owned by
    /// `allocator` so it survives an arena reset.
    location: []u8,
    parent: ?*const IgnoreFile,
    ignore_case: bool,

    file_ignored: glob.Expression = glob.Expression.empty,
    file_included: glob.Expression = glob.Expression.empty,
    dir_ignored: glob.Expression = glob.Expression.empty,
    dir_included: glob.Expression = glob.Expression.empty,

    /// Creates an ignore file for `contents` at `location` (the directory that
    /// contains it). `parent` is the ignore file of the enclosing directory.
    pub fn init(
        allocator: Allocator,
        contents: []const u8,
        location: []const u8,
        parent: ?*const IgnoreFile,
        ignore_case: bool,
    ) !*IgnoreFile {
        const self = try allocator.create(IgnoreFile);
        errdefer allocator.destroy(self);

        const normalized = try normalizeLocation(allocator, location);
        errdefer allocator.free(normalized);

        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .location = normalized,
            .parent = parent,
            .ignore_case = ignore_case,
        };
        errdefer self.arena.deinit();
        try self.parse(contents);
        return self;
    }

    pub fn deinit(self: *IgnoreFile) void {
        self.arena.deinit();
        self.allocator.free(self.location);
        self.allocator.destroy(self);
    }

    /// Updates the contents of the ignore file, preserving the location and
    /// parent.
    pub fn updateContents(self: *IgnoreFile, contents: []const u8) !void {
        try self.parse(contents);
    }

    /// Returns true if a path in a traversable directory has not been ignored.
    ///
    /// Note: for performance reasons this does not check whether parent
    /// directories have been ignored, so it should always be used in tandem
    /// with a traversal that checks each directory. In cases where a path must
    /// be tested in isolation, use `isArbitraryPathIgnored`.
    pub fn isPathIncludedInTraversal(self: *const IgnoreFile, path: []const u8, is_dir: bool) !bool {
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        try validatePath(normalized);
        return !self.isPathIgnored(normalized, is_dir);
    }

    /// Returns true if an arbitrary path has been ignored. This is an expensive
    /// operation and should only be used outside of traversals.
    pub fn isArbitraryPathIgnored(self: *const IgnoreFile, path: []const u8, is_dir: bool) !bool {
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);
        try validatePath(normalized);

        var segments = std.array_list.Managed([]const u8).init(self.allocator);
        defer segments.deinit();
        var iterator = std.mem.splitScalar(u8, normalized, '/');
        while (iterator.next()) |segment| {
            if (segment.len > 0) try segments.append(segment);
        }

        var walking_path = std.array_list.Managed(u8).init(self.allocator);
        defer walking_path.deinit();
        for (segments.items, 0..) |segment, index| {
            try walking_path.append('/');
            try walking_path.appendSlice(segment);
            const is_last = index + 1 == segments.items.len;
            const included = try self.isPathIncludedInTraversal(
                walking_path.items,
                if (is_last) is_dir else true,
            );
            if (!included) return true;
        }
        return false;
    }

    fn isPathIgnored(self: *const IgnoreFile, path: []const u8, is_dir: bool) bool {
        const starts_with_location = if (self.ignore_case)
            strings.startsWithIgnoreCase(path, self.location)
        else
            std.mem.startsWith(u8, path, self.location);
        if (!starts_with_location) return false;

        const dir_included = is_dir and self.dir_included.matches(path);
        if (is_dir and self.dir_ignored.matches(path) and !dir_included) return true;

        const file_included = self.file_included.matches(path);
        if (self.file_ignored.matches(path) and !file_included) return true;

        // If this file explicitly un-ignores a path via a negation pattern
        // (e.g., `!.myconfig/`), do not delegate to the parent. In git, a
        // negation in a child .gitignore overrides a positive pattern in a
        // parent or global .gitignore.
        if (dir_included or file_included) return false;

        if (self.parent) |parent| return parent.isPathIgnored(path, is_dir);

        return false;
    }

    fn parse(self: *IgnoreFile, contents: []const u8) !void {
        _ = self.arena.reset(.retain_capacity);
        // A failed parse must not leave slices into the reset arena behind.
        errdefer {
            self.file_ignored = glob.Expression.empty;
            self.file_included = glob.Expression.empty;
            self.dir_ignored = glob.Expression.empty;
            self.dir_included = glob.Expression.empty;
        }
        const arena = self.arena.allocator();

        var content_lines = std.array_list.Managed([]const u8).init(arena);
        var iterator = std.mem.splitScalar(u8, contents, '\n');
        while (iterator.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            if (line.len == 0 or line[0] == '#') continue;
            try content_lines.append(line);
        }

        // Lines that end with `/` only apply to directories. Upstream splits
        // the lines with `includes('!')`, so a `!` anywhere in a line marks it
        // as a negation.
        var file_ignored_lines = std.array_list.Managed([]const u8).init(arena);
        var file_included_lines = std.array_list.Managed([]const u8).init(arena);
        var dir_ignored_lines = std.array_list.Managed([]const u8).init(arena);
        var dir_included_lines = std.array_list.Managed([]const u8).init(arena);

        for (content_lines.items) |line| {
            const dir_only = std.mem.endsWith(u8, line, "/");
            if (std.mem.indexOfScalar(u8, line, '!') == null) {
                if (!dir_only) try file_ignored_lines.append(line);
                try dir_ignored_lines.append(line);
            } else {
                // Upstream's `line.replace(/!/g, '')`.
                var stripped = std.array_list.Managed(u8).init(arena);
                for (line) |ch| {
                    if (ch != '!') try stripped.append(ch);
                }
                const pattern = try stripped.toOwnedSlice();
                if (!dir_only) try file_included_lines.append(pattern);
                try dir_included_lines.append(pattern);
            }
        }

        self.file_ignored = try self.linesToExpression(file_ignored_lines.items, true);
        self.file_included = try self.linesToExpression(file_included_lines.items, false);
        self.dir_ignored = try self.linesToExpression(dir_ignored_lines.items, true);
        self.dir_included = try self.linesToExpression(dir_included_lines.items, false);
    }

    fn linesToExpression(
        self: *IgnoreFile,
        lines: []const []const u8,
        trim_for_exclusions: bool,
    ) !glob.Expression {
        const arena = self.arena.allocator();
        var patterns = std.array_list.Managed([]const u8).init(arena);
        for (lines) |line| {
            try patterns.append(try self.lineToGlob(arena, line));
        }
        return glob.Expression.init(arena, patterns.items, .{
            .trim_for_exclusions = trim_for_exclusions,
            .ignore_case = self.ignore_case,
        });
    }

    /// Converts one `.gitignore` line to the glob that `location` prefixes.
    /// Lines without a slash (or with a trailing slash) match at any depth;
    /// other lines are anchored to the directory of the ignore file.
    fn lineToGlob(self: *const IgnoreFile, arena: Allocator, line: []const u8) ![]const u8 {
        // A negation that removes every character (`!`) produces no pattern.
        if (line.len == 0) return "";
        const first_separator = std.mem.indexOfScalar(u8, line, '/');
        if (first_separator == null or first_separator.? == line.len - 1) {
            return std.fmt.allocPrint(arena, "**/{s}", .{line});
        }

        var value = line;
        if (first_separator.? == 0) {
            if (self.location.len > 0 and self.location[self.location.len - 1] == '/') {
                value = line[1..];
            }
        } else if (self.location.len == 0 or self.location[self.location.len - 1] != '/') {
            value = try std.fmt.allocPrint(arena, "/{s}", .{line});
        }
        return std.fmt.allocPrint(arena, "{s}{s}", .{ self.location, value });
    }
};

/// Traversal helper for the workspace walkers. A missing ignore file includes
/// every path; a malformed path (for example a relative workspace folder) is
/// treated as included instead of failing the walk.
pub fn isPathIncluded(ignore: ?*const IgnoreFile, path: []const u8, is_dir: bool) bool {
    const file = ignore orelse return true;
    return file.isPathIncludedInTraversal(path, is_dir) catch true;
}

fn normalizePath(allocator: Allocator, path: []const u8) ![]u8 {
    const copy = try allocator.dupe(u8, path);
    for (copy) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return copy;
}

fn normalizeLocation(allocator: Allocator, location: []const u8) ![]u8 {
    var copy = try allocator.dupe(u8, location);
    for (copy) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    if (copy.len == 0 or copy[copy.len - 1] != '/') {
        const extended = try allocator.alloc(u8, copy.len + 1);
        @memcpy(extended[0..copy.len], copy);
        extended[copy.len] = '/';
        allocator.free(copy);
        copy = extended;
    }
    return copy;
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path[path.len - 1] == '/') return error.UnexpectedPathFormat;
    if (path[0] == '/') return;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and path[2] == '/') return;
    return error.UnexpectedPathFormat;
}
