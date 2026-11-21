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

/// Mirrors upstream `FileKind`.
pub const FileKind = enum(u2) {
    FILE = 0,
    FOLDER = 1,
    ROOT_FOLDER = 2,
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

/// Mirror of upstream `FileType` bit flags.
pub const FileType = struct {
    pub const Unknown: u8 = 0;
    pub const File: u8 = 1;
    pub const Directory: u8 = 2;
    pub const SymbolicLink: u8 = 64;

    pub fn isFile(value: u8) bool {
        return value & File != 0;
    }

    pub fn isDirectory(value: u8) bool {
        return value & Directory != 0;
    }

    pub fn isSymbolicLink(value: u8) bool {
        return value & SymbolicLink != 0;
    }
};

/// Mirror of upstream `FileOperation`.
pub const FileOperation = enum { CREATE, DELETE, MOVE, COPY, WRITE };

test "FileType flags" {
    try std.testing.expect(FileType.isFile(FileType.File));
    try std.testing.expect(FileType.isDirectory(FileType.Directory));
    try std.testing.expect(FileType.isFile(FileType.File | FileType.SymbolicLink));
    try std.testing.expect(!FileType.isDirectory(FileType.File));
    try std.testing.expect(!FileType.isFile(FileType.Unknown));
}

/// Mirror of the metadata fields of upstream `IFileStat` used by the terminal
/// file service.
pub const FileStat = struct {
    resource: []const u8,
    name: []const u8,
    type: u8 = FileType.Unknown,
    size: u64 = 0,
    mtime: u64 = 0,
    ctime: u64 = 0,
    etag: []const u8 = "",
    readonly: bool = false,
    locked: bool = false,
    executable: bool = false,
    children: ?[]const FileStat = null,

    pub fn isFile(self: *const FileStat) bool {
        return FileType.isFile(self.type);
    }

    pub fn isDirectory(self: *const FileStat) bool {
        return FileType.isDirectory(self.type);
    }

    pub fn isSymbolicLink(self: *const FileStat) bool {
        return FileType.isSymbolicLink(self.type);
    }
};

test "FileStat type helpers" {
    const stat = FileStat{ .resource = "/a", .name = "a", .type = FileType.Directory };
    try std.testing.expect(stat.isDirectory());
    try std.testing.expect(!stat.isFile());
    const file = FileStat{ .resource = "/a/b", .name = "b", .type = FileType.File | FileType.SymbolicLink };
    try std.testing.expect(file.isFile());
    try std.testing.expect(file.isSymbolicLink());
}

// ---------------------------------------------------------------------------
// File system provider contracts
// (port of the provider-facing subset of the same upstream `files.ts`)
// ---------------------------------------------------------------------------

/// Bit values of upstream `FilePermission`.
pub const FilePermission = struct {
    pub const Readonly: u8 = 1 << 0;
};

/// Mirrors upstream `IStat`.
pub const IStat = struct {
    /// `FileType` bits.
    type: u8,
    mtime: i64,
    ctime: i64,
    size: u64,
    permissions: ?u8 = null,
};

/// Mirrors upstream `IFileStat` (the `FileService`-resolved stat).
pub const IFileStat = struct {
    name: []const u8,
    resource: []const u8,
    type: u8,
    mtime: i64,
    ctime: i64,
    size: u64,
    etag: ?[]const u8 = null,
    readonly: bool = false,
    executable: bool = false,
    children: ?[]IFileStat = null,
    isRoot: bool = false,
};

/// Bit values of upstream `FileSystemProviderCapabilities`.
pub const FileSystemProviderCapabilities = struct {
    pub const None: u32 = 0;
    pub const FileReadWrite: u32 = 1 << 1;
    pub const FileOpenReadWriteClose: u32 = 1 << 2;
    pub const FileReadStream: u32 = 1 << 4;
    pub const FileFolderCopy: u32 = 1 << 3;
    pub const PathCaseSensitive: u32 = 1 << 10;
    pub const Readonly: u32 = 1 << 11;
    pub const Trash: u32 = 1 << 12;
    pub const FileWriteUnlock: u32 = 1 << 13;
    pub const FileAtomicRead: u32 = 1 << 14;
    pub const FileAtomicWrite: u32 = 1 << 15;
    pub const FileAtomicDelete: u32 = 1 << 16;
    pub const FileClone: u32 = 1 << 17;
    pub const FileRealpath: u32 = 1 << 18;
    pub const FileAppend: u32 = 1 << 19;
    pub const FileAtomicRename: u32 = 1 << 20;
};

/// Mirrors upstream `FileSystemProviderErrorCode`; Zig errors replace the
/// thrown error object.
pub const FileSystemProviderError = error{
    FileNotFound,
    FileExists,
    FileNotADirectory,
    FileIsADirectory,
    FileReadonly,
    NoPermissions,
    Unavailable,
    Unknown,
    OutOfMemory,
};

/// Mirrors the provider's `onDidChangeFile` payload.
pub const IFileChange = struct {
    type: FileChangeType,
    resource: []const u8,
};

pub const IFileDeleteOptions = struct {
    recursive: bool = false,
    useTrash: bool = false,
    atomic: bool = false,
};

pub const IFileOverwriteOptions = struct {
    overwrite: bool = false,
    atomic: bool = false,
    unlock: bool = false,
};

pub const IFileWriteOptions = struct {
    create: bool,
    overwrite: bool,
    append: bool = false,
    atomic: bool = false,
    unlock: bool = false,
};

pub const IFileOpenOptions = struct {
    create: bool,
    overwrite: bool,
    append: bool = false,
    unlock: bool = false,
};

pub const IWatchOptions = struct {
    recursive: bool = false,
    excludes: []const []const u8 = &.{},
    filter: ?u8 = null,
};

pub const IFileChangeListener = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, changes: []const IFileChange) void,
};

/// The terminal provider contract. Resources are canonical path strings (the
/// repository-wide terminal substitution for `URI`). Mutations are synchronous;
/// `readFile`/`readdir` allocate results that the caller frees with the same
/// allocator.
pub const IFileSystemProvider = struct {
    context: *anyopaque,
    capabilities: *const fn (context: *anyopaque) u32,
    stat: *const fn (context: *anyopaque, resource: []const u8) FileSystemProviderError!IStat,
    mkdir: *const fn (context: *anyopaque, resource: []const u8) FileSystemProviderError!void,
    readdir: *const fn (context: *anyopaque, resource: []const u8) FileSystemProviderError![]DirectoryEntry,
    delete: *const fn (context: *anyopaque, resource: []const u8, options: IFileDeleteOptions) FileSystemProviderError!void,
    rename: *const fn (context: *anyopaque, from: []const u8, to: []const u8, options: IFileOverwriteOptions) FileSystemProviderError!void,
    read_file: *const fn (context: *anyopaque, resource: []const u8) FileSystemProviderError![]u8,
    write_file: *const fn (context: *anyopaque, resource: []const u8, content: []const u8, options: IFileWriteOptions) FileSystemProviderError!void,
    open: *const fn (context: *anyopaque, resource: []const u8, options: IFileOpenOptions) FileSystemProviderError!u32,
    close: *const fn (context: *anyopaque, fd: u32) FileSystemProviderError!void,
    read: *const fn (context: *anyopaque, fd: u32, position: usize, data: []u8, offset: usize, length: usize) FileSystemProviderError!usize,
    write: *const fn (context: *anyopaque, fd: u32, position: usize, data: []const u8, offset: usize, length: usize) FileSystemProviderError!usize,
    watch: *const fn (context: *anyopaque, resource: []const u8, options: IWatchOptions) FileSystemProviderError!void,
    add_change_listener: *const fn (context: *anyopaque, listener: IFileChangeListener) void,
    remove_change_listener: *const fn (context: *anyopaque, listener: IFileChangeListener) void,

    pub fn getCapabilities(self: IFileSystemProvider) u32 {
        return self.capabilities(self.context);
    }
    pub fn getStat(self: IFileSystemProvider, resource: []const u8) FileSystemProviderError!IStat {
        return self.stat(self.context, resource);
    }
    pub fn makeDirectory(self: IFileSystemProvider, resource: []const u8) FileSystemProviderError!void {
        return self.mkdir(self.context, resource);
    }
    pub fn getDirectoryEntries(self: IFileSystemProvider, resource: []const u8) FileSystemProviderError![]DirectoryEntry {
        return self.readdir(self.context, resource);
    }
    pub fn deleteResource(self: IFileSystemProvider, resource: []const u8, options: IFileDeleteOptions) FileSystemProviderError!void {
        return self.delete(self.context, resource, options);
    }
    pub fn renameResource(self: IFileSystemProvider, from: []const u8, to: []const u8, options: IFileOverwriteOptions) FileSystemProviderError!void {
        return self.rename(self.context, from, to, options);
    }
    pub fn readFile(self: IFileSystemProvider, resource: []const u8) FileSystemProviderError![]u8 {
        return self.read_file(self.context, resource);
    }
    pub fn writeFile(self: IFileSystemProvider, resource: []const u8, content: []const u8, options: IFileWriteOptions) FileSystemProviderError!void {
        return self.write_file(self.context, resource, content, options);
    }
    pub fn addChangeListener(self: IFileSystemProvider, listener: IFileChangeListener) void {
        self.add_change_listener(self.context, listener);
    }
    pub fn removeChangeListener(self: IFileSystemProvider, listener: IFileChangeListener) void {
        self.remove_change_listener(self.context, listener);
    }
};

/// One `readdir` result.
pub const DirectoryEntry = struct {
    name: []const u8,
    type: u8,
};

/// Port of upstream `ByteSize.formatSize` (the terminal has no localized
/// formatting, so the units are plain ASCII).
pub const ByteSize = struct {
    pub const KB: u64 = 1024;
    pub const MB: u64 = KB * KB;
    pub const GB: u64 = MB * KB;
    pub const TB: u64 = GB * KB;

    pub fn formatSize(buffer: []u8, size: u64) []const u8 {
        if (size < KB) {
            return std.fmt.bufPrint(buffer, "{d}B", .{size}) catch "0B";
        }
        if (size < MB) {
            return std.fmt.bufPrint(buffer, "{d:.2}KB", .{@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(KB))}) catch "0KB";
        }
        if (size < GB) {
            return std.fmt.bufPrint(buffer, "{d:.2}MB", .{@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(MB))}) catch "0MB";
        }
        if (size < TB) {
            return std.fmt.bufPrint(buffer, "{d:.2}GB", .{@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(GB))}) catch "0GB";
        }
        return std.fmt.bufPrint(buffer, "{d:.2}TB", .{@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(TB))}) catch "0TB";
    }
};

test "files: ByteSize formatting matches VS Code" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0B", ByteSize.formatSize(&buffer, 0));
    try std.testing.expectEqualStrings("1023B", ByteSize.formatSize(&buffer, 1023));
    try std.testing.expectEqualStrings("1.00KB", ByteSize.formatSize(&buffer, 1024));
    try std.testing.expectEqualStrings("1.50KB", ByteSize.formatSize(&buffer, 1536));
    try std.testing.expectEqualStrings("2.50MB", ByteSize.formatSize(&buffer, 5 * ByteSize.MB / 2));
    try std.testing.expectEqualStrings("1.50GB", ByteSize.formatSize(&buffer, 3 * ByteSize.GB / 2));
}
