// Port of the repository-opening lifecycle from
// `vscode/extensions/git/src/model.ts`. The terminal Git extension uses its
// existing Repository/ISCMProvider adapter instead of a JavaScript extension
// host. Repository discovery and the Git service delegate are owned here,
// separate from the workbench's Source Control view and status UI.
//
// Parent-repository consent and ignored/unsafe repository tracking remain
// unported. The full opened repository list is owned here; the SCM view
// service supplies the active selection used by commands and history.
const std = @import("std");
const Allocator = std.mem.Allocator;
const extpath = @import("../../../vs/base/common/extpath.zig");
const git_util = @import("util.zig");
const Git = @import("git.zig").Git;
const git = @import("git.zig");
const repository_mod = @import("repository.zig");
const Repository = repository_mod.Repository;
const GitService = @import("../../../vs/workbench/contrib/git/browser/gitService.zig").GitService;
const IGitExtensionDelegate = @import("../../../vs/workbench/contrib/git/common/gitService.zig").IGitExtensionDelegate;
const ConfigurationService = @import("../../../vs/workbench/services/configuration/browser/configurationService.zig").ConfigurationService;
const dispatch = @import("../../../vs/base/common/windowDispatch.zig");
const WindowQueue = dispatch.Queue;
const time = @import("../../../vs/base/common/timeCompat.zig");
const INotificationService = @import("../../../vs/platform/notification/common/notification.zig").INotificationService;
const Emitter = @import("../../../vs/base/common/event.zig").Emitter;
const worker_mod = @import("../../../vs/editor/browser/services/editorWorkerService.zig");
const workspace_context = @import("../../../vs/workbench/services/workspaces/common/workspaceContextService.zig");
const editor_service = @import("../../../vs/workbench/services/editor/common/editorService.zig");

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

/// A Git repository open is two phases: discover and read the initial
/// status on a worker, then publish the concrete repository and services
/// on the window. All process arguments are immutable captured values.
pub const RepositoryOpenRequest = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    exe: []const u8,
    timeout: std.Io.Timeout,
    max_file_size: usize,
    path: []const u8,
    result: ?struct { root: []const u8, state: git.GitRepositoryState } = null,
    disabled_reason: ?[]const u8 = null,

    fn create(cli: *const Git, path: []const u8) !*RepositoryOpenRequest {
        const self = try std.heap.page_allocator.create(RepositoryOpenRequest);
        errdefer std.heap.page_allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        self.* = .{ .arena = undefined, .io = cli.io, .exe = try a.dupe(u8, cli.exe), .timeout = cli.timeout, .max_file_size = cli.max_file_size, .path = try a.dupe(u8, path) };
        self.arena = arena;
        return self;
    }

    pub fn discover(self: *RepositoryOpenRequest) !void {
        const a = self.arena.allocator();
        const reader = try Git.init(a, .{ .git_path = self.exe, .io = self.io });
        defer reader.deinit();
        defer if (reader.isDisabled()) {
            self.disabled_reason = a.dupe(u8, reader.disabledReason() orelse "git unavailable") catch null;
        };
        reader.timeout = self.timeout;
        reader.max_file_size = self.max_file_size;
        const root = try reader.discover(self.path) orelse return error.NoRepository;
        const state = try reader.status(root);
        self.result = .{ .root = root, .state = state };
    }

    pub fn captureResource(self: *RepositoryOpenRequest, uri: std.Uri) !*GitResourceRead {
        const result = self.result orelse return error.NoRepository;
        return GitResourceRead.create(self.io, self.exe, self.timeout, self.max_file_size, result.root, &result.state, uri);
    }

    pub fn destroy(self: *RepositoryOpenRequest) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
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

    fn create(io: std.Io, exe: []const u8, timeout: std.Io.Timeout, max_file_size: usize, root: []const u8, state: *const git.GitRepositoryState, uri: std.Uri) !*GitResourceRead {
        const request = try std.heap.page_allocator.create(GitResourceRead);
        errdefer std.heap.page_allocator.destroy(request);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const git_uri = @import("uri.zig");
        const params = try git_uri.fromGitUri(a, uri);
        const relative = extpath.relativeToRoot(params.path, root) orelse return error.OutsideRepository;
        var ref: []const u8 = params.ref;
        if (git_uri.normalizeIndexStage(ref)) |stage| ref = try a.dupe(u8, &stage);
        if (std.mem.eql(u8, ref, "~")) {
            ref = "HEAD";
            for (state.index_changes) |change| {
                if (std.mem.eql(u8, change.path, relative)) {
                    ref = "";
                    break;
                }
            }
        }
        request.* = .{ .arena = undefined, .io = io, .exe = try a.dupe(u8, exe), .timeout = timeout, .max_file_size = max_file_size, .root = try a.dupe(u8, root), .path = params.path, .relative = relative, .ref = ref, .submodule = params.submoduleOf != null };
        request.arena = arena;
        return request;
    }

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
    repository_scans: std.ArrayList(*RepositoryScan) = .empty,
    pending_repository_scans: std.AutoHashMapUnmanaged(*RepositoryScan, void) = .empty,
    repository_scan_task: dispatch.Task = .{},
    repository_open_worker: ?*worker_mod.EditorWorkerService = null,
    pending_repository_openings: std.ArrayList(*PendingRepositoryOpen) = .empty,
    workspace_binding: ?WorkspaceBinding = null,
    repository_count_key: ?@import("../../../vs/platform/contextkey/common/contextkey.zig").IContextKey = null,
    git_missing_key: ?@import("../../../vs/platform/contextkey/common/contextkey.zig").IContextKey = null,

    pub fn init(allocator: Allocator) Model {
        return .{ .allocator = allocator, .on_did_open_repository = .init(allocator), .on_did_close_repository = .init(allocator) };
    }

    const RepositoryScan = struct {
        model: *Model,
        repository: *Repository,
        notification: ?INotificationService,
        open: *const fn (*anyopaque, []const u8) anyerror!void,
        context: *anyopaque,
        detect_submodules: bool,
        submodule_limit: usize,
        detect_worktrees: bool,
        worktree_limit: usize,
        limit_reached: bool = false,
        listener: ?usize = null,

        fn statusChanged(_: void, self: *RepositoryScan) !void {
            if (self.limit_reached) return;
            const state = self.repository.repository.stateRef();
            if ((!self.detect_submodules or state.submodules.len == 0) and (!self.detect_worktrees or state.is_worktree or state.worktrees.len == 0)) {
                _ = self.model.pending_repository_scans.remove(self);
                if (self.model.pending_repository_scans.count() == 0) self.model.repository_scan_task.schedule(null);
                return;
            }
            try self.model.pending_repository_scans.put(self.model.allocator, self, {});
            self.model.repository_scan_task.schedule(time.milliTimestamp() + 500);
        }

        fn scan(self: *RepositoryScan) !bool {
            const state = self.repository.repository.stateRef();
            const modules = if (self.detect_submodules) state.submodules else &.{};
            const worktrees = if (self.detect_worktrees and !state.is_worktree) state.worktrees else &.{};
            if (modules.len > self.submodule_limit) {
                self.limit_reached = true;
                if (self.notification) |notifications| {
                    const message = try std.fmt.allocPrint(self.model.allocator, "The \"{s}\" repository has {d} submodules which won't be opened automatically. You can still open each one individually by opening a file within.", .{ std.fs.path.basename(self.repository.root), modules.len });
                    defer self.model.allocator.free(message);
                    notifications.warn(.{ .text = message });
                }
            }
            if (worktrees.len > self.worktree_limit) {
                self.limit_reached = true;
                if (self.notification) |notifications| {
                    const message = try std.fmt.allocPrint(self.model.allocator, "The \"{s}\" repository has {d} worktrees which won't be opened automatically. You can still open each one individually by opening a file within.", .{ std.fs.path.basename(self.repository.root), worktrees.len });
                    defer self.model.allocator.free(message);
                    notifications.warn(.{ .text = message });
                }
            }
            if (self.limit_reached) {
                if (self.listener) |id| self.repository.on_did_run_git_status.unlisten(id);
                self.listener = null;
            }
            // Copy paths before opening: opening a nested repository can
            // dispatch status events and change the repository collection.
            var arena = std.heap.ArenaAllocator.init(self.model.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var paths: std.ArrayList([]const u8) = .empty;
            for (modules[0..@min(modules.len, self.submodule_limit)]) |module| {
                const path = try std.fs.path.join(a, &.{ self.repository.root, module.path });
                if (self.model.repositoryForRoot(path) != null) continue;
                try paths.append(a, path);
            }
            for (worktrees[0..@min(worktrees.len, self.worktree_limit)]) |worktree| {
                if (self.model.repositoryForRoot(worktree.path) != null) continue;
                try paths.append(a, try a.dupe(u8, worktree.path));
            }
            const before = self.model.open_repositories.items.len;
            for (paths.items) |path| try self.open(self.context, path);
            return before != self.model.open_repositories.items.len;
        }

        fn dispose(self: *RepositoryScan) void {
            _ = self.model.pending_repository_scans.remove(self);
            if (self.listener) |id| self.repository.on_did_run_git_status.unlisten(id);
            self.model.allocator.destroy(self);
        }
    };

    pub const RepositoryOpenListener = struct {
        context: *anyopaque,
        publish: *const fn (*anyopaque, *RepositoryOpenRequest) anyerror!void,
    };

    pub const WorkspaceHost = struct {
        context: *anyopaque,
        open_repository: *const fn (*anyopaque, []const u8) anyerror!void,
        close_repository: *const fn (*anyopaque, *Repository) void,
    };

    const WorkspaceBinding = struct {
        workspace: *workspace_context.WorkspaceContextService,
        editors: editor_service.IEditorService,
        host: WorkspaceHost,
        listener: @import("../../../vs/base/common/event.zig").SignalSubscription,
    };

    pub fn bindWorkspace(self: *Model, workspace: *workspace_context.WorkspaceContextService, editors: editor_service.IEditorService, host: WorkspaceHost) !void {
        if (self.workspace_binding) |binding| {
            if (binding.workspace == workspace) return;
            binding.listener.dispose();
            self.workspace_binding = null;
        }
        self.workspace_binding = .{
            .workspace = workspace,
            .editors = editors,
            .host = host,
            .listener = try workspace.on_did_change_workspace_folders.listenDisposable(self, onDidChangeWorkspaceFolders),
        };
    }

    fn onDidChangeWorkspaceFolders(change: workspace_context.WorkspaceFoldersChangeEvent, self: *Model) !void {
        const binding = self.workspace_binding orelse return;
        // Preserve repositories still in use by visible text editors (both
        // sides of a diff, including Git virtual documents) or contained by
        // another remaining workspace folder.
        if (change.removed.len > 0) {
            const resources = try binding.editors.getVisibleTextResources(self.allocator);
            defer self.allocator.free(resources);
            var active: std.AutoHashMapUnmanaged(*Repository, void) = .empty;
            defer active.deinit(self.allocator);
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            for (resources) |resource| {
                const path = if (std.mem.eql(u8, resource.scheme, "git")) blk: {
                    const params = @import("uri.zig").fromGitUri(scratch.allocator(), resource) catch continue;
                    break :blk params.path;
                } else try @import("../../../vs/base/common/stdUri.zig").fsPath(resource, scratch.allocator());
                if (self.getRepository(path)) |repository| try active.put(self.allocator, repository, {});
            }
            var to_close: std.AutoHashMapUnmanaged(*Repository, void) = .empty;
            defer to_close.deinit(self.allocator);
            for (change.removed) |folder| {
                self.cancelRepositoryOpen(folder.resource);
                const repository = self.getRepository(folder.resource) orelse continue;
                if (active.contains(repository)) continue;
                var contained = false;
                for (binding.workspace.getWorkspace().folders.items) |remaining| {
                    if (try git_util.isDescendant(self.allocator, remaining.resource, repository.root)) {
                        contained = true;
                        break;
                    }
                }
                if (!contained) try to_close.put(self.allocator, repository, {});
            }
            var iterator = to_close.keyIterator();
            while (iterator.next()) |repository| binding.host.close_repository(binding.host.context, repository.*);
        }
        for (change.added) |folder| {
            if (self.getRepository(folder.resource) == null) try binding.host.open_repository(binding.host.context, folder.resource);
        }
    }

    const PendingRepositoryOpen = struct {
        worker_request: worker_mod.Request = .{ .compute = compute, .reply = reply },
        owner: ?*Model,
        request: *RepositoryOpenRequest,
        listener: RepositoryOpenListener,

        fn compute(message: *worker_mod.Request) void {
            const self: *PendingRepositoryOpen = @fieldParentPtr("worker_request", message);
            self.request.discover() catch {};
        }

        fn reply(message: *worker_mod.Request) bool {
            const self: *PendingRepositoryOpen = @fieldParentPtr("worker_request", message);
            defer {
                self.request.destroy();
                std.heap.page_allocator.destroy(self);
            }
            const owner = self.owner orelse return false;
            owner.removePendingRepositoryOpen(self);
            const before = owner.open_repositories.items.len;
            self.listener.publish(self.listener.context, self.request) catch return false;
            return before != owner.open_repositories.items.len;
        }
    };

    fn removePendingRepositoryOpen(self: *Model, pending: *PendingRepositoryOpen) void {
        pending.owner = null;
        for (self.pending_repository_openings.items, 0..) |candidate, index| {
            if (candidate != pending) continue;
            _ = self.pending_repository_openings.orderedRemove(index);
            return;
        }
    }

    pub fn cancelRepositoryOpen(self: *Model, path: []const u8) void {
        for (self.pending_repository_openings.items) |pending| {
            if (!(git_util.pathEquals(self.allocator, pending.request.path, path) catch false)) continue;
            self.removePendingRepositoryOpen(pending);
            return;
        }
    }

    /// Repository scans use the same immutable discovery/status capture as a
    /// Git virtual-document read, with completion delivered on the window.
    pub fn requestRepositoryOpen(self: *Model, path: []const u8, options: OpenOptions, listener: RepositoryOpenListener) !void {
        if (self.repositoryForRoot(path) != null) return;
        for (self.pending_repository_openings.items) |pending| {
            if (git_util.pathEquals(self.allocator, pending.request.path, path) catch false) return;
        }
        const request = (try self.captureRepositoryOpen(path, options)) orelse return;
        errdefer request.destroy();
        const pending = try std.heap.page_allocator.create(PendingRepositoryOpen);
        errdefer std.heap.page_allocator.destroy(pending);
        pending.* = .{ .owner = self, .request = request, .listener = listener };
        const worker = self.repository_open_worker orelse blk: {
            const created = try self.allocator.create(worker_mod.EditorWorkerService);
            created.* = .init();
            created.attachWindow(options.window);
            self.repository_open_worker = created;
            break :blk created;
        };
        try self.pending_repository_openings.append(self.allocator, pending);
        worker.computeDiff(&pending.worker_request, time.milliTimestamp());
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
        scan_repository: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
        notifications: ?INotificationService = null,
    };

    fn ensureGit(self: *Model, open_options: OpenOptions) !?*Git {
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
                if (std.math.isFinite(megabytes)) {
                    // diffEditor.maxFileSize is a non-negative MB value;
                    // zero means unlimited. Saturate before converting to a
                    // process-output byte limit on the native platform.
                    const bounded = std.math.clamp(megabytes, 0, @as(f64, 1 << 30));
                    options.max_file_size_kb = @intFromFloat(@min(@floor(bounded) * 1024, @as(f64, @floatFromInt(std.math.maxInt(usize) / 1024))));
                }
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
        return cli;
    }

    pub fn openRepository(self: *Model, repo_path: []const u8, open_options: OpenOptions) !?*Repository {
        if (self.repositoryForRoot(repo_path)) |provider| return provider;
        const cli = (try self.ensureGit(open_options)) orelse return null;
        const opened = (cli.openRepository(repo_path) catch null) orelse {
            if (cli.isDisabled()) if (self.git_missing_key) |key| key.set(.{ .boolean = true });
            return null;
        };
        return self.publishOpenedRepository(cli, opened.root_path, open_options);
    }

    pub fn captureRepositoryOpen(self: *Model, path: []const u8, open_options: OpenOptions) !?*RepositoryOpenRequest {
        const cli = (try self.ensureGit(open_options)) orelse return null;
        return try RepositoryOpenRequest.create(cli, path);
    }

    pub fn publishRepositoryOpen(self: *Model, request: *RepositoryOpenRequest, options: OpenOptions) !?*Repository {
        const cli = self.git orelse return null;
        if (request.disabled_reason) |reason| {
            cli.markUnavailable(reason);
            if (self.git_missing_key) |key| key.set(.{ .boolean = true });
            return null;
        }
        const result = request.result orelse return null;
        if (self.repositoryForRoot(result.root)) |provider| return provider;
        _ = try cli.adoptRepository(result.root, result.state);
        return self.publishOpenedRepository(cli, result.root, options);
    }

    fn publishOpenedRepository(self: *Model, cli: *Git, root: []const u8, open_options: OpenOptions) !?*Repository {
        if (self.repositoryForRoot(root)) |provider| return provider;
        const concrete = cli.repositoryForRoot(root) orelse return null;
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

        const provider = try Repository.create(self.allocator, cli, concrete, root, open_options.host);
        errdefer provider.destroy();
        provider.attachWindow(open_options.window);
        if (open_options.host_service) |host| try provider.attachHostService(host);
        try provider.setConfiguration(open_options.configuration);
        try self.open_repositories.append(self.allocator, provider);
        errdefer _ = self.open_repositories.pop();
        try self.attachRepositoryScan(provider, open_options);
        if (self.repository == null) {
            self.repository = provider;
            self.git_root = provider.root;
        }
        self.updateRepositoryCount();
        self.on_did_open_repository.fire(provider) catch {};
        return provider;
    }

    fn attachRepositoryScan(self: *Model, provider: *Repository, options: OpenOptions) !void {
        const open = options.scan_repository orelse return;
        var detect_submodules = true;
        var submodule_limit: usize = 10;
        var detect_worktrees = false;
        var worktree_limit: usize = 50;
        if (options.configuration) |config| {
            if (config.getValue("git.detectSubmodules", .{ .resource = provider.root })) |value| {
                if (value.* == .bool) detect_submodules = value.bool;
            }
            if (config.getValue("git.detectSubmodulesLimit", .{ .resource = provider.root })) |value| {
                if (value.* == .integer) submodule_limit = @intCast(@max(value.integer, 0));
            }
            if (config.getValue("git.detectWorktrees", .{ .resource = provider.root })) |value| {
                if (value.* == .bool) detect_worktrees = value.bool;
            }
            if (config.getValue("git.detectWorktreesLimit", .{ .resource = provider.root })) |value| {
                if (value.* == .integer) worktree_limit = @intCast(@max(value.integer, 0));
            }
        }
        if (!detect_submodules and !detect_worktrees) return;
        if (self.repository_scan_task.queue == null) self.repository_scan_task = .{ .queue = options.window, .context = self, .run = scanRepositories };
        const binding = try self.allocator.create(RepositoryScan);
        binding.* = .{ .model = self, .repository = provider, .notification = options.notifications, .open = open, .context = options.host.context, .detect_submodules = detect_submodules, .submodule_limit = submodule_limit, .detect_worktrees = detect_worktrees, .worktree_limit = worktree_limit };
        errdefer binding.dispose();
        binding.listener = try provider.on_did_run_git_status.listen(binding, RepositoryScan.statusChanged);
        try self.repository_scans.append(self.allocator, binding);
        errdefer _ = self.repository_scans.pop();
        try RepositoryScan.statusChanged({}, binding);
    }

    fn scanRepositories(context: *anyopaque, _: i64, _: bool) bool {
        const self: *Model = @ptrCast(@alignCast(context));
        var pending = self.pending_repository_scans;
        self.pending_repository_scans = .empty;
        defer pending.deinit(self.allocator);
        var iterator = pending.keyIterator();
        var changed = false;
        while (iterator.next()) |binding| {
            changed = (binding.*.scan() catch false) or changed;
        }
        return changed;
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
            for (self.repository_scans.items, 0..) |binding, i| {
                if (binding.repository != provider) continue;
                _ = self.repository_scans.orderedRemove(i);
                binding.dispose();
                break;
            }
            if (self.repository == provider) {
                self.repository = if (self.open_repositories.items.len > 0) self.open_repositories.items[0] else null;
                self.git_root = if (self.repository) |selected| selected.root else null;
            }
            self.updateRepositoryCount();
            self.on_did_close_repository.fire(provider) catch {};
            const concrete = provider.repository;
            provider.destroy();
            if (self.git) |cli| cli.removeRepository(concrete);
            return;
        }
    }

    pub fn repositories(self: *const Model) []const *Repository {
        return self.open_repositories.items;
    }

    pub fn setActiveRepository(self: *Model, id: ?[]const u8) void {
        self.repository = null;
        if (id) |provider_id| {
            for (self.open_repositories.items) |provider| {
                if (std.mem.eql(u8, provider.id, provider_id)) {
                    self.repository = provider;
                    break;
                }
            }
        }
        self.git_root = if (self.repository) |provider| provider.root else null;
    }

    pub fn repositoryForRoot(self: *const Model, path: []const u8) ?*Repository {
        for (self.open_repositories.items) |provider| {
            if (git_util.pathEquals(self.allocator, path, provider.root) catch false) return provider;
        }
        return null;
    }

    /// Upstream getOpenRepository prefers the most deeply nested open root.
    /// A relative path is only meaningful for the existing selected view.
    pub fn getRepository(self: *const Model, path: []const u8) ?*Repository {
        if (!std.fs.path.isAbsolute(path)) return self.repository;
        var result: ?*Repository = null;
        for (self.open_repositories.items) |provider| {
            if (!(git_util.pathEquals(self.allocator, path, provider.root) catch false) and !(git_util.isDescendant(self.allocator, provider.root, path) catch false)) continue;
            if (provider.containsSubmodule(path)) continue;
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
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const params = try @import("uri.zig").fromGitUri(scratch.allocator(), uri);
        const repository = (if (params.submoduleOf) |parent| self.repositoryForRoot(parent) else self.getRepository(params.path)) orelse return error.NoRepository;
        return GitResourceRead.create(io, cli.exe, cli.timeout, cli.max_file_size, repository.root, repository.repository.stateRef(), uri);
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
        if (self.workspace_binding) |binding| binding.listener.dispose();
        if (self.repository_count_key) |key| key.reset();
        if (self.git_missing_key) |key| key.reset();
        self.repository_scan_task.schedule(null);
        for (self.pending_repository_openings.items) |pending| pending.owner = null;
        self.pending_repository_openings.deinit(self.allocator);
        if (self.repository_open_worker) |worker| {
            worker.deinit();
            self.allocator.destroy(worker);
        }
        for (self.repository_scans.items) |binding| binding.dispose();
        self.repository_scans.deinit(self.allocator);
        self.pending_repository_scans.deinit(self.allocator);
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
