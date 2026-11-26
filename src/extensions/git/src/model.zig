// Port of the single-workspace repository-opening lifecycle from
// `vscode/extensions/git/src/model.ts`. The terminal Git extension uses its
// existing Repository/ISCMProvider adapter instead of a JavaScript extension
// host. Repository discovery and the Git service delegate are owned here,
// separate from the workbench's Source Control view and status UI.
//
// Parent-repository consent, ignored/unsafe repository tracking and
// multi-repository discovery are not yet ported by this single-root adapter.
const std = @import("std");
const Allocator = std.mem.Allocator;
const extpath = @import("../../../vs/base/common/extpath.zig");
const Git = @import("git.zig").Git;
const git = @import("git.zig");
const repository_mod = @import("repository.zig");
const Repository = repository_mod.Repository;
const GitService = @import("../../../vs/workbench/contrib/git/browser/gitService.zig").GitService;
const IGitExtensionDelegate = @import("../../../vs/workbench/contrib/git/common/gitService.zig").IGitExtensionDelegate;
const ConfigurationService = @import("../../../vs/workbench/services/configuration/browser/configurationService.zig").ConfigurationService;
const WindowQueue = @import("../../../vs/base/common/windowDispatch.zig").Queue;

const SnapshotSource = @import("../../../vs/editor/browser/widget/diffEditor/diffProviderFactoryService.zig").SnapshotSource;

/// Immutable Git virtual-document request. All data is copied before
/// scheduling; the worker creates its own Git reader and never accesses the
/// repository model, status cache or extension callbacks.
const SnapshotRead = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    exe: []const u8,
    timeout: std.Io.Timeout,
    max_file_size: usize,
    root: []const u8,
    path: []const u8,
    original_path: []const u8,
    modified_path: []const u8,
    source: union(enum) {
        refs: struct { working: ?[]const u8, left: git.DiffRef, right: git.DiffRef, has_diff: bool },
        revisions: struct { left: ?[]const u8, right: []const u8 },
    },

    fn destroy(context: *anyopaque) void {
        const self: *SnapshotRead = @ptrCast(@alignCast(context));
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn resource(self: *SnapshotRead, allocator: Allocator, relative: []const u8, ref: []const u8, working_file: bool) !SnapshotSource.Resource {
        const path = try std.fs.path.join(allocator, &.{ self.root, relative });
        return .{
            .path = path,
            .uri = if (working_file) .{ .scheme = "file", .host = .{ .raw = "" }, .path = .{ .raw = path } } else try @import("uri.zig").toGitUri(allocator, path, ref),
            .is_working_file = working_file,
        };
    }

    fn resourceRef(ref: git.DiffRef, left: bool) []const u8 {
        return switch (ref) {
            .head => "HEAD",
            .index => if (left) "~" else "",
            .working => "wt",
            .empty => "empty",
        };
    }

    fn read(context: *anyopaque, allocator: Allocator) !SnapshotSource.Texts {
        const self: *SnapshotRead = @ptrCast(@alignCast(context));
        const reader = try Git.init(allocator, .{ .git_path = self.exe, .io = self.io });
        defer reader.deinit();
        reader.timeout = self.timeout;
        reader.max_file_size = self.max_file_size;
        switch (self.source) {
            .refs => |refs| {
                const text = try reader.resolveDiffTexts(self.root, self.modified_path, refs.working, refs.left, refs.right);
                if (text.original.len == 0 and text.modified.len == 0 and !refs.has_diff) {
                    if (std.Io.Dir.cwd().access(self.io, self.path, .{})) |_| {
                        return error.DiffUnavailable;
                    } else |_| {}
                }
                return .{
                    .original = text.original,
                    .modified = text.modified,
                    .original_resource = try self.resource(allocator, self.original_path, resourceRef(refs.left, true), refs.left == .working and text.original_available),
                    .modified_resource = try self.resource(allocator, self.modified_path, resourceRef(refs.right, false), refs.right == .working and text.modified_available),
                };
            },
            .revisions => |refs| {
                const original = if (refs.left) |revision|
                    (reader.readRefAt(allocator, self.root, self.original_path, revision) catch null) orelse try allocator.dupe(u8, "")
                else
                    try allocator.dupe(u8, "");
                const modified = (reader.readRefAt(allocator, self.root, self.modified_path, refs.right) catch null) orelse try allocator.dupe(u8, "");
                return .{
                    .original = original,
                    .modified = modified,
                    .original_resource = try self.resource(allocator, self.original_path, refs.left orelse "empty", false),
                    .modified_resource = try self.resource(allocator, self.modified_path, refs.right, false),
                };
            },
        }
    }

    fn interface(self: *SnapshotRead) SnapshotSource {
        return .{ .context = self, .read = read, .destroy = destroy };
    }
};

pub const Model = struct {
    allocator: Allocator,
    git: ?*Git = null,
    git_delegate: ?*IGitExtensionDelegate = null,
    git_service: ?*GitService = null,
    repository: ?*Repository = null,
    git_root: ?[]u8 = null,
    repository_count_key: ?@import("../../../vs/platform/contextkey/common/contextkey.zig").IContextKey = null,
    git_missing_key: ?@import("../../../vs/platform/contextkey/common/contextkey.zig").IContextKey = null,

    pub fn init(allocator: Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub const OpenOptions = struct {
        io: std.Io,
        configuration: ?*ConfigurationService = null,
        context_keys: ?@import("../../../vs/platform/contextkey/common/contextkey.zig").IContextKeyService = null,
        window: *WindowQueue,
        host_service: ?@import("../../../vs/workbench/services/host/browser/host.zig").IHostService = null,
        host: repository_mod.Host,
        on_disabled: ?*const fn (?*anyopaque, []const u8) void = null,
        on_disabled_context: ?*anyopaque = null,
    };

    pub fn openRepository(self: *Model, repo_path: []const u8, open_options: OpenOptions) !?*Repository {
        if (self.git != null) return self.repository;
        if (open_options.context_keys) |keys| {
            if (self.repository_count_key == null) self.repository_count_key = try keys.createKey("gitOpenRepositoryCount", .{ .string = "0" });
            if (self.git_missing_key == null) self.git_missing_key = try keys.createKey("git.missing", .{ .boolean = false });
        }
        if (open_options.configuration) |configuration| {
            if (!configuration.getBool("git.enabled", true)) return null;
        }
        var options = git.Options{
            .git_path = null,
            .enabled = true,
            .timeout_ms = 5000,
            .io = open_options.io,
            .on_disabled = open_options.on_disabled,
            .on_disabled_context = open_options.on_disabled_context,
        };
        if (open_options.configuration) |configuration| {
            if (configuration.getValue("git.path", .{})) |value| {
                switch (value.*) {
                    .string => |text| options.git_path = text,
                    else => {},
                }
            }
            if (configuration.getValue("diffEditor.maxFileSize", .{})) |value| {
                const megabytes: f64 = switch (value.*) {
                    .integer => |number| @floatFromInt(number),
                    .float => |number| number,
                    else => 50,
                };
                if (megabytes > 0 and megabytes < 1024) options.max_file_size_kb = @intFromFloat(megabytes * 1024);
            }
        }
        const cli = Git.init(self.allocator, options) catch return null;
        self.git = cli;
        errdefer self.deinit();
        if (cli.isDisabled()) {
            if (self.git_missing_key) |key| key.set(.{ .boolean = true });
            return null;
        }
        const opened = (cli.openRepository(repo_path) catch null) orelse {
            if (cli.isDisabled()) if (self.git_missing_key) |key| key.set(.{ .boolean = true });
            return null;
        };
        const concrete = cli.repositoryForRoot(opened.root_path) orelse return null;

        const service = try self.allocator.create(GitService);
        service.* = GitService.init(self.allocator);
        self.git_service = service;
        const delegate = try self.allocator.create(IGitExtensionDelegate);
        delegate.* = cli.interface();
        self.git_delegate = delegate;
        _ = service.setDelegate(delegate) catch {};
        const root = try self.allocator.dupe(u8, opened.root_path);
        self.git_root = root;

        const provider = try Repository.create(self.allocator, cli, concrete, root, open_options.host);
        provider.attachWindow(open_options.window);
        self.repository = provider;
        if (open_options.host_service) |host| try provider.attachHostService(host);
        try provider.setConfiguration(open_options.configuration);
        if (self.repository_count_key) |key| key.set(.{ .string = "1" });
        return provider;
    }

    pub fn detachConfiguration(self: *Model) void {
        if (self.repository) |provider| provider.detachConfiguration();
    }

    pub fn setConfiguration(self: *Model, config: ?*ConfigurationService) !void {
        if (self.repository) |provider| try provider.setConfiguration(config);
    }

    fn captureSnapshot(self: *Model, io: std.Io, path: []const u8, original_path: []const u8, modified_path: []const u8) !*SnapshotRead {
        const cli = self.git orelse return error.NoGit;
        const root = self.git_root orelse return error.NoRepository;
        const request = try std.heap.page_allocator.create(SnapshotRead);
        errdefer std.heap.page_allocator.destroy(request);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        request.* = .{
            .arena = undefined,
            .io = io,
            .exe = try allocator.dupe(u8, cli.exe),
            .timeout = cli.timeout,
            .max_file_size = cli.max_file_size,
            .root = try allocator.dupe(u8, root),
            .path = try allocator.dupe(u8, path),
            .original_path = try allocator.dupe(u8, original_path),
            .modified_path = try allocator.dupe(u8, modified_path),
            .source = undefined,
        };
        request.arena = arena;
        return request;
    }

    pub fn snapshotSource(self: *Model, io: std.Io, path: []const u8, working: ?[]const u8, left: git.DiffRef, right: git.DiffRef, has_diff: bool) !SnapshotSource {
        if (self.repository == null) return error.NoRepository;
        const root = self.git_root orelse return error.NoRepository;
        const relative = extpath.relativeToRoot(path, root) orelse return error.OutsideRepository;
        const request = try self.captureSnapshot(io, path, relative, relative);
        errdefer SnapshotRead.destroy(request);
        request.source = .{ .refs = .{
            .working = if (working) |text| try request.arena.allocator().dupe(u8, text) else null,
            .left = left,
            .right = right,
            .has_diff = has_diff,
        } };
        return request.interface();
    }

    pub fn revisionSnapshotSource(self: *Model, io: std.Io, path: []const u8, original_path: ?[]const u8, left: ?[]const u8, right: []const u8) !SnapshotSource {
        const root = self.git_root orelse return error.NoRepository;
        const relative_right = if (std.fs.path.isAbsolute(path)) extpath.relativeToRoot(path, root) orelse return error.OutsideRepository else path;
        const relative_left = if (original_path) |value|
            if (std.fs.path.isAbsolute(value)) extpath.relativeToRoot(value, root) orelse relative_right else value
        else
            relative_right;
        const request = try self.captureSnapshot(io, path, relative_left, relative_right);
        errdefer SnapshotRead.destroy(request);
        const allocator = request.arena.allocator();
        request.source = .{ .revisions = .{
            .left = if (left) |revision| try allocator.dupe(u8, revision) else null,
            .right = try allocator.dupe(u8, right),
        } };
        return request.interface();
    }

    /// The terminal projects Git's virtual text resources to snapshot buffers
    /// for the editor service. Both returned slices are owned by the caller.
    pub fn resolveDiffTexts(self: *Model, path: []const u8, working: ?[]const u8, left: git.DiffRef, right: git.DiffRef) !git.ResolvedDiffTexts {
        if (self.repository == null) return error.NoRepository;
        const root = self.git_root orelse return error.NoRepository;
        const relative = extpath.relativeToRoot(path, root) orelse return error.OutsideRepository;
        const cli = self.git orelse return error.NoGit;
        return cli.resolveDiffTexts(root, relative, working, left, right);
    }

    pub fn resolveRefDiffTexts(
        self: *Model,
        path: []const u8,
        original_path: ?[]const u8,
        left_rev: ?[]const u8,
        right_rev: []const u8,
    ) !git.ResolvedDiffTexts {
        const root = self.git_root orelse return error.NoRepository;
        const cli = self.git orelse return error.NoGit;
        const relative_right = if (std.fs.path.isAbsolute(path))
            extpath.relativeToRoot(path, root) orelse return error.OutsideRepository
        else
            path;
        const relative_left = if (original_path) |value|
            if (std.fs.path.isAbsolute(value))
                extpath.relativeToRoot(value, root) orelse relative_right
            else
                value
        else
            relative_right;

        const left_text = if (left_rev) |revision| blk: {
            const value = cli.readRefAt(self.allocator, root, relative_left, revision) catch null;
            break :blk value orelse try self.allocator.dupe(u8, "");
        } else try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(left_text);
        const right_text = blk: {
            const value = cli.readRefAt(self.allocator, root, relative_right, right_rev) catch null;
            break :blk value orelse try self.allocator.dupe(u8, "");
        };
        return .{ .original = left_text, .modified = right_text };
    }

    /// Source Control unregisters its provider before releasing the model.
    /// Reset makes the single-workspace extension reusable after a workspace
    /// or git.enabled change.
    pub fn deinit(self: *Model) void {
        if (self.repository_count_key) |key| key.reset();
        if (self.git_missing_key) |key| key.reset();
        if (self.repository) |provider| provider.destroy();
        if (self.git_service) |service| {
            service.deinit();
            self.allocator.destroy(service);
        }
        if (self.git_delegate) |delegate| self.allocator.destroy(delegate);
        if (self.git) |cli| cli.deinit();
        if (self.git_root) |root| self.allocator.free(root);
        self.* = init(self.allocator);
    }
};
