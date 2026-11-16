// Port of the watcher-relevant parts of
// `src/vs/platform/files/common/files.ts`.
//
// Terminal adaptation: resources are canonical path strings instead of `URI`s.
// `FileChangesEvent` performs the same `contains`/`affects` checks with linear
// scans over the change lists instead of upstream's `TernarySearchTree`; the
// observable behavior (including treating a deleted parent as a match for a
// child resource) is unchanged.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Possible changes that can occur to a file.
pub const FileChangeType = enum(u2) {
    UPDATED = 0,
    ADDED = 1,
    DELETED = 2,
};

/// Bit mask used by watch requests to filter emitted changes.
pub const FileChangeFilter = struct {
    pub const UPDATED: u8 = 1 << 1;
    pub const ADDED: u8 = 1 << 2;
    pub const DELETED: u8 = 1 << 3;

    pub const all: u8 = UPDATED | ADDED | DELETED;
};

/// Identifies a single change in a file.
pub const FileChange = struct {
    type: FileChangeType,
    /// Path of the changed file. The slice is owned by the publisher and is
    /// only guaranteed to stay valid for the duration of the synchronous
    /// listener call.
    resource: []const u8,
    /// Correlation id of the matching watch request, when one was provided.
    cId: ?u32 = null,
};

/// Mirrors upstream `isParent`: returns true when `path` is a child of
/// `candidate`. Equal paths and empty inputs are never parents.
pub fn isParent(path: []const u8, candidate: []const u8, ignore_case: bool) bool {
    if (path.len == 0 or candidate.len == 0) return false;
    if (path.len <= candidate.len) return false;

    if (isSeparator(candidate[candidate.len - 1])) {
        return startsWithIgnoreCaseOrExact(path, candidate, ignore_case);
    }
    if (path.len < candidate.len + 1) return false;
    if (!isSeparator(path[candidate.len])) return false;
    return startsWithIgnoreCaseOrExact(path[0..candidate.len], candidate, ignore_case);
}

fn isSeparator(ch: u8) bool {
    if (ch == std.fs.path.sep) return true;
    // Accept `/` on Windows as well. Tests and a number of upstream callers
    // construct logical paths with `/` even when the native separator is `\`.
    return std.fs.path.sep == '\\' and ch == '/';
}

fn startsWithIgnoreCaseOrExact(path: []const u8, prefix: []const u8, ignore_case: bool) bool {
    if (ignore_case) return std.ascii.startsWithIgnoreCase(path, prefix);
    return std.mem.startsWith(u8, path, prefix);
}

fn pathEqual(a: []const u8, b: []const u8, ignore_case: bool) bool {
    if (ignore_case) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

fn isEqualOrParent(path: []const u8, base: []const u8, ignore_case: bool) bool {
    if (pathEqual(path, base, ignore_case)) return true;
    return isParent(path, base, ignore_case);
}

/// A normalized file change event, mirroring upstream `FileChangesEvent`.
pub const FileChangesEvent = struct {
    allocator: Allocator,
    ignore_path_casing: bool,
    raw_added: []const []const u8,
    raw_updated: []const []const u8,
    raw_deleted: []const []const u8,
    correlation_id: ?u32 = null,
    mixed_correlation: bool = false,

    pub fn init(
        allocator: Allocator,
        changes: []const FileChange,
        ignore_path_casing: bool,
    ) !FileChangesEvent {
        var added = std.array_list.Managed([]const u8).init(allocator);
        errdefer added.deinit();
        var updated = std.array_list.Managed([]const u8).init(allocator);
        errdefer updated.deinit();
        var deleted = std.array_list.Managed([]const u8).init(allocator);
        errdefer deleted.deinit();

        var correlation_id: ?u32 = null;
        var correlation_set = false;
        var mixed = false;

        for (changes) |change| {
            switch (change.type) {
                .ADDED => try added.append(change.resource),
                .UPDATED => try updated.append(change.resource),
                .DELETED => try deleted.append(change.resource),
            }

            if (!mixed) {
                if (change.cId) |id| {
                    if (!correlation_set) {
                        correlation_id = id;
                        correlation_set = true;
                    } else if (correlation_id != id) {
                        mixed = true;
                    }
                } else if (correlation_set) {
                    mixed = true;
                }
            }
        }

        const raw_added = try added.toOwnedSlice();
        errdefer allocator.free(raw_added);
        const raw_updated = try updated.toOwnedSlice();
        errdefer allocator.free(raw_updated);
        const raw_deleted = try deleted.toOwnedSlice();
        errdefer allocator.free(raw_deleted);

        return .{
            .allocator = allocator,
            .ignore_path_casing = ignore_path_casing,
            .raw_added = raw_added,
            .raw_updated = raw_updated,
            .raw_deleted = raw_deleted,
            .correlation_id = if (mixed) null else correlation_id,
            .mixed_correlation = mixed,
        };
    }

    pub fn deinit(self: *FileChangesEvent) void {
        self.allocator.free(self.raw_added);
        self.allocator.free(self.raw_updated);
        self.allocator.free(self.raw_deleted);
    }

    /// Returns whether the event matches `resource`. Deleting a parent folder
    /// also matches the resource.
    pub fn contains(self: *const FileChangesEvent, resource: []const u8, types: []const FileChangeType) bool {
        return self.doContains(resource, false, types);
    }

    /// Returns whether the event matches `resource` or one of its children.
    pub fn affects(self: *const FileChangesEvent, resource: []const u8, types: []const FileChangeType) bool {
        return self.doContains(resource, true, types);
    }

    fn doContains(
        self: *const FileChangesEvent,
        resource: []const u8,
        include_children: bool,
        types: []const FileChangeType,
    ) bool {
        const has_types_filter = types.len > 0;
        const ignore_case = self.ignore_path_casing;

        if (!has_types_filter or hasType(types, .ADDED)) {
            for (self.raw_added) |changed| {
                if (pathEqual(changed, resource, ignore_case)) return true;
                if (include_children and isParent(changed, resource, ignore_case)) return true;
            }
        }

        if (!has_types_filter or hasType(types, .UPDATED)) {
            for (self.raw_updated) |changed| {
                if (pathEqual(changed, resource, ignore_case)) return true;
                if (include_children and isParent(changed, resource, ignore_case)) return true;
            }
        }

        if (!has_types_filter or hasType(types, .DELETED)) {
            for (self.raw_deleted) |changed| {
                // Deleted parents match children, including the resource itself.
                if (pathEqual(changed, resource, ignore_case)) return true;
                if (isParent(resource, changed, ignore_case)) return true;
                if (include_children and isParent(changed, resource, ignore_case)) return true;
            }
        }

        return false;
    }

    pub fn gotAdded(self: *const FileChangesEvent) bool {
        return self.raw_added.len > 0;
    }

    pub fn gotDeleted(self: *const FileChangesEvent) bool {
        return self.raw_deleted.len > 0;
    }

    pub fn gotUpdated(self: *const FileChangesEvent) bool {
        return self.raw_updated.len > 0;
    }

    pub fn correlates(self: *const FileChangesEvent, correlation_id: u32) bool {
        return !self.mixed_correlation and self.correlation_id != null and self.correlation_id.? == correlation_id;
    }

    pub fn hasCorrelation(self: *const FileChangesEvent) bool {
        return !self.mixed_correlation and self.correlation_id != null;
    }
};

fn hasType(types: []const FileChangeType, value: FileChangeType) bool {
    for (types) |candidate| {
        if (candidate == value) return true;
    }
    return false;
}

test "isParent: posix" {
    if (std.fs.path.sep != '/') return;
    try std.testing.expect(isParent("/some/path", "/", true));
    try std.testing.expect(isParent("/some/path", "/some", true));
    try std.testing.expect(isParent("/some/path", "/some/", true));
    try std.testing.expect(isParent("/someöäü/path", "/someöäü", true));
    try std.testing.expect(isParent("/foo/bar/test.ts", "/foo/bar", true));
    try std.testing.expect(!isParent("/some/path", "/some/path", true));
    try std.testing.expect(!isParent("/foo/bar/test.ts", "/foo/barr", true));
    try std.testing.expect(!isParent("/foo/bar/test.ts", "/foo/bar/test", true));
    try std.testing.expect(isParent("/some/path", "/SOME", true));
    try std.testing.expect(!isParent("/some/path", "/SOME", false));
}

test "FileChangesEvent: contains and affects" {
    const allocator = std.testing.allocator;
    const changes = [_]FileChange{
        .{ .type = .UPDATED, .resource = "/foo/updated.txt" },
        .{ .type = .UPDATED, .resource = "/foo/otherupdated.txt" },
        .{ .type = .ADDED, .resource = "/added.txt" },
        .{ .type = .DELETED, .resource = "/bar/deleted.txt" },
        .{ .type = .DELETED, .resource = "/bar/folder" },
        .{ .type = .DELETED, .resource = "/BAR/FOLDER" },
    };

    for ([_]bool{ false, true }) |ignore_case| {
        var event = try FileChangesEvent.init(allocator, &changes, ignore_case);
        defer event.deinit();

        try std.testing.expect(!event.contains("/foo", &.{.UPDATED}));
        try std.testing.expect(event.affects("/foo", &.{.UPDATED}));
        try std.testing.expect(event.contains("/foo/updated.txt", &.{.UPDATED}));
        try std.testing.expect(event.contains("/bar/folder", &.{.DELETED}));
        try std.testing.expect(event.contains("/bar/folder/somefile", &.{.DELETED}));
        try std.testing.expect(!event.contains("/bar/folder2/somefile", &.{.DELETED}));
        try std.testing.expect(event.gotAdded());
        try std.testing.expect(event.gotUpdated());
        try std.testing.expect(event.gotDeleted());
    }
}

test "FileChangesEvent: correlation" {
    const allocator = std.testing.allocator;
    const changes = [_]FileChange{
        .{ .type = .ADDED, .resource = "/a", .cId = 7 },
        .{ .type = .ADDED, .resource = "/b", .cId = 7 },
    };
    var event = try FileChangesEvent.init(allocator, &changes, false);
    defer event.deinit();
    try std.testing.expect(event.hasCorrelation());
    try std.testing.expect(event.correlates(7));
    try std.testing.expect(!event.correlates(8));
}
