// Single-file channel behavior from
// `src/vs/workbench/contrib/output/test/common/outputChannelModel.test.ts`.
const std = @import("std");
const OutputService = @import("../../browser/outputServices.zig").OutputService;
const file_service = @import("../../../../../platform/files/common/fileService.zig");
const disk = @import("../../../../../platform/files/node/diskFileSystemProvider.zig");
const FileLoggerService = @import("../../../../../platform/log/common/fileLog.zig").FileLoggerService;

test "Output: file-backed channel append, clear, replace and selected-channel lifetime" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "channel.log" });
    defer a.free(path);
    const uri: std.Uri = .{ .scheme = "file", .path = .{ .raw = path } };
    var provider = disk.DiskFileSystemProvider.init(a, io);
    defer provider.deinit();
    var files = file_service.ProviderFileService.init(a);
    defer files.deinit();
    const registration = try files.registerProvider("file", provider.interface());
    defer registration.dispose();
    var loggers = FileLoggerService.init(a, std.testing.io, files.interface());
    defer loggers.deinit();
    var output = OutputService.init(a, files.interface(), &loggers);
    defer output.deinit();
    try output.attach();
    try files.writeFileUri(uri, "firsté\n", .{ .create = true, .overwrite = true });
    const channel = try output.registerChannel(.{ .id = "first", .label = "First", .source = uri });
    _ = try output.registerChannel(.{ .id = "second", .label = "Second", .source = uri });
    try std.testing.expect(try output.showChannel("first"));
    output.setVisible(true);
    try std.testing.expectEqualStrings("firsté\n", channel.model.content);
    try output.update("first", .Clear, "firsté\n".len);
    try std.testing.expectEqualStrings("", channel.model.content);
    try files.writeFileUri(uri, "second\n", .{ .create = true, .overwrite = true, .append = true });
    // The active visible channel is updated by the file service event.
    try std.testing.expectEqualStrings("second\n", channel.model.content);
    try files.writeFileUri(uri, "replacement", .{ .create = true, .overwrite = true, .append = true });
    try output.update("first", .Replace, "firsté\nsecond\n".len);
    try std.testing.expectEqualStrings("replacement", channel.model.content);
    try output.cycleChannels(false);
    try std.testing.expectEqualStrings("second", output.active.?.descriptor.id);
    output.removeChannel("second");
    try std.testing.expectEqual(channel, output.active.?);
    output.removeChannel("first");
    try std.testing.expect(output.active == null);
}
