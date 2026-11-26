// Port of `src/vs/platform/files/test/browser/inmemoryFileService.test.ts`.
//
// Terminal adaptation: resources are `inmemory:/...` strings instead of URIs,
// operations are synchronous (so the async provider-change timeout is not
// needed) and the stream test uses the terminal synchronous `readFile` path.
// The in-memory fixture, operations, assertions and read-only/event behavior
// follow the upstream suite.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const files = @import("../../common/files.zig");
const file_service = @import("../../common/fileService.zig");
const in_memory = @import("../../common/inMemoryFilesystemProvider.zig");

const ProviderFileService = file_service.ProviderFileService;
const FileOperationEvent = file_service.FileOperationEvent;
const InMemoryFileSystemProvider = in_memory.InMemoryFileSystemProvider;
const FileOperation = files.FileOperation;
const FileStat = files.FileStat;
const FileChangesEvent = files.FileChangesEvent;
const VSBuffer = @import("../../../../base/common/buffer.zig").VSBuffer;

const OperationSink = struct {
    count: usize = 0,
    operation: ?FileOperation = null,
    resource: [256]u8 = undefined,
    resource_len: usize = 0,
    target_is_directory: bool = false,

    fn callback(event: FileOperationEvent, self: *OperationSink) anyerror!void {
        self.count += 1;
        self.operation = event.operation;
        const length = @min(event.resource.len, self.resource.len);
        @memcpy(self.resource[0..length], event.resource[0..length]);
        self.resource_len = length;
        self.target_is_directory = if (event.target) |target| target.isDirectory() else false;
    }

    fn resourcePath(self: *const OperationSink) []const u8 {
        return self.resource[0..self.resource_len];
    }
};

const ChangeSink = struct {
    count: usize = 0,

    fn callback(event: FileChangesEvent, self: *ChangeSink) anyerror!void {
        _ = event;
        self.count += 1;
    }
};

const Fixture = struct {
    allocator: Allocator,
    provider: InMemoryFileSystemProvider,
    service: ProviderFileService,
    arena: std.heap.ArenaAllocator,
    root: []const u8 = "inmemory:/",

    fn init(self: *Fixture, allocator: Allocator) !void {
        self.allocator = allocator;
        self.root = "inmemory:/";
        self.provider = try InMemoryFileSystemProvider.init(allocator);
        errdefer self.provider.deinit();
        self.service = ProviderFileService.init(allocator);
        errdefer self.service.deinit();
        self.arena = std.heap.ArenaAllocator.init(allocator);
        _ = try self.service.registerProvider("inmemory", self.provider.interface());

        _ = try self.service.createFolder(try self.path("examples"));
        _ = try self.service.createFolder(try self.path("other"));
        try self.write("index.html", "Index");
        try self.write("site.css", "body { }");
        try self.write("small.txt", "Small File");
        try self.write("small_umlaut.txt", "Small File with Ümlaut");

        _ = try self.service.createFolder(try self.path("deep"));
        try self.write("deep/conway.js", "console.log(\"conway\");");
        try self.write("deep/a.txt", "A");
        try self.write("deep/b.txt", "B");
        try self.write("deep/c.txt", "C");

        _ = try self.service.createFolder(try self.path("other/deep"));
        try self.write("other/deep/1.txt", "1");
        try self.write("other/deep/2.txt", "2");
        try self.write("other/deep/3.txt", "3");
        try self.write("other/deep/4.txt", "4");
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.service.deinit();
        self.provider.deinit();
    }

    fn path(self: *Fixture, relative: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.root, relative });
    }

    fn write(self: *Fixture, relative: []const u8, contents: []const u8) !void {
        try self.service.writeFile(try self.path(relative), contents, .{ .create = true, .overwrite = true });
    }

    fn read(self: *Fixture, relative: []const u8) ![]const u8 {
        const resource = try self.path(relative);
        const buffer = try self.service.readFile(self.arena.allocator(), resource, 0);
        return buffer.bytes;
    }

    fn sortedChildren(self: *Fixture, stat: *const FileStat) ![]const []const u8 {
        var names = std.array_list.Managed([]const u8).init(self.arena.allocator());
        for (stat.children orelse &.{}) |child| try names.append(child.name);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        return names.items;
    }
};

test "in-memory file service: createFolder reports an operation event" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    var sink = OperationSink{};
    _ = try fixture.service.listenOperation(&sink, OperationSink.callback);

    const new_folder = try fixture.path("newFolder");
    const stat = try fixture.service.createFolder(new_folder);
    try testing.expectEqualStrings("newFolder", stat.name);
    try testing.expect(fixture.service.exists(new_folder));
    try testing.expectEqual(@as(usize, 1), sink.count);
    try testing.expectEqual(FileOperation.CREATE, sink.operation.?);
    try testing.expectEqualStrings(new_folder, sink.resourcePath());
    try testing.expect(sink.target_is_directory);
}

test "in-memory file service: createFolder creates multiple intermediate folders" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    const path = try fixture.path("a/couple/of/folders");
    const stat = try fixture.service.createFolder(path);
    try testing.expectEqualStrings("folders", stat.name);
    try testing.expect(fixture.service.exists(path));
}

test "in-memory file service: exists" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    try testing.expect(fixture.service.exists(fixture.root));
    try testing.expect(!fixture.service.exists(try fixture.path("does-not-exist")));
}

test "in-memory file service: resolve file and directory" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    const resolved_file = try fixture.service.resolve(fixture.arena.allocator(), try fixture.path("index.html"), null);
    try testing.expectEqualStrings("index.html", resolved_file.name);
    try testing.expect(resolved_file.isFile());
    try testing.expect(!resolved_file.isDirectory());

    var resolved_root = try fixture.service.resolve(fixture.arena.allocator(), fixture.root, null);
    defer fixture.service.freeResolved(fixture.arena.allocator(), &resolved_root);
    try testing.expect(resolved_root.isDirectory());
    const names = try fixture.sortedChildren(&resolved_root);
    try testing.expectEqual(@as(usize, 7), names.len);
    try testing.expectEqualStrings("deep", names[0]);
    try testing.expectEqualStrings("examples", names[1]);
    try testing.expectEqualStrings("index.html", names[2]);
}

test "in-memory file service: resolve with resolveTo resolves descendant children" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    const resolve_to = [_][]const u8{"deep"};
    var resolved = try fixture.service.resolve(fixture.arena.allocator(), fixture.root, &resolve_to);
    defer fixture.service.freeResolved(fixture.arena.allocator(), &resolved);
    try testing.expectEqual(@as(usize, 1), resolved.children.?.len);
    const deep = resolved.children.?[0];
    try testing.expectEqualStrings("deep", deep.name);
    try testing.expectEqual(@as(usize, 4), deep.children.?.len);
}

test "in-memory file service: readFile and positions" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    try testing.expectEqualStrings("Small File", try fixture.read("small.txt"));

    const from_position = try fixture.service.readFile(fixture.arena.allocator(), try fixture.path("small.txt"), 6);
    try testing.expectEqualStrings("File", from_position.bytes);

    const umlaut_position = "Small File with Ü".len;
    const umlaut = try fixture.service.readFile(fixture.arena.allocator(), try fixture.path("small_umlaut.txt"), umlaut_position);
    try testing.expectEqualStrings("mlaut", umlaut.bytes);
}

test "in-memory file service: writeFile replaces and appends" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    const path = try fixture.path("small.txt");
    try fixture.service.writeFile(path, "Updated", .{ .create = true, .overwrite = true });
    try testing.expectEqualStrings("Updated", try fixture.read("small.txt"));

    try fixture.service.writeFile(try fixture.path("append.txt"), "Hello", .{ .create = true, .overwrite = true });
    try fixture.service.writeFile(try fixture.path("append.txt"), " World", .{ .create = true, .overwrite = true, .append = true });
    try testing.expectEqualStrings("Hello World", try fixture.read("append.txt"));
}

test "in-memory file service: provider open/write appends" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    const resource = try fixture.path("append-open.txt");
    try fixture.service.writeFile(resource, "Hello", .{ .create = true, .overwrite = true });
    const fd = try fixture.provider.open("/append-open.txt", .{ .create = true, .overwrite = false, .append = true });
    _ = try fixture.provider.write(fd, 0, " World", 0, 6);
    try fixture.provider.close(fd);
    try testing.expectEqualStrings("Hello World", try fixture.read("append-open.txt"));
}

test "in-memory file service: appends large buffers" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    const prefix = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(prefix);
    const suffix = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(suffix);
    for (prefix, 0..) |*byte, index| byte.* = @intCast((index + 1) % 256);
    for (suffix, 0..) |*byte, index| byte.* = @intCast((index + 2) % 256);

    const resource = try fixture.path("append-large.txt");
    try fixture.service.writeFile(resource, prefix, .{ .create = true, .overwrite = true });
    try fixture.service.writeFile(resource, suffix, .{ .create = true, .overwrite = true, .append = true });

    const content = try fixture.service.readFile(fixture.arena.allocator(), resource, 0);
    try testing.expectEqual(prefix.len + suffix.len, content.bytes.len);
    try testing.expectEqualSlices(u8, prefix[0..64], content.bytes[0..64]);
    try testing.expectEqualSlices(u8, suffix[0..64], content.bytes[prefix.len .. prefix.len + 64]);
    try testing.expectEqualSlices(u8, suffix[suffix.len - 64 ..], content.bytes[content.bytes.len - 64 ..]);
}

test "in-memory file service: rename and copy" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    const source = try fixture.path("site.css");
    const target = try fixture.path("SITE.css");
    try fixture.service.move(source, target, true);
    try testing.expect(!fixture.service.exists(source));
    try testing.expect(fixture.service.exists(target));

    const copy_source = try fixture.path("index.html");
    const copy_target = try fixture.path("index-copy.html");
    try fixture.service.copy(copy_source, copy_target, true);
    try testing.expectEqualStrings("Index", try fixture.read("index-copy.html"));
}

test "in-memory file service: delete" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    const resource = try fixture.path("to-delete.txt");
    try fixture.service.writeFile(resource, "delete me", .{ .create = true, .overwrite = true });
    try testing.expect(fixture.service.exists(resource));
    try fixture.service.del(resource);
    try testing.expect(!fixture.service.exists(resource));
}

test "in-memory file service: provider changes bubble through the service" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    var sink = ChangeSink{};
    _ = try fixture.service.listenFilesChange(&sink, ChangeSink.callback);

    const resource = try fixture.path("events.txt");
    try fixture.service.writeFile(resource, "1", .{ .create = true, .overwrite = true });
    try fixture.service.writeFile(resource, "2", .{ .create = true, .overwrite = true });
    try fixture.service.del(resource);
    try testing.expect(sink.count > 0);
}

test "in-memory file service: read-only provider rejects writes" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    fixture.provider.setReadOnly(true);
    try testing.expect(fixture.provider.capabilities & files.FileSystemProviderCapabilities.Readonly != 0);
    try testing.expectError(error.FileReadonly, fixture.service.writeFile(
        try fixture.path("readonly.txt"),
        "fail",
        .{ .create = true, .overwrite = true },
    ));

    fixture.provider.setReadOnly(false);
    try fixture.service.writeFile(try fixture.path("readonly.txt"), "ok", .{ .create = true, .overwrite = true });
}

test "in-memory file service: readFile stream replacement" {
    // The terminal provider reads synchronously; the upstream stream test's
    // content assertion is kept against the read path.
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    try testing.expectEqualStrings("Small File", try fixture.read("small.txt"));
}

test "in-memory file service: provider open/write appends large buffers" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    const prefix = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(prefix);
    const suffix = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(suffix);
    for (prefix, 0..) |*byte, index| byte.* = @intCast((index + 1) % 256);
    for (suffix, 0..) |*byte, index| byte.* = @intCast((index + 2) % 256);

    const resource = try fixture.path("append-large-open.txt");
    try fixture.service.writeFile(resource, prefix, .{ .create = true, .overwrite = true });
    const fd = try fixture.provider.open("/append-large-open.txt", .{ .create = true, .overwrite = false, .append = true });
    _ = try fixture.provider.write(fd, 123, suffix, 0, suffix.len);
    try fixture.provider.close(fd);

    const content = try fixture.service.readFile(fixture.arena.allocator(), resource, 0);
    try testing.expectEqual(prefix.len + suffix.len, content.bytes.len);
    try testing.expectEqualSlices(u8, prefix[0..64], content.bytes[0..64]);
    try testing.expectEqualSlices(u8, suffix[0..64], content.bytes[prefix.len .. prefix.len + 64]);
    try testing.expectEqualSlices(u8, suffix[suffix.len - 64 ..], content.bytes[content.bytes.len - 64 ..]);
}
