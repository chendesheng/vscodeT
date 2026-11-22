// Port of `src/vs/workbench/services/search/node/ripgrepFileSearch.ts` and the
// file-search half of `ripgrepSearchUtils.ts`.
//
// The TUI assumes `rg` is installed and on `PATH` instead of resolving the
// bundled `@vscode/ripgrep-universal` binary through `rgDiskPath()`. Callers
// may inject a different executable path for tests. Argument construction,
// include/exclude anchoring, exclude-exception globs, drive-letter rewriting
// and the symlink-loop limit follow upstream.
//
// The process is spawned with pipes so the walker can stream stdout. The
// walker takes ownership of the two pipe handles and clears the fields on the
// child struct, which lets a cancelling thread kill the child without closing
// a pipe that the walker is still draining.
//
// On POSIX the child leads its own process group so cancellation kills the
// whole ripgrep process tree. Killing only the direct child lets a wrapper
// script's foreground command keep the stdout/stderr pipes open, and the
// reader then waits for the rest of the wrapper instead of cancelling.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const glob = @import("../../../../base/common/glob.zig");
const search = @import("../common/search.zig");

pub const rg_executable = "rg";

/// Spawn option that puts ripgrep in its own process group on POSIX. Zero is
/// `setpgid(0, 0)` / `POSIX_SPAWN_SETPGROUP`, making the child the group
/// leader. Windows has no equivalent here, so the child is killed directly.
pub const child_process_group: ?std.posix.pid_t = if (builtin.os.tag == .windows) null else 0;

/// Kills a ripgrep child spawned with `child_process_group` and reaps it.
pub fn killChild(child: *std.process.Child, io: Io) void {
    switch (builtin.os.tag) {
        .windows => {},
        else => {
            if (child.id) |id| {
                const pid: std.posix.pid_t = @intCast(id);
                std.posix.kill(-pid, .TERM) catch {};
            }
        },
    }
    child.kill(io);
}

/// The number of symbolic link loops a single ripgrep run may report before we
/// stop following symbolic links, mirroring upstream.
pub const MAX_RIPGREP_SYMLINK_LOOPS: usize = 1000;

const version_control_folders = [_][]const u8{ ".git", ".svn", ".hg", ".jj" };

pub const BuildOptions = struct {
    /// Raw include glob expression, relative to the folder. Upstream passes an
    /// `IExpression`; the terminal represents it as a comma-separated glob list.
    include: ?[]const u8 = null,
    /// Exclude entries for this folder, after nested-root merging.
    exclude: ?[]const glob.ExcludeEntry = null,
    threads: ?usize = null,
    /// The paths re-included by `!` exclude exceptions. When set, this is an
    /// exception run: ripgrep is asked only for those paths and ignore files
    /// are disabled.
    exclude_exceptions: ?[]const []const u8 = null,
    exists: bool = false,
};

pub const Args = struct {
    allocator: Allocator,
    args: []const []const u8,
    /// Whether any enabled exclude entry needs a sibling-clause post filter.
    sibling_clauses: bool,

    pub fn deinit(self: *Args) void {
        for (self.args) |arg| self.allocator.free(arg);
        self.allocator.free(self.args);
    }
};

pub const Spawned = struct {
    allocator: Allocator,
    io: Io,
    child: std.process.Child,
    args: Args,
    cwd: []u8,

    pub fn deinit(self: *Spawned) void {
        if (self.child.id != null) killChild(&self.child, self.io);
        self.args.deinit();
        self.allocator.free(self.cwd);
    }
};

/// Builds the exact ripgrep command line upstream builds for a file query.
pub fn buildArgs(
    allocator: Allocator,
    query: *const search.FileQuery,
    folder_query: search.FolderQuery,
    options: BuildOptions,
) !Args {
    var args = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }

    try push(&args, allocator, "--files");
    try push(&args, allocator, "--hidden");
    try push(&args, allocator, "--case-sensitive");
    try push(&args, allocator, "--no-require-git");

    if (query.ignore_glob_case or folder_query.ignore_glob_case) {
        try push(&args, allocator, "--glob-case-insensitive");
        try push(&args, allocator, "--ignore-file-case-insensitive");
    }

    // Exceptions are applied instead of the include/exclude globs: ripgrep
    // cannot intersect them with the globs of the exception run. Upstream
    // applies the includes to the exception results in the post filter.
    var sibling_clauses = false;
    if (options.exclude_exceptions) |exceptions| {
        const exception_globs = try getExcludeExceptionGlobs(allocator, exceptions);
        defer freeStrings(allocator, exception_globs);
        for (exception_globs) |glob_arg| try pushGlob(&args, allocator, glob_arg);
    } else {
        // Includes match at any depth and are anchored like upstream.
        const include_source = options.include orelse folder_query.include_pattern orelse query.include_pattern;
        if (include_source) |include| {
            const globs = try splitGlobList(allocator, include);
            defer freeStrings(allocator, globs);
            for (globs) |glob_value| {
                const anchored = try anchorGlob(allocator, glob_value);
                defer allocator.free(anchored);
                try pushGlob(&args, allocator, anchored);
            }
        }
        if (options.exclude) |entries| {
            const exclude_globs = try excludeGlobs(allocator, entries);
            defer freeStrings(allocator, exclude_globs.values);
            for (exclude_globs.values) |glob_value| {
                const anchored = try anchorGlob(allocator, glob_value);
                defer allocator.free(anchored);
                const prefixed = try std.fmt.allocPrint(allocator, "!{s}", .{anchored});
                defer allocator.free(prefixed);
                try pushGlob(&args, allocator, prefixed);
            }
            sibling_clauses = exclude_globs.sibling_clauses;
        }
    }

    const disregard_ignore = folder_query.disregard_ignore_files orelse !query.settings.use_ignore_files;
    const disregard_parent = folder_query.disregard_parent_ignore_files orelse !query.settings.use_parent_ignore_files;
    const disregard_global = folder_query.disregard_global_ignore_files orelse !query.settings.use_global_ignore_files;

    if (options.exclude_exceptions != null or disregard_ignore) {
        try push(&args, allocator, "--no-ignore");
    } else if (disregard_parent) {
        try push(&args, allocator, "--no-ignore-parent");
    }

    const ignore_symlinks = folder_query.ignore_symlinks orelse
        (query.ignore_symlinks or !query.settings.follow_symlinks);
    if (!ignore_symlinks) try push(&args, allocator, "--follow");

    if (options.exists and options.exclude_exceptions == null) {
        try push(&args, allocator, "--quiet");
    }

    if (options.threads) |threads| {
        if (threads > 0) {
            try push(&args, allocator, "--threads");
            const threads_text = try std.fmt.allocPrint(allocator, "{d}", .{threads});
            defer allocator.free(threads_text);
            try push(&args, allocator, threads_text);
        }
    }

    try push(&args, allocator, "--no-config");
    if (disregard_global) try push(&args, allocator, "--no-ignore-global");

    return .{
        .allocator = allocator,
        .args = try args.toOwnedSlice(),
        .sibling_clauses = sibling_clauses,
    };
}

/// Spawns one `rg --files` run in `folder_query.folder` with piped stdio.
pub fn spawn(
    io: Io,
    allocator: Allocator,
    rg_path: []const u8,
    query: *const search.FileQuery,
    folder_query: search.FolderQuery,
    options: BuildOptions,
) !Spawned {
    var args = try buildArgs(allocator, query, folder_query, options);
    errdefer args.deinit();
    const cwd = try allocator.dupe(u8, folder_query.folder);
    errdefer allocator.free(cwd);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(rg_path);
    try argv.appendSlice(args.args);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = child_process_group,
        .create_no_window = builtin.os.tag == .windows,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.RipgrepNotFound,
        else => return err,
    };
    errdefer if (child.id != null) killChild(&child, io);

    if (child.stdout == null or child.stderr == null) return error.RipgrepPipeFailure;

    return .{
        .allocator = allocator,
        .io = io,
        .child = child,
        .args = args,
        .cwd = cwd,
    };
}

fn push(args: *std.array_list.Managed([]const u8), allocator: Allocator, value: []const u8) !void {
    try args.append(try allocator.dupe(u8, value));
}

fn pushGlob(args: *std.array_list.Managed([]const u8), allocator: Allocator, value: []const u8) !void {
    try push(args, allocator, "-g");
    try push(args, allocator, value);
}

fn freeStrings(allocator: Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

/// Port of `anchorGlob`.
pub fn anchorGlob(allocator: Allocator, value: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, value, "**") or
        std.mem.startsWith(u8, value, "/") or
        std.mem.startsWith(u8, value, "\\"))
    {
        return allocator.dupe(u8, value);
    }
    return std.fmt.allocPrint(allocator, "/{s}", .{value});
}

/// Port of `getAbsoluteGlob`: absolute globs are kept, relative globs are
/// joined to the workspace folder. Node's `path.join` normalizes every
/// separator to `\` on Windows; Zig's `std.fs.path.join` only inserts the
/// separator between the parts, so rewrite the existing ones to match the
/// ripgrep arguments upstream builds.
pub fn getAbsoluteGlob(allocator: Allocator, folder: []const u8, key: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(key)) return allocator.dupe(u8, key);
    const joined = try std.fs.path.join(allocator, &.{ folder, key });
    if (builtin.os.tag == .windows) {
        for (joined) |*ch| {
            if (ch.* == '/') ch.* = '\\';
        }
    }
    return joined;
}

/// Port of `fixDriveC`. On POSIX this is an identity function.
pub fn fixDriveC(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len >= 3 and std.ascii.toLower(path[0]) == 'c' and path[1] == ':' and
        (path[2] == '/' or path[2] == '\\'))
    {
        return std.fmt.allocPrint(allocator, "/{s}", .{path[3..]});
    }
    return allocator.dupe(u8, path);
}

const ExcludeGlobs = struct {
    values: [][]u8,
    sibling_clauses: bool,
};

/// Port of `globExprsToRgGlobs` for the exclude expression. When `absolute`
/// is true relative keys are resolved against the folder.
fn excludeGlobs(
    allocator: Allocator,
    entries: []const glob.ExcludeEntry,
) !ExcludeGlobs {
    var values = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit();
    }
    var sibling_clauses = false;
    for (entries) |entry| {
        if (!entry.enabled) continue;
        if (entry.when != null) {
            sibling_clauses = true;
            continue;
        }
        const pattern = std.mem.trim(u8, entry.pattern, " \t\r\n");
        if (pattern.len == 0 or glob.isExcludeException(pattern)) continue;

        // Exclude globs stay relative to the ripgrep cwd; upstream passes
        // `absoluteGlobs=false` for the file-search exclude expression.
        const normalized = try normalizeRgGlob(allocator, pattern);
        defer allocator.free(normalized);
        const fixed = try fixDriveC(allocator, normalized);
        defer allocator.free(fixed);

        if (std.mem.startsWith(u8, fixed, "\\\\")) {
            // Absolute UNC globs do not match in ripgrep; match inside the share.
            const value = try std.fmt.allocPrint(allocator, "{s}**", .{fixed});
            errdefer allocator.free(value);
            try values.append(value);
        } else {
            try values.append(try allocator.dupe(u8, fixed));
        }
    }
    return .{
        .values = try values.toOwnedSlice(),
        .sibling_clauses = sibling_clauses,
    };
}

fn normalizeRgGlob(allocator: Allocator, value: []const u8) ![]u8 {
    const trimmed = trimTrailingSlash(value);
    if (std.mem.startsWith(u8, trimmed, "\\\\")) {
        const result = try allocator.dupe(u8, trimmed);
        for (result[2..]) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
        return result;
    }
    const result = try allocator.dupe(u8, trimmed);
    for (result) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return result;
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '\\') end -= 1;
    while (end > 0 and value[end - 1] == '/') end -= 1;
    return value[0..end];
}

/// Port of `getExcludeExceptionGlobs`: the exception run only walks the folders
/// that lead to the re-included paths, unless an exception can match at any
/// depth.
pub fn getExcludeExceptionGlobs(
    allocator: Allocator,
    exclude_exceptions: []const []const u8,
) ![][]u8 {
    var globs = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (globs.items) |value| allocator.free(value);
        globs.deinit();
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    var expanded = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (expanded.items) |value| allocator.free(value);
        expanded.deinit();
    }
    for (exclude_exceptions) |exception| {
        const alternatives = try expandBraces(allocator, exception);
        defer {
            for (alternatives) |value| allocator.free(value);
            allocator.free(alternatives);
        }
        for (alternatives) |alternative| try expanded.append(try allocator.dupe(u8, alternative));
    }

    var any_unanchored = false;
    for (expanded.items) |exception| {
        if (std.mem.startsWith(u8, exception, "**")) {
            any_unanchored = true;
            break;
        }
    }

    if (!any_unanchored) {
        try appendUnique(&globs, &seen, allocator, "!*");
        for (expanded.items) |exception| {
            const segments = try splitGlobAware(allocator, exception, '/');
            defer freeStrings(allocator, segments);
            var joined = std.array_list.Managed(u8).init(allocator);
            defer joined.deinit();
            for (segments, 0..) |segment, index| {
                if (index > 0) try joined.append('/');
                try joined.appendSlice(segment);
                if (index + 1 >= segments.len) continue;
                const parent = try anchorGlob(allocator, joined.items);
                defer allocator.free(parent);
                const folder_glob = try std.fmt.allocPrint(allocator, "{s}/", .{parent});
                defer allocator.free(folder_glob);
                try appendUnique(&globs, &seen, allocator, folder_glob);
            }
        }
    }

    for (expanded.items) |exception| {
        const anchored = try anchorGlob(allocator, exception);
        defer allocator.free(anchored);
        try appendUnique(&globs, &seen, allocator, anchored);

        const everything = try std.fmt.allocPrint(allocator, "{s}/**", .{exception});
        defer allocator.free(everything);
        const anchored_everything = try anchorGlob(allocator, everything);
        defer allocator.free(anchored_everything);
        try appendUnique(&globs, &seen, allocator, anchored_everything);
    }

    // Later globs take precedence in ripgrep, so re-exclude the version
    // control folders that no exception names.
    for (version_control_folders) |folder| {
        var named = false;
        for (expanded.items) |exception| {
            const segments = try splitGlobAware(allocator, exception, '/');
            defer freeStrings(allocator, segments);
            for (segments) |segment| {
                if (std.mem.eql(u8, segment, folder)) {
                    named = true;
                    break;
                }
            }
            if (named) break;
        }
        if (named) continue;
        const skipped = try std.fmt.allocPrint(allocator, "!**/{s}", .{folder});
        defer allocator.free(skipped);
        try appendUnique(&globs, &seen, allocator, skipped);
    }

    return globs.toOwnedSlice();
}

fn appendUnique(
    values: *std.array_list.Managed([]u8),
    seen: *std.StringHashMap(void),
    allocator: Allocator,
    value: []const u8,
) !void {
    if (seen.contains(value)) return;
    const key = try allocator.dupe(u8, value);
    errdefer allocator.free(key);
    try seen.put(key, {});
    try values.append(try allocator.dupe(u8, value));
}

/// Splits a glob expression on top-level commas, like the search include input.
pub fn splitGlobList(allocator: Allocator, expression: []const u8) ![][]u8 {
    return splitGlobAware(allocator, expression, ',');
}

/// Port of `splitGlobAware`: separators inside braces or brackets are kept.
pub fn splitGlobAware(allocator: Allocator, pattern: []const u8, separator: u8) ![][]u8 {
    var values = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit();
    }
    if (pattern.len == 0) return values.toOwnedSlice();

    var start: usize = 0;
    var in_braces = false;
    var in_brackets = false;
    for (pattern, 0..) |ch, index| {
        if (ch == separator and !in_braces and !in_brackets) {
            try values.append(try allocator.dupe(u8, std.mem.trim(u8, pattern[start..index], " \t\r\n")));
            start = index + 1;
            continue;
        }
        switch (ch) {
            '{' => in_braces = true,
            '}' => in_braces = false,
            '[' => in_brackets = true,
            ']' => in_brackets = false,
            else => {},
        }
    }
    try values.append(try allocator.dupe(u8, std.mem.trim(u8, pattern[start..], " \t\r\n")));
    return values.toOwnedSlice();
}

/// Expands non-nesting brace groups, mirroring upstream `expandBraces`.
pub fn expandBraces(allocator: Allocator, pattern: []const u8) ![][]u8 {
    var values = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit();
    }
    try expandBracesInto(allocator, &values, pattern);
    return values.toOwnedSlice();
}

fn expandBracesInto(
    allocator: Allocator,
    values: *std.array_list.Managed([]u8),
    pattern: []const u8,
) !void {
    var open: ?usize = null;
    var in_brackets = false;
    for (pattern, 0..) |ch, index| {
        if (in_brackets) {
            if (ch == ']') in_brackets = false;
            continue;
        }
        if (ch == '[') {
            in_brackets = true;
            continue;
        }
        if (ch == '{') {
            open = index;
            break;
        }
    }
    const start = open orelse {
        try values.append(try allocator.dupe(u8, pattern));
        return;
    };
    var close: ?usize = null;
    in_brackets = false;
    var index = start + 1;
    while (index < pattern.len) : (index += 1) {
        const ch = pattern[index];
        if (in_brackets) {
            if (ch == ']') in_brackets = false;
            continue;
        }
        if (ch == '[') {
            in_brackets = true;
            continue;
        }
        if (ch == '}') {
            close = index;
            break;
        }
    }
    const end = close orelse {
        try values.append(try allocator.dupe(u8, pattern));
        return;
    };
    var alternatives = std.mem.splitScalar(u8, pattern[start + 1 .. end], ',');
    while (alternatives.next()) |alternative| {
        const combined = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            pattern[0..start],
            alternative,
            pattern[end + 1 ..],
        });
        defer allocator.free(combined);
        try expandBracesInto(allocator, values, combined);
    }
}

/// Port of `RipgrepSymlinkLoopDetector`.
pub const SymlinkLoopDetector = struct {
    allocator: Allocator,
    loop_count: usize = 0,
    partial_line: std.array_list.Managed(u8),

    pub fn init(allocator: Allocator) SymlinkLoopDetector {
        return .{
            .allocator = allocator,
            .partial_line = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *SymlinkLoopDetector) void {
        self.partial_line.deinit();
    }

    /// Returns whether ripgrep has reported more than the allowed number of
    /// loops. The allocator failure path simply keeps the previous count.
    pub fn handleStderr(self: *SymlinkLoopDetector, data: []const u8) bool {
        self.partial_line.appendSlice(data) catch return false;
        var last_end: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.partial_line.items, start, '\n')) |newline| {
            const line = self.partial_line.items[start..newline];
            if (std.mem.indexOf(u8, line, "File system loop found") != null) self.loop_count += 1;
            start = newline + 1;
            last_end = start;
        }
        if (last_end > 0) {
            const remaining = self.partial_line.items.len - last_end;
            std.mem.copyForwards(u8, self.partial_line.items[0..remaining], self.partial_line.items[last_end..]);
            self.partial_line.items.len = remaining;
        }
        return self.loop_count > MAX_RIPGREP_SYMLINK_LOOPS;
    }
};

pub const StderrCapture = struct {
    allocator: Allocator,
    text: std.array_list.Managed(u8),
    limit: usize = 64 * 1024,
    truncated: bool = false,

    pub fn init(allocator: Allocator) StderrCapture {
        return .{ .allocator = allocator, .text = std.array_list.Managed(u8).init(allocator) };
    }

    pub fn deinit(self: *StderrCapture) void {
        self.text.deinit();
    }

    pub fn append(self: *StderrCapture, data: []const u8) void {
        if (self.text.items.len >= self.limit) {
            self.truncated = true;
            return;
        }
        const remaining = self.limit - self.text.items.len;
        const take = @min(remaining, data.len);
        self.text.appendSlice(data[0..take]) catch {
            self.truncated = true;
            return;
        };
        if (take < data.len) self.truncated = true;
    }

    pub fn value(self: *const StderrCapture) []const u8 {
        return self.text.items;
    }
};

/// Port of `rgErrorMsgForDisplay`. The walker only reports an error when the
/// child exits with a non-success code and produced stderr; this helper picks
/// the useful first line.
pub fn errorMessageForDisplay(stderr: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
    if (trimmed.len == 0) return null;
    const first_line = std.mem.trim(u8, std.mem.sliceTo(trimmed, '\n'), " \t\r");
    if (first_line.len == 0) return null;
    return first_line;
}

test "fixDriveC and getAbsoluteGlob: POSIX" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const cases = [_]struct { folder: []const u8, pattern: []const u8, expected: []const u8 }{
        .{ .folder = "/foo/bar", .pattern = "glob/**", .expected = "/foo/bar/glob/**" },
        .{ .folder = "/", .pattern = "glob/**", .expected = "/glob/**" },
        .{ .folder = "/", .pattern = "/project/folder", .expected = "/project/folder" },
    };
    for (cases) |case| {
        const absolute = try getAbsoluteGlob(allocator, case.folder, case.pattern);
        defer allocator.free(absolute);
        const fixed = try fixDriveC(allocator, absolute);
        defer allocator.free(fixed);
        try std.testing.expectEqualStrings(case.expected, fixed);
    }
}

test "getExcludeExceptionGlobs: parents, globs and version-control folders" {
    const allocator = std.testing.allocator;
    const globs = try getExcludeExceptionGlobs(allocator, &.{"node_modules/@types"});
    defer freeStrings(allocator, globs);
    try std.testing.expectEqualStrings("!*", globs[0]);
    try std.testing.expect(containsString(globs, "/node_modules/"));
    try std.testing.expect(containsString(globs, "/node_modules/@types"));
    try std.testing.expect(containsString(globs, "/node_modules/@types/**"));
    try std.testing.expect(containsString(globs, "!**/.git"));
}

test "splitGlobAware: braces and brackets are kept" {
    const allocator = std.testing.allocator;
    const values = try splitGlobAware(allocator, "a/{b,c},d[1,2]", ',');
    defer freeStrings(allocator, values);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("a/{b,c}", values[0]);
    try std.testing.expectEqualStrings("d[1,2]", values[1]);
}

test "expandBraces: non-nesting alternatives" {
    const allocator = std.testing.allocator;
    const values = try expandBraces(allocator, "src/{a,b}/*.{js,ts}");
    defer freeStrings(allocator, values);
    try std.testing.expectEqual(@as(usize, 4), values.len);
    try std.testing.expect(containsString(values, "src/a/*.js"));
    try std.testing.expect(containsString(values, "src/b/*.ts"));
}

test "SymlinkLoopDetector: counts loops across chunks" {
    var detector = SymlinkLoopDetector.init(std.testing.allocator);
    defer detector.deinit();
    try std.testing.expect(!detector.handleStderr("rg: File system loop found: foo\nrg: File system lo"));
    try std.testing.expect(!detector.handleStderr("op found: bar\n"));
    try std.testing.expectEqual(@as(usize, 2), detector.loop_count);
}

fn containsString(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, wanted)) return true;
    }
    return false;
}
