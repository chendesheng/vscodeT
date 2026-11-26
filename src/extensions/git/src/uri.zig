// Port of vscode/extensions/git/src/uri.ts.
// std.Uri is the model-resource boundary in the terminal. The caller owns
// the returned components (normally through a virtual-read request arena).
const std = @import("std");
const URI = @import("../../../vs/base/common/uri.zig").URI;

pub fn toGitUri(allocator: std.mem.Allocator, path: []const u8, ref: []const u8) !std.Uri {
    return toGitUriWithOptions(allocator, path, ref, .{});
}

pub const GitUriOptions = struct {
    scheme: ?[]const u8 = null,
    replace_file_extension: bool = false,
    submodule_of: ?[]const u8 = null,
};

pub const GitUriParams = struct {
    path: []const u8,
    ref: []const u8,
    submoduleOf: ?[]const u8 = null,
};

/// URI query components live in the supplied request arena.
pub fn fromGitUri(arena: std.mem.Allocator, uri: std.Uri) !GitUriParams {
    return std.json.parseFromSliceLeaky(GitUriParams, arena, try @import("../../../vs/base/common/stdUri.zig").query(uri, arena), .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

/// The historical merge-editor shorthand resolves the corresponding index stage.
pub fn normalizeIndexStage(ref: []const u8) ?[2]u8 {
    if (ref.len == 2 and ref[0] == '~' and std.ascii.isDigit(ref[1])) return .{ ':', ref[1] };
    return null;
}

pub fn toGitUriWithOptions(allocator: std.mem.Allocator, path: []const u8, ref: []const u8, options: GitUriOptions) !std.Uri {
    var file = try URI.file(allocator, path);
    defer file.deinit();
    var query: std.Io.Writer.Allocating = .init(allocator);
    errdefer query.deinit();
    if (options.submodule_of) |parent| {
        try std.json.Stringify.value(.{ .path = path, .ref = ref, .submoduleOf = parent }, .{}, &query.writer);
    } else {
        try std.json.Stringify.value(.{ .path = path, .ref = ref }, .{}, &query.writer);
    }
    const suffix = if (options.replace_file_extension) ".git" else if (options.submodule_of != null) ".diff" else "";
    const uri_path = try std.mem.concat(allocator, u8, &.{ file.path, suffix });
    errdefer allocator.free(uri_path);
    return .{
        .scheme = options.scheme orelse "git",
        .path = .{ .raw = uri_path },
        .query = .{ .raw = try query.toOwnedSlice() },
    };
}

/// Encoded resource identity retained by SCM history and resource groups.
pub fn gitUriString(allocator: std.mem.Allocator, path: []const u8, ref: []const u8) ![]u8 {
    const uri = try toGitUri(allocator, path, ref);
    defer allocator.free(uri.path.raw);
    defer allocator.free(uri.query.?.raw);
    return std.fmt.allocPrint(allocator, "{f}", .{uri});
}

pub fn fileUriString(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try URI.file(allocator, path);
    defer file.deinit();
    return file.toStringEncoded(allocator);
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

test "git URI quick-diff extension replacement keeps the original path in the query" {
    const a = std.testing.allocator;
    const uri = try toGitUriWithOptions(a, "/repo/a.zig", "", .{ .replace_file_extension = true });
    defer a.free(uri.path.raw);
    defer a.free(uri.query.?.raw);
    try std.testing.expectEqualStrings("/repo/a.zig.git", uri.path.raw);
    try std.testing.expectEqualStrings("{\"path\":\"/repo/a.zig\",\"ref\":\"\"}", uri.query.?.raw);
}

test "Git URI preserves submodule owner and diff extension and recognizes index stages" {
    const a = std.testing.allocator;
    const uri = try toGitUriWithOptions(a, "/repo/sub module", "index", .{ .submodule_of = "/repo" });
    defer a.free(uri.path.raw);
    defer a.free(uri.query.?.raw);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const params = try fromGitUri(arena.allocator(), uri);
    try std.testing.expectEqualStrings("/repo/sub module", params.path);
    try std.testing.expectEqualStrings("index", params.ref);
    try std.testing.expectEqualStrings("/repo", params.submoduleOf.?);
    try std.testing.expectEqualStrings("/repo/sub module.diff", uri.path.raw);
    try std.testing.expectEqualSlices(u8, ":1", &normalizeIndexStage("~1").?);
    try std.testing.expectEqualSlices(u8, ":3", &normalizeIndexStage("~3").?);
    try std.testing.expect(normalizeIndexStage("~") == null);
    try std.testing.expect(normalizeIndexStage("~10") == null);
}
