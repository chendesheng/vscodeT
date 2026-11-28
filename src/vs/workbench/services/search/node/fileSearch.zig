// Port of the normal file-traversal path in
// `src/vs/workbench/services/search/node/fileSearch.ts`.
//
// Terminal adaptations:
// * Workspace resources are canonical path strings instead of URIs.
// * Folder traversals run sequentially instead of through `parallel`; the TUI
//   has a single search worker and this keeps the child-process lifetime and
//   cancellation simple.
// * The JavaScript child-process callbacks become a chunked read loop plus one
//   stderr drainer thread, so a full stderr pipe cannot block ripgrep.
// * macOS NFC normalization and the browser-only `find` fallback are not
//   ported (the upstream file search no longer uses the fallback).
//
// The walker owns every returned string. Cancellation sets the flag and kills
// the active child's process group through `child_mutex`; the walker discards
// partial output before returning `error.Canceled`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const glob = @import("../../../../base/common/glob.zig");
const search = @import("../common/search.zig");
const ripgrep = @import("./ripgrepFileSearch.zig");
const time_compat = @import("../../../../base/common/timeCompat.zig");
const fuzzy_scorer = @import("../../../../base/common/fuzzyScorer.zig");

const read_chunk_size = 64 * 1024;

pub const WalkOutcome = struct {
    allocator: Allocator,
    matches: []search.RawFileMatch,
    errors: [][]u8,
    limit_hit: bool,
    stats: search.FileSearchStats,

    pub fn deinit(self: *WalkOutcome) void {
        for (self.matches) |*match| match.deinit(self.allocator);
        self.allocator.free(self.matches);
        for (self.errors) |error_message| self.allocator.free(error_message);
        self.allocator.free(self.errors);
    }
};

const RunningChild = struct {
    child: std.process.Child,
    io: Io,
    killed: bool = false,
    reaping: bool = false,
};

/// Collects stderr on its own thread. Two pipes must be drained concurrently
/// or ripgrep can block when one of them fills.
const StderrDrain = struct {
    io: Io,
    file: Io.File,
    capture: ripgrep.StderrCapture,
    detector: ripgrep.SymlinkLoopDetector,
    loop_exceeded: std.atomic.Value(bool) = .init(false),

    fn run(self: *StderrDrain) void {
        var buffer: [read_chunk_size]u8 = undefined;
        while (true) {
            const n = self.file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => break,
            };
            if (n == 0) continue;
            const data = buffer[0..n];
            self.capture.append(data);
            if (self.detector.handleStderr(data)) self.loop_exceeded.store(true, .release);
        }
    }
};

pub const FileWalker = struct {
    allocator: Allocator,
    io: Io,
    query: *const search.FileQuery,
    rg_path: []const u8 = ripgrep.rg_executable,
    threads: ?usize = null,
    /// Upstream `prepareQuery(filePattern).normalizedLowercase`; fuzzy file
    /// matching ignores whitespace, `*`, quotes and the ellipsis modifier.
    normalized_file_pattern: ?[]u8 = null,

    cancelled: std.atomic.Value(bool) = .init(false),
    child_mutex: Io.Mutex = .init,
    active_child: ?*RunningChild = null,

    matches: std.array_list.Managed(search.RawFileMatch),
    errors: std.array_list.Managed([]u8),
    result_count: usize = 0,
    is_limit_hit: bool = false,
    directories_walked: usize = 0,
    files_walked: usize = 0,
    cmd_result_count: usize = 0,
    exclude_exception_runs: usize = 0,
    file_walk_time_ms: i64 = 0,
    cmd_time_ms: i64 = 0,
    exclude_exception_time_ms: i64 = 0,

    pub fn init(
        allocator: Allocator,
        io: Io,
        query: *const search.FileQuery,
        rg_path: []const u8,
    ) !FileWalker {
        var normalized_file_pattern: ?[]u8 = null;
        errdefer if (normalized_file_pattern) |pattern| allocator.free(pattern);
        if (query.file_pattern.len > 0 and !query.should_glob_match_file_pattern) {
            var prepared = try fuzzy_scorer.prepareQuery(allocator, query.file_pattern);
            defer prepared.deinit(allocator);
            normalized_file_pattern = try allocator.dupe(u8, prepared.normalizedLowercase);
        }
        return .{
            .allocator = allocator,
            .io = io,
            .query = query,
            .rg_path = rg_path,
            .normalized_file_pattern = normalized_file_pattern,
            .matches = std.array_list.Managed(search.RawFileMatch).init(allocator),
            .errors = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *FileWalker) void {
        if (self.normalized_file_pattern) |pattern| self.allocator.free(pattern);
        for (self.matches.items) |*match| match.deinit(self.allocator);
        self.matches.deinit();
        for (self.errors.items) |error_message| self.allocator.free(error_message);
        self.errors.deinit();
    }

    /// Sets the cancel flag and kills the active child without touching a pipe
    /// that the walker is draining (the walker clears the pipe fields before
    /// publishing the child).
    pub fn cancel(self: *FileWalker) void {
        self.cancelled.store(true, .release);
        self.killActiveChild();
    }

    fn killActiveChild(self: *FileWalker) void {
        self.child_mutex.lockUncancelable(self.io);
        defer self.child_mutex.unlock(self.io);
        if (self.active_child) |running| {
            if (!running.killed and !running.reaping) {
                ripgrep.killChild(&running.child, running.io);
                running.killed = true;
            }
        }
    }

    pub fn walk(self: *FileWalker) !WalkOutcome {
        const started = time_compat.milliTimestamp(self.io);
        errdefer self.discardMatches();

        try self.walkExtraFiles();

        for (self.query.folder_queries) |folder_query| {
            if (self.cancelled.load(.acquire)) return error.Canceled;
            if (self.is_limit_hit) break;
            var folder_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer folder_arena.deinit();
            try self.walkFolder(folder_query, folder_arena.allocator());
        }

        self.file_walk_time_ms = time_compat.milliTimestamp(self.io) - started;
        const matches = try self.matches.toOwnedSlice();
        errdefer {
            for (matches) |*match| match.deinit(self.allocator);
            self.allocator.free(matches);
        }
        return .{
            .allocator = self.allocator,
            .matches = matches,
            .errors = try self.errors.toOwnedSlice(),
            .limit_hit = self.is_limit_hit,
            .stats = self.stats(),
        };
    }

    fn stats(self: *const FileWalker) search.FileSearchStats {
        return .{
            .file_walk_time_ms = self.file_walk_time_ms,
            .cmd_time_ms = self.cmd_time_ms,
            .directories_walked = self.directories_walked,
            .files_walked = self.files_walked,
            .cmd_result_count = self.cmd_result_count,
            .exclude_exception_runs = self.exclude_exception_runs,
            .exclude_exception_time_ms = self.exclude_exception_time_ms,
        };
    }

    fn discardMatches(self: *FileWalker) void {
        for (self.matches.items) |*match| match.deinit(self.allocator);
        self.matches.clearRetainingCapacity();
        for (self.errors.items) |error_message| self.allocator.free(error_message);
        self.errors.clearRetainingCapacity();
    }

    fn walkExtraFiles(self: *FileWalker) !void {
        if (self.query.extra_file_resources.len == 0) return;

        var global = try glob.parseExcludeExpression(self.allocator, self.query.exclude_entries, .{
            .ignore_case = self.query.ignore_glob_case,
        });
        defer global.deinit();

        for (self.query.extra_file_resources) |path| {
            const basename = baseName(path);
            if (global.matchesExclude(path, basename)) continue;
            try self.matchFile(path, path, path, null);
            if (self.is_limit_hit) return;
        }
    }

    fn walkFolder(self: *FileWalker, folder_query: search.FolderQuery, arena: Allocator) !void {
        var excludes = try FolderExcludes.init(
            self.allocator,
            arena,
            self.query.exclude_entries,
            self.query.folder_queries,
            folder_query.folder,
            self.query.ignore_glob_case or folder_query.ignore_glob_case,
        );
        defer excludes.deinit();

        const include = try buildInclude(arena, self.query, folder_query);

        var seen_paths = std.StringHashMap(void).init(arena);
        defer {
            var keys = seen_paths.keyIterator();
            while (keys.next()) |key| self.allocator.free(key.*);
        }
        var tree = try DirectoryTree.init(arena);

        if (excludes.exceptions.len > 0) {
            try self.traverse(folder_query, &excludes, include, .{
                .seen_paths = &seen_paths,
                .tree = if (excludes.hasSiblingClauses()) &tree else null,
            });
            if (self.cancelled.load(.acquire)) return error.Canceled;
            if (!self.is_limit_hit) {
                self.exclude_exception_runs += 1;
                const started = time_compat.milliTimestamp(self.io);
                try self.traverse(folder_query, &excludes, include, .{
                    .exclude_exceptions = excludes.exceptions,
                    .seen_paths = &seen_paths,
                });
                self.exclude_exception_time_ms += time_compat.milliTimestamp(self.io) - started;
            }
        } else {
            try self.traverse(folder_query, &excludes, include, .{
                .tree = if (excludes.hasSiblingClauses()) &tree else null,
            });
        }

        if (self.cancelled.load(.acquire)) return error.Canceled;
        if (tree.rootCount() > 0 and !self.is_limit_hit) {
            try self.matchDirectoryTree(&tree, folder_query, &excludes, include);
        }
        if (self.cancelled.load(.acquire)) return error.Canceled;
    }

    const TraversalOptions = struct {
        paths_to_skip: ?*const std.StringHashMap(void) = null,
        seen_paths: ?*std.StringHashMap(void) = null,
        exclude_exceptions: ?[]const []const u8 = null,
        tree: ?*DirectoryTree = null,
    };

    fn traverse(
        self: *FileWalker,
        folder_query: search.FolderQuery,
        excludes: *FolderExcludes,
        include: ?glob.Expression,
        options: TraversalOptions,
    ) !void {
        var ignore_symlinks = folder_query.ignore_symlinks orelse
            (self.query.ignore_symlinks or !self.query.settings.follow_symlinks);
        var paths_to_skip = options.paths_to_skip;
        var retries: usize = 0;

        var reported = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (reported.items) |path| self.allocator.free(path);
            reported.deinit();
        }
        var skip_set: ?*std.StringHashMap(void) = null;
        defer if (skip_set) |set| {
            set.deinit();
            self.allocator.destroy(set);
        };

        while (true) {
            if (self.cancelled.load(.acquire)) return error.Canceled;

            const retry = try self.runTraversal(
                folder_query,
                excludes,
                include,
                options,
                ignore_symlinks,
                paths_to_skip,
                &reported,
            );
            if (!retry) return;
            if (retries >= 1) return;

            retries += 1;
            ignore_symlinks = true;
            const set = try skipSetFor(self.allocator, reported.items);
            skip_set = set;
            paths_to_skip = set;
        }
    }

    fn runTraversal(
        self: *FileWalker,
        folder_query: search.FolderQuery,
        excludes: *FolderExcludes,
        include: ?glob.Expression,
        options: TraversalOptions,
        ignore_symlinks: bool,
        paths_to_skip: ?*const std.StringHashMap(void),
        reported: *std.array_list.Managed([]u8),
    ) !bool {
        const cmd_started = time_compat.milliTimestamp(self.io);
        defer self.cmd_time_ms += time_compat.milliTimestamp(self.io) - cmd_started;

        const query_folder = search.FolderQuery{
            .folder = folder_query.folder,
            .folder_name = folder_query.folder_name,
            .include_pattern = folder_query.include_pattern,
            .ignore_glob_case = folder_query.ignore_glob_case,
            .disregard_ignore_files = folder_query.disregard_ignore_files,
            .disregard_parent_ignore_files = folder_query.disregard_parent_ignore_files,
            .disregard_global_ignore_files = folder_query.disregard_global_ignore_files,
            .ignore_symlinks = ignore_symlinks,
        };
        var spawned = ripgrep.spawn(self.io, self.allocator, self.rg_path, self.query, query_folder, .{
            .include = folder_query.include_pattern orelse self.query.include_pattern,
            .exclude = excludes.mergedEntries(),
            .threads = self.threads,
            .exclude_exceptions = options.exclude_exceptions,
            .exists = self.query.exists,
        }) catch |err| return err;

        const stdout = spawned.child.stdout orelse {
            ripgrep.killChild(&spawned.child, self.io);
            spawned.args.deinit();
            self.allocator.free(spawned.cwd);
            return error.RipgrepPipeFailure;
        };
        const stderr = spawned.child.stderr orelse {
            ripgrep.killChild(&spawned.child, self.io);
            stdout.close(self.io);
            spawned.args.deinit();
            self.allocator.free(spawned.cwd);
            return error.RipgrepPipeFailure;
        };
        spawned.child.stdout = null;
        spawned.child.stderr = null;

        const running = self.allocator.create(RunningChild) catch |err| {
            ripgrep.killChild(&spawned.child, self.io);
            stdout.close(self.io);
            stderr.close(self.io);
            spawned.args.deinit();
            self.allocator.free(spawned.cwd);
            return err;
        };
        running.* = .{ .child = spawned.child, .io = self.io };
        self.child_mutex.lockUncancelable(self.io);
        self.active_child = running;
        self.child_mutex.unlock(self.io);

        var stderr_drain = StderrDrain{
            .io = self.io,
            .file = stderr,
            .capture = ripgrep.StderrCapture.init(self.allocator),
            .detector = ripgrep.SymlinkLoopDetector.init(self.allocator),
        };
        const stderr_thread = std.Thread.spawn(.{}, StderrDrain.run, .{&stderr_drain}) catch null;

        var pending = std.array_list.Managed(u8).init(self.allocator);
        var buffer: [read_chunk_size]u8 = undefined;
        var read_error: ?anyerror = null;

        read_loop: while (true) {
            if (self.cancelled.load(.acquire) or self.is_limit_hit) {
                self.killChild(running);
                break;
            }
            if (stderr_drain.loop_exceeded.load(.acquire) and !ignore_symlinks) {
                self.killChild(running);
                break;
            }
            const n = stdout.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    read_error = err;
                    self.killChild(running);
                    break;
                },
            };
            if (n == 0) continue;
            pending.appendSlice(buffer[0..n]) catch {
                read_error = error.OutOfMemory;
                self.killChild(running);
                break;
            };
            self.consumeLines(folder_query, excludes, include, options, paths_to_skip, reported, &pending) catch |err| {
                read_error = err;
                self.killChild(running);
                break :read_loop;
            };
            if (self.cancelled.load(.acquire) or self.is_limit_hit) {
                self.killChild(running);
                break :read_loop;
            }
        }
        if (!self.cancelled.load(.acquire) and !self.is_limit_hit and read_error == null and pending.items.len > 0) {
            const line = std.mem.trim(u8, pending.items, " \t\r\n");
            if (line.len > 0) {
                self.handleRelativePath(folder_query, excludes, include, options, paths_to_skip, reported, line) catch |err| {
                    read_error = err;
                };
            }
        }
        pending.deinit();

        if (stderr_thread) |thread| thread.join();
        const loop_exceeded = stderr_drain.loop_exceeded.load(.acquire);
        const term = self.finishChild(running);
        stdout.close(self.io);
        stderr.close(self.io);
        spawned.args.deinit();
        self.allocator.free(spawned.cwd);
        defer {
            stderr_drain.capture.deinit();
            stderr_drain.detector.deinit();
        }

        if (self.cancelled.load(.acquire)) return error.Canceled;
        if (read_error) |err| return err;
        if (loop_exceeded and !ignore_symlinks) return true;

        const exit_code: u8 = switch (term) {
            .exited => |code| code,
            else => 0,
        };
        if (exit_code > 1) {
            if (ripgrep.errorMessageForDisplay(stderr_drain.capture.value())) |message| {
                try self.errors.append(try self.allocator.dupe(u8, message));
            }
        } else if (self.query.exists and options.exclude_exceptions == null and exit_code == 0) {
            self.is_limit_hit = true;
        }
        return false;
    }

    fn killChild(self: *FileWalker, running: *RunningChild) void {
        self.child_mutex.lockUncancelable(self.io);
        defer self.child_mutex.unlock(self.io);
        if (!running.killed and !running.reaping) {
            ripgrep.killChild(&running.child, running.io);
            running.killed = true;
        }
    }

    fn finishChild(self: *FileWalker, running: *RunningChild) std.process.Child.Term {
        self.child_mutex.lockUncancelable(self.io);
        if (running.killed) {
            self.active_child = null;
            self.child_mutex.unlock(self.io);
            self.allocator.destroy(running);
            return .{ .unknown = 0 };
        }
        if (self.cancelled.load(.acquire)) {
            ripgrep.killChild(&running.child, running.io);
            running.killed = true;
            self.active_child = null;
            self.child_mutex.unlock(self.io);
            self.allocator.destroy(running);
            return .{ .unknown = 0 };
        }
        running.reaping = true;
        self.child_mutex.unlock(self.io);

        const term = running.child.wait(running.io) catch std.process.Child.Term{ .unknown = 0 };

        self.child_mutex.lockUncancelable(self.io);
        running.reaping = false;
        self.active_child = null;
        self.child_mutex.unlock(self.io);
        self.allocator.destroy(running);
        return term;
    }

    fn consumeLines(
        self: *FileWalker,
        folder_query: search.FolderQuery,
        excludes: *FolderExcludes,
        include: ?glob.Expression,
        options: TraversalOptions,
        paths_to_skip: ?*const std.StringHashMap(void),
        reported: *std.array_list.Managed([]u8),
        pending: *std.array_list.Managed(u8),
    ) !void {
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pending.items, start, '\n')) |newline| {
            var line = pending.items[start..newline];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            start = newline + 1;
            if (line.len == 0) continue;
            try self.handleRelativePath(folder_query, excludes, include, options, paths_to_skip, reported, line);
            if (self.cancelled.load(.acquire) or self.is_limit_hit) break;
        }
        if (start == 0) return;
        const remaining = pending.items.len - start;
        if (remaining > 0) {
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[start..]);
        }
        pending.items.len = remaining;
    }

    fn handleRelativePath(
        self: *FileWalker,
        folder_query: search.FolderQuery,
        excludes: *FolderExcludes,
        include: ?glob.Expression,
        options: TraversalOptions,
        paths_to_skip: ?*const std.StringHashMap(void),
        reported: *std.array_list.Managed([]u8),
        relative_path: []const u8,
    ) !void {
        if (paths_to_skip) |set| {
            if (set.contains(relative_path)) return;
        }

        if (options.exclude_exceptions != null) {
            if (options.seen_paths) |seen| {
                if (seen.contains(relative_path)) return;
            }
            if (!excludes.isExcepted(relative_path, null)) return;
            if (!includeMatches(include, relative_path)) return;
            if (excludes.isNestedRoot(relative_path)) return;
        }

        if (options.seen_paths) |seen| {
            if (options.exclude_exceptions != null or excludes.isExcepted(relative_path, null)) {
                if (!seen.contains(relative_path)) {
                    try seen.put(try self.allocator.dupe(u8, relative_path), {});
                }
            }
        }

        self.cmd_result_count += 1;
        try reported.append(try self.allocator.dupe(u8, relative_path));

        if (options.tree) |tree| {
            try tree.add(relative_path);
            return;
        }

        const search_path = try makeSearchPath(self.allocator, folder_query, relative_path);
        defer self.allocator.free(search_path);
        try self.matchFile(folder_query.folder, relative_path, search_path, include);
    }

    fn matchFile(
        self: *FileWalker,
        base: []const u8,
        relative_path: []const u8,
        search_path: []const u8,
        include: ?glob.Expression,
    ) !void {
        if (!self.isFileMatch(relative_path, search_path)) return;
        if (!includeMatches(include, relative_path)) return;

        self.result_count += 1;
        if (self.query.exists or (self.query.max_results > 0 and self.result_count > self.query.max_results)) {
            self.is_limit_hit = true;
        }
        if (self.is_limit_hit) return;

        const owned_base = try self.allocator.dupe(u8, base);
        errdefer self.allocator.free(owned_base);
        const owned_relative = try self.allocator.dupe(u8, relative_path);
        errdefer self.allocator.free(owned_relative);
        const owned_search_path = try self.allocator.dupe(u8, search_path);
        errdefer self.allocator.free(owned_search_path);
        try self.matches.append(.{
            .base = owned_base,
            .relative_path = owned_relative,
            .search_path = owned_search_path,
            .basename = baseName(owned_relative),
        });
    }

    fn isFileMatch(self: *FileWalker, relative_path: []const u8, search_path: []const u8) bool {
        const file_pattern = self.query.file_pattern;
        if (file_pattern.len == 0) return true;
        if (std.mem.eql(u8, file_pattern, "*")) return true;
        const match_path = if (search_path.len > 0) search_path else relative_path;
        if (self.query.should_glob_match_file_pattern) {
            return search.isFilePatternMatch(
                self.allocator,
                relative_path,
                match_path,
                file_pattern,
                false,
                self.query.ignore_glob_case,
            ) catch false;
        }
        const fuzzy_pattern = self.normalized_file_pattern orelse file_pattern;
        return search.isFilePatternMatch(
            self.allocator,
            relative_path,
            match_path,
            fuzzy_pattern,
            true,
            false,
        ) catch false;
    }

    fn matchDirectoryTree(
        self: *FileWalker,
        tree: *DirectoryTree,
        folder_query: search.FolderQuery,
        excludes: *FolderExcludes,
        include: ?glob.Expression,
    ) !void {
        const root_entries = tree.entriesFor(".") orelse return;
        try self.matchDirectory(tree, folder_query, excludes, include, root_entries, false);
    }

    fn matchDirectory(
        self: *FileWalker,
        tree: *DirectoryTree,
        folder_query: search.FolderQuery,
        excludes: *FolderExcludes,
        include: ?glob.Expression,
        entries: []const TreeEntry,
        is_parent_excluded: bool,
    ) !void {
        self.directories_walked += 1;
        var sibling_context = SiblingContext{
            .entries = entries,
            .ignore_case = self.query.ignore_glob_case,
        };
        const file_pattern = self.query.file_pattern;
        for (entries) |entry| {
            if (self.cancelled.load(.acquire) or self.is_limit_hit) return;
            const sub = tree.entriesFor(entry.relative_path);
            const has_sibling = if (pathEquals(file_pattern, entry.basename, self.query.ignore_glob_case))
                null
            else
                glob.HasSibling{ .context = &sibling_context, .callback = SiblingContext.hasSibling };

            const evaluation = glob.evaluateExcludeTreeEntry(&excludes.relative, .{
                .path = entry.relative_path,
                .basename = entry.basename,
                .is_directory = sub != null,
                .is_parent_excluded = is_parent_excluded,
                .has_sibling = has_sibling,
            });
            if (!evaluation.is_visited) continue;

            if (sub) |children| {
                try self.matchDirectory(tree, folder_query, excludes, include, children, evaluation.is_excluded);
            } else {
                self.files_walked += 1;
                if (pathEquals(entry.relative_path, file_pattern, self.query.ignore_glob_case)) {
                    // The exact relative path was already matched before the
                    // tree walk, mirroring upstream `addDirectoryEntries`.
                    continue;
                }
                const search_path = try makeSearchPath(self.allocator, folder_query, entry.relative_path);
                defer self.allocator.free(search_path);
                try self.matchFile(folder_query.folder, entry.relative_path, search_path, include);
            }
        }
    }
};

const SiblingContext = struct {
    entries: []const TreeEntry,
    ignore_case: bool,

    fn hasSibling(context: *anyopaque, name: []const u8) bool {
        const self: *SiblingContext = @ptrCast(@alignCast(context));
        for (self.entries) |entry| {
            if (pathEquals(entry.basename, name, self.ignore_case)) return true;
        }
        return false;
    }
};

const TreeEntry = struct {
    relative_path: []const u8,
    basename: []const u8,
};

/// Upstream's `IDirectoryTree`: entries keyed by their relative directory.
const DirectoryTree = struct {
    allocator: Allocator,
    map: std.StringHashMap(std.array_list.Managed(TreeEntry)),

    fn init(allocator: Allocator) !DirectoryTree {
        var map = std.StringHashMap(std.array_list.Managed(TreeEntry)).init(allocator);
        try map.put(".", std.array_list.Managed(TreeEntry).init(allocator));
        return .{ .allocator = allocator, .map = map };
    }

    fn rootCount(self: *const DirectoryTree) usize {
        const root = self.map.get(".") orelse return 0;
        return root.items.len;
    }

    fn entriesFor(self: *const DirectoryTree, directory: []const u8) ?[]const TreeEntry {
        const entries = self.map.getPtr(directory) orelse return null;
        return entries.items;
    }

    fn add(self: *DirectoryTree, relative_path: []const u8) Allocator.Error!void {
        const owned = try self.allocator.dupe(u8, relative_path);
        try self.addOwned(owned);
    }

    fn addOwned(self: *DirectoryTree, relative_path: []const u8) Allocator.Error!void {
        const basename = baseName(relative_path);
        const directory = dirName(relative_path);
        try self.ensureDirectory(directory);
        const entries = self.map.getPtr(directory) orelse return error.OutOfMemory;
        try entries.append(.{ .relative_path = relative_path, .basename = basename });
    }

    fn ensureDirectory(self: *DirectoryTree, directory: []const u8) Allocator.Error!void {
        if (self.map.contains(directory)) return;
        try self.map.put(directory, std.array_list.Managed(TreeEntry).init(self.allocator));
        if (std.mem.eql(u8, directory, ".")) return;
        try self.addOwned(directory);
    }
};

const FolderExcludes = struct {
    relative: glob.ParsedExcludeExpression,
    ignore_case: bool,
    nested_roots: []const []const u8,
    exceptions: []const []const u8,
    merged_entries: std.array_list.Managed(glob.ExcludeEntry),

    fn init(
        allocator: Allocator,
        arena: Allocator,
        entries: []const glob.ExcludeEntry,
        folder_queries: []const search.FolderQuery,
        root: []const u8,
        ignore_case: bool,
    ) !FolderExcludes {
        var merged = std.array_list.Managed(glob.ExcludeEntry).init(allocator);
        errdefer merged.deinit();
        try merged.appendSlice(entries);

        var nested_roots = std.array_list.Managed([]const u8).init(arena);
        for (folder_queries) |other| {
            if (std.mem.eql(u8, other.folder, root)) continue;
            if (!isEqualOrParent(other.folder, root, ignore_case)) continue;
            const relative = other.folder[root.len..];
            const trimmed = std.mem.trimStart(u8, relative, "/\\");
            if (trimmed.len == 0) continue;
            const owned = try arena.dupe(u8, trimmed);
            try nested_roots.append(owned);
            try merged.append(.{ .pattern = owned, .enabled = true });
        }

        // Absolute excludes are passed to ripgrep as-is. The sibling-clause
        // post filter only needs the relative expression, mirroring upstream's
        // relative half of `AbsoluteAndRelativeParsedExpression`.
        var relative = try glob.ParsedExcludeExpression.init(arena, merged.items, .{
            .ignore_case = ignore_case,
        });
        errdefer relative.deinit();

        return .{
            .relative = relative,
            .ignore_case = ignore_case,
            .nested_roots = nested_roots.items,
            .exceptions = relative.exceptions,
            .merged_entries = merged,
        };
    }

    fn deinit(self: *FolderExcludes) void {
        self.relative.deinit();
        self.merged_entries.deinit();
    }

    fn mergedEntries(self: *FolderExcludes) []const glob.ExcludeEntry {
        return self.merged_entries.items;
    }

    fn hasSiblingClauses(self: *const FolderExcludes) bool {
        return self.relative.sibling_rules.len > 0;
    }

    fn isExcepted(self: *const FolderExcludes, relative_path: []const u8, basename: ?[]const u8) bool {
        return self.relative.isExcepted(relative_path, basename);
    }

    fn isNestedRoot(self: *const FolderExcludes, relative_path: []const u8) bool {
        for (self.nested_roots) |nested| {
            if (isEqualOrParent(relative_path, nested, self.ignore_case)) return true;
        }
        return false;
    }
};

fn buildInclude(
    arena: Allocator,
    query: *const search.FileQuery,
    folder_query: search.FolderQuery,
) !?glob.Expression {
    const source = folder_query.include_pattern orelse query.include_pattern orelse return null;
    const pieces = try ripgrep.splitGlobList(arena, source);
    if (pieces.len == 0) return null;
    return try glob.Expression.init(arena, pieces, .{
        .ignore_case = query.ignore_glob_case or folder_query.ignore_glob_case,
    });
}

fn includeMatches(include: ?glob.Expression, relative_path: []const u8) bool {
    const expression = include orelse return true;
    if (expression.isEmpty()) return true;
    if (expression.matches(relative_path)) return true;
    // A basename-only include pattern (`*.js`) matches at any depth upstream.
    return expression.matches(baseName(relative_path));
}

fn makeSearchPath(allocator: Allocator, folder_query: search.FolderQuery, relative_path: []const u8) ![]u8 {
    const name = folder_query.folder_name orelse return allocator.dupe(u8, relative_path);
    return std.fs.path.join(allocator, &.{ name, relative_path });
}

fn skipSetFor(allocator: Allocator, paths: []const []u8) !*std.StringHashMap(void) {
    const set = try allocator.create(std.StringHashMap(void));
    errdefer allocator.destroy(set);
    set.* = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();
    for (paths) |path| try set.put(path, {});
    return set;
}

fn baseName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0) : (end -= 1) {
        if (isSeparator(path[end - 1])) return path[end..];
    }
    return path;
}

fn dirName(path: []const u8) []const u8 {
    const basename = baseName(path);
    if (basename.len == path.len) return ".";
    const end = path.len - basename.len;
    const directory = std.mem.trimEnd(u8, path[0..end], "/\\");
    return if (directory.len == 0) "." else directory;
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn pathEquals(a: []const u8, b: []const u8, ignore_case: bool) bool {
    if (a.len != b.len) return false;
    if (!ignore_case) return std.mem.eql(u8, a, b);
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn isEqualOrParent(path: []const u8, parent: []const u8, ignore_case: bool) bool {
    if (pathEquals(path, parent, ignore_case)) return true;
    if (path.len <= parent.len) return false;
    const prefix = path[0..parent.len];
    if (!pathEquals(prefix, parent, ignore_case)) return false;
    return isSeparator(path[parent.len]);
}

test "FileWalker: baseName, dirName and equal-or-parent" {
    try std.testing.expectEqualStrings("file.txt", baseName("a/b/file.txt"));
    try std.testing.expectEqualStrings("file.txt", baseName("a\\b\\file.txt"));
    try std.testing.expectEqualStrings("a/b", dirName("a/b/file.txt"));
    try std.testing.expectEqualStrings(".", dirName("file.txt"));
    try std.testing.expect(isEqualOrParent("/a/b/c", "/a/b", false));
    try std.testing.expect(!isEqualOrParent("/a/bc", "/a/b", false));
    try std.testing.expect(isEqualOrParent("/A/B/C", "/a/b", true));
}
