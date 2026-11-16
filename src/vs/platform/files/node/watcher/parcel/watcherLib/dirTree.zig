// Port of `src/DirTree.cc` from `@parcel/watcher` v2.5.6 (external package).
//
// Snapshot files keep upstream's text layout: a count line followed by
// `len<path><mtime_ns> <is_dir>\n` entries. `getChanges` compares a live tree
// against a snapshot and appends create/update/delete events.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const event_mod = @import("event.zig");
const EventList = event_mod.EventList;

pub const DirEntry = struct {
    path: []const u8,
    mtime_ns: i64,
    is_dir: bool,
    removed: bool = false,
};

pub const DirTree = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.array_list.Managed(DirEntry),
    index: std.StringHashMap(usize),

    pub fn init(allocator: Allocator) DirTree {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = std.array_list.Managed(DirEntry).init(allocator),
            .index = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *DirTree) void {
        self.entries.deinit();
        self.index.deinit();
        self.arena.deinit();
    }

    pub fn add(self: *DirTree, path: []const u8, mtime_ns: i64, is_dir: bool) !void {
        if (self.index.get(path)) |index| {
            self.entries.items[index].mtime_ns = mtime_ns;
            self.entries.items[index].is_dir = is_dir;
            self.entries.items[index].removed = false;
            return;
        }
        const owned = try self.arena.allocator().dupe(u8, path);
        try self.entries.append(.{ .path = owned, .mtime_ns = mtime_ns, .is_dir = is_dir });
        try self.index.put(owned, self.entries.items.len - 1);
    }

    pub fn find(self: *DirTree, path: []const u8) ?*DirEntry {
        const index = self.index.get(path) orelse return null;
        const entry = &self.entries.items[index];
        if (entry.removed) return null;
        return entry;
    }

    pub fn update(self: *DirTree, path: []const u8, mtime_ns: i64) void {
        if (self.find(path)) |entry| entry.mtime_ns = mtime_ns;
    }

    pub fn remove(self: *DirTree, path: []const u8) void {
        if (self.find(path)) |entry| {
            if (entry.is_dir) {
                const prefix = entry.path;
                for (self.entries.items) |*candidate| {
                    if (candidate.removed) continue;
                    if (isSubtree(candidate.path, prefix)) {
                        candidate.removed = true;
                        _ = self.index.remove(candidate.path);
                    }
                }
            }
            entry.removed = true;
            _ = self.index.remove(entry.path);
        }
    }

    fn isSubtree(path: []const u8, root: []const u8) bool {
        if (std.mem.eql(u8, path, root)) return true;
        if (!std.mem.startsWith(u8, path, root)) return false;
        if (root.len == 0) return false;
        return path[root.len] == std.fs.path.sep;
    }

    /// Adds changes relative to `snapshot` to `events`.
    pub fn getChanges(self: *DirTree, snapshot: *DirTree, events: *EventList) !void {
        for (self.entries.items) |entry| {
            if (entry.removed) continue;
            if (snapshot.find(entry.path)) |old| {
                if (old.mtime_ns != entry.mtime_ns and !old.is_dir and !entry.is_dir) {
                    try events.update(entry.path);
                }
            } else {
                try events.create(entry.path);
            }
        }
        for (snapshot.entries.items) |entry| {
            if (entry.removed) continue;
            if (self.find(entry.path) == null) {
                try events.remove(entry.path);
            }
        }
    }

    pub fn writeSnapshot(self: *const DirTree, io: Io, path: []const u8) !void {
        var buffer: Io.Writer.Allocating = .init(self.allocator);
        defer buffer.deinit();
        const writer = &buffer.writer;
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (!entry.removed) count += 1;
        }
        try writer.print("{d}\n", .{count});
        for (self.entries.items) |entry| {
            if (entry.removed) continue;
            try writer.print("{d}{s}{d} {d}\n", .{
                entry.path.len,
                entry.path,
                entry.mtime_ns,
                @intFromBool(entry.is_dir),
            });
        }
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = buffer.written(),
        });
    }

    pub fn readSnapshot(allocator: Allocator, io: Io, path: []const u8) !DirTree {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024));
        defer allocator.free(data);

        var tree = DirTree.init(allocator);
        errdefer tree.deinit();

        var cursor: usize = 0;
        const count = try readUnsigned(data, &cursor);
        try skipNewline(data, &cursor);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const path_len = try readUnsigned(data, &cursor);
            if (cursor + path_len > data.len) return error.InvalidSnapshot;
            const entry_path = data[cursor .. cursor + path_len];
            cursor += path_len;
            const mtime = try readSigned(data, &cursor);
            try skipSpace(data, &cursor);
            const is_dir_value = try readUnsigned(data, &cursor);
            try skipNewline(data, &cursor);
            try tree.add(entry_path, mtime, is_dir_value != 0);
        }
        return tree;
    }
};

fn readUnsigned(data: []const u8, cursor: *usize) !usize {
    var value: usize = 0;
    var digits: usize = 0;
    while (cursor.* < data.len) : (cursor.* += 1) {
        const ch = data[cursor.*];
        if (ch < '0' or ch > '9') break;
        value = value * 10 + (ch - '0');
        digits += 1;
    }
    if (digits == 0) return error.InvalidSnapshot;
    return value;
}

fn readSigned(data: []const u8, cursor: *usize) !i64 {
    var sign: i64 = 1;
    if (cursor.* < data.len and data[cursor.*] == '-') {
        sign = -1;
        cursor.* += 1;
    }
    return sign * @as(i64, @intCast(try readUnsigned(data, cursor)));
}

fn skipSpace(data: []const u8, cursor: *usize) !void {
    if (cursor.* >= data.len or data[cursor.*] != ' ') return error.InvalidSnapshot;
    cursor.* += 1;
}

fn skipNewline(data: []const u8, cursor: *usize) !void {
    if (cursor.* < data.len and data[cursor.*] == '\r') cursor.* += 1;
    if (cursor.* >= data.len or data[cursor.*] != '\n') return error.InvalidSnapshot;
    cursor.* += 1;
}

test "DirTree: snapshot roundtrip and changes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_len];
    const snapshot_path = try std.fs.path.join(allocator, &.{ root, "snapshot" });
    defer allocator.free(snapshot_path);

    var old = DirTree.init(allocator);
    defer old.deinit();
    try old.add("/root/a", 1, false);
    try old.add("/root/dir", 1, true);
    try old.writeSnapshot(io, snapshot_path);

    var snapshot = try DirTree.readSnapshot(allocator, io, snapshot_path);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.find("/root/a") != null);

    var current = DirTree.init(allocator);
    defer current.deinit();
    try current.add("/root/a", 2, false);
    try current.add("/root/b", 1, false);

    var events = EventList.init(allocator);
    defer events.deinit();
    try current.getChanges(&snapshot, &events);
    const list = try events.getEvents(allocator);
    defer allocator.free(list);
    try std.testing.expectEqual(@as(usize, 3), list.len);
}
