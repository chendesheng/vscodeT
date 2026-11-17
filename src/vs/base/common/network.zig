// Port of the scheme constants and local file-resource helper subset of
// `src/vs/base/common/network.ts`. The terminal app has no extension host or
// remote/web resource roots, so `FileAccess` resolves paths relative to an
// explicitly passed application root.
const std = @import("std");
const Allocator = std.mem.Allocator;
const uri_mod = @import("./uri.zig");
const URI = uri_mod.URI;

pub const Schemas = struct {
    pub const in_memory = "inmemory";
    pub const vscode = "vscode";
    pub const internal = "private";
    pub const walk_through = "walkThrough";
    pub const walk_through_snippet = "walkThroughSnippet";
    pub const http = "http";
    pub const https = "https";
    pub const file = "file";
    pub const mailto = "mailto";
    pub const untitled = "untitled";
    pub const data = "data";
    pub const command = "command";
    pub const vscode_remote = "vscode-remote";
    pub const vscode_remote_resource = "vscode-remote-resource";
    pub const vscode_user_data = "vscode-userdata";
    pub const vscode_settings = "vscode-settings";
    pub const vscode_terminal = "vscode-terminal";
    pub const vscode_notebook_cell = "vscode-notebook-cell";
};

pub const FileAccess = struct {
    /// Resolves a resource path against the application root as a `file:` URI.
    pub fn asFileUri(allocator: Allocator, app_root: []const u8, path: []const u8) !URI {
        if (std.fs.path.isAbsolute(path)) return URI.file(allocator, path);
        const joined = try std.fs.path.join(allocator, &.{ app_root, path });
        defer allocator.free(joined);
        return URI.file(allocator, joined);
    }
};

test "network schemes and file access" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("file", Schemas.file);
    try std.testing.expectEqualStrings("vscode-userdata", Schemas.vscode_user_data);
    var uri = try FileAccess.asFileUri(allocator, "/app", "vs/workbench/a.js");
    defer uri.deinit();
    try std.testing.expectEqualStrings("/app/vs/workbench/a.js", uri.path);
    const text = try uri.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("file:///app/vs/workbench/a.js", text);
}
