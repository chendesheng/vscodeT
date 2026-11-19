// Port of the location-scan cases from
// `src/vs/platform/extensionManagement/test/node/extensionsScannerService.test.ts`
// to the profile-less scan used by the TUI.
const std = @import("std");
const scanner = @import("../../common/extensionsScannerService.zig");

fn writeExtension(tmp: *std.testing.TmpDir, io: std.Io, folder: []const u8, manifest: []const u8) !void {
    try tmp.dir.createDirPath(io, folder);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}{c}package.json", .{ folder, std.fs.path.sep });
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = manifest });
}

fn scan(tmp: *std.testing.TmpDir, io: std.Io) ![]scanner.ScannedExtension {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    return scanner.scanExtensionsFromLocation(std.testing.allocator, io, path_buffer[0..length], .user);
}

fn deinit(extensions: []scanner.ScannedExtension) void {
    for (extensions) |*extension| extension.deinit(std.testing.allocator);
    std.testing.allocator.free(extensions);
}

test "scan user extensions" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, io, "pub.name-1.0.0",
        \\{"name":"name","publisher":"pub","version":"1.0.0"}
    );

    const actual = try scan(&tmp, io);
    defer deinit(actual);

    try std.testing.expectEqual(1, actual.len);
    try std.testing.expectEqualStrings("pub.name", actual[0].identifier);
    try std.testing.expectEqualStrings("1.0.0", actual[0].manifest.value.object.get("version").?.string);
}

test "scan all user extensions include all versions" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, io, "pub.name-1.0.1",
        \\{"name":"name","publisher":"pub","version":"1.0.1"}
    );
    try writeExtension(&tmp, io, "pub.name-1.0.2",
        \\{"name":"name","publisher":"pub","version":"1.0.2"}
    );

    const actual = try scan(&tmp, io);
    defer deinit(actual);

    try std.testing.expectEqual(2, actual.len);
    try std.testing.expectEqualStrings("pub.name", actual[0].identifier);
    try std.testing.expectEqualStrings("1.0.1", actual[0].manifest.value.object.get("version").?.string);
    try std.testing.expectEqualStrings("pub.name", actual[1].identifier);
    try std.testing.expectEqualStrings("1.0.2", actual[1].manifest.value.object.get("version").?.string);
}

test "user extension folders starting with a dot are skipped" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, io, ".obsolete",
        \\{"name":"name","publisher":"pub","version":"1.0.0"}
    );

    const actual = try scan(&tmp, io);
    defer deinit(actual);

    try std.testing.expectEqual(0, actual.len);
}

test "a directory without package.json is skipped" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pub.name-1.0.0");

    const actual = try scan(&tmp, io);
    defer deinit(actual);

    try std.testing.expectEqual(0, actual.len);
}

test "a non-directory child is skipped" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "pub.name-1.0.0.zip", .data = "not an extension" });

    const actual = try scan(&tmp, io);
    defer deinit(actual);

    try std.testing.expectEqual(0, actual.len);
}

test "a missing publisher uses the undefined publisher id" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, io, "name-1.0.0",
        \\{"name":"name","version":"1.0.0"}
    );

    const actual = try scan(&tmp, io);
    defer deinit(actual);

    try std.testing.expectEqual(1, actual.len);
    try std.testing.expectEqualStrings("undefined_publisher.name", actual[0].identifier);
}

test "an invalid manifest object is skipped" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, io, "pub.name-1.0.0", "[]");

    const actual = try scan(&tmp, io);
    defer deinit(actual);

    try std.testing.expectEqual(0, actual.len);
}

test "findExtension compares identifiers case-insensitively" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, io, "VSCodeVim.Vim-1.32.4",
        \\{"name":"Vim","publisher":"VSCodeVim","version":"1.32.4"}
    );

    const actual = try scan(&tmp, io);
    defer deinit(actual);

    try std.testing.expect(scanner.findExtension(actual, "vscodevim.vim") != null);
    try std.testing.expect(scanner.findExtension(actual, "vscodevim.viml") == null);
}
