// Port regression for `src/vs/workbench/api/browser/mainThreadLogService.ts`.
const std = @import("std");
const actor_mod = @import("../../browser/mainThreadLogService.zig");
const FileLoggerService = @import("../../../../platform/log/common/fileLog.zig").FileLoggerService;
const ProviderFileService = @import("../../../../platform/files/common/fileService.zig").ProviderFileService;
const DiskFileSystemProvider = @import("../../../../platform/files/node/diskFileSystemProvider.zig").DiskFileSystemProvider;
const std_uri = @import("../../../../base/common/stdUri.zig");
const rpc = @import("../../../services/extensions/common/rpcProtocol.zig");

test "MainThreadLogger: unformatted output preserves byte offsets and metadata" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try std.fs.path.join(a, &.{ root, "output.log" });
    const uri: std.Uri = .{ .scheme = "file", .path = .{ .raw = path } };
    const resource = rpc.Arg{ .json = try std_uri.jsonComponents(a, uri) };
    var disk = DiskFileSystemProvider.init(allocator, io);
    defer disk.deinit();
    var files = ProviderFileService.init(allocator);
    defer files.deinit();
    const registration = try files.registerProvider("file", disk.interface());
    defer registration.dispose();
    var loggers = FileLoggerService.init(allocator, files.interface());
    defer loggers.deinit();
    var actor = actor_mod.MainThreadLoggerService{ .service = &loggers };
    const opts = rpc.Arg{ .json = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"id\":\"zig-log\",\"name\":\"Zig\",\"donotUseFormatters\":true,\"donotRotate\":true,\"logLevel\":\"always\"}", .{}) };
    try std.testing.expect((try actor.invoke("$createLogger", &.{ resource, opts }, a)) == .empty);
    const messages = rpc.Arg{ .json = try std.json.parseFromSliceLeaky(std.json.Value, a, "[[3,\"hello\"],[3,\"é\\n\"]]", .{}) };
    try std.testing.expect((try actor.invoke("$log", &.{ resource, messages }, a)) == .empty);
    try std.testing.expect((try actor.invoke("$flush", &.{resource}, a)) == .empty);
    try std.testing.expectEqualStrings("helloé\n", try files.readFileUri(a, uri));
    // Disposing the registry entry does not delete the file.
    try std.testing.expectEqualStrings("zig-log", (try loggers.getLogger(uri)).?.options.id.?);
    try std.testing.expect((try actor.invoke("$setVisibility", &.{ resource, .{ .json = .{ .bool = false } } }, a)) == .empty);
    try std.testing.expect((try loggers.getLogger(uri)).?.options.hidden);
    try std.testing.expect((try actor.invoke("$deregisterLogger", &.{resource}, a)) == .empty);
    try std.testing.expect((try loggers.getLogger(uri)) == null);
    try std.testing.expectEqualStrings("helloé\n", try files.readFileUri(a, uri));
}
