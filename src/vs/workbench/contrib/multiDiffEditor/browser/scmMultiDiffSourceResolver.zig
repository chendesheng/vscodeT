// Port of the source URI contracts in
// `src/vs/workbench/contrib/multiDiffEditor/browser/scmMultiDiffSourceResolver.ts`.
// The source's query is the upstream JSON object; URI serialization uses the
// shared std.Uri encoder rather than concatenating raw query bytes.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ScmMultiDiffSourceResolver = struct {
    pub const scheme = "scm-multi-diff-source";
    pub const UriFields = struct { repositoryUri: []const u8, groupId: []const u8 };
    pub fn getMultiDiffSourceUri(allocator: Allocator, repository_uri: []const u8, group_id: []const u8) ![]u8 {
        const query = try std.json.Stringify.valueAlloc(allocator, UriFields{ .repositoryUri = repository_uri, .groupId = group_id }, .{});
        defer allocator.free(query);
        const uri: std.Uri = .{ .scheme = scheme, .path = .{ .raw = "" }, .query = .{ .raw = query } };
        return std.fmt.allocPrint(allocator, "{f}", .{uri});
    }
    pub fn parseUri(allocator: Allocator, uri: std.Uri) !?std.json.Parsed(UriFields) {
        if (!std.mem.eql(u8, uri.scheme, scheme) or uri.query == null) return null;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const query = try uri.query.?.toRawMaybeAlloc(arena.allocator());
        return std.json.parseFromSlice(UriFields, allocator, query, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null;
    }
};

pub const ScmHistoryItemResolver = struct {
    pub const scheme = "scm-history-item";
    pub const UriFields = struct {
        repositoryId: []const u8,
        historyItemId: []const u8,
        historyItemParentId: ?[]const u8 = null,
        historyItemDisplayId: ?[]const u8 = null,
    };
    pub fn getMultiDiffSourceUri(allocator: Allocator, root_path: []const u8, fields: UriFields) ![]u8 {
        const query = try std.json.Stringify.valueAlloc(allocator, fields, .{});
        defer allocator.free(query);
        const uri: std.Uri = .{ .scheme = scheme, .path = .{ .raw = root_path }, .query = .{ .raw = query } };
        return std.fmt.allocPrint(allocator, "{f}", .{uri});
    }
    pub fn parseUri(allocator: Allocator, uri: std.Uri) !?std.json.Parsed(UriFields) {
        if (!std.mem.eql(u8, uri.scheme, scheme) or uri.query == null) return null;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const query = try uri.query.?.toRawMaybeAlloc(arena.allocator());
        return std.json.parseFromSlice(UriFields, allocator, query, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null;
    }
};
