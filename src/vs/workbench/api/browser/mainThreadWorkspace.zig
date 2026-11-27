// Port of local workspace data and file-query behavior from
// `src/vs/workbench/api/browser/mainThreadWorkspace.ts`.
// The window owns a single local workspace context; queries reuse the
// native ripgrep walker. Remote/trust and workspace editing APIs remain gaps.
const std = @import("std");
const search = @import("../../services/search/common/search.zig");
const FileWalker = @import("../../services/search/node/fileSearch.zig").FileWalker;
const glob = @import("../../../base/common/glob.zig");
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const std_uri = @import("../../../base/common/stdUri.zig");
const WorkspaceContextService = @import("../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const CancellationToken = @import("../../../base/common/cancellation.zig").CancellationToken;

pub fn workspaceData(arena: std.mem.Allocator, io: std.Io, context: *WorkspaceContextService) !std.json.Value {
    if (!context.hasWorkspaceData()) return .null;
    const workspace = context.getWorkspace();
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    var data: std.json.ObjectMap = .empty;
    try data.put(arena, "id", .{ .string = workspace.id });
    const label = workspace.name orelse if (workspace.folders.items.len == 1) workspace.folders.items[0].name else "workspace";
    try data.put(arena, "name", .{ .string = label });
    try data.put(arena, "transient", .{ .bool = false });
    try data.put(arena, "isUntitled", .{ .bool = false });
    try data.put(arena, "configuration", if (workspace.configuration) |path| try manager.fileUri(arena, try std.fs.path.resolve(arena, &.{ cwd, path })) else .null);
    var folders = std.json.Array.init(arena);
    for (workspace.folders.items) |folder| {
        var value: std.json.ObjectMap = .empty;
        try value.put(arena, "uri", try manager.fileUri(arena, try std.fs.path.resolve(arena, &.{ cwd, folder.resource })));
        try value.put(arena, "name", .{ .string = folder.name });
        try value.put(arena, "index", .{ .integer = @intCast(folder.index) });
        try folders.append(.{ .object = value });
    }
    try data.put(arena, "folders", .{ .array = folders });
    return .{ .object = data };
}

/// Workbench counterpart of workspaceContains.checkGlobFileExists.
pub fn checkExists(io: std.Io, allocator: std.mem.Allocator, arena: std.mem.Allocator, args: []const rpc.Arg, token: ?CancellationToken) !bool {
    if (args.len < 2 or args[0] != .json or args[0].json != .array or args[1] != .json or args[1].json != .array) return error.InvalidArguments;
    for (args[0].json.array.items) |folder| {
        const uri = try std.Uri.parse(try std_uri.encodedResourceFromJson(arena, folder));
        if (!std.mem.eql(u8, uri.scheme, "file")) continue;
        const path = try std_uri.fsPath(uri, arena);
        for (args[1].json.array.items) |pattern| {
            if (token) |cancel| if (cancel.isCancellationRequested()) return false;
            if (pattern != .string) return error.InvalidArguments;
            var query = try search.FileQuery.init(allocator, &.{.{ .resource = path, .name = std.fs.path.basename(path) }}, .{ .include_pattern = pattern.string, .exists = true });
            defer query.deinit();
            var walker = try FileWalker.init(allocator, io, &query, "rg");
            defer walker.deinit();
            var found = try walker.walk();
            defer found.deinit();
            if (token) |cancel| if (cancel.isCancellationRequested()) return false;
            if (found.limit_hit) return true;
        }
    }
    return false;
}

pub fn findFiles(io: std.Io, allocator: std.mem.Allocator, arena: std.mem.Allocator, workspace: ?[]const u8, args: []const rpc.Arg) !std.json.Value {
    var result = std.json.Array.init(arena);
    if (args.len < 2 or args[0] != .json or args[1] != .json or args[1].json != .object) return error.InvalidArguments;
    const folder = args[0].json;
    const root = if (folder == .object) blk: {
        if (!std.mem.eql(u8, string(folder, "scheme") orelse "", "file")) return .{ .array = result };
        break :blk try std_uri.fsPath(try std.Uri.parse(try std_uri.encodedResourceFromJson(arena, folder)), arena);
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
