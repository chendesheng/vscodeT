// Local workspace file queries from ExtHostWorkspace.findFiles use the same
// ripgrep walker, glob exclusions and result limit as native workspace search.
const std = @import("std");
const search = @import("../../services/search/common/search.zig");
const FileWalker = @import("../../services/search/node/fileSearch.zig").FileWalker;
const glob = @import("../../../base/common/glob.zig");
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");

pub fn findFiles(io: std.Io, allocator: std.mem.Allocator, arena: std.mem.Allocator, workspace: ?[]const u8, args: []const rpc.Arg) !std.json.Value {
    var result = std.json.Array.init(arena);
    if (args.len < 2 or args[0] != .json or args[1] != .json or args[1].json != .object) return error.InvalidArguments;
    const folder = args[0].json;
    const root = if (folder == .object) blk: {
        if (!std.mem.eql(u8, string(folder, "scheme") orelse "", "file")) return .{ .array = result };
        break :blk string(folder, "path") orelse return error.InvalidArguments;
    } else workspace orelse ".";
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const path = try std.fs.path.resolve(arena, &.{ cwd, root });
    const options = args[1].json;
    var excludes: std.ArrayList(glob.ExcludeEntry) = .empty;
    if (options.object.get("excludePattern")) |list| {
        if (list == .array) for (list.array.items) |item| {
            if (string(item, "pattern")) |pattern| try excludes.append(arena, .{ .pattern = pattern });
        };
    }
    const limit = options.object.get("maxResults");
    var query = try search.FileQuery.init(allocator, &.{.{ .resource = path, .name = std.fs.path.basename(path) }}, .{
        .include_pattern = string(options, "includePattern"),
        .file_pattern = string(options, "filePattern") orelse "",
        .exclude_entries = excludes.items,
        .max_results = if (limit != null and limit.? == .integer) std.math.cast(usize, limit.?.integer) orelse 0 else 0,
        .should_glob_match_file_pattern = boolean(options, "shouldGlobSearch"),
        .ignore_glob_case = boolean(options, "ignoreGlobCase"),
        .ignore_symlinks = boolean(options, "ignoreSymlinks"),
        .settings = .{
            .use_ignore_files = !boolean(options, "disregardIgnoreFiles"),
            .use_parent_ignore_files = !boolean(options, "disregardParentIgnoreFiles"),
            .use_global_ignore_files = !boolean(options, "disregardGlobalIgnoreFiles"),
        },
    });
    defer query.deinit();
    var walker = try FileWalker.init(allocator, io, &query, "rg");
    defer walker.deinit();
    var found = try walker.walk();
    defer found.deinit();
    for (found.matches) |item| {
        const absolute = try std.fs.path.join(arena, &.{ item.base, item.relative_path });
        try result.append(try manager.fileUri(arena, absolute));
    }
    return .{ .array = result };
}

fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const prop = value.object.get(key) orelse return null;
    return if (prop == .string) prop.string else null;
}

fn boolean(value: std.json.Value, key: []const u8) bool {
    const prop = value.object.get(key) orelse return false;
    return prop == .bool and prop.bool;
}
