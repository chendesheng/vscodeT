// Terminal integration coverage for local VSIX publication and removal in
// `src/vs/platform/extensionManagement/node/extensionManagementService.ts`.
const std = @import("std");
const management = @import("../../node/extensionManagementService.zig");

test "ExtensionManagementService: validate, install and uninstall a local VSIX" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    const root = path[0..len];
    const fixture = @embedFile("fixture.vsix");
    try std.testing.expectError(error.ExtensionIdentifierMismatch, management.installVSIX(allocator, io, root, fixture, "another.ext", "1.0.0"));
    try management.installVSIX(allocator, io, root, fixture, "pub.example", "1.0.0");
    const readme = try tmp.dir.readFileAlloc(io, "pub.example-1.0.0/README.md", allocator, .unlimited);
    defer allocator.free(readme);
    try std.testing.expectEqualStrings("# Example\n", readme);
    try management.uninstall(allocator, io, root, "PUB.EXAMPLE");
    // The default profile no longer selects it; cached package data may be
    // shared by another profile and must remain intact.
    const scanner = @import("../../common/extensionsScannerService.zig");
    var inventory = try scanner.scanAllExtensions(allocator, io, null, root);
    defer inventory.deinit(allocator);
    try std.testing.expect(inventory.find("pub.example") == null);
    _ = try tmp.dir.statFile(io, "pub.example-1.0.0/README.md", .{});
}

const Source = struct {
    missing: bool = false,
    depa: usize = 0,
    depb: usize = 0,
    pack: usize = 0,
    optional: usize = 0,

    fn resolve(context: *anyopaque, allocator: std.mem.Allocator, _: std.Io, id: []const u8, _: bool) !?management.Package {
        const self: *Source = @ptrCast(@alignCast(context));
        const bytes = if (std.mem.eql(u8, id, "pub.depa")) blk: {
            self.depa += 1;
            break :blk @embedFile("fixture-depa.vsix");
        } else if (std.mem.eql(u8, id, "pub.depb")) blk: {
            self.depb += 1;
            if (self.missing) return null;
            break :blk @embedFile("fixture-depb.vsix");
        } else if (std.mem.eql(u8, id, "pub.pack")) blk: {
            self.pack += 1;
            break :blk @embedFile("fixture-pack.vsix");
        } else if (std.mem.eql(u8, id, "pub.optional")) {
            self.optional += 1;
            return null;
        } else return error.UnexpectedDependency;
        const data = try allocator.dupe(u8, bytes);
        errdefer allocator.free(data);
        return .{ .bytes = data, .version = try allocator.dupe(u8, "1.0.0") };
    }

    fn interface(self: *Source) management.PackageSource {
        return .{ .context = self, .resolve = resolve };
    }
};

test "ExtensionManagementService: installs dependency diamond, cycle and pack once" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var source: Source = .{};
    try management.installWithSource(allocator, io, path[0..len], null, @embedFile("fixture-root.vsix"), "pub.root", "1.0.0", source.interface(), false);
    try std.testing.expectEqual(@as(usize, 1), source.depa);
    try std.testing.expectEqual(@as(usize, 1), source.depb);
    try std.testing.expectEqual(@as(usize, 1), source.pack);
    try std.testing.expectEqual(@as(usize, 1), source.optional);
    for ([_][]const u8{ "pub.root-1.0.0", "pub.depa-1.0.0", "pub.depb-1.0.0", "pub.pack-1.0.0" }) |name| _ = try tmp.dir.statFile(io, name, .{});
}

test "ExtensionManagementService: failed required dependency leaves no staged publication" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var source: Source = .{ .missing = true };
    try std.testing.expectError(error.ExtensionDependencyUnavailable, management.installWithSource(allocator, io, path[0..len], null, @embedFile("fixture-root.vsix"), "pub.root", "1.0.0", source.interface(), false));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "pub.root-1.0.0", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "pub.depa-1.0.0", .{}));
}

test "ExtensionManagementService: dependent removal validates before changing profile" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..len];
    var source: Source = .{};
    try management.installWithSource(allocator, io, root, null, @embedFile("fixture-root.vsix"), "pub.root", "1.0.0", source.interface(), false);
    try std.testing.expectError(error.ExtensionHasDependents, management.uninstall(allocator, io, root, "pub.depa"));
    try management.uninstallMany(allocator, io, root, &.{ "pub.root", "pub.depa", "pub.depb", "pub.pack" });
    const scanner = @import("../../common/extensionsScannerService.zig");
    var inventory = try scanner.scanAllExtensions(allocator, io, null, root);
    defer inventory.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), inventory.all.len);
}
