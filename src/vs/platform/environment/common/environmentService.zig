// Port of `IEnvironmentService.extensionsPath` from
// `src/vs/platform/environment/common/environmentService.ts`.
//
// The TUI has no launch-argument or product service of its own, so the caller
// supplies the same inputs VS Code derives them from. The resolution order and
// the `resolve`/`join` behavior of the upstream getter are preserved.
const std = @import("std");
const Allocator = std.mem.Allocator;
const product = @import("../../product/common/product.zig");

pub const Environment = struct {
    /// `IEnvironmentService.userHome` (`paths.homeDir`).
    user_home: []const u8,
    /// `--extensions-dir`.
    cli_extensions_dir: ?[]const u8 = null,
    /// `VSCODE_EXTENSIONS`.
    env_extensions: ?[]const u8 = null,
    /// `VSCODE_PORTABLE`.
    env_portable: ?[]const u8 = null,

    pub fn extensionsPath(self: Environment, allocator: Allocator) Allocator.Error![]u8 {
        if (self.cli_extensions_dir) |dir| return std.fs.path.resolve(allocator, &.{dir});
        if (self.env_extensions) |dir| return allocator.dupe(u8, dir);
        if (self.env_portable) |dir| return std.fs.path.join(allocator, &.{ dir, "extensions" });
        return std.fs.path.join(allocator, &.{ self.user_home, product.data_folder_name, "extensions" });
    }
};

test "extensionsPath: default is <home>/<dataFolderName>/extensions" {
    const allocator = std.testing.allocator;
    const environment = Environment{ .user_home = "/home/user" };
    const path = try environment.extensionsPath(allocator);
    defer allocator.free(path);
    const expected = try std.fs.path.join(allocator, &.{ "/home/user", product.data_folder_name, "extensions" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "extensionsPath: VSCODE_PORTABLE overrides the home default" {
    const allocator = std.testing.allocator;
    const environment = Environment{
        .user_home = "/home/user",
        .env_portable = "/opt/portable",
    };
    const path = try environment.extensionsPath(allocator);
    defer allocator.free(path);
    const expected = try std.fs.path.join(allocator, &.{ "/opt/portable", "extensions" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "extensionsPath: VSCODE_EXTENSIONS overrides portable and home" {
    const allocator = std.testing.allocator;
    const environment = Environment{
        .user_home = "/home/user",
        .env_extensions = "/srv/code/extensions",
        .env_portable = "/opt/portable",
    };
    const path = try environment.extensionsPath(allocator);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/srv/code/extensions", path);
}

test "extensionsPath: --extensions-dir overrides every environment value" {
    const allocator = std.testing.allocator;
    const environment = Environment{
        .user_home = "/home/user",
        .cli_extensions_dir = "/tmp/extensions",
        .env_extensions = "/srv/code/extensions",
        .env_portable = "/opt/portable",
    };
    const path = try environment.extensionsPath(allocator);
    defer allocator.free(path);
    const expected = try std.fs.path.resolve(allocator, &.{"/tmp/extensions"});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}
