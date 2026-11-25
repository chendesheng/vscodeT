// Terminal adaptation of the ripgrep text-search process boundary for the
// Search view. Upstream runs `RipgrepTextSearchEngine` in the search process
// and streams results to the workbench. The TUI owns one worker thread here:
// it spawns rg per workspace folder, streams JSON through
// `ripgrepTextSearchEngine.Parser`, and queues raw per-file results for the
// main thread to filter and publish.
//
// Filtering, open-editor results and result trimming live in `SearchService`;
// this worker only handles process lifetime, parsing, folder traversal and
// symlink-loop retries.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const search = @import("../common/search.zig");
const glob = @import("../../../../base/common/glob.zig");
const ripgrep = @import("./ripgrepFileSearch.zig");
const engine = @import("./ripgrepTextSearchEngine.zig");

const read_chunk_size = 64 * 1024;
const queue_limit = 256;

pub const MISSING_RIPGREP_MESSAGE = "Text search requires ripgrep (`rg`) on PATH";

pub const Item = struct {
    folder_index: usize,
    exception_run: bool = false,
    file: engine.ParsedFile,

    pub fn deinit(self: *Item) void {
        self.file.deinit();
    }
};

const RunningChild = struct {
    child: std.process.Child,
    io: Io,
    killed: bool = false,
    reaping: bool = false,
};

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

pub const TextSearchWorker = struct {
    allocator: Allocator,
    query: *const search.TextQuery,
    rg_path: []u8,
    threads: ?usize,

    io_state: std.Io.Threaded,
    io: Io,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    thread: ?std.Thread = null,
    finished: bool = false,
    progress: ?search.SearchProgressListener = null,

    queue: std.array_list.Managed(Item),
    messages: std.array_list.Managed(search.SearchMessage),
    cancelled: std.atomic.Value(bool) = .init(false),
    child_mutex: Io.Mutex = .init,
    active_child: ?*RunningChild = null,
    failure: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: Allocator, query: *const search.TextQuery, rg_path: []const u8) !*TextSearchWorker {
        const self = try allocator.create(TextSearchWorker);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .query = query,
            .rg_path = try allocator.dupe(u8, rg_path),
            .threads = null,
            .io_state = undefined,
            .io = undefined,
            .queue = std.array_list.Managed(Item).init(allocator),
            .messages = std.array_list.Managed(search.SearchMessage).init(allocator),
        };
        errdefer allocator.free(self.rg_path);
        self.io_state = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = processEnviron() });
        self.io = self.io_state.io();
        errdefer self.io_state.deinit();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn deinit(self: *TextSearchWorker) void {
        self.cancel();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.mutex.lockUncancelable(self.io);
        for (self.queue.items) |*item| item.deinit();
        self.queue.deinit();
        for (self.messages.items) |message| self.allocator.free(message.text);
        self.messages.deinit();
        self.mutex.unlock(self.io);
        self.io_state.deinit();
        self.allocator.free(self.rg_path);
        self.allocator.destroy(self);
    }

    pub fn cancel(self: *TextSearchWorker) void {
        self.cancelled.store(true, .release);
        self.killActive();
        self.mutex.lockUncancelable(self.io);
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    /// Transfers up to `max_files` queued files to the caller. Returns an
    /// empty slice while the worker is still running.
    pub fn takeBatch(self: *TextSearchWorker, allocator: Allocator, max_files: usize) ![]Item {
        var result = std.array_list.Managed(Item).init(allocator);
        errdefer result.deinit();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const count = @min(max_files, self.queue.items.len);
        for (self.queue.items[0..count]) |item| try result.append(item);
        if (count > 0) {
            const remaining = self.queue.items.len - count;
            if (remaining > 0) {
                std.mem.copyForwards(Item, self.queue.items[0..remaining], self.queue.items[count..]);
            }
            self.queue.items.len = remaining;
            self.condition.broadcast(self.io);
        }
        return result.toOwnedSlice();
    }

    pub fn setProgressListener(self: *TextSearchWorker, listener: search.SearchProgressListener) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.progress = listener;
        if (self.finished or self.queue.items.len > 0) listener.notify(listener.context);
    }

    pub fn isFinished(self: *TextSearchWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.finished;
    }

    pub fn hasQueued(self: *TextSearchWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.queue.items.len > 0;
    }

    /// Waits up to `timeout_ms` for work or completion.
    pub fn waitForWork(self: *TextSearchWorker, timeout_ms: i64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.queue.items.len > 0 or self.finished or self.failure.load(.acquire)) return true;
        if (timeout_ms <= 0) return false;
        const deadline = time_compat.milliTimestamp() + timeout_ms;
        while (!self.finished and !self.failure.load(.acquire) and self.queue.items.len == 0) {
            const now = time_compat.milliTimestamp();
            if (now >= deadline) break;
            self.condition.waitTimeout(self.io, &self.mutex, .{
                .duration = .{ .raw = std.Io.Duration.fromMilliseconds(@max(deadline - now, 1)), .clock = .awake },
            }) catch |err| switch (err) {
                error.Timeout => {},
                else => break,
            };
        }
        return self.queue.items.len > 0 or self.finished or self.failure.load(.acquire);
    }

    /// Takes runtime messages accumulated by the worker.
    pub fn takeMessages(self: *TextSearchWorker, allocator: Allocator) ![]search.SearchMessage {
        _ = allocator;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.messages.toOwnedSlice();
    }

    fn run(self: *TextSearchWorker) void {
        self.work() catch |err| {
            self.addMessageFmt("Text search failed: {s}", .{@errorName(err)}) catch {};
            self.failure.store(true, .release);
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.finished = true;
        self.condition.broadcast(self.io);
        if (self.progress) |listener| listener.notify(listener.context);
    }

    fn work(self: *TextSearchWorker) !void {
        for (self.query.folder_queries, 0..) |folder_query, folder_index| {
            if (self.cancelled.load(.acquire)) return;
            try self.runFolder(folder_query, folder_index);
            if (self.failure.load(.acquire)) return;
        }
    }

    fn runFolder(self: *TextSearchWorker, folder_query: search.FolderQuery, folder_index: usize) !void {
        var exclude_globs = try collectExcludeGlobs(self.allocator, self.query, folder_query);
        defer freeStrings(self.allocator, exclude_globs);
        const exceptions = try collectExceptionGlobs(self.allocator, self.query);
        defer freeStrings(self.allocator, exceptions);

        var reported = std.StringHashMap(usize).init(self.allocator);
        defer {
            var keys = reported.keyIterator();
            while (keys.next()) |key| self.allocator.free(key.*);
            reported.deinit();
        }

        const first = try self.runFolderMode(folder_query, folder_index, false, &exclude_globs, &reported, null, null, false);
        if (self.cancelled.load(.acquire) or self.failure.load(.acquire)) return;
        if (first.retry) {
            _ = self.runFolderMode(folder_query, folder_index, false, &exclude_globs, null, &reported, null, true) catch .{};
            if (self.cancelled.load(.acquire) or self.failure.load(.acquire)) return;
        }
        if (exceptions.len > 0) {
            _ = self.runFolderMode(folder_query, folder_index, true, &exclude_globs, null, null, exceptions, false) catch .{};
            if (self.cancelled.load(.acquire) or self.failure.load(.acquire)) return;
        }
    }

    const ModeResult = struct { retry: bool = false };

    fn runFolderMode(
        self: *TextSearchWorker,
        folder_query: search.FolderQuery,
        folder_index: usize,
        exception_run: bool,
        exclude_globs: *[][]u8,
        track_paths: ?*std.StringHashMap(usize),
        paths_to_skip: ?*const std.StringHashMap(usize),
        exceptions: ?[]const []const u8,
        ignore_symlinks: bool,
    ) !ModeResult {
        var args = try engine.buildArgs(self.allocator, self.query, folder_query, .{
            .threads = self.threads,
            .exclude_exceptions = exceptions,
            .exclude_globs = exclude_globs.*,
            .include_pattern = self.query.include_pattern,
            .ignore_symlinks = ignore_symlinks,
        });
        defer args.deinit();

        const root_path = folder_query.folder;
        const cwd = try self.allocator.dupe(u8, root_path);
        defer self.allocator.free(cwd);

        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.append(self.rg_path);
        try argv.appendSlice(args.args);

        var child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = ripgrep.child_process_group,
            .create_no_window = builtin.os.tag == .windows,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                try self.addMessage(MISSING_RIPGREP_MESSAGE);
                self.failure.store(true, .release);
                return .{};
            },
            else => return err,
        };
        const stdout = child.stdout orelse return error.RipgrepPipeFailure;
        const stderr = child.stderr orelse return error.RipgrepPipeFailure;
        child.stdout = null;
        child.stderr = null;

        const running = try self.allocator.create(RunningChild);
        running.* = .{ .child = child, .io = self.io };
        self.child_mutex.lockUncancelable(self.io);
        self.active_child = running;
        self.child_mutex.unlock(self.io);

        var drain = StderrDrain{
            .io = self.io,
            .file = stderr,
            .capture = ripgrep.StderrCapture.init(self.allocator),
            .detector = ripgrep.SymlinkLoopDetector.init(self.allocator),
        };
        const stderr_thread = std.Thread.spawn(.{}, StderrDrain.run, .{&drain}) catch null;

        var sink = RunSink{
            .worker = self,
            .folder_index = folder_index,
            .exception_run = exception_run,
            .track_paths = track_paths,
            .paths_to_skip = paths_to_skip,
        };
        var parser = engine.Parser.init(
            self.allocator,
            folder_query.folder,
            self.query.preview,
            std.math.maxInt(usize),
            .{ .context = &sink, .on_file = RunSink.onFile },
        );
        defer parser.deinit();

        var buffer: [read_chunk_size]u8 = undefined;
        var read_error: ?anyerror = null;
        read_loop: while (true) {
            if (self.cancelled.load(.acquire)) {
                self.kill(running);
                break;
            }
            if (drain.loop_exceeded.load(.acquire)) {
                self.kill(running);
                break;
            }
            const n = stdout.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    read_error = err;
                    self.kill(running);
                    break;
                },
            };
            if (n == 0) continue;
            parser.handleData(buffer[0..n]) catch |err| {
                read_error = err;
                self.kill(running);
                break :read_loop;
            };
            if (self.cancelled.load(.acquire)) {
                self.kill(running);
                break;
            }
        }
        if (!self.cancelled.load(.acquire) and read_error == null) {
            parser.flush() catch |err| {
                read_error = err;
            };
        }

        if (stderr_thread) |thread| thread.join();
        const loop_exceeded = drain.loop_exceeded.load(.acquire);
        const term = self.finish(running);
        stdout.close(self.io);
        stderr.close(self.io);
        defer {
            drain.capture.deinit();
            drain.detector.deinit();
        }

        if (parser.malformed and !exception_run) {
            self.addMessageFmt("Text search returned malformed ripgrep output", .{}) catch {};
        }
        if (self.cancelled.load(.acquire)) return .{};
        if (read_error) |err| return err;

        if (loop_exceeded and !exception_run) {
            self.addMessageFmt(
                "Symbolic links in '{s}' were not followed because they form too many loops, so results may be incomplete.",
                .{root_path},
            ) catch {};
            return .{ .retry = true };
        }

        const exit_code: u8 = switch (term) {
            .exited => |code| code,
            else => 0,
        };
        if (exit_code > 1) {
            if (engine.errorMessageForDisplay(self.allocator, drain.capture.value())) |display| {
                const text = display.text;
                const is_loop_warning = std.mem.indexOf(u8, text, "File system loop found") != null;
                self.addOwnedMessage(text, if (is_loop_warning) .warning else display.kind) catch self.allocator.free(text);
                if (!is_loop_warning and display.kind == .err) self.failure.store(true, .release);
            }
        }
        return .{};
    }

    fn queueFile(self: *TextSearchWorker, file: engine.ParsedFile, folder_index: usize, exception_run: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.queue.items.len >= queue_limit and !self.cancelled.load(.acquire)) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        if (self.cancelled.load(.acquire)) {
            var mutable = file;
            mutable.deinit();
            return;
        }
        self.queue.append(.{
            .folder_index = folder_index,
            .exception_run = exception_run,
            .file = file,
        }) catch {
            var mutable = file;
            mutable.deinit();
            return error.OutOfMemory;
        };
        if (self.progress) |listener| listener.notify(listener.context);
        self.condition.broadcast(self.io);
    }

    fn kill(self: *TextSearchWorker, running: *RunningChild) void {
        self.child_mutex.lockUncancelable(self.io);
        defer self.child_mutex.unlock(self.io);
        if (!running.killed and !running.reaping) {
            ripgrep.killChild(&running.child, running.io);
            running.killed = true;
        }
    }

    fn killActive(self: *TextSearchWorker) void {
        self.child_mutex.lockUncancelable(self.io);
        defer self.child_mutex.unlock(self.io);
        if (self.active_child) |running| {
            if (!running.killed and !running.reaping) {
                ripgrep.killChild(&running.child, running.io);
                running.killed = true;
            }
        }
    }

    fn finish(self: *TextSearchWorker, running: *RunningChild) std.process.Child.Term {
        self.child_mutex.lockUncancelable(self.io);
        if (running.killed) {
            self.active_child = null;
            self.child_mutex.unlock(self.io);
            self.allocator.destroy(running);
            return .{ .unknown = 0 };
        }
        running.reaping = true;
        self.active_child = null;
        self.child_mutex.unlock(self.io);
        const term = running.child.wait(running.io) catch std.process.Child.Term{ .unknown = 0 };
        self.child_mutex.lockUncancelable(self.io);
        running.reaping = false;
        self.child_mutex.unlock(self.io);
        self.allocator.destroy(running);
        return term;
    }

    fn addMessage(self: *TextSearchWorker, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        self.addOwnedMessage(copy, .err) catch |err| {
            self.allocator.free(copy);
            return err;
        };
    }

    fn addMessageFmt(self: *TextSearchWorker, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        self.addOwnedMessage(text, .warning) catch |err| {
            self.allocator.free(text);
            return err;
        };
    }

    fn addOwnedMessage(self: *TextSearchWorker, text: []u8, kind: search.SearchMessageKind) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.messages.append(.{ .text = text, .kind = kind });
        self.condition.broadcast(self.io);
    }
};

const RunSink = struct {
    worker: *TextSearchWorker,
    folder_index: usize,
    exception_run: bool,
    track_paths: ?*std.StringHashMap(usize),
    paths_to_skip: ?*const std.StringHashMap(usize),

    fn onFile(context: *anyopaque, file: engine.ParsedFile) anyerror!void {
        const self: *RunSink = @ptrCast(@alignCast(context));
        var owned = file;
        if (self.paths_to_skip) |skip| {
            if (skip.get(owned.path)) |count| {
                if (count > 0) {
                    owned.deinit();
                    return;
                }
            }
        }
        if (self.track_paths) |track| {
            if (track.getPtr(owned.path)) |count| {
                count.* += 1;
            } else {
                const key = try owned.allocator.dupe(u8, owned.path);
                errdefer owned.allocator.free(key);
                try track.put(key, 1);
            }
        }
        try self.worker.queueFile(owned, self.folder_index, self.exception_run);
    }
};

fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => if (builtin.link_libc)
            .{ .block = .{ .slice = @ptrCast(@as([:null]?[*:0]u8, std.mem.span(std.c.environ))) } }
        else
            .empty,
    };
}

fn collectExceptionGlobs(allocator: Allocator, query: *const search.TextQuery) ![][]u8 {
    const config_exceptions = try glob.getExcludeExceptions(allocator, query.exclude_entries);
    var result = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (result.items) |value| allocator.free(value);
        result.deinit();
    }
    for (config_exceptions) |value| {
        try result.append(try allocator.dupe(u8, value));
    }
    freeStrings(allocator, config_exceptions);

    const pieces = try ripgrep.splitGlobList(allocator, query.exclude_pattern);
    defer {
        for (pieces) |value| allocator.free(value);
        allocator.free(pieces);
    }
    for (pieces) |value| {
        if (!std.mem.startsWith(u8, value, "!") or value.len == 1) continue;
        try result.append(try allocator.dupe(u8, value[1..]));
    }
    return result.toOwnedSlice();
}

fn collectExcludeGlobs(
    allocator: Allocator,
    query: *const search.TextQuery,
    folder_query: search.FolderQuery,
) ![][]u8 {
    var globs = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (globs.items) |value| allocator.free(value);
        globs.deinit();
    }
    for (query.exclude_entries) |entry| {
        if (!entry.enabled or entry.when != null) continue;
        if (glob.isExcludeException(entry.pattern)) continue;
        try globs.append(try allocator.dupe(u8, entry.pattern));
    }
    const user_excludes = try ripgrep.splitGlobList(allocator, query.exclude_pattern);
    defer {
        for (user_excludes) |value| allocator.free(value);
        allocator.free(user_excludes);
    }
    for (user_excludes) |value| {
        if (value.len == 0 or std.mem.startsWith(u8, value, "!")) continue;
        try globs.append(try allocator.dupe(u8, value));
    }
    for (query.folder_queries) |other| {
        if (std.mem.eql(u8, other.folder, folder_query.folder)) continue;
        if (!isEqualOrParent(other.folder, folder_query.folder)) continue;
        const relative = std.mem.trimStart(u8, other.folder[folder_query.folder.len..], "/\\");
        if (relative.len == 0) continue;
        const copy = try allocator.dupe(u8, relative);
        errdefer allocator.free(copy);
        for (copy) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
        try globs.append(copy);
    }
    return globs.toOwnedSlice();
}

fn isEqualOrParent(path: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, path, parent)) return true;
    if (path.len <= parent.len) return false;
    if (!std.mem.startsWith(u8, path, parent)) return false;
    return path[parent.len] == '/' or path[parent.len] == '\\';
}

fn freeStrings(allocator: Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

const time_compat = @import("../../../../base/common/timeCompat.zig");
