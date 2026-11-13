// TUI workspace file index for quick open.
//
// Upstream Go to File is backed by `ISearchService.fileSearch`, which uses the
// search process, `.gitignore` and `search.exclude`. The terminal has no
// search process, so this adapter walks the workspace folders lazily with
// `std.Io.Dir`. It honors `.gitignore`/`.ignore` through the ported
// `IgnoreFile` (nested files inherit their parent, so negations work), keeps a
// fixed exclude list for version control metadata and Zig build output, skips
// symbolic links and caps the index. `search.exclude` is not honored.
//
// Matching uses the ported `filters.fuzzyScore` subsequence scorer rather
// than the browser `fuzzyScorer.ts` path-aware scorer. Every whitespace-
// separated query word must match the label or the relative directory; label
// matches win when both match. Results are ordered by score, then shorter
// label, shorter path and path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const filters = @import("../vs/base/common/filters.zig");
const workspace_context = @import("../vs/workbench/services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const ignore_file_module = @import("../vs/workbench/services/search/common/ignoreFile.zig");
const IgnoreFile = ignore_file_module.IgnoreFile;
const anything = @import("../vs/workbench/contrib/search/browser/anythingQuickAccess.zig");
const FileMatch = anything.FileMatch;
const RecentFile = anything.RecentFile;

pub const Description = struct {
    label: []u8,
    description: []u8,

    pub fn deinit(self: Description, allocator: Allocator) void {
        allocator.free(self.label);
        allocator.free(self.description);
    }
};

const Entry = struct {
    path: []u8,
    label: []u8,
    description: []u8,
};

const QueueEntry = struct {
    path: []u8,
    /// Ignore chain that applies to the directory's children.
    ignore: ?*const IgnoreFile = null,
};

pub const max_ignore_file_size: usize = 1024 * 1024;

pub const WorkspaceFileIndex = struct {
    pub const MAX_ENTRIES = 100_000;

    allocator: Allocator,
    io: Io,
    workspace: *WorkspaceContextService,
    entries: std.array_list.Managed(Entry),
    queue: std.array_list.Managed(QueueEntry),
    /// Owns every ignore file loaded during the walk.
    ignore_files: std.array_list.Managed(*IgnoreFile),
    queue_index: usize = 0,
    started: bool = false,
    done: bool = false,
    capped: bool = false,
    max_entries: usize = MAX_ENTRIES,

    pub fn init(
        allocator: Allocator,
        io: Io,
        workspace: *WorkspaceContextService,
    ) !*WorkspaceFileIndex {
        const self = try allocator.create(WorkspaceFileIndex);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .workspace = workspace,
            .entries = std.array_list.Managed(Entry).init(allocator),
            .queue = std.array_list.Managed(QueueEntry).init(allocator),
            .ignore_files = std.array_list.Managed(*IgnoreFile).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *WorkspaceFileIndex) void {
        self.clear();
        self.entries.deinit();
        self.queue.deinit();
        self.ignore_files.deinit();
        self.allocator.destroy(self);
    }

    pub fn reset(self: *WorkspaceFileIndex, workspace: *WorkspaceContextService) void {
        self.clear();
        self.workspace = workspace;
    }

    fn clear(self: *WorkspaceFileIndex) void {
        for (self.entries.items) |entry| freeEntry(self.allocator, entry);
        self.entries.clearRetainingCapacity();
        for (self.queue.items) |entry| self.allocator.free(entry.path);
        self.queue.clearRetainingCapacity();
        for (self.ignore_files.items) |ignore_file| ignore_file.deinit();
        self.ignore_files.clearRetainingCapacity();
        self.queue_index = 0;
        self.started = false;
        self.done = false;
        self.capped = false;
    }

    pub fn isIndexing(self: *const WorkspaceFileIndex) bool {
        return self.started and !self.done;
    }

    pub fn start(self: *WorkspaceFileIndex) void {
        if (self.started) return;
        self.started = true;
        for (self.workspace.getWorkspace().folders.items) |*folder| {
            const copy = self.allocator.dupe(u8, folder.resource) catch continue;
            self.queue.append(.{ .path = copy }) catch {
                self.allocator.free(copy);
                continue;
            };
        }
        if (self.queue.items.len == 0) self.done = true;
    }

    /// Processes up to `max_directories` queued directories. Returns true when
    /// the index changed (entries were added or the walk finished).
    pub fn step(self: *WorkspaceFileIndex, max_directories: usize) bool {
        if (!self.started) self.start();
        if (self.done) return false;

        const entries_before = self.entries.items.len;
        var processed: usize = 0;
        while (processed < max_directories and self.queue_index < self.queue.items.len) : (processed += 1) {
            // `scanDirectory` appends to `queue`, which may reallocate it; copy
            // the entry before scanning so the slice cannot dangle.
            const directory = self.queue.items[self.queue_index];
            self.queue_index += 1;
            self.scanDirectory(directory) catch {};
            if (self.entries.items.len >= self.max_entries) {
                self.capped = true;
                self.done = true;
                break;
            }
        }

        if (self.queue_index >= self.queue.items.len) self.done = true;
        self.compactQueue();
        return self.entries.items.len != entries_before or self.done;
    }

    fn compactQueue(self: *WorkspaceFileIndex) void {
        if (self.queue_index == 0) return;
        if (self.queue_index < self.queue.items.len) return;
        for (self.queue.items) |entry| self.allocator.free(entry.path);
        self.queue.clearRetainingCapacity();
        for (self.ignore_files.items) |ignore_file| ignore_file.deinit();
        self.ignore_files.clearRetainingCapacity();
        self.queue_index = 0;
    }

    fn scanDirectory(self: *WorkspaceFileIndex, queued: QueueEntry) !void {
        var dir = Io.Dir.cwd().openDir(self.io, queued.path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        // The ignore file of this directory excludes its children.
        const ignore = try self.loadIgnoreFiles(queued.path, queued.ignore);

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const path = try std.fs.path.join(self.allocator, &.{ queued.path, entry.name });
            defer self.allocator.free(path);

            switch (entry.kind) {
                .sym_link => continue,
                .directory => {
                    if (isExcludedDirectory(entry.name)) continue;
                    // `isPathIncludedInTraversal` does not check the parent
                    // directories; the walk already did when it descended.
                    if (!ignore_file_module.isPathIncluded(ignore, path, true)) continue;
                    const copy = self.allocator.dupe(u8, path) catch continue;
                    self.queue.append(.{ .path = copy, .ignore = ignore }) catch {
                        self.allocator.free(copy);
                        continue;
                    };
                },
                .file => {
                    if (!ignore_file_module.isPathIncluded(ignore, path, false)) continue;
                    try self.addEntry(path, entry.name);
                },
                else => continue,
            }
        }
    }

    /// Loads `<directory>/.gitignore` and then `<directory>/.ignore` on top of
    /// `parent` and returns the innermost ignore file.
    fn loadIgnoreFiles(
        self: *WorkspaceFileIndex,
        directory: []const u8,
        parent: ?*const IgnoreFile,
    ) !?*const IgnoreFile {
        var current = parent;
        for (ignore_file_module.ignore_file_names) |name| {
            const path = try std.fs.path.join(self.allocator, &.{ directory, name });
            defer self.allocator.free(path);
            const contents = Io.Dir.cwd().readFileAlloc(
                self.io,
                path,
                self.allocator,
                .limited(max_ignore_file_size),
            ) catch continue;
            defer self.allocator.free(contents);

            const ignore_file = try IgnoreFile.init(self.allocator, contents, directory, current, false);
            errdefer ignore_file.deinit();
            try self.ignore_files.append(ignore_file);
            current = ignore_file;
        }
        return current;
    }

    fn addEntry(self: *WorkspaceFileIndex, path: []const u8, name: []const u8) !void {
        if (self.entries.items.len >= self.max_entries) return;
        const description = try self.describePath(path);
        errdefer self.allocator.free(description);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const label_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(label_copy);
        try self.entries.append(.{
            .path = path_copy,
            .label = label_copy,
            .description = description,
        });
    }

    fn describePath(self: *WorkspaceFileIndex, path: []const u8) ![]u8 {
        const folder = self.workspace.getWorkspaceFolder(path);
        const directory = std.fs.path.dirname(path) orelse "";
        if (folder) |root| {
            const relative = relativeDirectory(root.resource, directory);
            if (self.workspace.getWorkspace().folders.items.len > 1) {
                if (relative.len == 0) return self.allocator.dupe(u8, root.name);
                return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root.name, relative });
            }
            return self.allocator.dupe(u8, relative);
        }
        return self.allocator.dupe(u8, directory);
    }

    /// Label and relative description for an arbitrary path, used for recent
    /// editors that may not be in the index.
    pub fn describe(self: *WorkspaceFileIndex, allocator: Allocator, path: []const u8) !Description {
        const folder = self.workspace.getWorkspaceFolder(path);
        const directory = std.fs.path.dirname(path) orelse "";
        var description: []u8 = undefined;
        if (folder) |root| {
            const relative = relativeDirectory(root.resource, directory);
            if (self.workspace.getWorkspace().folders.items.len > 1) {
                description = if (relative.len == 0)
                    try allocator.dupe(u8, root.name)
                else
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root.name, relative });
            } else {
                description = try allocator.dupe(u8, relative);
            }
        } else {
            description = try allocator.dupe(u8, directory);
        }
        errdefer allocator.free(description);
        return .{
            .label = try allocator.dupe(u8, std.fs.path.basename(path)),
            .description = description,
        };
    }

    pub fn recentFiles(
        self: *WorkspaceFileIndex,
        allocator: Allocator,
        paths: []const []u8,
    ) ![]RecentFile {
        var result = std.array_list.Managed(RecentFile).init(allocator);
        for (paths) |path| {
            const description = try self.describe(allocator, path);
            try result.append(.{
                .path = try allocator.dupe(u8, path),
                .label = description.label,
                .description = description.description,
            });
        }
        return try result.toOwnedSlice();
    }

    pub fn search(
        self: *WorkspaceFileIndex,
        filter: []const u8,
        max_results: usize,
        allocator: Allocator,
    ) ![]FileMatch {
        const trimmed = std.mem.trim(u8, filter, " \t");
        if (trimmed.len == 0) return try allocator.alloc(FileMatch, 0);

        var scored = std.array_list.Managed(ScoredFile).init(allocator);
        defer scored.deinit();

        for (self.entries.items) |entry| {
            const match = try scoreEntry(allocator, trimmed, entry) orelse continue;
            try scored.append(match);
        }

        std.mem.sort(ScoredFile, scored.items, {}, struct {
            fn lessThan(_: void, a: ScoredFile, b: ScoredFile) bool {
                if (a.score != b.score) return a.score > b.score;
                if (a.file.label.len != b.file.label.len) return a.file.label.len < b.file.label.len;
                if (a.file.path.len != b.file.path.len) return a.file.path.len < b.file.path.len;
                return std.mem.lessThan(u8, a.file.path, b.file.path);
            }
        }.lessThan);

        const count = @min(scored.items.len, max_results);
        var result = std.array_list.Managed(FileMatch).init(allocator);
        for (scored.items[0..count]) |item| {
            try result.append(item.file);
        }
        return try result.toOwnedSlice();
    }

    fn scoreEntry(allocator: Allocator, filter: []const u8, entry: Entry) !?ScoredFile {
        var words = std.mem.tokenizeAny(u8, filter, " \t");
        var total: i32 = 0;
        var label_matches = std.array_list.Managed(filters.Match).init(allocator);
        var description_matches = std.array_list.Managed(filters.Match).init(allocator);

        while (words.next()) |word| {
            if (try filters.fuzzyScoreWithPositions(allocator, word, entry.label)) |scored| {
                defer allocator.free(scored.positions);
                total += scored.score;
                try appendPositions(&label_matches, scored.positions);
                continue;
            }
            if (try filters.fuzzyScoreWithPositions(allocator, word, entry.description)) |scored| {
                defer allocator.free(scored.positions);
                total += scored.score;
                try appendPositions(&description_matches, scored.positions);
                continue;
            }
            label_matches.deinit();
            description_matches.deinit();
            return null;
        }

        return .{
            .file = .{
                .path = entry.path,
                .label = entry.label,
                .description = entry.description,
                .label_matches = try label_matches.toOwnedSlice(),
                .description_matches = try description_matches.toOwnedSlice(),
            },
            .score = total,
        };
    }
};

const ScoredFile = struct {
    file: FileMatch,
    score: i32,
};

fn appendPositions(
    matches: *std.array_list.Managed(filters.Match),
    positions: []const usize,
) !void {
    for (positions) |position| {
        if (matches.items.len > 0 and matches.items[matches.items.len - 1].end == position) {
            matches.items[matches.items.len - 1].end = position + 1;
        } else {
            try matches.append(.{ .start = position, .end = position + 1 });
        }
    }
}

fn relativeDirectory(root: []const u8, directory: []const u8) []const u8 {
    if (directory.len == 0) return "";
    if (std.mem.eql(u8, root, directory)) return "";
    if (std.mem.startsWith(u8, directory, root)) {
        var index = root.len;
        if (index < directory.len and directory[index] == '/') index += 1;
        return directory[index..];
    }
    return directory;
}

fn isExcludedDirectory(name: []const u8) bool {
    const excluded = [_][]const u8{
        ".git",         ".hg",        ".svn",
        "node_modules", ".zig-cache", "zig-cache",
        "zig-out",
    };
    for (excluded) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn freeEntry(allocator: Allocator, entry: Entry) void {
    allocator.free(entry.path);
    allocator.free(entry.label);
    allocator.free(entry.description);
}

test "WorkspaceFileIndex: lazy walk, excludes and search" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    {
        var file = try tmp.dir.createFile(io, "alpha.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "alpha");
    }
    try tmp.dir.createDirPath(io, "nested");
    {
        var file = try tmp.dir.createFile(io, "nested/beta.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "beta");
    }
    try tmp.dir.createDirPath(io, ".git");
    {
        var file = try tmp.dir.createFile(io, ".git/ignored.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "ignored");
    }
    {
        var file = try tmp.dir.createFile(io, ".gitignore", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "ignored-by-ignore-file.txt\n");
    }
    {
        var file = try tmp.dir.createFile(io, "ignored-by-ignore-file.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "ignored");
    }

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();

    const index = try WorkspaceFileIndex.init(allocator, io, context);
    defer index.deinit();

    index.start();
    var guard: usize = 0;
    while (!index.done and guard < 100) : (guard += 1) _ = index.step(10);

    try std.testing.expect(index.entries.items.len >= 2);
    var found_ignored = false;
    for (index.entries.items) |entry| {
        if (std.mem.indexOf(u8, entry.path, "/.git/") != null) found_ignored = true;
        if (std.mem.endsWith(u8, entry.path, "ignored-by-ignore-file.txt")) found_ignored = true;
    }
    try std.testing.expect(!found_ignored);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const results = try index.search("beta", 10, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("beta.txt", results[0].label);
    try std.testing.expectEqualStrings("nested", results[0].description);
}
