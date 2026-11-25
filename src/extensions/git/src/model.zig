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

pub const Model = struct {
    allocator: Allocator,
    git: ?*Git = null,
    git_delegate: ?*IGitExtensionDelegate = null,
    git_service: ?*GitService = null,
    repository: ?*Repository = null,
    git_root: ?[]u8 = null,

    pub fn init(allocator: Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub const OpenOptions = struct {
        io: std.Io,
        configuration: ?*ConfigurationService = null,
        window: *WindowQueue,
        host: repository_mod.Host,
        on_disabled: ?*const fn (?*anyopaque, []const u8) void = null,
        on_disabled_context: ?*anyopaque = null,
    };

    pub fn openRepository(self: *Model, repo_path: []const u8, open_options: OpenOptions) !?*Repository {
        if (self.git != null) return self.repository;
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
        if (cli.isDisabled()) return null;
        const opened = (cli.openRepository(repo_path) catch null) orelse return null;
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
        try provider.setConfiguration(open_options.configuration);
        return provider;
    }

    pub fn detachConfiguration(self: *Model) void {
        if (self.repository) |provider| provider.detachConfiguration();
    }

    pub fn setConfiguration(self: *Model, config: ?*ConfigurationService) !void {
        if (self.repository) |provider| try provider.setConfiguration(config);
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
