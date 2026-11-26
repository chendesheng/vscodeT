// Port of vscode/extensions/git/src/uri.ts.
// std.Uri is the model-resource boundary in the terminal. The caller owns
// the returned components (normally through a virtual-read request arena).
const std = @import("std");
const URI = @import("../../../vs/base/common/uri.zig").URI;

pub fn toGitUri(allocator: std.mem.Allocator, path: []const u8, ref: []const u8) !std.Uri {
    var file = try URI.file(allocator, path);
    defer file.deinit();
    var query: std.Io.Writer.Allocating = .init(allocator);
    errdefer query.deinit();
    try std.json.Stringify.value(.{ .path = path, .ref = ref }, .{}, &query.writer);
    const uri_path = try allocator.dupe(u8, file.path);
    errdefer allocator.free(uri_path);
    return .{
        .scheme = "git",
        .path = .{ .raw = uri_path },
        .query = .{ .raw = try query.toOwnedSlice() },
    };
}

test "git URI preserves path and ref in its query" {
    const allocator = std.testing.allocator;
    const uri = try toGitUri(allocator, "/repo/a #b.zig", "HEAD");
    defer allocator.free(uri.path.raw);
    defer allocator.free(uri.query.?.raw);
    try std.testing.expectEqualStrings("git", uri.scheme);
    try std.testing.expectEqualStrings("/repo/a #b.zig", uri.path.raw);
    try std.testing.expectEqualStrings("{\"path\":\"/repo/a #b.zig\",\"ref\":\"HEAD\"}", uri.query.?.raw);
}
