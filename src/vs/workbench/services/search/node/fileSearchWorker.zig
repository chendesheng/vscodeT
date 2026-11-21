// Terminal adaptation of the quick-open file-search cache in
// `src/vs/workbench/contrib/search/browser/anythingQuickAccess.ts` and
// `src/vs/workbench/contrib/search/common/cacheState.ts`.
//
// Upstream quick open calls `ISearchService.fileSearch`; the search process
// runs `rg --files` once and the browser filters the cached listing for each
// keystroke. The terminal has no separate search process, so this worker owns
// one background thread: `beginSession` runs one `rg --files` listing per
// picker session, and `request` filters and scores the cached raw paths with
// the shared fuzzy scorer. The event-loop thread only publishes the worker
// result into the picker arena.
//
// Latest request wins: requests carry a generation, scoring checks it between
// cache entries, and only the newest result is published. Session changes bump
// a second generation so a listing is discarded when the picker hides, the
// workspace changes, or a new session starts. All strings in a published
// result are owned by the worker until `takeResult` transfers them.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const glob = @import("../../../../base/common/glob.zig");
const filters = @import("../../../../base/common/filters.zig");
const fuzzy_scorer = @import("../../../../base/common/fuzzyScorer.zig");
const search = @import("../common/search.zig");
const file_search = @import("./fileSearch.zig");
const FileWalker = file_search.FileWalker;
const WalkOutcome = file_search.WalkOutcome;
const time_compat = @import("../../../../base/common/timeCompat.zig");

pub const MAX_RESULTS: usize = 512;
pub const DEFAULT_MAX_CACHED_FILES: usize = 200_000;
pub const MISSING_RIPGREP_MESSAGE = "Go to File requires ripgrep (`rg`) on PATH";

pub const Options = struct {
    /// Executable resolved from `PATH`. Tests inject a fake command here.
    rg_path: []const u8 = "rg",
    threads: ?usize = null,
    max_cached_files: usize = DEFAULT_MAX_CACHED_FILES,
};

pub const Result = struct {
    allocator: Allocator,
    filter: []u8,
    matches: []search.FileMatch,
    /// Present when the listing failed. The provider reports it once and then
    /// clears the busy state.
    error_message: ?[]u8,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.filter);
        for (self.matches) |*match| match.deinit();
        self.allocator.free(self.matches);
        if (self.error_message) |message| self.allocator.free(message);
    }
};

const Folder = struct {
    resource: []u8,
    name: []u8,
};

const Session = struct {
    allocator: Allocator,
    folders: []Folder,
    excludes: []glob.ExcludeEntry,
    settings: search.FileSearchSettings,

    fn init(
        allocator: Allocator,
        folders: []const search.FolderInfo,
        excludes: []const glob.ExcludeEntry,
        settings: search.FileSearchSettings,
    ) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        const owned_folders = try allocator.alloc(Folder, folders.len);
        errdefer allocator.free(owned_folders);
        var copied_folders: usize = 0;
        errdefer for (owned_folders[0..copied_folders]) |folder| {
            allocator.free(folder.resource);
            allocator.free(folder.name);
        };
        for (folders, 0..) |folder, index| {
            const resource = try allocator.dupe(u8, folder.resource);
            errdefer allocator.free(resource);
            const name = try allocator.dupe(u8, folder.name);
            errdefer allocator.free(name);
            owned_folders[index] = .{ .resource = resource, .name = name };
            copied_folders += 1;
        }

        const owned_excludes = try allocator.alloc(glob.ExcludeEntry, excludes.len);
        errdefer allocator.free(owned_excludes);
        var copied_excludes: usize = 0;
        errdefer for (owned_excludes[0..copied_excludes]) |entry| {
            allocator.free(entry.pattern);
            if (entry.when) |when| allocator.free(when);
        };
        for (excludes, 0..) |entry, index| {
            const pattern = try allocator.dupe(u8, entry.pattern);
            errdefer allocator.free(pattern);
            const when = if (entry.when) |value| try allocator.dupe(u8, value) else null;
            owned_excludes[index] = .{ .pattern = pattern, .enabled = entry.enabled, .when = when };
            copied_excludes += 1;
        }

        self.* = .{
            .allocator = allocator,
            .folders = owned_folders,
            .excludes = owned_excludes,
            .settings = settings,
        };
        return self;
    }

    fn deinit(self: *Session) void {
        for (self.folders) |folder| {
            self.allocator.free(folder.resource);
            self.allocator.free(folder.name);
        }
        self.allocator.free(self.folders);
        for (self.excludes) |entry| {
            self.allocator.free(entry.pattern);
            if (entry.when) |when| self.allocator.free(when);
        }
        self.allocator.free(self.excludes);
        self.allocator.destroy(self);
    }
};

const CacheEntry = struct {
    raw: search.RawFileMatch,
    path: []u8,
    description: []u8,

    fn deinit(self: *CacheEntry, allocator: Allocator) void {
        self.raw.deinit(allocator);
        allocator.free(self.path);
        allocator.free(self.description);
    }
};

const Listing = struct {
    allocator: Allocator,
    /// Arena that owns every string in `cache` and `error_message`. It is
    /// transferred to the worker on success and destroyed with the session.
    cache_allocator: Allocator,
    arena: ?*std.heap.ArenaAllocator = null,
    cache: []CacheEntry,
    error_message: ?[]u8,

    fn deinit(self: *Listing) void {
        for (self.cache) |*entry| entry.deinit(self.cache_allocator);
        self.cache_allocator.free(self.cache);
        if (self.error_message) |message| self.cache_allocator.free(message);
        if (self.arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
        }
    }
};

pub const FileSearchWorker = struct {
    allocator: Allocator,
    /// Child processes and pipe reads use a dedicated threaded Io. Callers may
    /// pass the global single-threaded Io (the workbench does), which is not
    /// safe for concurrent spawns from the worker thread.
    io_state: std.Io.Threaded,
    io: Io,
    rg_path: []u8,
    threads: ?usize,
    max_cached_files: usize,

    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    thread: ?std.Thread = null,
    stop: bool = false,

    session_epoch: std.atomic.Value(u64) = .init(0),
    request_epoch: std.atomic.Value(u64) = .init(0),

    /// Main-thread-owned until the worker takes it.
    pending_session: ?*Session = null,
    pending_filter: ?[]u8 = null,

    active_session: ?*Session = null,
    active_session_epoch: u64 = 0,
    active_walker: ?*FileWalker = null,
    /// One raw path record per workspace file, not one picker item per file.
    /// Every keystroke must rank all cached candidates; `computeResult` then
    /// materializes at most `MAX_RESULTS` owned result records, and only those
    /// become picker items (the widget itself paints only its visible rows).
    cache: []CacheEntry = &.{},
    cache_allocator: Allocator = undefined,
    cache_arena: ?*std.heap.ArenaAllocator = null,
    cache_ready: bool = false,
    cache_error: ?[]u8 = null,
    error_announced: bool = false,
    listing: bool = false,
    computing: bool = false,
    result: ?*Result = null,

    pub fn init(allocator: Allocator, options: Options) !*FileSearchWorker {
        const self = try allocator.create(FileSearchWorker);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io_state = undefined,
            .io = undefined,
            .rg_path = try allocator.dupe(u8, options.rg_path),
            .threads = options.threads,
            .max_cached_files = options.max_cached_files,
            .cache_allocator = allocator,
        };
        errdefer allocator.free(self.rg_path);
        self.io_state = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = processEnviron() });
        self.io = self.io_state.io();
        errdefer self.io_state.deinit();
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
        return self;
    }

    pub fn deinit(self: *FileSearchWorker) void {
        self.endSession();
        self.mutex.lockUncancelable(self.io);
        self.stop = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.io_state.deinit();
        self.allocator.free(self.rg_path);
        self.allocator.destroy(self);
    }

    /// Starts a new listing session. The worker owns copies of `folders` and
    /// `excludes`; the caller may free its slices when this returns.
    pub fn beginSession(
        self: *FileSearchWorker,
        folders: []const search.FolderInfo,
        excludes: []const glob.ExcludeEntry,
        settings: search.FileSearchSettings,
    ) !void {
        const session = try Session.init(self.allocator, folders, excludes, settings);

        self.mutex.lockUncancelable(self.io);
        if (self.pending_session) |old| old.deinit();
        self.pending_session = session;
        if (self.pending_filter) |filter| self.allocator.free(filter);
        self.pending_filter = null;
        if (self.result) |result| {
            result.deinit();
            self.allocator.destroy(result);
            self.result = null;
        }
        _ = self.session_epoch.fetchAdd(1, .release);
        _ = self.request_epoch.fetchAdd(1, .release);
        // Interrupt a listing that belongs to the previous session. The walker
        // is only cleared by this worker under the same mutex.
        if (self.active_walker) |walker| walker.cancel();
        self.listing = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    /// Queues the newest quick-open filter. Replaces any still-pending filter.
    pub fn request(self: *FileSearchWorker, filter: []const u8) !void {
        const copy = try self.allocator.dupe(u8, filter);
        self.mutex.lockUncancelable(self.io);
        if (self.pending_filter) |old| self.allocator.free(old);
        self.pending_filter = copy;
        if (self.result) |result| {
            // A result for an older filter would never be consumed.
            result.deinit();
            self.allocator.destroy(result);
            self.result = null;
        }
        _ = self.request_epoch.fetchAdd(1, .release);
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    pub fn hasResult(self: *FileSearchWorker, filter: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.result orelse return false;
        return std.mem.eql(u8, result.filter, filter);
    }

    pub fn hasAnyResult(self: *FileSearchWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.result != null;
    }

    /// Waits up to `timeout_ms` for a published result without consuming it.
    pub fn waitForResult(self: *FileSearchWorker, timeout_ms: i64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.result != null) return true;
        if (timeout_ms <= 0) return false;
        const deadline = time_compat.milliTimestamp() + timeout_ms;
        while (self.result == null) {
            const now = time_compat.milliTimestamp();
            if (now >= deadline) break;
            const remaining = @max(deadline - now, 1);
            self.condition.waitTimeout(self.io, &self.mutex, .{
                .duration = .{ .raw = std.Io.Duration.fromMilliseconds(remaining), .clock = .awake },
            }) catch |err| switch (err) {
                error.Timeout => {},
                else => break,
            };
        }
        return self.result != null;
    }

    /// Transfers the published result to the caller.
    pub fn takeResult(self: *FileSearchWorker, timeout_ms: i64) ?Result {
        _ = self.waitForResult(timeout_ms);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.result orelse return null;
        self.result = null;
        const value = result.*;
        self.allocator.destroy(result);
        return value;
    }

    /// Transfers the result only when it belongs to `filter`.
    pub fn takeResultFor(self: *FileSearchWorker, filter: []const u8, timeout_ms: i64) ?Result {
        _ = self.waitForResult(timeout_ms);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.result orelse return null;
        if (!std.mem.eql(u8, result.filter, filter)) return null;
        self.result = null;
        const value = result.*;
        self.allocator.destroy(result);
        return value;
    }

    pub fn isBusy(self: *FileSearchWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.listing or self.computing or self.pending_session != null or self.pending_filter != null;
    }

    /// Cancels the active listing and discards the session cache/result. The
    /// caller blocks only until the child has been killed and the worker has
    /// cleared its state, so the workspace snapshot can be released safely.
    pub fn endSession(self: *FileSearchWorker) void {
        self.mutex.lockUncancelable(self.io);
        _ = self.session_epoch.fetchAdd(1, .release);
        if (self.pending_session) |session| {
            session.deinit();
            self.pending_session = null;
        }
        if (self.pending_filter) |filter| {
            self.allocator.free(filter);
            self.pending_filter = null;
        }
        if (self.result) |result| {
            result.deinit();
            self.allocator.destroy(result);
            self.result = null;
        }
        if (self.active_walker) |walker| walker.cancel();
        self.condition.broadcast(self.io);

        while (self.listing or self.computing or self.active_session != null or self.cache_ready or
            self.cache.len > 0 or self.pending_session != null or self.pending_filter != null)
        {
            // Keep killing retries that raced with the first cancel.
            if (self.active_walker) |walker| walker.cancel();
            self.condition.waitTimeout(self.io, &self.mutex, .{
                .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20), .clock = .awake },
            }) catch |err| switch (err) {
                error.Timeout => {},
                else => break,
            };
        }
        self.mutex.unlock(self.io);
    }

    fn workerLoop(self: *FileSearchWorker) void {
        self.mutex.lockUncancelable(self.io);
        while (true) {
            if (self.stop) {
                self.clearWorkerStateLocked();
                self.mutex.unlock(self.io);
                return;
            }

            const epoch_now = self.session_epoch.load(.acquire);
            if (self.active_session != null and self.active_session_epoch != epoch_now) {
                self.clearSessionStateLocked();
                self.condition.broadcast(self.io);
                continue;
            }

            if (self.pending_session) |session| {
                self.pending_session = null;
                self.clearSessionStateLocked();
                self.active_session = session;
                self.active_session_epoch = epoch_now;
                self.cache_ready = false;
                self.cache_error = null;
                self.error_announced = false;
                self.listing = true;
                const epoch = epoch_now;
                self.mutex.unlock(self.io);

                var listing = self.buildListing(session, epoch);
                self.mutex.lockUncancelable(self.io);

                if (self.session_epoch.load(.acquire) != epoch) {
                    listing.deinit();
                    self.clearSessionStateLocked();
                } else {
                    self.cache = listing.cache;
                    self.cache_allocator = listing.cache_allocator;
                    self.cache_arena = listing.arena;
                    self.cache_error = listing.error_message;
                    self.cache_ready = true;
                    self.listing = false;
                    listing.cache = &.{};
                    listing.error_message = null;
                    listing.arena = null;
                }
                self.condition.broadcast(self.io);
                continue;
            }

            if (self.active_session != null and self.cache_ready) {
                if (self.pending_filter) |filter| {
                    self.pending_filter = null;
                    self.computing = true;
                    const session_epoch = self.session_epoch.load(.acquire);
                    const request_epoch = self.request_epoch.load(.acquire);
                    self.mutex.unlock(self.io);

                    self.computeResult(filter, session_epoch, request_epoch);

                    self.mutex.lockUncancelable(self.io);
                    self.computing = false;
                    self.allocator.free(filter);
                    self.condition.broadcast(self.io);
                    continue;
                }
            }

            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    fn emptyListing(self: *FileSearchWorker, arena: ?*std.heap.ArenaAllocator, message: ?[]u8) Listing {
        if (arena) |owned| {
            owned.deinit();
            self.allocator.destroy(owned);
        }
        return .{
            .allocator = self.allocator,
            .cache_allocator = self.allocator,
            .cache = &.{},
            .error_message = message,
        };
    }

    fn buildListing(self: *FileSearchWorker, session: *Session, session_epoch: u64) Listing {
        if (session.folders.len == 0) return self.emptyListing(null, null);

        var folder_infos = std.array_list.Managed(search.FolderInfo).init(self.allocator);
        defer folder_infos.deinit();
        for (session.folders) |folder| {
            folder_infos.append(.{ .resource = folder.resource, .name = folder.name }) catch {
                return self.emptyListing(null, null);
            };
        }

        // The listing is the hot path: a large checkout has one allocation per
        // path field. A per-session arena turns those into a handful of chunk
        // allocations, which matters in debug builds where the general-purpose
        // allocator records stack traces for every allocation.
        const arena = self.allocator.create(std.heap.ArenaAllocator) catch return self.emptyListing(null, null);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        const arena_allocator = arena.allocator();

        // Multi-root listings prefix result search paths with the folder name,
        // mirroring `QueryBuilder.commonQuery`.
        var query = search.FileQuery.init(self.allocator, folder_infos.items, .{
            .max_results = self.max_cached_files,
            .settings = session.settings,
        }) catch {
            return self.emptyListing(arena, null);
        };
        defer query.deinit();

        var walker = FileWalker.init(arena_allocator, self.io, &query, self.rg_path) catch |err| {
            const message: ?[]u8 = std.fmt.allocPrint(
                self.allocator,
                "Go to File could not prepare the search: {s}",
                .{@errorName(err)},
            ) catch null;
            return self.emptyListing(arena, message);
        };
        defer walker.deinit();

        self.mutex.lockUncancelable(self.io);
        self.active_walker = &walker;
        self.mutex.unlock(self.io);

        const outcome = walker.walk() catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.active_walker = null;
            self.mutex.unlock(self.io);
            if (self.session_epoch.load(.acquire) != session_epoch) {
                return self.emptyListing(arena, null);
            }
            const message: ?[]u8 = switch (err) {
                error.RipgrepNotFound => self.allocator.dupe(u8, MISSING_RIPGREP_MESSAGE) catch null,
                error.Canceled => null,
                else => std.fmt.allocPrint(
                    self.allocator,
                    "Go to File could not run ripgrep: {s}",
                    .{@errorName(err)},
                ) catch null,
            };
            return self.emptyListing(arena, message);
        };

        self.mutex.lockUncancelable(self.io);
        self.active_walker = null;
        self.mutex.unlock(self.io);

        return self.adoptListing(session, outcome, arena, arena_allocator);
    }

    fn adoptListing(
        self: *FileSearchWorker,
        session: *Session,
        outcome: WalkOutcome,
        arena: *std.heap.ArenaAllocator,
        arena_allocator: Allocator,
    ) Listing {
        var mutable = outcome;
        var cache = std.array_list.Managed(CacheEntry).init(arena_allocator);
        defer cache.deinit();

        for (mutable.matches) |match| {
            const description = describeFile(arena_allocator, session, &match) catch {
                var skipped = match;
                skipped.deinit(arena_allocator);
                continue;
            };
            const path = std.fs.path.join(arena_allocator, &.{ match.base, match.relative_path }) catch {
                arena_allocator.free(description);
                var skipped = match;
                skipped.deinit(arena_allocator);
                continue;
            };
            cache.append(.{ .raw = match, .path = path, .description = description }) catch {
                arena_allocator.free(description);
                arena_allocator.free(path);
                var skipped = match;
                skipped.deinit(arena_allocator);
                continue;
            };
        }
        arena_allocator.free(mutable.matches);
        mutable.matches = &.{};

        const error_message = if (mutable.errors.len > 0)
            arena_allocator.dupe(u8, mutable.errors[0]) catch null
        else
            null;

        for (mutable.errors) |message| arena_allocator.free(message);
        arena_allocator.free(mutable.errors);
        mutable.errors = &.{};

        return .{
            .allocator = self.allocator,
            .cache_allocator = arena_allocator,
            .arena = arena,
            .cache = cache.toOwnedSlice() catch &.{},
            .error_message = error_message,
        };
    }

    fn computeResult(
        self: *FileSearchWorker,
        filter: []const u8,
        session_epoch: u64,
        request_epoch: u64,
    ) void {
        if (self.session_epoch.load(.acquire) != session_epoch or
            self.request_epoch.load(.acquire) != request_epoch)
        {
            return;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const prepared = fuzzy_scorer.prepareQuery(arena_allocator, filter) catch return;
        var scored = std.array_list.Managed(ScoredEntry).init(arena_allocator);

        if (prepared.normalized.len > 0) {
            for (self.cache, 0..) |*entry, index| {
                if ((index & 0xFF) == 0) {
                    if (self.session_epoch.load(.acquire) != session_epoch or
                        self.request_epoch.load(.acquire) != request_epoch)
                    {
                        return;
                    }
                }
                const score = fuzzy_scorer.scoreItemFuzzy(
                    arena_allocator,
                    entry,
                    &prepared,
                    true,
                    CacheAccessor.accessor(),
                ) catch continue;
                if (score.score == 0) continue;
                const label_matches = convertMatches(arena_allocator, score.label_match) catch continue;
                const description_matches = convertMatches(arena_allocator, score.description_match) catch continue;
                scored.append(.{
                    .entry = entry,
                    .score = score.score,
                    .label_matches = label_matches,
                    .description_matches = description_matches,
                }) catch continue;
            }
        }

        std.mem.sort(ScoredEntry, scored.items, {}, struct {
            fn lessThan(_: void, a: ScoredEntry, b: ScoredEntry) bool {
                if (a.score != b.score) return a.score > b.score;
                const a_label = a.entry.raw.basename;
                const b_label = b.entry.raw.basename;
                if (a_label.len != b_label.len) return a_label.len < b_label.len;
                if (a.entry.path.len != b.entry.path.len) return a.entry.path.len < b.entry.path.len;
                return std.mem.lessThan(u8, a.entry.path, b.entry.path);
            }
        }.lessThan);

        const count = @min(scored.items.len, MAX_RESULTS);
        var built = std.array_list.Managed(search.FileMatch).init(self.allocator);
        var matches_owned = false;
        defer {
            if (!matches_owned) {
                for (built.items) |*match| match.deinit();
            }
            built.deinit();
        }

        for (scored.items[0..count]) |item| {
            const path = self.allocator.dupe(u8, item.entry.path) catch break;
            const label = self.allocator.dupe(u8, item.entry.raw.basename) catch {
                self.allocator.free(path);
                break;
            };
            const description = self.allocator.dupe(u8, item.entry.description) catch {
                self.allocator.free(path);
                self.allocator.free(label);
                break;
            };
            const label_matches = self.allocator.dupe(filters.Match, item.label_matches) catch {
                self.allocator.free(path);
                self.allocator.free(label);
                self.allocator.free(description);
                break;
            };
            const description_matches = self.allocator.dupe(filters.Match, item.description_matches) catch {
                self.allocator.free(path);
                self.allocator.free(label);
                self.allocator.free(description);
                self.allocator.free(label_matches);
                break;
            };
            built.append(.{
                .allocator = self.allocator,
                .path = path,
                .label = label,
                .description = description,
                .label_matches = label_matches,
                .description_matches = description_matches,
            }) catch {
                self.allocator.free(path);
                self.allocator.free(label);
                self.allocator.free(description);
                self.allocator.free(label_matches);
                self.allocator.free(description_matches);
                break;
            };
        }

        const matches = built.toOwnedSlice() catch return;
        matches_owned = true;

        const result = self.allocator.create(Result) catch {
            for (matches) |*match| match.deinit();
            self.allocator.free(matches);
            return;
        };
        const filter_copy = self.allocator.dupe(u8, filter) catch {
            self.allocator.destroy(result);
            for (matches) |*match| match.deinit();
            self.allocator.free(matches);
            return;
        };
        var error_message: ?[]u8 = null;
        if (self.cache_error) |message| {
            if (!self.error_announced) error_message = self.allocator.dupe(u8, message) catch null;
        }
        result.* = .{
            .allocator = self.allocator,
            .filter = filter_copy,
            .matches = matches,
            .error_message = error_message,
        };

        self.mutex.lockUncancelable(self.io);
        if (self.session_epoch.load(.acquire) != session_epoch or
            self.request_epoch.load(.acquire) != request_epoch)
        {
            self.mutex.unlock(self.io);
            result.deinit();
            self.allocator.destroy(result);
            return;
        }
        if (self.result) |old| {
            old.deinit();
            self.allocator.destroy(old);
        }
        if (result.error_message != null) self.error_announced = true;
        self.result = result;
        self.mutex.unlock(self.io);
    }

    fn clearSessionStateLocked(self: *FileSearchWorker) void {
        if (self.active_session) |session| {
            session.deinit();
            self.active_session = null;
        }
        for (self.cache) |*entry| entry.deinit(self.cache_allocator);
        if (self.cache.len > 0) self.cache_allocator.free(self.cache);
        self.cache = &.{};
        if (self.cache_error) |message| self.cache_allocator.free(message);
        self.cache_error = null;
        self.cache_allocator = self.allocator;
        if (self.cache_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
            self.cache_arena = null;
        }
        self.cache_ready = false;
        self.error_announced = false;
        self.listing = false;
        self.computing = false;
        self.active_session_epoch = 0;
        if (self.active_walker) |walker| walker.cancel();
    }

    fn clearWorkerStateLocked(self: *FileSearchWorker) void {
        self.clearSessionStateLocked();
        if (self.pending_session) |session| {
            session.deinit();
            self.pending_session = null;
        }
        if (self.pending_filter) |filter| {
            self.allocator.free(filter);
            self.pending_filter = null;
        }
        if (self.result) |result| {
            result.deinit();
            self.allocator.destroy(result);
            self.result = null;
        }
    }
};

/// `std.process.spawn` resolves bare executable names against the `Io`'s
/// environment, so the worker's dedicated instance must carry the process
/// environment to find `rg` on `PATH`.
fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => if (builtin.link_libc)
            .{ .block = .{ .slice = @ptrCast(@as([:null]?[*:0]u8, std.mem.span(std.c.environ))) } }
        else
            .empty,
    };
}

const ScoredEntry = struct {
    entry: *CacheEntry,
    score: i64,
    label_matches: []filters.Match,
    description_matches: []filters.Match,
};

const CacheAccessor = struct {
    fn accessor() fuzzy_scorer.ItemAccessor {
        return .{
            .context = @ptrFromInt(@alignOf(usize)),
            .get_item_label = label,
            .get_item_description = description,
            .get_item_path = path,
        };
    }

    fn label(_: *anyopaque, item: *const anyopaque) ?[]const u8 {
        const entry: *const CacheEntry = @ptrCast(@alignCast(item));
        return entry.raw.basename;
    }

    fn description(_: *anyopaque, item: *const anyopaque) ?[]const u8 {
        const entry: *const CacheEntry = @ptrCast(@alignCast(item));
        return entry.description;
    }

    fn path(_: *anyopaque, item: *const anyopaque) ?[]const u8 {
        const entry: *const CacheEntry = @ptrCast(@alignCast(item));
        return entry.path;
    }
};

fn convertMatches(allocator: Allocator, matches: ?[]const fuzzy_scorer.Match) ![]filters.Match {
    const source = matches orelse return allocator.alloc(filters.Match, 0);
    const result = try allocator.alloc(filters.Match, source.len);
    for (source, 0..) |match, index| {
        result[index] = .{ .start = match.start, .end = match.end };
    }
    return result;
}

fn describeFile(allocator: Allocator, session: *const Session, match: *const search.RawFileMatch) ![]u8 {
    const directory = relativeDirectory(match.base, match.relative_path);
    if (session.folders.len > 1) {
        const name = folderName(session, match.base) orelse "";
        if (directory.len == 0) return allocator.dupe(u8, name);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, directory });
    }
    return allocator.dupe(u8, directory);
}

fn folderName(session: *const Session, base: []const u8) ?[]const u8 {
    for (session.folders) |folder| {
        if (std.mem.eql(u8, folder.resource, base)) return folder.name;
    }
    return null;
}

/// The relative directory that contains `relative_path`; empty for a root file.
fn relativeDirectory(base: []const u8, relative_path: []const u8) []const u8 {
    _ = base;
    var index = relative_path.len;
    while (index > 0) : (index -= 1) {
        const ch = relative_path[index - 1];
        if (ch == '/' or ch == '\\') return relative_path[0 .. index - 1];
    }
    return "";
}
