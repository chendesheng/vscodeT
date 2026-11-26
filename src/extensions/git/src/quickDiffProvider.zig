// Port of `extensions/git/src/quickDiffProvider.ts`.
// The native provider returns an owned URI descriptor immediately. The
// read-only Git text model provider resolves blob contents asynchronously;
// an ignored/missing index blob is rejected there rather than starting a
// second synchronous Git process on the window thread. The repository port
// currently owns one visible repository per workspace.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Repository = @import("repository.zig").Repository;
const quick_diff = @import("../../../vs/workbench/contrib/scm/common/quickDiff.zig");
const paths = @import("../../../vs/base/common/extpath.zig");
const std_uri = @import("../../../vs/base/common/stdUri.zig");

pub const GitQuickDiffProvider = struct {
    base: quick_diff.QuickDiffProvider,

    pub fn init(repository: *Repository, id: []const u8) GitQuickDiffProvider {
        return .{ .base = .{
            .context = repository,
            .id = id,
            .label = "Git Local Changes (Working Tree)",
            .root_uri = .{ .scheme = "file", .path = .{ .raw = repository.root } },
            .kind = .primary,
            .get_original_fn = provideOriginalResource,
        } };
    }

    pub fn interface(self: *GitQuickDiffProvider) *quick_diff.QuickDiffProvider {
        return &self.base;
    }

    fn provideOriginalResource(context: *anyopaque, allocator: Allocator, uri: std.Uri) !?quick_diff.Original {
        if (!std.mem.eql(u8, uri.scheme, "file")) return null;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const path = try std_uri.fsPath(uri, arena.allocator());
        const repository: *Repository = @ptrCast(@alignCast(context));
        const relative = paths.relativeToRoot(path, repository.root) orelse return null;
        if (std.mem.eql(u8, relative, ".git") or paths.relativeToRoot(relative, ".git") != null) return null;
        if (repository.dot_git) |dot| {
            if (std.mem.eql(u8, path, dot.common_path) or paths.relativeToRoot(path, dot.common_path) != null) return null;
        }
        if (!isRegularResource(repository, path)) return null;
        for (repository.groups[0].resources.items) |resource| {
            if (std.mem.eql(u8, resource.absolute_path, path)) return null;
        }
        for (repository.groups[2].resources.items) |resource| {
            if (resource.kind == .untracked and std.mem.eql(u8, resource.absolute_path, path)) return null;
        }
        return try originalResource(allocator, path, "", "Index");
    }
};

pub const StagedResourceQuickDiffProvider = struct {
    base: quick_diff.QuickDiffProvider,

    pub fn init(repository: *Repository, id: []const u8) StagedResourceQuickDiffProvider {
        return .{ .base = .{
            .context = repository,
            .id = id,
            .label = "Git Local Changes (Index)",
            .root_uri = .{ .scheme = "file", .path = .{ .raw = repository.root } },
            .kind = .secondary,
            .get_original_fn = provideOriginalResource,
        } };
    }

    pub fn interface(self: *StagedResourceQuickDiffProvider) *quick_diff.QuickDiffProvider {
        return &self.base;
    }

    fn provideOriginalResource(context: *anyopaque, allocator: Allocator, uri: std.Uri) !?quick_diff.Original {
        if (!std.mem.eql(u8, uri.scheme, "file")) return null;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const path = try std_uri.fsPath(uri, arena.allocator());
        const repository: *Repository = @ptrCast(@alignCast(context));
        if (!isRegularResource(repository, path)) return null;
        for (repository.groups[1].resources.items) |resource| {
            if (std.mem.eql(u8, resource.absolute_path, path)) return try originalResource(allocator, path, "HEAD", "HEAD");
        }
        return null;
    }
};

fn isRegularResource(repository: *Repository, path: []const u8) bool {
    const git = repository.git orelse return false;
    const info = std.Io.Dir.cwd().statFile(git.io, path, .{ .follow_symlinks = false }) catch return false;
    return info.kind == .file;
}

fn originalResource(allocator: Allocator, path: []const u8, ref: []const u8, label: []const u8) !quick_diff.Original {
    const uri = try @import("uri.zig").toGitUriWithOptions(allocator, path, ref, .{ .replace_file_extension = true });
    defer allocator.free(uri.path.raw);
    defer allocator.free(uri.query.?.raw);
    const resource = try std_uri.encodedResource(allocator, uri);
    errdefer allocator.free(resource);
    return .{ .ref_label = try allocator.dupe(u8, label), .resource_uri = resource };
}

test "Git QuickDiffProvider: original resource preserves escaped path and quick diff extension" {
    const a = std.testing.allocator;
    var original = try originalResource(a, "/repo/a #b.txt", "", "Index");
    defer original.deinit(a);
    const uri = try std.Uri.parse(original.resource_uri);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectEqualStrings("git", uri.scheme);
    try std.testing.expectEqualStrings("/repo/a #b.txt.git", try std_uri.path(uri, arena.allocator()));
    try std.testing.expectEqualStrings("{\"path\":\"/repo/a #b.txt\",\"ref\":\"\"}", try std_uri.query(uri, arena.allocator()));
}
