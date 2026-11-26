// Port of the repository-opening lifecycle from
// `vscode/extensions/git/src/model.ts`. The terminal Git extension uses its
// existing Repository/ISCMProvider adapter instead of a JavaScript extension
// host. Repository discovery and the Git service delegate are owned here,
// separate from the workbench's Source Control view and status UI.
//
// Parent-repository consent and ignored/unsafe repository tracking remain
// unported. The primary repository is retained as the selection used by the
// existing SCM view while the model owns the full opened repository list.
const std = @import("std");
const builtin = @import("builtin");
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
const Emitter = @import("../../../vs/base/common/event.zig").Emitter;

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

    const Encoding = @import("../../../vs/workbench/services/textfile/common/encoding.zig");

    const Side = struct {
        resource: SnapshotSource.Resource,
        text: []const u8 = "",
        available: bool = false,
    };

    /// Decode Git and disk buffers through the same codec used by the file
    /// service. The immutable snapshot is never published as a fake aligned
    /// document; the real URI models own the resulting individual texts.
    fn readSide(self: *SnapshotRead, reader: *Git, a: Allocator, relative: []const u8, uri_ref: []const u8, read_ref: ?[]const u8, working: bool, open_text: ?[]const u8) !Side {
        if (working) if (open_text) |text| {
            return .{ .resource = try self.resource(a, relative, uri_ref, true), .text = text, .available = true };
        };
        var side: Side = .{ .resource = try self.resource(a, relative, uri_ref, false) };
        if (read_ref == null and !working) return side; // absent side
        // Keep the upstream ~1/~2/~3 URI identities; only the Git CLI
        // boundary converts them to the index-stage syntax.
        const stage = if (read_ref) |revision| @import("uri.zig").normalizeIndexStage(revision) else null;
        const bytes = (if (working)
            reader.readWorkingBuffer(self.root, relative)
        else
            reader.readGitBuffer(self.root, if (stage) |ref| &ref else read_ref.?, relative)) catch |err| {
            if (err == error.OutOfMemory) return err;
            side.resource.failure = err;
            return side;
        };
        defer reader.allocator.free(bytes);
        const decoded = (try Encoding.decodeText(a, bytes)) orelse return side;
        if (working) side.resource = try self.resource(a, relative, uri_ref, true);
        side.resource.encoding = decoded.encoding;
        side.text = decoded.text;
        side.available = true;
        return side;
    }

    fn readRef(self: *SnapshotRead, reader: *Git, a: Allocator, relative: []const u8, ref: git.DiffRef, working: ?[]const u8, left: bool) !Side {
        return switch (ref) {
            .head => self.readSide(reader, a, relative, "HEAD", "HEAD", false, null),
            .index => self.readSide(reader, a, relative, if (left) "~" else "", "", false, null),
            .working => self.readSide(reader, a, relative, "wt", null, true, working),
            .empty => blk: {
                const empty = try reader.getEmptyTree(self.root);
                break :blk self.readSide(reader, a, relative, empty, null, false, null);
            },
        };
    }

    fn read(context: *anyopaque, allocator: Allocator) !SnapshotSource.Texts {
        const self: *SnapshotRead = @ptrCast(@alignCast(context));
        const reader = try Git.init(allocator, .{ .git_path = self.exe, .io = self.io });
        defer reader.deinit();
        reader.timeout = self.timeout;
        reader.max_file_size = self.max_file_size;
        var original: Side = undefined;
        var modified: Side = undefined;
        switch (self.source) {
            .refs => |refs| {
                original = try self.readRef(reader, allocator, self.original_path, refs.left, refs.working, true);
                modified = try self.readRef(reader, allocator, self.modified_path, refs.right, refs.working, false);
                if (!original.available and !modified.available and !refs.has_diff) {
                    if (std.Io.Dir.cwd().access(self.io, self.path, .{})) |_| {
                        return error.DiffUnavailable;
                    } else |_| {}
                }
            },
            .revisions => |refs| {
                const left = if (refs.left) |revision| revision else try reader.getEmptyTree(self.root);
                original = try self.readSide(reader, allocator, self.original_path, left, refs.left, false, null);
                modified = try self.readSide(reader, allocator, self.modified_path, refs.right, refs.right, false, null);
            },
        }
        return .{
            .original = original.text,
            .modified = modified.text,
            .original_available = original.available,
            .modified_available = modified.available,
            .original_resource = original.resource,
            .modified_resource = modified.resource,
        };
    }

    fn interface(self: *SnapshotRead) SnapshotSource {
        return .{ .context = self, .read = read, .destroy = destroy };
    }
};

/// Immutable read/stat request for a registered Git filesystem resource.
pub const GitResourceRead = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    exe: []const u8,
    timeout: std.Io.Timeout,
    max_file_size: usize,
    root: []const u8,
    path: []const u8,
    relative: []const u8,
    ref: []const u8,
    submodule: bool,

    pub fn read(self: *const GitResourceRead, allocator: Allocator) ![]u8 {
        const reader = try Git.init(allocator, .{ .git_path = self.exe, .io = self.io });
        defer reader.deinit();
        reader.timeout = self.timeout;
        reader.max_file_size = self.max_file_size;
        return if (self.submodule)
            reader.readSubmoduleDiff(self.root, self.relative, std.mem.eql(u8, self.ref, "index"))
        else
            reader.readGitBuffer(self.root, self.ref, self.relative);
    }

    pub fn stat(self: *const GitResourceRead, allocator: Allocator) !u64 {
        const reader = try Git.init(allocator, .{ .git_path = self.exe, .io = self.io });
        defer reader.deinit();
        reader.timeout = self.timeout;
        const ref = if (self.submodule and (std.mem.eql(u8, self.ref, "index") or std.mem.eql(u8, self.ref, "wt"))) "HEAD" else self.ref;
        return reader.getObjectSize(self.root, ref, self.relative);
    }

    pub fn destroy(self: *GitResourceRead) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

pub const Model = struct {
    allocator: Allocator,
    git: ?*Git = null,
    git_delegate: ?*IGitExtensionDelegate = null,
    git_service: ?*GitService = null,
    /// Initial selection for the current native SCM view. Ownership lives
    /// exclusively in open_repositories; each repository has a stable root.
    repository: ?*Repository = null,
    git_root: ?[]const u8 = null,
    open_repositories: std.ArrayList(*Repository) = .empty,
    on_did_open_repository: Emitter(*Repository),
    on_did_close_repository: Emitter(*Repository),
    repository_count_buffer: [32]u8 = undefined,
    repository_count_key: ?@import("../../../vs/platform/contextkey/common/contextkey.zig").IContextKey = null,
    git_missing_key: ?@import("../../../vs/platform/contextkey/common/contextkey.zig").IContextKey = null,

    pub fn init(allocator: Allocator) Model {
        return .{ .allocator = allocator, .on_did_open_repository = .init(allocator), .on_did_close_repository = .init(allocator) };
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
        if (self.repositoryForRoot(repo_path)) |provider| return provider;
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
        const cli = self.git orelse blk: {
            const value = Git.init(self.allocator, options) catch return null;
            self.git = value;
            break :blk value;
        };
        if (cli.isDisabled()) {
            if (self.git_missing_key) |key| key.set(.{ .boolean = true });
            return null;
        }
        const opened = (cli.openRepository(repo_path) catch null) orelse {
            if (cli.isDisabled()) if (self.git_missing_key) |key| key.set(.{ .boolean = true });
            return null;
        };
        if (self.repositoryForRoot(opened.root_path)) |provider| return provider;
        const concrete = cli.repositoryForRoot(opened.root_path) orelse return null;
        if (self.git_service == null) {
            const service = try self.allocator.create(GitService);
            errdefer self.allocator.destroy(service);
            service.* = GitService.init(self.allocator);
            errdefer service.deinit();
            const delegate = try self.allocator.create(IGitExtensionDelegate);
            errdefer self.allocator.destroy(delegate);
            delegate.* = cli.interface();
            _ = try service.setDelegate(delegate);
            self.git_service = service;
            self.git_delegate = delegate;
        }

        const provider = try Repository.create(self.allocator, cli, concrete, opened.root_path, open_options.host);
        errdefer provider.destroy();
        provider.attachWindow(open_options.window);
        if (open_options.host_service) |host| try provider.attachHostService(host);
        try provider.setConfiguration(open_options.configuration);
        try self.open_repositories.append(self.allocator, provider);
        if (self.repository == null) {
            self.repository = provider;
            self.git_root = provider.root;
        }
        self.updateRepositoryCount();
        self.on_did_open_repository.fire(provider) catch {};
        return provider;
    }

    fn updateRepositoryCount(self: *Model) void {
        if (self.repository_count_key) |key| {
            const value = std.fmt.bufPrint(&self.repository_count_buffer, "{d}", .{self.open_repositories.items.len}) catch return;
            key.set(.{ .string = value });
        }
    }

    pub fn closeRepository(self: *Model, provider: *Repository) void {
        for (self.open_repositories.items, 0..) |candidate, index| {
            if (candidate != provider) continue;
            _ = self.open_repositories.orderedRemove(index);
            if (self.repository == provider) {
                self.repository = if (self.open_repositories.items.len > 0) self.open_repositories.items[0] else null;
                self.git_root = if (self.repository) |selected| selected.root else null;
            }
            self.updateRepositoryCount();
            self.on_did_close_repository.fire(provider) catch {};
            provider.destroy();
            return;
        }
    }

    pub fn repositories(self: *const Model) []const *Repository {
        return self.open_repositories.items;
    }

    pub fn repositoryForRoot(self: *const Model, path: []const u8) ?*Repository {
        for (self.open_repositories.items) |provider| {
            if (sameRoot(path, provider.root)) return provider;
        }
        return null;
    }

    fn sameRoot(left: []const u8, right: []const u8) bool {
        const a = std.mem.trimEnd(u8, left, "/\\");
        const b = std.mem.trimEnd(u8, right, "/\\");
        return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
    }

    /// Upstream getOpenRepository prefers the most deeply nested open root.
    /// A relative path is only meaningful for the existing selected view.
    pub fn getRepository(self: *const Model, path: []const u8) ?*Repository {
        if (!std.fs.path.isAbsolute(path)) return self.repository;
        var result: ?*Repository = null;
        for (self.open_repositories.items) |provider| {
            if (!sameRoot(path, provider.root) and extpath.relativeToRoot(path, provider.root) == null) continue;
            if (result == null or provider.root.len > result.?.root.len) result = provider;
        }
        return result;
    }

    pub fn detachConfiguration(self: *Model) void {
        for (self.open_repositories.items) |provider| provider.detachConfiguration();
    }

    pub fn setConfiguration(self: *Model, config: ?*ConfigurationService) !void {
        for (self.open_repositories.items) |provider| try provider.setConfiguration(config);
    }

    fn captureSnapshot(self: *Model, io: std.Io, root: []const u8, path: []const u8, original_path: []const u8, modified_path: []const u8) !*SnapshotRead {
        const cli = self.git orelse return error.NoGit;
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
        const repository = self.getRepository(path) orelse return error.NoRepository;
        const root = repository.root;
        const relative = extpath.relativeToRoot(path, root) orelse return error.OutsideRepository;
        const request = try self.captureSnapshot(io, root, path, relative, relative);
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
        const repository = self.getRepository(path) orelse return error.NoRepository;
        const root = repository.root;
        const relative_right = if (std.fs.path.isAbsolute(path)) extpath.relativeToRoot(path, root) orelse return error.OutsideRepository else path;
        const relative_left = if (original_path) |value|
            if (std.fs.path.isAbsolute(value)) extpath.relativeToRoot(value, root) orelse relative_right else value
        else
            relative_right;
        const request = try self.captureSnapshot(io, root, path, relative_left, relative_right);
        errdefer SnapshotRead.destroy(request);
        const allocator = request.arena.allocator();
        request.source = .{ .revisions = .{
            .left = if (left) |revision| try allocator.dupe(u8, revision) else null,
            .right = try allocator.dupe(u8, right),
        } };
        return request.interface();
    }

    /// Capture repository/ref policy on the window thread; the Git file
    /// provider reads or stats this immutable request on its own boundary.
    pub fn captureGitResource(self: *Model, io: std.Io, uri: std.Uri) !*GitResourceRead {
        if (!std.mem.eql(u8, uri.scheme, "git")) return error.UnsupportedDiffResourceScheme;
        const cli = self.git orelse return error.NoGit;
        const request = try std.heap.page_allocator.create(GitResourceRead);
        errdefer std.heap.page_allocator.destroy(request);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const git_uri = @import("uri.zig");
        const params = try git_uri.fromGitUri(a, uri);
        const repository = (if (params.submoduleOf) |parent| self.repositoryForRoot(parent) else self.getRepository(params.path)) orelse return error.NoRepository;
        const root = repository.root;
        const relative = extpath.relativeToRoot(params.path, root) orelse return error.OutsideRepository;
        var ref: []const u8 = params.ref;
        if (git_uri.normalizeIndexStage(ref)) |stage| ref = try a.dupe(u8, &stage);
        if (std.mem.eql(u8, ref, "~")) {
            ref = "HEAD";
            for (repository.repository.stateRef().index_changes) |change| {
                if (std.mem.eql(u8, change.path, relative)) {
                    ref = "";
                    break;
                }
            }
        }
        request.* = .{
            .arena = undefined,
            .io = io,
            .exe = try a.dupe(u8, cli.exe),
            .timeout = cli.timeout,
            .max_file_size = cli.max_file_size,
            .root = try a.dupe(u8, root),
            .path = params.path,
            .relative = relative,
            .ref = ref,
            .submodule = params.submoduleOf != null,
        };
        request.arena = arena;
        return request;
    }

    pub fn resolveDiffTexts(self: *Model, path: []const u8, working: ?[]const u8, left: git.DiffRef, right: git.DiffRef) !git.ResolvedDiffTexts {
        const repository = self.getRepository(path) orelse return error.NoRepository;
        const root = repository.root;
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
        const repository = self.getRepository(path) orelse return error.NoRepository;
        const root = repository.root;
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
        for (self.open_repositories.items) |provider| {
            self.on_did_close_repository.fire(provider) catch {};
            provider.destroy();
        }
        self.open_repositories.deinit(self.allocator);
        self.on_did_open_repository.deinit();
        self.on_did_close_repository.deinit();
        if (self.git_service) |service| {
            service.deinit();
            self.allocator.destroy(service);
        }
        if (self.git_delegate) |delegate| self.allocator.destroy(delegate);
        if (self.git) |cli| cli.deinit();
        self.* = init(self.allocator);
    }
};
