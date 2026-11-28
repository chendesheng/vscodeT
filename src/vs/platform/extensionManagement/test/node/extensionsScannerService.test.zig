// Port of the location-scan cases from
// `src/vs/platform/extensionManagement/test/node/extensionsScannerService.test.ts`
// to the profile-less scan used by the TUI, plus the metadata/NLS and
// system+user merge coverage the terminal Extensions view consumes.
const std = @import("std");
const scanner = @import("../../common/extensionsScannerService.zig");
const util = @import("../../common/extensionManagementUtil.zig");

const io = std.testing.io;

fn writeExtension(tmp: *std.testing.TmpDir, folder: []const u8, manifest: []const u8) !void {
    try tmp.dir.createDirPath(io, folder);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}{c}package.json", .{ folder, std.fs.path.sep });
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = manifest });
}

fn writeNls(tmp: *std.testing.TmpDir, folder: []const u8, contents: []const u8) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}{c}package.nls.json", .{ folder, std.fs.path.sep });
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = contents });
}

fn scan(tmp: *std.testing.TmpDir, extension_type: scanner.ExtensionType) ![]scanner.ScannedExtension {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    return scanner.scanExtensionsFromLocation(std.testing.allocator, io, path_buffer[0..length], extension_type);
}

fn deinit(extensions: []scanner.ScannedExtension) void {
    for (extensions) |*extension| extension.deinit(std.testing.allocator);
    std.testing.allocator.free(extensions);
}

test "scan user extensions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, "pub.name-1.0.0",
        \\{"name":"name","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expectEqual(1, actual.len);
    try std.testing.expectEqualStrings("pub.name", actual[0].identifier);
    try std.testing.expectEqualStrings("name", actual[0].name);
    try std.testing.expectEqualStrings("pub", actual[0].publisher);
    try std.testing.expectEqualStrings("1.0.0", actual[0].version);
    try std.testing.expectEqualStrings("name", actual[0].display_name);
    try std.testing.expectEqualStrings("", actual[0].description);
    try std.testing.expectEqual(scanner.ExtensionType.user, actual[0].extension_type);
    try std.testing.expect(!actual[0].isBuiltin());
}

test "scan all user extensions include all versions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, "pub.name-1.0.1",
        \\{"name":"name","publisher":"pub","version":"1.0.1","engines":{"vscode":"*"}}
    );
    try writeExtension(&tmp, "pub.name-1.0.2",
        \\{"name":"name","publisher":"pub","version":"1.0.2","engines":{"vscode":"*"}}
    );

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expectEqual(2, actual.len);
    try std.testing.expectEqualStrings("pub.name", actual[0].identifier);
    try std.testing.expectEqualStrings("1.0.1", actual[0].version);
    try std.testing.expectEqualStrings("pub.name", actual[1].identifier);
    try std.testing.expectEqualStrings("1.0.2", actual[1].version);
}

test "user extension folders starting with a dot are skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, ".obsolete",
        \\{"name":"name","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expectEqual(0, actual.len);
}

test "a directory without package.json is skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pub.name-1.0.0");

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expectEqual(0, actual.len);
}

test "a non-directory child is skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "pub.name-1.0.0.zip", .data = "not an extension" });

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expectEqual(0, actual.len);
}

test "a missing publisher uses the undefined publisher id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, "name-1.0.0",
        \\{"name":"name","version":"1.0.0","engines":{"vscode":"*"}}
    );

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expectEqual(1, actual.len);
    try std.testing.expectEqualStrings("undefined_publisher.name", actual[0].identifier);
    try std.testing.expectEqualStrings(util.undefined_publisher, actual[0].publisher);
}

test "an invalid manifest object is skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, "pub.name-1.0.0", "[]");

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expectEqual(0, actual.len);
}

test "a manifest without a version or engines is skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, "pub.noversion-1.0.0",
        \\{"name":"noversion","publisher":"pub","engines":{"vscode":"*"}}
    );
    try writeExtension(&tmp, "pub.noengines-1.0.0",
        \\{"name":"noengines","publisher":"pub","version":"1.0.0"}
    );

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expectEqual(0, actual.len);
}

test "manifest display name, description and categories are read and NLS-resolved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, "pub.nls-1.0.0",
        \\{"name":"nls","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"},"displayName":"%displayName%","description":"%description%","categories":["Themes","Other"]}
    );
    try writeNls(&tmp, "pub.nls-1.0.0",
        \\{"displayName":"Localized Name","description":"Localized description."}
    );

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expectEqual(1, actual.len);
    try std.testing.expectEqualStrings("Localized Name", actual[0].display_name);
    try std.testing.expectEqualStrings("Localized description.", actual[0].description);
    try std.testing.expectEqual(@as(usize, 2), actual[0].categories.len);
    try std.testing.expectEqualStrings("Themes", actual[0].categories[0]);
    try std.testing.expectEqualStrings("Other", actual[0].categories[1]);
}

test "an unresolved NLS key stays raw like upstream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, "pub.nls-1.0.0",
        \\{"name":"nls","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"},"displayName":"%missing%"}
    );

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expectEqual(1, actual.len);
    try std.testing.expectEqualStrings("%missing%", actual[0].display_name);
}

test "findExtension compares identifiers case-insensitively" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, "Example.Extension-1.0.0",
        \\{"name":"Extension","publisher":"Example","version":"1.0.0","engines":{"vscode":"*"}}
    );

    const actual = try scan(&tmp, .user);
    defer deinit(actual);

    try std.testing.expect(scanner.findExtension(actual, "example.extension") != null);
    try std.testing.expect(scanner.findExtension(actual, "example.extension-other") == null);
}

fn testRoots(tmp: *std.testing.TmpDir) !struct { system: []u8, user: []u8 } {
    const allocator = std.testing.allocator;
    try tmp.dir.createDirPath(io, "system");
    try tmp.dir.createDirPath(io, "user");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..length];
    return .{
        .system = try std.fs.path.join(allocator, &.{ root, "system" }),
        .user = try std.fs.path.join(allocator, &.{ root, "user" }),
    };
}

test "scanAllExtensions merges system and user with newest-version wins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const roots = try testRoots(&tmp);
    defer allocator.free(roots.system);
    defer allocator.free(roots.user);
    try writeExtension(&tmp, "system/pub.shared-1.0.0",
        \\{"name":"shared","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );
    try writeExtension(&tmp, "system/pub.equal-1.0.0",
        \\{"name":"equal","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );
    try writeExtension(&tmp, "user/pub.shared-1.2.0",
        \\{"name":"shared","publisher":"pub","version":"1.2.0","engines":{"vscode":"*"}}
    );
    try writeExtension(&tmp, "user/pub.equal-1.0.0",
        \\{"name":"equal","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );
    try writeExtension(&tmp, "user/pub.onlyuser-1.0.0",
        \\{"name":"onlyuser","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );

    var result = try scanner.scanAllExtensions(allocator, io, roots.system, roots.user);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.system.len);
    try std.testing.expectEqual(@as(usize, 3), result.user.len);
    try std.testing.expectEqual(@as(usize, 3), result.all.len);

    const shared = result.find("pub.shared").?;
    try std.testing.expectEqualStrings("1.2.0", shared.version);
    try std.testing.expectEqual(scanner.ExtensionType.user, shared.extension_type);
    try std.testing.expect(std.mem.indexOf(u8, shared.location, "user") != null);

    // Equal versions keep the system entry.
    const equal = result.find("pub.equal").?;
    try std.testing.expectEqual(scanner.ExtensionType.system, equal.extension_type);
    try std.testing.expect(std.mem.indexOf(u8, equal.location, "system") != null);

    try std.testing.expect(result.find("pub.onlyuser") != null);
}

test "scanExtensionsFromRoots reads one extension or a collection" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, "collection/one",
        \\{"name":"one","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );
    try writeExtension(&tmp, "collection/two",
        \\{"name":"two","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );
    try writeExtension(&tmp, "single",
        \\{"name":"single","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..length];
    const collection = try std.fs.path.join(allocator, &.{ root, "collection" });
    defer allocator.free(collection);
    const single = try std.fs.path.join(allocator, &.{ root, "single" });
    defer allocator.free(single);
    const missing = try std.fs.path.join(allocator, &.{ root, "missing" });
    defer allocator.free(missing);

    const actual = try scanner.scanExtensionsFromRoots(allocator, io, &.{ collection, single, missing }, .system);
    defer {
        for (actual) |*extension| extension.deinit(allocator);
        allocator.free(actual);
    }
    try std.testing.expectEqual(@as(usize, 3), actual.len);
}

test "manifest with JSONC comments is accepted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExtension(&tmp, "pub.commented-1.0.0",
        \\{
        \\  // The extension manifest parser tolerates comments.
        \\  "name": "commented",
        \\  "publisher": "pub",
        \\  "version": "1.0.0",
        \\  "engines": { "vscode": "*" },
        \\}
    );

    const actual = try scan(&tmp, .user);
    defer deinit(actual);
    try std.testing.expectEqual(1, actual.len);
    try std.testing.expectEqualStrings("commented", actual[0].name);
}

test "scanAllExtensions honors selected profile version instead of newest cached version" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pub.example-1.0.0");
    try tmp.dir.createDirPath(io, "pub.example-2.0.0");
    try tmp.dir.writeFile(io, .{ .sub_path = "pub.example-1.0.0/package.json", .data = "{\"publisher\":\"pub\",\"name\":\"example\",\"version\":\"1.0.0\",\"engines\":{\"vscode\":\"*\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pub.example-2.0.0/package.json", .data = "{\"publisher\":\"pub\",\"name\":\"example\",\"version\":\"2.0.0\",\"engines\":{\"vscode\":\"*\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "extensions.json", .data = "[{\"identifier\":{\"id\":\"pub.example\"},\"version\":\"1.0.0\",\"relativeLocation\":\"pub.example-1.0.0\"}]" });
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var inventory = try scanner.scanAllExtensions(allocator, io, null, path[0..len]);
    defer inventory.deinit(allocator);
    try std.testing.expectEqualStrings("1.0.0", inventory.find("pub.example").?.version);
    try std.testing.expectEqual(@as(usize, 2), inventory.user.len);
}
