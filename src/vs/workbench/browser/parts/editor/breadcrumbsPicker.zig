// Port of the portable file-picker decisions of
// `src/vs/workbench/browser/parts/editor/breadcrumbsPicker.ts`.
//
// Upstream `BreadcrumbsFilePicker` is a tree inside a context view: selecting
// a breadcrumb opens the tree at the clicked element's parent directory and
// focuses the clicked element. This file keeps those decisions and the
// immediate-children/sort rules; the terminal workbench maps the entries to the
// existing quick pick. The outline picker's tree/quick-pick sources are not
// ported because the TUI ships no document-symbol provider yet.
//
// Terminal adaptations: `IFileService.resolve` becomes a direct `Io.Dir`
// iteration; a folder selection drills into the folder by reopening the picker
// instead of expanding a tree row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const model_mod = @import("breadcrumbsModel.zig");
const FileElement = model_mod.FileElement;

pub const Entry = struct {
    path: []u8,
    name: []u8,
    is_dir: bool,

    pub fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
    }
};

/// The directory whose immediate children the picker shows for `file`.
/// Upstream shows the workspace for a root folder and the parent directory for
/// every other element. The TUI has no workspace tree in the picker, so a root
/// folder lists its own children.
pub fn inputDirectory(file: *const FileElement) []const u8 {
    if (file.kind == .ROOT_FOLDER) return file.path;
    return dirnamePath(file.path);
}

/// Lists the immediate children of `directory`, directories first and then
/// case-insensitive by name. The caller frees the returned entries.
pub fn list(allocator: Allocator, io: Io, directory: []const u8) ![]Entry {
    var dir = try Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);

    var entries = std.array_list.Managed(Entry).init(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (entry.kind != .file and entry.kind != .directory) continue;
        const path = try std.fs.path.join(allocator, &.{ directory, entry.name });
        errdefer allocator.free(path);
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try entries.append(.{
            .path = path,
            .name = name,
            .is_dir = entry.kind == .directory,
        });
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    return try entries.toOwnedSlice();
}

pub fn freeEntries(allocator: Allocator, entries: []Entry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn dirnamePath(path: []const u8) []const u8 {
    var end = path.len;
    if (end == 0) return path;
    while (end > 0 and isSeparator(path[end - 1])) end -= 1;
    var index = end;
    while (index > 0) : (index -= 1) {
        if (isSeparator(path[index - 1])) {
            const parent = index - 1;
            if (parent == 0) return path[0..1];
            if (parent == 2 and path[1] == ':') return path[0..3];
            return path[0..parent];
        }
    }
    return path;
}
