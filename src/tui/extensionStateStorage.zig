// Native profile storage for extension enablement.
//
// The workbench's profile storage is upstream's SQLite-backed storage
// database; the terminal has no profile storage service, so each native state
// owner persists its own JSON file. This file is the projection of upstream's
// profile value for `extensionsIdentifiers/disabled`
// (`[{ "id": "publisher.name" }]`), used by `ExtensionEnablementService`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../vs/platform/storage/common/storage.zig");
const enablement = @import("../vs/workbench/services/extensionManagement/browser/extensionEnablementService.zig");

pub const ExtensionStateStorage = struct {
    allocator: Allocator,
    io: std.Io,
    path: []u8,

    pub fn init(allocator: Allocator, io: std.Io, user_data_dir: []const u8) !ExtensionStateStorage {
        const path = try std.fs.path.join(allocator, &.{ user_data_dir, "User", "globalStorage", "extensions.state.json" });
        errdefer allocator.free(path);
        return .{ .allocator = allocator, .io = io, .path = path };
    }

    pub fn deinit(self: *ExtensionStateStorage) void {
        self.allocator.free(self.path);
    }

    pub fn store(self: *ExtensionStateStorage) enablement.Store {
        return .{ .context = self, .load = load, .save = save };
    }

    fn load(context: *anyopaque, allocator: Allocator) anyerror!?[]const u8 {
        const self: *ExtensionStateStorage = @ptrCast(@alignCast(context));
        return std.Io.Dir.cwd().readFileAlloc(self.io, self.path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    fn save(context: *anyopaque, value: []const u8) anyerror!void {
        const self: *ExtensionStateStorage = @ptrCast(@alignCast(context));
        try storage.writeStateFileRaw(self.io, self.path, value);
    }
};

test "extension state storage round-trips and treats a missing file as empty" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..length];

    var adapter = try ExtensionStateStorage.init(allocator, io, root);
    defer adapter.deinit();
    const store = adapter.store();

    try std.testing.expect((try store.load(store.context, allocator)) == null);

    try store.save(store.context, "[{\"id\":\"example.extension\"}]");
    const loaded = (try store.load(store.context, allocator)).?;
    defer allocator.free(loaded);
    try std.testing.expectEqualStrings("[{\"id\":\"example.extension\"}]", loaded);

    // The state file lives under the profile's globalStorage directory.
    const expected = try std.fs.path.join(allocator, &.{ root, "User", "globalStorage", "extensions.state.json" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, adapter.path);
}
