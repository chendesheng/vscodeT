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
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "pub.example-1.0.0/README.md", .{}));
}
