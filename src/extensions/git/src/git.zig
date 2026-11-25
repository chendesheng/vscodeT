// Port of `vscode/extensions/git/src/git.ts` (terminal CLI host).
//
// This is the terminal host replacement for the `Git` class of the `vscode.git`
// extension and for the `IGitExtensionDelegate` proxy that normally sits in
// `src/vs/workbench/api/browser/mainThreadGitExtensionService.ts`. The terminal
// workbench has no extension host and therefore no SCM actor to proxy git
// operations through, so spawning/parsing and the delegate implementation
// collapse into this file. Git is driven directly through its command line:
//
// - every invocation is an argv array (never a shell),
// - the repository root is passed as an explicit `cwd`,
// - stdout/stderr are piped and bounded,
// - every spawn has a deadline (`std.Io.Timeout`) so the UI thread cannot block
//   forever on a hung git process.
//
// The read-only diff plan only needs `openRepository`, `status` and `readRef`.
// `getRefs`, `diffBetweenWithStats`, `diffBetweenWithStats2` and `commitFiles`
// are implemented with real git commands so the delegate is not a stub, but
// `commitFiles` is outside the read-only plan and is not exercised by the TUI.
//
// Adaptation notes:
// - Resources are local paths instead of `URI` (see the common git service).
// - `IGitRepositoryState` owns its strings; `GitRepository.updateState` clones
//   them into the repository arena.
// - `Git.Cache` keeps blob contents keyed by `<root>\x00<ref>\x00<path>`.
//   The key is logically `<ref>:<path>`, scoped by root so that two open
//   repositories with the same relative path never collide.
// - A missing git binary or `git.enabled=false` disables the provider and is
//   reported once through `Options.on_disabled`. A path that is not inside a
//   repository is not a hard disable: `discover` returns null so another
//   workspace folder can still be opened.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const git_common = @import("../../../vs/workbench/contrib/git/common/gitService.zig");
const git_browser = @import("../../../vs/workbench/contrib/git/browser/gitService.zig");

pub const GitRepositoryState = git_common.GitRepositoryState;
pub const GitChange = git_common.GitChange;
pub const GitDiffChange = git_common.GitDiffChange;
pub const GitBranch = git_common.GitBranch;
pub const GitRef = git_common.GitRef;
pub const GitRefType = git_common.GitRefType;
pub const GitRefQuery = git_common.GitRefQuery;
pub const GitUpstreamRef = git_common.GitUpstreamRef;
pub const GitCommitOptions = git_common.GitCommitOptions;
pub const freeGitCommits = git_common.freeGitCommits;
pub const GitCommit = git_common.GitCommit;
pub const GitCommitShortStat = git_common.GitCommitShortStat;
pub const GitLogOptions = git_common.GitLogOptions;
pub const GitDiffShortStat = git_common.GitCommitShortStat;

/// `git log` record format from the upstream extension.
const commit_format = "%H%n%aN%n%aE%n%at%n%ct%n%P%n%D%n%B";
pub const CancellationToken = git_common.CancellationToken;
pub const IGitRepository = git_common.IGitRepository;
pub const IGitExtensionDelegate = git_common.IGitExtensionDelegate;

/// The status entry cap from `docs/git-diff-plan.md` §5.2. Records after the
/// cap are parsed (so the byte stream stays in sync for renames) but not added
/// to the state.
pub const max_status_entries: usize = 10_000;

/// Upper bound for a `git status --porcelain=v2 -z --branch -uall` capture.
/// 10k entries with long paths stay well below this.
const status_output_limit: usize = 64 * 1024 * 1024;
const discovery_output_limit: usize = 64 * 1024;
const get_refs_output_limit: usize = 16 * 1024 * 1024;
const diff_output_limit: usize = 64 * 1024 * 1024;
const log_output_limit: usize = 32 * 1024 * 1024;
const merge_base_output_limit: usize = 64 * 1024;

const GitVersion = struct { major: usize, minor: usize };
const stderr_limit: usize = 64 * 1024;

/// A revision that `readRef` can materialize.
pub const RefKind = enum {
    head,
    index,
    working,

    pub fn cacheName(self: RefKind) []const u8 {
        return switch (self) {
            .head => "HEAD",
            .index => "index",
            .working => "working",
        };
    }
};

pub const Options = struct {
    /// `git.path` override. When null the executable is looked up on `PATH`
    /// by the spawn implementation (`argv[0] == "git"`).
    git_path: ?[]const u8 = null,
    /// `git.enabled` gate. When false the provider is disabled immediately.
    enabled: bool = true,
    /// `diffEditor.maxFileSize` equivalent, in KiB. Oversized blobs are
    /// skipped by `readRef`.
    max_file_size_kb: usize = 50 * 1024,
    /// Deadline for every git invocation, in milliseconds.
    timeout_ms: i64 = 5000,
    /// Host I/O implementation. The workbench should pass its own. When null a
    /// dedicated `std.Io.Threaded` is created (and destroyed by `deinit`).
    io: ?std.Io = null,
    /// Environment used for the dedicated `std.Io.Threaded` (and therefore for
    /// PATH lookup and the child environment). Ignored when `io` is provided.
    /// `std.process.Init.Minimal.environ` can be passed here by `main`.
    environ: std.process.Environ = .empty,
    /// Called at most once for a hard disable and at most once when a scan
    /// finds a directory that is not a git repository.
    on_disabled: ?*const fn (context: ?*anyopaque, reason: []const u8) void = null,
    on_disabled_context: ?*anyopaque = null,
};

/// Owned blob cache. Keys and values are owned by the cache; `get` returns a
/// borrowed slice valid until the next `invalidate`/`deinit`.
pub const Cache = struct {
    allocator: Allocator,
    map: std.StringHashMap([]u8),

    pub fn init(allocator: Allocator) Cache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        self.invalidate();
        self.map.deinit();
    }

    pub fn get(self: *const Cache, key: []const u8) ?[]u8 {
        return self.map.get(key);
    }

    /// Takes ownership of `key` and `value` on success. On failure the caller
    /// still owns both slices.
    pub fn put(self: *Cache, key: []u8, value: []u8) Allocator.Error!void {
        if (self.map.getEntry(key)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
            entry.key_ptr.* = key;
            entry.value_ptr.* = value;
            return;
        }
        try self.map.put(key, value);
    }

    pub fn invalidate(self: *Cache) void {
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.clearRetainingCapacity();
    }
};

const RunFailure = error{
    NoGit,
    GitFailed,
    Timeout,
    OutputTooLarge,
} || Allocator.Error;

/// Terminal command-line git adapter. One instance owns the repository list,
/// the delegate vtable and the blob cache.
pub const Git = struct {
    allocator: Allocator,
    exe: []u8,
    io: std.Io,
    /// Only initialized when `owns_io` is true.
    threaded: std.Io.Threaded,
    owns_io: bool,
    timeout: std.Io.Timeout,
    max_file_size: usize,

    cache: Cache,
    repo_list: std.array_list.Managed(*git_browser.GitRepository),
    repository_interfaces: std.array_list.Managed(IGitRepository),
    delegate_interface: IGitExtensionDelegate,

    disabled: bool = false,
    disabled_reason: ?[]const u8 = null,
    disabled_reported: bool = false,
    no_repo_reported: bool = false,
    on_disabled: ?*const fn (context: ?*anyopaque, reason: []const u8) void = null,
    on_disabled_context: ?*anyopaque = null,
    /// Cached `git --version`, probed lazily before options such as
    /// `--diff-merges=first-parent` are used.
    git_version: ?GitVersion = null,

    pub fn init(allocator: Allocator, options: Options) !*Git {
        const self = try allocator.create(Git);
        errdefer allocator.destroy(self);

        const exe = if (options.git_path) |path| blk: {
            if (path.len == 0) break :blk try allocator.dupe(u8, "git");
            break :blk try allocator.dupe(u8, path);
        } else try allocator.dupe(u8, "git");
        errdefer allocator.free(exe);

        var threaded: std.Io.Threaded = undefined;
        var io: std.Io = undefined;
        var owns_io = false;
        if (options.io) |provided| {
            io = provided;
        } else {
            threaded = std.Io.Threaded.init(allocator, .{ .environ = options.environ });
            io = threaded.io();
            owns_io = true;
        }

        const max_file_size = if (options.max_file_size_kb > std.math.maxInt(usize) / 1024)
            std.math.maxInt(usize)
        else
            options.max_file_size_kb * 1024;

        self.* = .{
            .allocator = allocator,
            .exe = exe,
            .io = io,
            .threaded = threaded,
            .owns_io = owns_io,
            .timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(if (options.timeout_ms > 0) options.timeout_ms else 5000),
                .clock = .awake,
            } },
            .max_file_size = max_file_size,
            .cache = Cache.init(allocator),
            .repo_list = std.array_list.Managed(*git_browser.GitRepository).init(allocator),
            .repository_interfaces = std.array_list.Managed(IGitRepository).init(allocator),
            .delegate_interface = undefined,
            .on_disabled = options.on_disabled,
            .on_disabled_context = options.on_disabled_context,
        };

        self.delegate_interface = .{
            .context = self,
            .repositories_fn = repositoriesThunk,
            .open_repository_fn = openRepositoryThunk,
            .get_refs_fn = getRefsThunk,
            .diff_between_with_stats_fn = diffBetweenWithStatsThunk,
            .diff_between_with_stats2_fn = diffBetweenWithStats2Thunk,
            .commit_files_fn = commitFilesThunk,
            .log_fn = logThunk,
            .diff_root_commit_fn = diffRootCommitThunk,
            .merge_base_fn = mergeBaseThunk,
            .get_branch_fn = getBranchThunk,
            .get_branch_base_fn = getBranchBaseThunk,
            .read_ref_at_fn = readRefAtThunk,
            .has_git_version_at_least_fn = hasGitVersionAtLeastThunk,
        };

        if (!options.enabled) self.disable("git.enabled is false");
        return self;
    }

    pub fn deinit(self: *Git) void {
        for (self.repo_list.items) |repository| repository.destroy();
        self.repo_list.deinit();
        self.repository_interfaces.deinit();
        self.cache.deinit();
        if (self.owns_io) self.threaded.deinit();
        self.allocator.free(self.exe);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn interface(self: *Git) IGitExtensionDelegate {
        return self.delegate_interface;
    }

    /// Borrowed slice; invalidated by the next successful `openRepository`.
    pub fn repositories(self: *const Git) []const IGitRepository {
        return self.repository_interfaces.items;
    }

    /// The concrete repository for `root`, if it was opened through this
    /// delegate. Used by the TUI SCM provider to refresh status through
    /// `GitRepository.updateState`.
    pub fn repositoryForRoot(self: *Git, root: []const u8) ?*git_browser.GitRepository {
        return self.findRepository(root);
    }

    pub fn isDisabled(self: *const Git) bool {
        return self.disabled;
    }

    pub fn disabledReason(self: *const Git) ?[]const u8 {
        return self.disabled_reason;
    }

    fn disable(self: *Git, reason: []const u8) void {
        self.disabled = true;
        self.disabled_reason = reason;
        if (self.disabled_reported) return;
        self.disabled_reported = true;
        if (self.on_disabled) |callback| callback(self.on_disabled_context, reason);
    }

    fn reportNoRepository(self: *Git) void {
        if (self.no_repo_reported) return;
        self.no_repo_reported = true;
        if (self.on_disabled) |callback| callback(self.on_disabled_context, "not a git repository");
    }

    fn directoryExists(self: *const Git, path: []const u8) bool {
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }

    /// Runs git with an explicit cwd, argv-only command line, piped and
    /// bounded stdout/stderr, and the configured deadline. `stdin` is always
    /// ignored by `std.process.run`.
    fn run(
        self: *Git,
        argv: []const []const u8,
        cwd: []const u8,
        stdout_limit: usize,
    ) RunFailure!std.process.RunResult {
        if (self.disabled) return error.NoGit;
        return std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdout_limit = .limited(stdout_limit),
            .stderr_limit = .limited(stderr_limit),
            .timeout = self.timeout,
            .reserve_amount = 4096,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                self.disable("git executable not found");
                return error.NoGit;
            },
            error.AccessDenied, error.PermissionDenied => {
                self.disable("git executable is not accessible");
                return error.NoGit;
            },
            error.Timeout => return error.Timeout,
            error.StreamTooLong => return error.OutputTooLarge,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.GitFailed,
        };
    }

    fn runRevParse(self: *Git, start: []const u8, argument: []const u8, stdout_limit: usize) !?[]u8 {
        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.appendSlice(&.{ self.exe, "-C", start, "rev-parse", argument });

        var result = self.run(argv.items, start, stdout_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);
        if (!result.term.success()) return null;

        const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
        if (trimmed.len == 0) return null;
        return try self.allocator.dupe(u8, trimmed);
    }

    pub const DotGit = struct {
        path: []u8,
        common_path: []u8,

        pub fn deinit(self: DotGit, allocator: Allocator) void {
            allocator.free(self.path);
            allocator.free(self.common_path);
        }
    };

    pub fn getRepositoryDotGit(self: *Git, root: []const u8) !DotGit {
        var result = try self.run(&.{ self.exe, "rev-parse", "--git-dir", "--git-common-dir" }, root, discovery_output_limit);
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);
        if (!result.term.success()) return error.NoGit;
        var paths = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
        const path = try std.fs.path.resolveAlloc(self.allocator, &.{ root, paths.next() orelse return error.NoGit });
        errdefer self.allocator.free(path);
        return .{ .path = path, .common_path = try std.fs.path.resolveAlloc(self.allocator, &.{ root, paths.next() orelse return error.NoGit }) };
    }

    /// Resolves `start` to the absolute repository root, or null when git is
    /// unavailable / `start` is not inside a repository. Never panics.
    pub fn discover(self: *Git, start: []const u8) !?[]u8 {
        if (self.disabled) return null;
        std.Io.Dir.cwd().access(self.io, start, .{}) catch return null;

        if (try self.runRevParse(start, "--show-toplevel", discovery_output_limit)) |top| {
            defer self.allocator.free(top);
            const root = try self.absoluteRoot(start, top);
            return normalizeRoot(root, builtin.os.tag == .windows);
        }

        if (try self.runRevParse(start, "--git-common-dir", discovery_output_limit)) |common| {
            defer self.allocator.free(common);
            const root = try self.rootFromCommonDir(start, common);
            return normalizeRoot(root, builtin.os.tag == .windows);
        }

        if (!self.disabled) self.reportNoRepository();
        return null;
    }

    /// Compares cached repository roots with a caller's spelling. Windows
    /// treats `/` and `\` as interchangeable separators, so a workspace folder
    /// passed as `C:/repo` still finds the repository discovered as `C:\repo`.
    fn equalRoots(left: []const u8, right: []const u8, comptime windows: bool) bool {
        if (!windows) return std.mem.eql(u8, left, right);
        if (left.len != right.len) return false;
        for (left, right) |left_byte, right_byte| {
            if (left_byte == right_byte) continue;
            const left_sep = left_byte == '/' or left_byte == '\\';
            const right_sep = right_byte == '/' or right_byte == '\\';
            if (!left_sep or !right_sep) return false;
        }
        return true;
    }

    /// Git for Windows prints repository roots with forward slashes, while the
    /// caller spelled the workspace folder with native separators. Normalize
    /// before the root is cached or compared with `repositoryForRoot`/`discover`
    /// results. `/` is only a separator on Windows; it is a legal filename byte
    /// elsewhere.
    fn normalizeRoot(root: []u8, comptime windows: bool) []u8 {
        if (windows) {
            for (root) |*byte| {
                if (byte.* == '/') byte.* = '\\';
            }
        }
        return root;
    }

    fn absoluteRoot(self: *Git, start: []const u8, raw: []const u8) ![]u8 {
        const trimmed = std.mem.trimEnd(u8, raw, "\r\n");
        if (std.fs.path.isAbsolute(trimmed)) return self.allocator.dupe(u8, trimmed);
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.allocator);
        defer self.allocator.free(cwd);
        return std.fs.path.resolveAlloc(self.allocator, &.{ cwd, start, trimmed });
    }

    fn rootFromCommonDir(self: *Git, start: []const u8, raw: []const u8) ![]u8 {
        const trimmed = std.mem.trimEnd(u8, raw, "\r\n");
        if (trimmed.len == 0) return error.GitFailed;

        const absolute = if (std.fs.path.isAbsolute(trimmed))
            try self.allocator.dupe(u8, trimmed)
        else blk: {
            const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.allocator);
            defer self.allocator.free(cwd);
            break :blk try std.fs.path.resolveAlloc(self.allocator, &.{ cwd, start, trimmed });
        };
        defer self.allocator.free(absolute);

        if (std.mem.eql(u8, std.fs.path.basename(absolute), ".git")) {
            if (std.fs.path.dirname(absolute)) |parent| {
                return self.allocator.dupe(u8, parent);
            }
        }
        return self.allocator.dupe(u8, absolute);
    }

    /// Reads the repository status. The returned state owns every string;
    /// callers free it with `state.deinit(allocator)`. This also invalidates
    /// the blob cache, as required by the quick-diff refresh path.
    pub fn status(self: *Git, root: []const u8) !GitRepositoryState {
        if (self.disabled) return error.NoGit;
        if (!self.directoryExists(root)) return error.NoGit;
        self.invalidate();

        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.appendSlice(&.{
            self.exe,
            "-c",
            "core.quotepath=false",
            "--no-optional-locks",
            "status",
            "--porcelain=v2",
            "-z",
            "--branch",
            "-uall",
        });

        var result = self.run(argv.items, root, status_output_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => return error.Timeout,
            error.NoGit => return error.NoGit,
            error.OutputTooLarge, error.GitFailed => return error.GitFailed,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (!result.term.success()) {
            if (isNotARepository(result.stderr)) {
                self.reportNoRepository();
                return error.NoGit;
            }
            return error.GitFailed;
        }

        return parseStatus(self.allocator, result.stdout);
    }

    /// Recomputes the status for `repository` and installs it through
    /// `GitRepository.updateState`, then frees the temporary state.
    pub fn refresh(self: *Git, repository: *git_browser.GitRepository) !void {
        var state = try self.status(repository.rootPath());
        defer state.deinit(self.allocator);
        try repository.updateState(state);
    }

    /// Reads `path` at `ref`. Returns owned bytes, or null for missing blobs,
    /// deleted files, binary (NUL-containing or invalid UTF-8) content,
    /// oversized blobs and pathological paths. Git failures are reported as
    /// null so a diff request can degrade to an empty side; only allocation
    /// failures propagate.
    pub fn readRef(self: *Git, root: []const u8, path: []const u8, ref: RefKind) !?[]u8 {
        if (!isSafeRelativePath(path)) return null;
        return switch (ref) {
            .head => self.readGitBlob(root, "HEAD", path),
            .index => self.readGitBlob(root, "index", path),
            .working => self.readWorkingFile(root, path),
        };
    }

    fn blobOutputLimit(self: *const Git) usize {
        if (self.max_file_size == std.math.maxInt(usize)) return std.math.maxInt(usize);
        return self.max_file_size + 1;
    }

    fn readGitBlob(self: *Git, root: []const u8, which: []const u8, path: []const u8) !?[]u8 {
        if (!self.directoryExists(root)) return null;
        const revision = if (std.mem.eql(u8, which, "HEAD"))
            try std.fmt.allocPrint(self.allocator, "HEAD:{s}", .{path})
        else if (std.mem.eql(u8, which, "index"))
            try std.fmt.allocPrint(self.allocator, ":{s}", .{path})
        else
            try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ which, path });
        defer self.allocator.free(revision);

        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.appendSlice(&.{ self.exe, "show", "--textconv", revision });

        var result = self.run(argv.items, root, self.blobOutputLimit()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);
        if (!result.term.success()) return null;

        return try ownTextBlob(self.allocator, result.stdout, self.max_file_size);
    }

    fn readWorkingFile(self: *Git, root: []const u8, path: []const u8) !?[]u8 {
        const full_path = std.fs.path.join(self.allocator, &.{ root, path }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer self.allocator.free(full_path);

        const limit = if (self.max_file_size == std.math.maxInt(usize))
            std.Io.Limit.unlimited
        else
            std.Io.Limit.limited(self.max_file_size + 1);

        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, full_path, self.allocator, limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        if (bytes.len > self.max_file_size) {
            self.allocator.free(bytes);
            return null;
        }
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) {
            self.allocator.free(bytes);
            return null;
        }
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            self.allocator.free(bytes);
            return null;
        }
        return bytes;
    }

    /// Cache-aware `readRef`. The returned slice is borrowed from the blob
    /// cache and stays valid until `invalidate` (status refresh) or `deinit`.
    /// Callers must not free it.
    pub fn readRefCached(self: *Git, root: []const u8, path: []const u8, ref: RefKind) !?[]u8 {
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}\x00{s}", .{ root, ref.cacheName(), path });
        defer self.allocator.free(key);
        if (self.cache.get(key)) |cached| return cached;

        const value = try self.readRef(root, path, ref) orelse return null;
        errdefer self.allocator.free(value);

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.cache.put(owned_key, value);
        return value;
    }

    /// Drops every cached blob. Called by every status refresh.
    pub fn invalidate(self: *Git) void {
        self.cache.invalidate();
    }

    /// Discovers the repository for `path` and returns a fresh, reusable
    /// repository interface. Returns null when disabled or outside a
    /// repository.
    pub fn openRepository(self: *Git, path: []const u8) !?IGitRepository {
        if (self.disabled) return null;
        const root = try self.discover(path) orelse return null;
        defer self.allocator.free(root);

        if (self.findRepository(root)) |existing| {
            self.refresh(existing) catch |err| switch (err) {
                error.NoGit => return null,
                else => return err,
            };
            return existing.interface();
        }

        var state = self.status(root) catch |err| switch (err) {
            error.NoGit => return null,
            else => return err,
        };
        defer state.deinit(self.allocator);

        const repository = try git_browser.GitRepository.create(self.allocator, root, state, &self.delegate_interface);
        errdefer repository.destroy();

        try self.repo_list.append(repository);
        errdefer _ = self.repo_list.pop();

        try self.repository_interfaces.append(repository.interface());
        return repository.interface();
    }

    fn findRepository(self: *Git, root: []const u8) ?*git_browser.GitRepository {
        for (self.repo_list.items) |repository| {
            if (equalRoots(repository.rootPath(), root, builtin.os.tag == .windows)) return repository;
        }
        return null;
    }

    /// `git for-each-ref`. Returned refs are owned by `allocator`; the caller
    /// owns each name/commit/remote string and the slice.
    pub fn getRefs(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        query: GitRefQuery,
        token: CancellationToken,
    ) ![]GitRef {
        if (token.isCancellationRequested()) return error.CancellationError;
        if (self.disabled) return error.NoGit;
        if (!self.directoryExists(root)) return error.NoGit;

        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();

        var owned_args = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (owned_args.items) |argument| self.allocator.free(argument);
            owned_args.deinit();
        }

        try argv.appendSlice(&.{ self.exe, "for-each-ref", "--format=%(refname)%00%(objectname)%00%(*objectname)" });

        if (query.count) |count| {
            try owned_args.ensureUnusedCapacity(1);
            const argument = try std.fmt.allocPrint(self.allocator, "--count={d}", .{count});
            owned_args.appendAssumeCapacity(argument);
            try argv.append(argument);
        }

        if (query.sort) |sort| {
            const sort_argument: ?[]const u8 = switch (sort) {
                .alphabetically => null,
                .committerdate => "-committerdate",
                .creatordate => "-creatordate",
            };
            if (sort_argument) |argument| {
                try argv.append("--sort");
                try argv.append(argument);
            }
        }

        if (query.pattern) |pattern| {
            if (pattern.len > 0 and !std.mem.startsWith(u8, pattern, "refs/")) {
                try owned_args.ensureUnusedCapacity(1);
                const argument = try std.fmt.allocPrint(self.allocator, "refs/{s}", .{pattern});
                owned_args.appendAssumeCapacity(argument);
                try argv.append(argument);
            } else if (pattern.len > 0) {
                try argv.append(pattern);
            }
        }

        if (query.contains) |contains| {
            try argv.append("--contains");
            try argv.append(contains);
        }

        var result = self.run(argv.items, root, get_refs_output_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => return error.Timeout,
            error.NoGit => return error.NoGit,
            error.OutputTooLarge, error.GitFailed => return error.GitFailed,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (!result.term.success()) return error.GitFailed;
        if (token.isCancellationRequested()) return error.CancellationError;

        var refs = try parseRefs(allocator, result.stdout);
        errdefer {
            freeRefs(allocator, refs);
            allocator.free(refs);
        }
        if (query.count) |count| {
            if (refs.len > count) {
                const truncated = try allocator.alloc(GitRef, count);
                @memcpy(truncated, refs[0..count]);
                for (refs[count..]) |ref| freeRef(allocator, ref);
                allocator.free(refs);
                refs = truncated;
            }
        }
        return refs;
    }

    /// `git diff --numstat` between two refs (three-dot, like the upstream
    /// repository). Result strings are owned by `allocator`.
    pub fn diffBetweenWithStats(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        ref1: []const u8,
        ref2: []const u8,
        path: ?[]const u8,
    ) ![]GitDiffChange {
        const refspec = try std.fmt.allocPrint(allocator, "{s}...{s}", .{ ref1, ref2 });
        defer allocator.free(refspec);
        return self.diffNumStat(allocator, root, refspec, path);
    }

    /// `git diff --numstat <ref>` (working tree against `ref`).
    pub fn diffBetweenWithStats2(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        ref: []const u8,
        path: ?[]const u8,
    ) ![]GitDiffChange {
        return self.diffNumStat(allocator, root, ref, path);
    }

    fn diffNumStat(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        refspec: []const u8,
        path: ?[]const u8,
    ) ![]GitDiffChange {
        if (self.disabled) return error.NoGit;
        if (!self.directoryExists(root)) return error.NoGit;
        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.appendSlice(&.{ self.exe, "diff", "--raw", "--numstat", "--diff-filter=ADMR", "--find-renames=50%", "-z", refspec });
        if (path) |p| {
            try argv.append("--");
            try argv.append(p);
        }

        var result = self.run(argv.items, root, diff_output_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => return error.Timeout,
            error.NoGit => return error.NoGit,
            error.OutputTooLarge, error.GitFailed => return error.GitFailed,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (!result.term.success()) return error.GitFailed;
        return parseGitChangesRaw(allocator, result.stdout);
    }

    /// Stages `files` (including deleted paths) and commits the index. This is
    /// outside the read-only plan; it is implemented so the delegate contract
    /// is real rather than a stub. A commit with nothing staged resolves
    /// without an error, mirroring upstream.
    pub fn commitFiles(
        self: *Git,
        root: []const u8,
        files: []const []const u8,
        message: []const u8,
        options: GitCommitOptions,
    ) !void {
        if (self.disabled) return error.NoGit;
        if (!self.directoryExists(root)) return error.NoGit;
        if (std.mem.indexOfScalar(u8, message, 0) != null) return error.InvalidPath;
        for (files) |file| {
            if (std.mem.indexOfScalar(u8, file, 0) != null) return error.InvalidPath;
        }

        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();

        if (files.len > 0) {
            try self.runResourceAction(root, .stage, files);
        }

        try argv.appendSlice(&.{ self.exe, "commit" });
        if (options.amend) try argv.append("--amend");
        if (options.amend and message.len == 0) {
            try argv.append("--no-edit");
        } else {
            try argv.appendSlice(&.{ "-m", message });
        }
        if (options.no_verify orelse false) try argv.append("--no-verify");
        if (options.sign_commit) |sign| {
            if (sign) try argv.append("-S") else try argv.append("--no-gpg-sign");
        }

        var commit_result = try self.run(argv.items, root, status_output_limit);
        defer self.allocator.free(commit_result.stdout);
        defer self.allocator.free(commit_result.stderr);
        if (!commit_result.term.success()) {
            if (isNothingToCommit(commit_result.stderr)) return;
            return error.GitFailed;
        }
    }

    pub const ResourceAction = enum { stage, unstage, unstage_unborn, restore };

    pub fn runResourceAction(self: *Git, root: []const u8, action: ResourceAction, files: []const []const u8) !void {
        if (files.len == 0) return;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{ self.exe, "--literal-pathspecs" });
        try argv.appendSlice(self.allocator, switch (action) {
            .stage => &.{ "add", "-A", "--" },
            .unstage => &.{ "restore", "--staged", "--" },
            .unstage_unborn => &.{ "rm", "--cached", "-f", "--ignore-unmatch", "--" },
            .restore => &.{ "restore", "--worktree", "--" },
        });
        for (files) |file| {
            if (file.len == 0 or std.mem.indexOfScalar(u8, file, 0) != null) return error.InvalidPath;
        }
        try argv.appendSlice(self.allocator, files);
        const result = try self.run(argv.items, root, status_output_limit);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (!result.term.success()) return error.GitFailed;
    }

    pub const RemoteAction = enum { fetch, pull, push, publish };

    pub fn runRemoteAction(self: *Git, root: []const u8, action: RemoteAction, remote: ?[]const u8) !void {
        const args: []const []const u8 = switch (action) {
            .fetch => &.{ self.exe, "fetch", "--all" },
            .pull => &.{ self.exe, "pull" },
            .push => &.{ self.exe, "push" },
            .publish => &.{ self.exe, "push", "--set-upstream", "--", remote orelse return error.NoRemote, "HEAD" },
        };
        const result = try self.run(args, root, status_output_limit);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (!result.term.success()) return error.GitFailed;
    }

    /// `git log` with the upstream extension's record format. Returns an owned
    /// (possibly empty) array; a non-zero exit code is an empty/unborn history,
    /// matching the extension.
    pub fn log(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        options: GitLogOptions,
        token: CancellationToken,
    ) ![]GitCommit {
        if (token.isCancellationRequested()) return error.CancellationError;
        if (self.disabled) return error.NoGit;
        if (!self.directoryExists(root)) return error.NoGit;
        if (!options.all_refs) {
            if (options.ref_names) |ref_names| {
                if (ref_names.len == 0) return allocator.alloc(GitCommit, 0);
            }
        }

        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        var owned_args = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (owned_args.items) |argument| self.allocator.free(argument);
            owned_args.deinit();
        }

        try argv.appendSlice(&.{ self.exe, "-c", "i18n.logOutputEncoding=UTF-8", "log", "--format=" ++ commit_format, "-z" });
        if (options.short_stats) {
            try argv.append("--shortstat");
            if (self.hasGitVersionAtLeast(2, 31)) try argv.append("--diff-merges=first-parent");
        }
        if (options.range) |range| {
            try argv.append(range);
        } else {
            const limit = options.max_entries orelse 32;
            const argument = try std.fmt.allocPrint(self.allocator, "-n{d}", .{limit});
            try owned_args.append(argument);
            try argv.append(argument);
        }
        if (options.author) |author| {
            const argument = try std.fmt.allocPrint(self.allocator, "--author={s}", .{author});
            try owned_args.append(argument);
            try argv.append(argument);
        }
        if (options.grep) |grep| {
            const argument = try std.fmt.allocPrint(self.allocator, "--grep={s}", .{grep});
            try owned_args.append(argument);
            try argv.append(argument);
            try argv.append("--extended-regexp");
            try argv.append("--regexp-ignore-case");
        }
        if (options.max_parents) |max_parents| {
            const argument = try std.fmt.allocPrint(self.allocator, "--max-parents={d}", .{max_parents});
            try owned_args.append(argument);
            try argv.append(argument);
        }
        if (options.skip) |skip| {
            const argument = try std.fmt.allocPrint(self.allocator, "--skip={d}", .{skip});
            try owned_args.append(argument);
            try argv.append(argument);
        }
        if (options.all_refs) {
            try argv.append("--topo-order");
            try argv.append("--decorate=full");
            try argv.append("--all");
        } else if (options.ref_names) |ref_names| {
            try argv.append("--topo-order");
            try argv.append("--decorate=full");
            try argv.appendSlice(ref_names);
        }

        var result = self.run(argv.items, root, log_output_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => return error.Timeout,
            error.NoGit => return error.NoGit,
            error.OutputTooLarge, error.GitFailed => return error.GitFailed,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (!result.term.success()) return allocator.alloc(GitCommit, 0);
        if (token.isCancellationRequested()) return error.CancellationError;
        return parseGitCommits(allocator, result.stdout);
    }

    /// `git diff-tree --root` for a root commit; the terminal substitute for
    /// the upstream empty-tree diff.
    pub fn diffRootCommit(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        commit: []const u8,
    ) ![]GitDiffChange {
        if (self.disabled) return error.NoGit;
        if (!self.directoryExists(root)) return error.NoGit;
        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.appendSlice(&.{
            self.exe,
            "diff-tree",
            "--root",
            "--no-commit-id",
            "-r",
            "--raw",
            "--numstat",
            "--diff-filter=ADMR",
            "--find-renames=50%",
            "-z",
            commit,
            "--",
        });
        var result = self.run(argv.items, root, diff_output_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => return error.Timeout,
            error.NoGit => return error.NoGit,
            error.OutputTooLarge, error.GitFailed => return error.GitFailed,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (!result.term.success()) return allocator.alloc(GitDiffChange, 0);
        return parseGitChangesRaw(allocator, result.stdout);
    }

    /// `git merge-base <refs...>`; null when the refs have no common ancestor.
    pub fn mergeBase(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        refs: []const []const u8,
    ) !?[]u8 {
        if (refs.len == 0) return null;
        if (self.disabled) return error.NoGit;
        if (!self.directoryExists(root)) return error.NoGit;
        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.append(self.exe);
        try argv.append("merge-base");
        try argv.appendSlice(refs);
        var result = self.run(argv.items, root, merge_base_output_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout, error.NoGit, error.OutputTooLarge, error.GitFailed => return null,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (!result.term.success()) return null;
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    }

    /// `git for-each-ref` for a single branch (local or remote), including its
    /// upstream details. Returns an owned `GitBranch` or null.
    pub fn getBranch(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        name: []const u8,
    ) !?GitBranch {
        if (self.disabled) return error.NoGit;
        if (!self.directoryExists(root)) return error.NoGit;
        if (name.len == 0 or name.len > 1024) return null;
        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.appendSlice(&.{
            self.exe,
            "for-each-ref",
            "--format=%(refname)%00%(upstream:short)%00%(objectname)%00%(upstream:remotename)%00%(upstream:remoteref)",
        });
        if (std.mem.startsWith(u8, name, "refs/")) {
            try argv.append(name);
        } else {
            const local = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
            defer self.allocator.free(local);
            const remote = try std.fmt.allocPrint(self.allocator, "refs/remotes/{s}", .{name});
            defer self.allocator.free(remote);
            try argv.append(local);
            try argv.append(remote);
        }
        var result = self.run(argv.items, root, get_refs_output_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => return error.Timeout,
            error.NoGit => return error.NoGit,
            error.OutputTooLarge, error.GitFailed => return error.GitFailed,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (!result.term.success()) return null;
        return parseBranch(allocator, result.stdout);
    }

    /// Read-only port of `repository.getBranchBase`: the branch base from
    /// `branch.<name>.vscode-merge-base`, the creation reflog, or the remote
    /// default branch. Unlike upstream it never writes the config key back.
    pub fn getBranchBase(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        name: []const u8,
    ) !?GitBranch {
        var branch = (try self.getBranch(allocator, root, name)) orelse return null;
        var branch_owned = true;
        errdefer if (branch_owned) branch.deinit(allocator);

        const local_name = branch.ref.name orelse {
            branch.deinit(allocator);
            return null;
        };
        const config_key = try std.fmt.allocPrint(self.allocator, "branch.{s}.vscode-merge-base", .{local_name});
        defer self.allocator.free(config_key);
        if (try self.getConfig(allocator, root, config_key)) |config_value| {
            defer allocator.free(config_value);
            if (config_value.len > 0) {
                if (try self.getBranch(allocator, root, config_value)) |config_branch| {
                    if (config_branch.ref.remote != null) {
                        branch.deinit(allocator);
                        return config_branch;
                    }
                    var config_owned = config_branch;
                    config_owned.deinit(allocator);
                }
            }
        }

        // Creation reflog.
        const reflog_ref = branch.ref.name orelse {
            branch.deinit(allocator);
            return null;
        };
        if (try self.getReflogSubject(allocator, root, reflog_ref, "branch: Created from *.")) |entry| {
            defer allocator.free(entry);
            if (std.mem.startsWith(u8, entry, "branch: Created from ")) {
                const created_from = entry["branch: Created from ".len..];
                if (created_from.len > 0 and !std.mem.eql(u8, created_from, "HEAD")) {
                    if (try self.branchOrUpstream(allocator, root, created_from)) |base| {
                        branch.deinit(allocator);
                        return base;
                    }
                }
                if (std.mem.eql(u8, created_from, "HEAD")) {
                    const checkout_pattern = try std.fmt.allocPrint(
                        self.allocator,
                        "checkout: moving from .* to {s}",
                        .{if (std.mem.startsWith(u8, local_name, "refs/heads/")) local_name["refs/heads/".len..] else local_name},
                    );
                    defer self.allocator.free(checkout_pattern);
                    if (try self.getReflogSubject(allocator, root, "HEAD", checkout_pattern)) |checkout| {
                        defer allocator.free(checkout);
                        if (std.mem.indexOf(u8, checkout, "checkout: moving from ")) |start| {
                            const rest = checkout[start + "checkout: moving from ".len ..];
                            if (std.mem.indexOf(u8, rest, " ")) |end| {
                                if (try self.branchOrUpstream(allocator, root, rest[0..end])) |base| {
                                    branch.deinit(allocator);
                                    return base;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Default branch of the first remote.
        if (try self.defaultRemote(allocator, root)) |remote| {
            defer allocator.free(remote);
            const symbolic = try std.fmt.allocPrint(self.allocator, "refs/remotes/{s}/HEAD", .{remote});
            defer self.allocator.free(symbolic);
            if (try self.runOutput(allocator, root, &.{ self.exe, "symbolic-ref", "--short", symbolic }, merge_base_output_limit)) |default_ref| {
                defer allocator.free(default_ref);
                if (try self.branchOrUpstream(allocator, root, default_ref)) |base| {
                    branch.deinit(allocator);
                    return base;
                }
            }
        }

        branch_owned = false;
        return branch;
    }

    fn branchOrUpstream(self: *Git, allocator: Allocator, root: []const u8, name: []const u8) !?GitBranch {
        var branch = (try self.getBranch(allocator, root, name)) orelse return null;
        if (branch.ref.remote != null) return branch;
        const upstream = branch.upstream orelse {
            branch.deinit(allocator);
            return null;
        };
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ upstream.remote, upstream.name });
        defer allocator.free(full);
        branch.deinit(allocator);
        return try self.getBranch(allocator, root, full);
    }

    fn getConfig(self: *Git, allocator: Allocator, root: []const u8, key: []const u8) !?[]u8 {
        return self.runOutput(allocator, root, &.{ self.exe, "config", "--get", key }, merge_base_output_limit);
    }

    fn getReflogSubject(self: *Git, allocator: Allocator, root: []const u8, ref: []const u8, pattern: []const u8) !?[]u8 {
        const grep = try std.fmt.allocPrint(self.allocator, "--grep-reflog={s}", .{pattern});
        defer self.allocator.free(grep);
        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.appendSlice(&.{ self.exe, "reflog", "show", ref, "--format=%gs", grep });
        const output = (try self.runOutput(allocator, root, argv.items, merge_base_output_limit)) orelse return null;
        defer self.allocator.free(output);
        const trimmed = std.mem.trim(u8, output, "\r\n");
        if (trimmed.len == 0) return null;
        // Upstream requires exactly one matching reflog entry.
        if (std.mem.indexOfScalar(u8, trimmed, '\n') != null) return null;
        return try allocator.dupe(u8, trimmed);
    }

    fn defaultRemote(self: *Git, allocator: Allocator, root: []const u8) !?[]u8 {
        const output = (try self.runOutput(allocator, root, &.{ self.exe, "remote" }, merge_base_output_limit)) orelse return null;
        defer allocator.free(output);
        const trimmed = std.mem.trim(u8, output, "\r\n");
        if (trimmed.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
        const first = std.mem.trimEnd(u8, trimmed[0..end], "\r");
        if (first.len == 0) return null;
        return try allocator.dupe(u8, first);
    }

    fn runOutput(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        argv: []const []const u8,
        limit: usize,
    ) !?[]u8 {
        var result = self.run(argv, root, limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (!result.term.success()) return null;
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    }

    /// Reads `path` at an arbitrary revision via `git show <rev>:<path>`.
    pub fn readRefAt(
        self: *Git,
        allocator: Allocator,
        root: []const u8,
        path: []const u8,
        revision: []const u8,
    ) !?[]u8 {
        if (!isSafeRelativePath(path)) return null;
        if (std.mem.indexOfScalar(u8, revision, 0) != null or std.mem.indexOfScalar(u8, revision, ':') != null) return null;
        const content = (try self.readGitBlob(root, revision, path)) orelse return null;
        defer self.allocator.free(content);
        return try allocator.dupe(u8, content);
    }

    pub fn hasGitVersionAtLeast(self: *const Git, major: usize, minor: usize) bool {
        const version = self.ensureGitVersion() orelse return false;
        return version.major > major or (version.major == major and version.minor >= minor);
    }

    fn ensureGitVersion(self: *const Git) ?GitVersion {
        if (self.git_version) |version| return version;
        var mutable: *Git = @constCast(self);
        var result = mutable.run(&.{ mutable.exe, "--version" }, ".", merge_base_output_limit) catch return null;
        defer mutable.allocator.free(result.stdout);
        defer mutable.allocator.free(result.stderr);
        if (!result.term.success()) return null;
        const version = parseGitVersion(result.stdout) orelse return null;
        mutable.git_version = version;
        return version;
    }

    fn repositoriesThunk(context: *anyopaque) []const IGitRepository {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.repositories();
    }

    fn openRepositoryThunk(context: *anyopaque, path: []const u8) anyerror!?IGitRepository {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.openRepository(path);
    }

    fn getRefsThunk(
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        query: GitRefQuery,
        token: CancellationToken,
    ) anyerror![]GitRef {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.getRefs(allocator, root, query, token);
    }

    fn diffBetweenWithStatsThunk(
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        ref1: []const u8,
        ref2: []const u8,
        path: ?[]const u8,
    ) anyerror![]GitDiffChange {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.diffBetweenWithStats(allocator, root, ref1, ref2, path);
    }

    fn diffBetweenWithStats2Thunk(
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        ref: []const u8,
        path: ?[]const u8,
    ) anyerror![]GitDiffChange {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.diffBetweenWithStats2(allocator, root, ref, path);
    }

    fn commitFilesThunk(
        context: *anyopaque,
        root: []const u8,
        files: []const []const u8,
        message: []const u8,
        options: GitCommitOptions,
    ) anyerror!void {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.commitFiles(root, files, message, options);
    }
    fn logThunk(
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        options: GitLogOptions,
        token: CancellationToken,
    ) anyerror![]GitCommit {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.log(allocator, root, options, token);
    }

    fn diffRootCommitThunk(
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        commit: []const u8,
    ) anyerror![]GitDiffChange {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.diffRootCommit(allocator, root, commit);
    }

    fn mergeBaseThunk(
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        refs: []const []const u8,
    ) anyerror!?[]u8 {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.mergeBase(allocator, root, refs);
    }

    fn getBranchThunk(
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        name: []const u8,
    ) anyerror!?GitBranch {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.getBranch(allocator, root, name);
    }

    fn getBranchBaseThunk(
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        name: []const u8,
    ) anyerror!?GitBranch {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.getBranchBase(allocator, root, name);
    }

    fn readRefAtThunk(
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        path: []const u8,
        revision: []const u8,
    ) anyerror!?[]u8 {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.readRefAt(allocator, root, path, revision);
    }

    fn hasGitVersionAtLeastThunk(
        context: *anyopaque,
        major: usize,
        minor: usize,
    ) bool {
        const self: *Git = @ptrCast(@alignCast(context));
        return self.hasGitVersionAtLeast(major, minor);
    }
};

// ---------------------------------------------------------------------------
// `git log`, `git for-each-ref` and raw diff parsers
// ---------------------------------------------------------------------------

fn findByte(bytes: []const u8, start: usize, needle: u8) ?usize {
    if (start >= bytes.len) return null;
    return std.mem.indexOfScalarPos(u8, bytes, start, needle);
}

fn nextLine(bytes: []const u8, position: *usize) ?[]const u8 {
    const end = findByte(bytes, position.*, '\n') orelse return null;
    const line = bytes[position.*..end];
    position.* = end + 1;
    return line;
}

pub fn parseGitVersion(bytes: []const u8) ?GitVersion {
    const marker = "git version ";
    const start = std.mem.indexOf(u8, bytes, marker) orelse return null;
    const rest = bytes[start + marker.len ..];
    var index: usize = 0;
    var major: usize = 0;
    while (index < rest.len and rest[index] >= '0' and rest[index] <= '9') : (index += 1) {
        major = major * 10 + (rest[index] - '0');
    }
    if (index >= rest.len or rest[index] != '.') return null;
    index += 1;
    var minor: usize = 0;
    var digits: usize = 0;
    while (index < rest.len and rest[index] >= '0' and rest[index] <= '9') : (index += 1) {
        minor = minor * 10 + (rest[index] - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    return .{ .major = major, .minor = minor };
}

fn parseSpaceList(allocator: Allocator, line: []const u8) ![]const []const u8 {
    var result = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (result.items) |value| allocator.free(value);
        result.deinit();
    }
    var iterator = std.mem.tokenizeScalar(u8, line, ' ');
    while (iterator.next()) |part| {
        try result.append(try allocator.dupe(u8, part));
    }
    return result.toOwnedSlice();
}

fn parseRefNames(allocator: Allocator, line: []const u8) ![]const []const u8 {
    var result = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (result.items) |value| allocator.free(value);
        result.deinit();
    }
    var iterator = std.mem.splitScalar(u8, line, ',');
    while (iterator.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        try result.append(try allocator.dupe(u8, name));
    }
    return result.toOwnedSlice();
}

fn numberBefore(line: []const u8, needle: []const u8) ?usize {
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    var end = at;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
    var start = end;
    while (start > 0 and line[start - 1] >= '0' and line[start - 1] <= '9') start -= 1;
    if (start == end) return null;
    return std.fmt.parseInt(usize, line[start..end], 10) catch null;
}

pub fn parseGitDiffShortStat(line: []const u8) GitCommitShortStat {
    return .{
        .files = numberBefore(line, "file") orelse 0,
        .insertions = numberBefore(line, "insertion") orelse 0,
        .deletions = numberBefore(line, "deletion") orelse 0,
    };
}

fn isGitShortStatLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "file changed") != null or
        std.mem.indexOf(u8, line, "files changed") != null;
}

/// Port of the extension's `parseGitCommits` for the `-z` output described in
/// the module header: seven newline fields, the message up to a NUL, then an
/// optional shortstat line.
pub fn parseGitCommits(allocator: Allocator, bytes: []const u8) ![]GitCommit {
    var commits = std.array_list.Managed(GitCommit).init(allocator);
    errdefer {
        for (commits.items) |*commit| commit.deinit(allocator);
        commits.deinit();
    }

    var position: usize = 0;
    while (position < bytes.len) {
        const hash = nextLine(bytes, &position) orelse break;
        if (hash.len == 0) break;
        const author_name = nextLine(bytes, &position) orelse break;
        const author_email = nextLine(bytes, &position) orelse break;
        const author_date_line = nextLine(bytes, &position) orelse break;
        const commit_date_line = nextLine(bytes, &position) orelse break;
        const parents_line = nextLine(bytes, &position) orelse break;
        const refs_line = nextLine(bytes, &position) orelse break;

        const nul = findByte(bytes, position, 0) orelse break;
        var message = bytes[position..nul];
        if (message.len > 0 and message[message.len - 1] == '\n') {
            message = message[0 .. message.len - 1];
        }
        position = nul + 1;

        var short_stat: ?GitCommitShortStat = null;
        if (position < bytes.len and bytes[position] == '\n') {
            if (findByte(bytes, position + 1, '\n')) |end| {
                const stat_line = bytes[position + 1 .. end];
                // Upstream matches `files? changed`: git prints "1 file changed"
                // for a single-file commit. Requiring the plural here used to
                // leave the shortstat line in the stream, so the next record
                // was read as a hash and every later commit was dropped.
                if (isGitShortStatLine(stat_line)) {
                    short_stat = parseGitDiffShortStat(stat_line);
                    position = end + 1;
                }
            }
        }

        const owned_hash = try allocator.dupe(u8, hash);
        errdefer allocator.free(owned_hash);
        const owned_message = try allocator.dupe(u8, message);
        errdefer allocator.free(owned_message);
        const owned_author_name = try allocator.dupe(u8, author_name);
        errdefer allocator.free(owned_author_name);
        const owned_author_email = try allocator.dupe(u8, author_email);
        errdefer allocator.free(owned_author_email);
        const parents = try parseSpaceList(allocator, parents_line);
        errdefer {
            for (parents) |parent| allocator.free(parent);
            if (parents.len > 0) allocator.free(parents);
        }
        const ref_names = try parseRefNames(allocator, refs_line);
        errdefer {
            for (ref_names) |name| allocator.free(name);
            if (ref_names.len > 0) allocator.free(ref_names);
        }

        try commits.append(.{
            .hash = owned_hash,
            .message = owned_message,
            .parents = parents,
            .author_name = owned_author_name,
            .author_email = owned_author_email,
            .author_date = std.fmt.parseInt(i64, std.mem.trim(u8, author_date_line, " \t"), 10) catch null,
            .commit_date = std.fmt.parseInt(i64, std.mem.trim(u8, commit_date_line, " \t"), 10) catch null,
            .ref_names = ref_names,
            .short_stat = short_stat,
        });
    }

    return commits.toOwnedSlice();
}

pub fn parseBranch(allocator: Allocator, bytes: []const u8) !?GitBranch {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const line = blk: {
        while (lines.next()) |candidate| {
            const trimmed = std.mem.trimEnd(u8, candidate, "\r");
            if (trimmed.len > 0) break :blk trimmed;
        }
        return null;
    };

    var fields = std.mem.splitScalar(u8, line, 0);
    const refname = fields.next() orelse return null;
    const upstream_short = fields.next() orelse "";
    const object_name = fields.next() orelse "";
    const remote_name = fields.next() orelse "";
    const upstream_remote_ref = fields.next() orelse "";

    var branch = GitBranch{ .ref = .{ .ref_type = .head } };
    errdefer branch.deinit(allocator);

    if (std.mem.startsWith(u8, refname, "refs/heads/")) {
        branch.ref.ref_type = .head;
        branch.ref.name = try allocator.dupe(u8, refname["refs/heads/".len..]);
        if (object_name.len > 0) branch.ref.commit = try allocator.dupe(u8, object_name);
        if (upstream_short.len > 0) {
            const slash = std.mem.indexOfScalar(u8, upstream_short, '/');
            const remote = if (remote_name.len > 0)
                try allocator.dupe(u8, remote_name)
            else if (slash) |index|
                try allocator.dupe(u8, upstream_short[0..index])
            else
                null;
            const upstream_name = if (upstream_remote_ref.len > 0 and std.mem.startsWith(u8, upstream_remote_ref, "refs/heads/"))
                try allocator.dupe(u8, upstream_remote_ref["refs/heads/".len..])
            else
                try allocator.dupe(u8, if (slash) |index| upstream_short[index + 1 ..] else upstream_short);
            branch.upstream = .{
                .remote = remote orelse try allocator.dupe(u8, ""),
                .name = upstream_name,
            };
        }
    } else if (std.mem.startsWith(u8, refname, "refs/remotes/")) {
        const rest = refname["refs/remotes/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        branch.ref.ref_type = .remote_head;
        branch.ref.remote = try allocator.dupe(u8, rest[0..slash]);
        branch.ref.name = try allocator.dupe(u8, rest[slash + 1 ..]);
        if (object_name.len > 0) branch.ref.commit = try allocator.dupe(u8, object_name);
    } else {
        return null;
    }

    return branch;
}

const NumStat = struct { insertions: usize = 0, deletions: usize = 0 };

/// Port of `parseGitChangesRaw`: parses the interleaved `--raw`/`--numstat -z`
/// records into changes with status letters and line counts.
pub fn parseGitChangesRaw(allocator: Allocator, bytes: []const u8) ![]GitDiffChange {
    var segments = std.array_list.Managed([]const u8).init(allocator);
    defer segments.deinit();
    var start: usize = 0;
    while (start <= bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, 0) orelse bytes.len;
        const segment = bytes[start..end];
        if (segment.len > 0) try segments.append(segment);
        if (end == bytes.len) break;
        start = end + 1;
    }

    var changes = std.array_list.Managed(GitDiffChange).init(allocator);
    errdefer {
        for (changes.items) |*change| {
            allocator.free(change.change.path);
            if (change.change.original_path) |path| allocator.free(path);
        }
        changes.deinit();
    }
    var num_stats = std.StringHashMap(NumStat).init(allocator);
    defer num_stats.deinit();

    var index: usize = 0;
    while (index < segments.items.len) {
        const segment = segments.items[index];
        if (segment.len == 0) {
            index += 1;
            continue;
        }
        if (segment[0] == ':') {
            var parts = std.mem.splitScalar(u8, segment, ' ');
            _ = parts.next();
            _ = parts.next();
            _ = parts.next();
            _ = parts.next();
            const status_field = parts.next() orelse {
                index += 1;
                continue;
            };
            if (status_field.len == 0) {
                index += 1;
                continue;
            }
            index += 1;
            if (index >= segments.items.len) break;
            const old_path = segments.items[index];
            index += 1;
            const status = status_field[0];
            var path = old_path;
            var original_path: ?[]const u8 = null;
            if ((status == 'R' or status == 'C') and index < segments.items.len) {
                path = segments.items[index];
                original_path = old_path;
                index += 1;
            }
            const owned_path = try allocator.dupe(u8, path);
            errdefer allocator.free(owned_path);
            const owned_original = if (original_path) |value| try allocator.dupe(u8, value) else null;
            errdefer if (owned_original) |value| allocator.free(value);
            try changes.append(.{
                .change = .{ .path = owned_path, .original_path = owned_original, .status = status },
            });
        } else {
            var parts = std.mem.splitScalar(u8, segment, '\t');
            const insertions_text = parts.next() orelse "";
            const deletions_text = parts.next() orelse "";
            const file_path = parts.next() orelse "";
            var stat_path = file_path;
            index += 1; // past the numstat record
            if (file_path.len == 0) {
                // Rename numstat: skip the old path and use the new one.
                index += 1;
                if (index >= segments.items.len) break;
                stat_path = segments.items[index];
                index += 1;
            }
            try num_stats.put(stat_path, .{
                .insertions = std.fmt.parseInt(usize, insertions_text, 10) catch 0,
                .deletions = std.fmt.parseInt(usize, deletions_text, 10) catch 0,
            });
        }
    }

    for (changes.items) |*change| {
        if (num_stats.get(change.change.path)) |stat| {
            change.insertions = stat.insertions;
            change.deletions = stat.deletions;
        }
    }

    return changes.toOwnedSlice();
}

fn ownTextBlob(allocator: Allocator, bytes: []const u8, max_file_size: usize) !?[]u8 {
    if (bytes.len > max_file_size) return null;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return null;
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    return try allocator.dupe(u8, bytes);
}

fn isNotARepository(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "not a git repository") != null or
        std.mem.indexOf(u8, stderr, "not a git repo") != null;
}

fn isNothingToCommit(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "nothing to commit") != null or
        std.mem.indexOf(u8, stderr, "no changes added to commit") != null or
        std.mem.indexOf(u8, stderr, "nothing added to commit") != null;
}

fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn freeChange(allocator: Allocator, change: GitChange) void {
    allocator.free(change.path);
    if (change.original_path) |path| allocator.free(path);
    if (change.modified_path) |path| allocator.free(path);
}

fn freeChangeList(list: *std.array_list.Managed(GitChange), allocator: Allocator) void {
    for (list.items) |change| freeChange(allocator, change);
    list.deinit();
}

fn freeRef(allocator: Allocator, ref: GitRef) void {
    if (ref.name) |name| allocator.free(name);
    if (ref.commit) |commit| allocator.free(commit);
    if (ref.remote) |remote| allocator.free(remote);
}

fn freeRefs(allocator: Allocator, refs: []const GitRef) void {
    for (refs) |ref| freeRef(allocator, ref);
}

fn freeBranch(allocator: Allocator, branch: *GitBranch) void {
    if (branch.ref.name) |name| allocator.free(name);
    if (branch.ref.commit) |commit| allocator.free(commit);
    if (branch.ref.remote) |remote| allocator.free(remote);
    if (branch.upstream) |upstream| {
        allocator.free(upstream.remote);
        allocator.free(upstream.name);
        if (upstream.commit) |commit| allocator.free(commit);
    }
}

// ---------------------------------------------------------------------------
// `git status --porcelain=v2 -z` parser
// ---------------------------------------------------------------------------

const TypeRecord = struct {
    x: u8,
    y: u8,
    path: []const u8,
};

const RenameRecord = struct {
    x: u8,
    y: u8,
    /// May be empty for a structurally complete but malformed record; the
    /// caller still consumes the following original-path field in that case.
    path: []const u8,
};

/// Pure parser for `git status --porcelain=v2 -z --branch -uall` output. The
/// input is a sequence of NUL-terminated fields. Malformed, truncated and
/// unknown records are skipped without failing the whole status. Paths are
/// repository-relative and may contain spaces, UTF-8 or arbitrary bytes.
pub fn parseStatus(allocator: Allocator, bytes: []const u8) !GitRepositoryState {
    var index_changes = std.array_list.Managed(GitChange).init(allocator);
    errdefer freeChangeList(&index_changes, allocator);
    var working_tree_changes = std.array_list.Managed(GitChange).init(allocator);
    errdefer freeChangeList(&working_tree_changes, allocator);
    var merge_changes = std.array_list.Managed(GitChange).init(allocator);
    errdefer freeChangeList(&merge_changes, allocator);
    var untracked_changes = std.array_list.Managed(GitChange).init(allocator);
    errdefer freeChangeList(&untracked_changes, allocator);

    var branch_info_present = false;
    var oid: ?[]const u8 = null;
    var branch_name: ?[]const u8 = null;
    var detached = false;
    var upstream: ?[]const u8 = null;
    var ahead: ?usize = null;
    var behind: ?usize = null;
    var entry_count: usize = 0;

    var position: usize = 0;
    while (nextField(bytes, &position)) |record| {
        if (record.len == 0) continue;

        if (record[0] == '#') {
            if (std.mem.startsWith(u8, record, "# branch.oid ")) {
                branch_info_present = true;
                oid = std.mem.trimEnd(u8, record["# branch.oid ".len..], "\r\n");
            } else if (std.mem.startsWith(u8, record, "# branch.head ")) {
                branch_info_present = true;
                const value = std.mem.trimEnd(u8, record["# branch.head ".len..], "\r\n");
                detached = std.mem.eql(u8, value, "(detached)");
                branch_name = if (detached or value.len == 0) null else value;
            } else if (std.mem.startsWith(u8, record, "# branch.upstream ")) {
                branch_info_present = true;
                const value = std.mem.trimEnd(u8, record["# branch.upstream ".len..], "\r\n");
                upstream = if (value.len == 0) null else value;
            } else if (std.mem.startsWith(u8, record, "# branch.ab ")) {
                branch_info_present = true;
                const value = std.mem.trimEnd(u8, record["# branch.ab ".len..], "\r\n");
                parseAheadBehind(value, &ahead, &behind);
            }
            continue;
        }

        switch (record[0]) {
            '1' => {
                const parsed = parseTypeRecord(record, '1', 6) orelse continue;
                if (parsed.path.len == 0 or std.mem.endsWith(u8, parsed.path, "/")) continue;
                if (entry_count >= max_status_entries) continue;
                entry_count += 1;
                try addXYChange(&index_changes, &working_tree_changes, allocator, parsed, null);
            },
            '2' => {
                const parsed = parseRenameRecord(record) orelse continue;
                // A v2 -z rename/copy record always has the original path in
                // the next NUL-separated field. Consume it even when the entry
                // is over the cap or the new path is empty, so the stream does
                // not desynchronize.
                const original = nextField(bytes, &position) orelse break;
                if (parsed.path.len == 0 or original.len == 0) continue;
                if (std.mem.endsWith(u8, parsed.path, "/") or std.mem.endsWith(u8, original, "/")) continue;
                if (entry_count >= max_status_entries) continue;
                entry_count += 1;
                try addXYChange(
                    &index_changes,
                    &working_tree_changes,
                    allocator,
                    .{ .x = parsed.x, .y = parsed.y, .path = parsed.path },
                    original,
                );
            },
            'u' => {
                const parsed = parseTypeRecord(record, 'u', 8) orelse continue;
                if (parsed.path.len == 0 or std.mem.endsWith(u8, parsed.path, "/")) continue;
                if (entry_count >= max_status_entries) continue;
                entry_count += 1;
                try appendChange(&merge_changes, allocator, parsed.path, null, 'U', .{ parsed.x, parsed.y });
            },
            '?' => {
                const path = parseSimplePath(record) orelse continue;
                if (path.len == 0 or std.mem.endsWith(u8, path, "/")) continue;
                if (entry_count >= max_status_entries) continue;
                entry_count += 1;
                try appendChange(&untracked_changes, allocator, path, null, '?', null);
            },
            '!' => {
                // Ignored entries have no state group in the read-only model.
                // Parse the shape so a malformed record is skipped cleanly.
                _ = parseSimplePath(record);
            },
            else => {},
        }
    }

    var state = GitRepositoryState{};
    errdefer state.deinit(allocator);

    if (branch_info_present) {
        state.head = try buildHead(allocator, oid, branch_name, detached, upstream, ahead, behind);
    }
    state.index_changes = try index_changes.toOwnedSlice();
    state.working_tree_changes = try working_tree_changes.toOwnedSlice();
    state.merge_changes = try merge_changes.toOwnedSlice();
    state.untracked_changes = try untracked_changes.toOwnedSlice();
    return state;
}

fn nextField(bytes: []const u8, position: *usize) ?[]const u8 {
    if (position.* >= bytes.len) return null;
    const start = position.*;
    const end = std.mem.indexOfScalarPos(u8, bytes, start, 0) orelse return null;
    position.* = end + 1;
    return bytes[start..end];
}

fn parseSimplePath(record: []const u8) ?[]const u8 {
    if (record.len < 3 or record[1] != ' ') return null;
    return record[2..];
}

fn parseTypeRecord(record: []const u8, record_type: u8, spaces_before_path: usize) ?TypeRecord {
    if (record.len < 5 or record[0] != record_type or record[1] != ' ') return null;
    const xy = record[2..4];
    if (record[4] != ' ') return null;

    var index: usize = 5;
    var remaining = spaces_before_path;
    while (remaining > 0) : (remaining -= 1) {
        const space = std.mem.indexOfScalarPos(u8, record, index, ' ') orelse return null;
        index = space + 1;
    }
    if (index > record.len) return null;
    return .{ .x = xy[0], .y = xy[1], .path = record[index..] };
}

fn parseRenameRecord(record: []const u8) ?RenameRecord {
    const parsed = parseTypeRecord(record, '2', 7) orelse return null;
    return .{ .x = parsed.x, .y = parsed.y, .path = parsed.path };
}

fn parseAheadBehind(value: []const u8, ahead: *?usize, behind: *?usize) void {
    var tokens = std.mem.tokenizeScalar(u8, value, ' ');
    const ahead_token = tokens.next() orelse return;
    const behind_token = tokens.next() orelse return;
    if (ahead_token.len < 2 or ahead_token[0] != '+') return;
    if (behind_token.len < 2 or behind_token[0] != '-') return;
    const parsed_ahead = std.fmt.parseInt(usize, ahead_token[1..], 10) catch return;
    const parsed_behind = std.fmt.parseInt(usize, behind_token[1..], 10) catch return;
    ahead.* = parsed_ahead;
    behind.* = parsed_behind;
}

fn appendChange(
    list: *std.array_list.Managed(GitChange),
    allocator: Allocator,
    path: []const u8,
    original: ?[]const u8,
    status: u8,
    conflict: ?[2]u8,
) !void {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_original = if (original) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_original) |value| allocator.free(value);
    try list.append(.{
        .path = owned_path,
        .original_path = owned_original,
        .status = status,
        .conflict = conflict,
    });
}

fn addXYChange(
    index_changes: *std.array_list.Managed(GitChange),
    working_tree_changes: *std.array_list.Managed(GitChange),
    allocator: Allocator,
    record: TypeRecord,
    original: ?[]const u8,
) !void {
    if (record.x != '.' and record.x != ' ') {
        try appendChange(index_changes, allocator, record.path, original, record.x, null);
    }
    if (record.y != '.' and record.y != ' ') {
        try appendChange(working_tree_changes, allocator, record.path, original, record.y, null);
    }
}

fn buildUpstream(allocator: Allocator, value: []const u8) !GitUpstreamRef {
    const slash = std.mem.indexOfScalar(u8, value, '/');
    const remote = if (slash) |index| value[0..index] else "";
    const name = if (slash) |index| value[index + 1 ..] else value;
    const owned_remote = try allocator.dupe(u8, remote);
    errdefer allocator.free(owned_remote);
    const owned_name = try allocator.dupe(u8, name);
    return .{ .remote = owned_remote, .name = owned_name };
}

fn buildHead(
    allocator: Allocator,
    oid: ?[]const u8,
    name: ?[]const u8,
    detached: bool,
    upstream: ?[]const u8,
    ahead: ?usize,
    behind: ?usize,
) !GitBranch {
    var branch = GitBranch{ .ref = .{ .ref_type = .head } };
    errdefer freeBranch(allocator, &branch);

    if (!detached) {
        if (name) |value| {
            if (value.len > 0) branch.ref.name = try allocator.dupe(u8, value);
        }
    }
    if (oid) |value| {
        if (value.len > 0 and !std.mem.eql(u8, value, "(initial)")) {
            branch.ref.commit = try allocator.dupe(u8, value);
        }
    }
    if (upstream) |value| {
        if (value.len > 0) branch.upstream = try buildUpstream(allocator, value);
    }
    branch.ahead = ahead;
    branch.behind = behind;
    return branch;
}

// ---------------------------------------------------------------------------
// `git for-each-ref` and `git diff --numstat -z` parsers
// ---------------------------------------------------------------------------

fn makeRef(
    allocator: Allocator,
    ref_type: GitRefType,
    name: []const u8,
    commit: []const u8,
    remote: ?[]const u8,
) !GitRef {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_commit = try allocator.dupe(u8, commit);
    errdefer allocator.free(owned_commit);
    const owned_remote = if (remote) |value| try allocator.dupe(u8, value) else null;
    return .{
        .ref_type = ref_type,
        .name = owned_name,
        .commit = owned_commit,
        .remote = owned_remote,
    };
}

fn parseRefs(allocator: Allocator, bytes: []const u8) ![]GitRef {
    var refs = std.array_list.Managed(GitRef).init(allocator);
    errdefer {
        freeRefs(allocator, refs.items);
        refs.deinit();
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, 0);
        const refname = fields.next() orelse continue;
        const objectname = fields.next() orelse continue;
        const peeled = fields.next() orelse "";

        var ref_type: GitRefType = undefined;
        var name: []const u8 = undefined;
        var remote: ?[]const u8 = null;
        if (std.mem.startsWith(u8, refname, "refs/heads/")) {
            ref_type = .head;
            name = refname["refs/heads/".len..];
        } else if (std.mem.startsWith(u8, refname, "refs/remotes/")) {
            const rest = refname["refs/remotes/".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
            if (slash == 0 or slash + 1 >= rest.len) continue;
            ref_type = .remote_head;
            name = rest;
            remote = rest[0..slash];
        } else if (std.mem.startsWith(u8, refname, "refs/tags/")) {
            ref_type = .tag;
            name = refname["refs/tags/".len..];
        } else {
            continue;
        }
        if (name.len == 0) continue;

        const commit = if (ref_type == .tag and peeled.len > 0) peeled else objectname;
        if (commit.len == 0) continue;

        const ref = try makeRef(allocator, ref_type, name, commit, remote);
        refs.append(ref) catch |err| {
            freeRef(allocator, ref);
            return err;
        };
    }
    return refs.toOwnedSlice();
}

fn parseNumStatCount(value: []const u8) usize {
    if (value.len == 0 or std.mem.eql(u8, value, "-")) return 0;
    return std.fmt.parseInt(usize, value, 10) catch 0;
}

fn parseNumStat(allocator: Allocator, bytes: []const u8) ![]GitDiffChange {
    var changes = std.array_list.Managed(GitDiffChange).init(allocator);
    errdefer {
        for (changes.items) |change| freeChange(allocator, change.change);
        changes.deinit();
    }

    var position: usize = 0;
    while (nextField(bytes, &position)) |record| {
        if (record.len == 0) continue;
        const first_tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
        const second_tab = std.mem.indexOfScalarPos(u8, record, first_tab + 1, '\t') orelse continue;
        const insertions = parseNumStatCount(record[0..first_tab]);
        const deletions = parseNumStatCount(record[first_tab + 1 .. second_tab]);
        const inline_path = record[second_tab + 1 ..];

        var path: []const u8 = undefined;
        var original: ?[]const u8 = null;
        if (inline_path.len > 0) {
            path = inline_path;
        } else {
            const old_path = nextField(bytes, &position) orelse break;
            const new_path = nextField(bytes, &position) orelse break;
            if (old_path.len == 0 or new_path.len == 0) continue;
            path = new_path;
            original = old_path;
        }
        if (path.len == 0) continue;

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_original = if (original) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_original) |value| allocator.free(value);
        try changes.append(.{
            .change = .{ .path = owned_path, .original_path = owned_original },
            .insertions = insertions,
            .deletions = deletions,
        });
    }
    return changes.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn buildStatus(allocator: Allocator, fields: []const []const u8) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    errdefer buffer.deinit();
    for (fields) |field| {
        try buffer.appendSlice(field);
        try buffer.append(0);
    }
    return buffer.toOwnedSlice();
}

fn expectChangePaths(changes: []const GitChange, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, changes.len);
    for (changes, expected) |change, path| {
        try std.testing.expectEqualStrings(path, change.path);
    }
}

fn hasChangePath(changes: []const GitChange, path: []const u8) bool {
    for (changes) |change| {
        if (std.mem.eql(u8, change.path, path)) return true;
    }
    return false;
}

fn findChange(changes: []const GitChange, path: []const u8) ?GitChange {
    for (changes) |change| {
        if (std.mem.eql(u8, change.path, path)) return change;
    }
    return null;
}

test "parseStatus: branch headers and staged/unstaged groups" {
    const allocator = std.testing.allocator;
    const bytes = try buildStatus(allocator, &.{
        "# branch.oid abc123",
        "# branch.head main",
        "# branch.upstream origin/main",
        "# branch.ab +2 -3",
        "1 M. N... 100644 100644 100644 aaa bbb src/staged.zig",
        "1 .M N... 100644 100644 100644 aaa bbb src/work.zig",
        "1 MM N... 100644 100644 100644 aaa bbb src/both.zig",
    });
    defer allocator.free(bytes);

    var state = try parseStatus(allocator, bytes);
    defer state.deinit(allocator);

    const head = state.head orelse return error.TestExpectedHead;
    try std.testing.expectEqual(GitRefType.head, head.ref.ref_type);
    try std.testing.expectEqualStrings("main", head.ref.name.?);
    try std.testing.expectEqualStrings("abc123", head.ref.commit.?);
    try std.testing.expect(head.upstream != null);
    try std.testing.expectEqualStrings("origin", head.upstream.?.remote);
    try std.testing.expectEqualStrings("main", head.upstream.?.name);
    try std.testing.expectEqual(@as(?usize, 2), head.ahead);
    try std.testing.expectEqual(@as(?usize, 3), head.behind);

    try expectChangePaths(state.index_changes, &.{ "src/staged.zig", "src/both.zig" });
    try expectChangePaths(state.working_tree_changes, &.{ "src/work.zig", "src/both.zig" });
    try std.testing.expectEqual(@as(usize, 0), state.merge_changes.len);
    try std.testing.expectEqual(@as(usize, 0), state.untracked_changes.len);
}

test "parseStatus: detached and unborn HEAD" {
    const allocator = std.testing.allocator;
    {
        const bytes = try buildStatus(allocator, &.{
            "# branch.oid 0123456789abcdef",
            "# branch.head (detached)",
        });
        defer allocator.free(bytes);
        var state = try parseStatus(allocator, bytes);
        defer state.deinit(allocator);
        const head = state.head.?;
        try std.testing.expect(head.ref.name == null);
        try std.testing.expectEqualStrings("0123456789abcdef", head.ref.commit.?);
    }
    {
        const bytes = try buildStatus(allocator, &.{
            "# branch.oid (initial)",
            "# branch.head main",
        });
        defer allocator.free(bytes);
        var state = try parseStatus(allocator, bytes);
        defer state.deinit(allocator);
        const head = state.head.?;
        try std.testing.expectEqualStrings("main", head.ref.name.?);
        try std.testing.expect(head.ref.commit == null);
    }
}

test "parseStatus: spaces and UTF-8 paths" {
    const allocator = std.testing.allocator;
    const bytes = try buildStatus(allocator, &.{
        "1 .M N... 100644 100644 100644 aaa bbb dir with space/ünïcode.zig",
    });
    defer allocator.free(bytes);
    var state = try parseStatus(allocator, bytes);
    defer state.deinit(allocator);
    try expectChangePaths(state.working_tree_changes, &.{"dir with space/ünïcode.zig"});
}

test "parseStatus: rename and copy records with -z original path" {
    const allocator = std.testing.allocator;
    const bytes = try buildStatus(allocator, &.{
        "2 R. N... 100644 100644 100644 aaa bbb R100 new name.zig",
        "old name.zig",
        "2 C. N... 100644 100644 100644 aaa bbb C75 copy.zig",
        "source.zig",
        "2 RM N... 100644 100644 100644 aaa bbb R100 both.zig",
        "both old.zig",
    });
    defer allocator.free(bytes);
    var state = try parseStatus(allocator, bytes);
    defer state.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), state.index_changes.len);
    const renamed = findChange(state.index_changes, "new name.zig") orelse return error.TestExpectedChange;
    try std.testing.expectEqualStrings("old name.zig", renamed.original_path.?);
    const copied = findChange(state.index_changes, "copy.zig") orelse return error.TestExpectedChange;
    try std.testing.expectEqualStrings("source.zig", copied.original_path.?);
    const both = findChange(state.index_changes, "both.zig") orelse return error.TestExpectedChange;
    try std.testing.expectEqualStrings("both old.zig", both.original_path.?);

    // `RM` is staged + modified in the working tree.
    try std.testing.expect(hasChangePath(state.working_tree_changes, "both.zig"));
    try std.testing.expectEqual(@as(usize, 1), state.working_tree_changes.len);
}

test "parseStatus: unmerged and untracked records" {
    const allocator = std.testing.allocator;
    const bytes = try buildStatus(allocator, &.{
        "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.zig",
        "u AA N... 100644 100644 100644 100644 aaa bbb ccc added.zig",
        "? untracked.zig",
        "? nested-repository/",
        "! ignored.zig",
    });
    defer allocator.free(bytes);
    var state = try parseStatus(allocator, bytes);
    defer state.deinit(allocator);

    try expectChangePaths(state.merge_changes, &.{ "conflict.zig", "added.zig" });
    // The conflict XY pair is preserved for the upstream conflict status map.
    try std.testing.expectEqual(@as(u8, 'U'), state.merge_changes[0].conflict.?[0]);
    try std.testing.expectEqual(@as(u8, 'U'), state.merge_changes[0].conflict.?[1]);
    try std.testing.expectEqual(@as(u8, 'A'), state.merge_changes[1].conflict.?[0]);
    try std.testing.expectEqual(@as(u8, 'A'), state.merge_changes[1].conflict.?[1]);
    try std.testing.expect(state.untracked_changes[0].conflict == null);
    try std.testing.expectEqual(@as(usize, 0), state.index_changes.len);
    try std.testing.expectEqual(@as(usize, 0), state.working_tree_changes.len);
    try expectChangePaths(state.untracked_changes, &.{"untracked.zig"});
}

test "parseStatus: malformed and truncated records are skipped" {
    const allocator = std.testing.allocator;
    const valid = try buildStatus(allocator, &.{
        "not-a-record",
        "1 M. N... 100644 100644 100644 aaa",
        "u XX too",
        "1 .M N... 100644 100644 100644 aaa bbb kept.zig",
        "2 R. N... 100644 100644 100644 aaa bbb R100 missing-original.zig",
    });
    defer allocator.free(valid);
    var state = try parseStatus(allocator, valid);
    defer state.deinit(allocator);
    try expectChangePaths(state.working_tree_changes, &.{"kept.zig"});

    // A trailing record without its terminating NUL is truncated and dropped.
    var truncated = std.array_list.Managed(u8).init(allocator);
    defer truncated.deinit();
    try truncated.appendSlice("1 .M N... 100644 100644 100644 aaa bbb ok.zig");
    try truncated.append(0);
    try truncated.appendSlice("1 .M N... 100644 100644 100644 aaa bbb dropped.zig");
    var truncated_state = try parseStatus(allocator, truncated.items);
    defer truncated_state.deinit(allocator);
    try expectChangePaths(truncated_state.working_tree_changes, &.{"ok.zig"});
}

test "parseStatus: entry cap" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    for (0..max_status_entries + 50) |index| {
        var line_buffer: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, "? file{d}.zig", .{index});
        try buffer.appendSlice(line);
        try buffer.append(0);
    }

    var state = try parseStatus(allocator, buffer.items);
    defer state.deinit(allocator);
    try std.testing.expectEqual(max_status_entries, state.untracked_changes.len);
    try std.testing.expectEqualStrings("file0.zig", state.untracked_changes[0].path);
}

test "parseNumStat: ordinary and rename records" {
    const allocator = std.testing.allocator;
    const bytes = try buildStatus(allocator, &.{
        "3\t1\tsrc/a.zig",
        "0\t0\t",
        "old.zig",
        "new.zig",
        "2\t0\tbinary-ish.dat",
    });
    defer allocator.free(bytes);

    const changes = try parseNumStat(allocator, bytes);
    defer {
        for (changes) |change| freeChange(allocator, change.change);
        allocator.free(changes);
    }

    try std.testing.expectEqual(@as(usize, 3), changes.len);
    try std.testing.expectEqualStrings("src/a.zig", changes[0].change.path);
    try std.testing.expectEqual(@as(usize, 3), changes[0].insertions);
    try std.testing.expectEqual(@as(usize, 1), changes[0].deletions);
    try std.testing.expectEqualStrings("new.zig", changes[1].change.path);
    try std.testing.expectEqualStrings("old.zig", changes[1].change.original_path.?);
    try std.testing.expectEqualStrings("binary-ish.dat", changes[2].change.path);
}

test "blob cache: same pointer and invalidate forces a re-read" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "first\n" });

    var cli = try Git.init(allocator, .{ .io = std.testing.io, .max_file_size_kb = 1 });
    defer cli.deinit();

    const first = (try cli.readRefCached(root, "file.txt", .working)).?;
    try std.testing.expectEqualStrings("first\n", first);
    const second = (try cli.readRefCached(root, "file.txt", .working)).?;
    try std.testing.expectEqualStrings("first\n", second);
    try std.testing.expectEqual(first.ptr, second.ptr);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "second\n" });
    const still_cached = (try cli.readRefCached(root, "file.txt", .working)).?;
    try std.testing.expectEqual(first.ptr, still_cached.ptr);
    try std.testing.expectEqualStrings("first\n", still_cached);

    cli.invalidate();
    const refreshed = (try cli.readRefCached(root, "file.txt", .working)).?;
    try std.testing.expectEqualStrings("second\n", refreshed);
}

test "readRef: binary, invalid UTF-8 and oversized files are skipped" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    var exact_data: [1024]u8 = undefined;
    @memset(&exact_data, 'x');
    var oversized_data: [2048]u8 = undefined;
    @memset(&oversized_data, 'x');

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "binary.dat", .data = "A\x00B" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.dat", .data = "\xff\xfe" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "exact.txt", .data = &exact_data });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "oversized.txt", .data = &oversized_data });

    var cli = try Git.init(allocator, .{ .io = std.testing.io, .max_file_size_kb = 1 });
    defer cli.deinit();

    try std.testing.expect((try cli.readRef(root, "binary.dat", .working)) == null);
    try std.testing.expect((try cli.readRef(root, "invalid.dat", .working)) == null);
    try std.testing.expect((try cli.readRef(root, "oversized.txt", .working)) == null);
    try std.testing.expect((try cli.readRef(root, "missing.txt", .working)) == null);
    try std.testing.expect((try cli.readRef(root, "..", .working)) == null);

    const exact = (try cli.readRef(root, "exact.txt", .working)).?;
    defer allocator.free(exact);
    try std.testing.expectEqual(@as(usize, 1024), exact.len);
}

fn createExternalTempDir(allocator: Allocator) ![]u8 {
    var random: [12]u8 = undefined;
    std.testing.io.random(&random);
    var encoded: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&encoded, &random);
    const path = try std.fmt.allocPrint(allocator, "/tmp/vscode-textbuffer-gitcli-{s}", .{encoded});
    std.Io.Dir.cwd().createDirPath(std.testing.io, path) catch |err| {
        allocator.free(path);
        return err;
    };
    return path;
}

test "discover: non-repository and disabled provider do not crash" {
    const allocator = std.testing.allocator;
    // `std.testing.tmpDir` lives under the workspace repository, so a
    // non-repository scan needs a directory outside any working tree.
    const root = createExternalTempDir(allocator) catch return error.SkipZigTest;
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
        allocator.free(root);
    }

    var cli = try Git.init(allocator, .{ .io = std.testing.io, .timeout_ms = 2000 });
    defer cli.deinit();
    try std.testing.expect((try cli.discover(root)) == null);
    try std.testing.expect(!cli.isDisabled());
    try std.testing.expectError(error.NoGit, cli.status(root));

    var disabled = try Git.init(allocator, .{ .io = std.testing.io, .enabled = false });
    defer disabled.deinit();
    try std.testing.expect(disabled.isDisabled());
    try std.testing.expect((try disabled.discover(root)) == null);

    var missing = try Git.init(allocator, .{
        .io = std.testing.io,
        .git_path = "/definitely/not-installed/git",
        .timeout_ms = 2000,
    });
    defer missing.deinit();
    try std.testing.expect((try missing.discover(root)) == null);
    try std.testing.expect(missing.isDisabled());
}

test "discover: git roots are normalized to native separators" {
    // Git for Windows prints `--show-toplevel` with `/`; the workspace folder
    // is spelled with `\`, so both must compare equal after discovery.
    var posix = [_]u8{ '/', 'a', '/', 'b' };
    try std.testing.expectEqualStrings("/a/b", Git.normalizeRoot(&posix, false));

    var windows = [_]u8{ 'C', ':', '/', 'a', '/', 'b' };
    try std.testing.expectEqualStrings("C:\\a\\b", Git.normalizeRoot(&windows, true));
}

test "discover: repository lookup accepts either separator on Windows" {
    try std.testing.expect(Git.equalRoots("C:/a/b", "C:\\a\\b", true));
    try std.testing.expect(!Git.equalRoots("C:/a/b", "C:/a/c", true));
    try std.testing.expect(!Git.equalRoots("C:/a/b", "C:\\a\\c", true));
    try std.testing.expect(!Git.equalRoots("/a/b", "\\a\\b", false));
}

fn runTestGit(allocator: Allocator, cwd: []const u8, args: []const []const u8) !std.process.RunResult {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.appendSlice(args);
    return std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20_000), .clock = .awake } },
    });
}

fn gitOk(allocator: Allocator, cwd: []const u8, args: []const []const u8) !bool {
    const result = runTestGit(allocator, cwd, args) catch return error.SkipZigTest;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term.success();
}

test "integration: temp repository status and readRef" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    if (!try gitOk(allocator, root, &.{"init"})) return error.SkipZigTest;
    _ = try gitOk(allocator, root, &.{ "symbolic-ref", "HEAD", "refs/heads/main" });
    _ = try gitOk(allocator, root, &.{ "config", "user.name", "Test User" });
    _ = try gitOk(allocator, root, &.{ "config", "user.email", "test@example.com" });

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old.txt", .data = "old\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gone.txt", .data = "gone\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "binary.dat", .data = "A\x00B" });
    if (!try gitOk(allocator, root, &.{ "add", "a.txt", "old.txt", "gone.txt", "binary.dat" })) return error.SkipZigTest;
    if (!try gitOk(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "initial" })) return error.SkipZigTest;

    // Working-tree modification.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "one\nTWO\n" });
    // Staged addition.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "bee\n" });
    // Untracked file.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "untracked.txt", .data = "untracked\n" });
    // Staged rename.
    if (!try gitOk(allocator, root, &.{ "mv", "old.txt", "new.txt" })) return error.SkipZigTest;
    // Unstaged deletion.
    try tmp.dir.deleteFile(std.testing.io, "gone.txt");
    if (!try gitOk(allocator, root, &.{ "add", "b.txt" })) return error.SkipZigTest;

    var cli = try Git.init(allocator, .{ .io = std.testing.io, .timeout_ms = 20_000 });
    defer cli.deinit();

    const discovered = (try cli.discover(root)) orelse return error.SkipZigTest;
    defer allocator.free(discovered);
    try std.testing.expectEqualStrings(root, discovered);

    var state = try cli.status(discovered);
    defer state.deinit(allocator);

    const head = state.head orelse return error.TestExpectedHead;
    try std.testing.expectEqualStrings("main", head.ref.name.?);
    try std.testing.expect(head.ref.commit != null);
    try std.testing.expectEqual(@as(usize, 40), head.ref.commit.?.len);

    try std.testing.expect(hasChangePath(state.index_changes, "b.txt"));
    try std.testing.expect(hasChangePath(state.index_changes, "new.txt"));
    const renamed = findChange(state.index_changes, "new.txt") orelse return error.TestExpectedChange;
    try std.testing.expectEqualStrings("old.txt", renamed.original_path.?);
    try std.testing.expect(hasChangePath(state.working_tree_changes, "a.txt"));
    try std.testing.expect(hasChangePath(state.working_tree_changes, "gone.txt"));
    try std.testing.expect(hasChangePath(state.untracked_changes, "untracked.txt"));
    try std.testing.expectEqual(@as(usize, 0), state.merge_changes.len);

    {
        const value = (try cli.readRef(discovered, "a.txt", .head)).?;
        defer allocator.free(value);
        try std.testing.expectEqualStrings("one\ntwo\n", value);
    }
    {
        const value = (try cli.readRef(discovered, "a.txt", .index)).?;
        defer allocator.free(value);
        try std.testing.expectEqualStrings("one\ntwo\n", value);
    }
    {
        const value = (try cli.readRef(discovered, "a.txt", .working)).?;
        defer allocator.free(value);
        try std.testing.expectEqualStrings("one\nTWO\n", value);
    }
    try std.testing.expect((try cli.readRef(discovered, "b.txt", .head)) == null);
    {
        const value = (try cli.readRef(discovered, "b.txt", .index)).?;
        defer allocator.free(value);
        try std.testing.expectEqualStrings("bee\n", value);
    }
    {
        const value = (try cli.readRef(discovered, "gone.txt", .head)).?;
        defer allocator.free(value);
        try std.testing.expectEqualStrings("gone\n", value);
    }
    try std.testing.expect((try cli.readRef(discovered, "gone.txt", .working)) == null);
    {
        const value = (try cli.readRef(discovered, "old.txt", .head)).?;
        defer allocator.free(value);
        try std.testing.expectEqualStrings("old\n", value);
    }
    try std.testing.expect((try cli.readRef(discovered, "old.txt", .index)) == null);
    try std.testing.expect((try cli.readRef(discovered, "new.txt", .head)) == null);
    {
        const value = (try cli.readRef(discovered, "new.txt", .index)).?;
        defer allocator.free(value);
        try std.testing.expectEqualStrings("old\n", value);
    }
    try std.testing.expect((try cli.readRef(discovered, "binary.dat", .head)) == null);
    {
        const value = (try cli.readRef(discovered, "untracked.txt", .working)).?;
        defer allocator.free(value);
        try std.testing.expectEqualStrings("untracked\n", value);
    }

    // Cache: same borrowed pointer until invalidated; a status refresh drops it.
    const cached_first = (try cli.readRefCached(discovered, "a.txt", .working)).?;
    try std.testing.expectEqualStrings("one\nTWO\n", cached_first);
    const cached_second = (try cli.readRefCached(discovered, "a.txt", .working)).?;
    try std.testing.expectEqual(cached_first.ptr, cached_second.ptr);

    var fresh_state = try cli.status(discovered);
    defer fresh_state.deinit(allocator);
    const after_refresh = (try cli.readRefCached(discovered, "a.txt", .working)).?;
    try std.testing.expectEqualStrings("one\nTWO\n", after_refresh);
}

test "integration: openRepository reuses a repository and refresh updates state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    if (!try gitOk(allocator, root, &.{"init"})) return error.SkipZigTest;
    _ = try gitOk(allocator, root, &.{ "symbolic-ref", "HEAD", "refs/heads/main" });
    _ = try gitOk(allocator, root, &.{ "config", "user.name", "Test User" });
    _ = try gitOk(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tracked.txt", .data = "one\n" });
    if (!try gitOk(allocator, root, &.{ "add", "tracked.txt" })) return error.SkipZigTest;
    if (!try gitOk(allocator, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "initial" })) return error.SkipZigTest;

    var cli = try Git.init(allocator, .{ .io = std.testing.io, .timeout_ms = 20_000 });
    defer cli.deinit();

    const first = (try cli.openRepository(root)) orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 1), cli.repositories().len);
    const first_repo: *git_browser.GitRepository = @ptrCast(@alignCast(first.context));
    try std.testing.expectEqualStrings(root, first.root_path);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tracked.txt", .data = "two\n" });
    const second = (try cli.openRepository(root)) orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 1), cli.repositories().len);
    const second_repo: *git_browser.GitRepository = @ptrCast(@alignCast(second.context));
    try std.testing.expectEqual(first_repo, second_repo);
    try std.testing.expect(hasChangePath(second_repo.stateRef().working_tree_changes, "tracked.txt"));

    var delegated = cli.interface();
    try std.testing.expectEqual(@as(usize, 1), delegated.repositories().len);
    const reopened = (try delegated.openRepository(root)) orelse return error.SkipZigTest;
    try std.testing.expectEqual(first_repo, @as(*git_browser.GitRepository, @ptrCast(@alignCast(reopened.context))));
}
