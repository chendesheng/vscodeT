// Port of `src/vs/workbench/services/search/node/ripgrepTextSearchEngine.ts`
// for the local file-scheme text search used by the Search view.
//
// The TUI resolves `rg` from `PATH` (with an injectable path for tests) instead
// of `rgDiskPath()`. Argument construction, JSON parsing, preview ranges,
// surrounding-context rows, exclude-exception runs, symlink-loop retry and
// stderr error mapping follow upstream. Extension-provider routing, remote
// folders and explicit file-encoding conversion are outside this module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const search = @import("../common/search.zig");
const glob = @import("../../../../base/common/glob.zig");
const ripgrep = @import("./ripgrepFileSearch.zig");

pub const TextSearchContext = search.TextSearchContext;
pub const TextSearchMatch = search.TextSearchMatch;
pub const SearchRange = search.SearchRange;

pub const Args = struct {
    allocator: Allocator,
    args: []const []const u8,

    pub fn deinit(self: *Args) void {
        for (self.args) |arg| self.allocator.free(arg);
        self.allocator.free(self.args);
    }
};

pub const ArgOptions = struct {
    threads: ?usize = null,
    /// `!`-re-included paths for an exclude-exception run.
    exclude_exceptions: ?[]const []const u8 = null,
    /// Positive exclude globs for this folder (config + user excludes).
    exclude_globs: []const []const u8 = &.{},
    /// Raw search-input include expression.
    include_pattern: []const u8 = "",
    /// Forces the symlink-loop retry to stop following links.
    ignore_symlinks: ?bool = null,
};

pub const ParsedFile = struct {
    allocator: Allocator,
    path: []u8,
    matches: []TextSearchMatch,
    contexts: []TextSearchContext,

    pub fn deinit(self: *ParsedFile) void {
        if (self.path.len > 0) self.allocator.free(self.path);
        for (self.matches) |*match| match.deinit();
        if (self.matches.len > 0) self.allocator.free(self.matches);
        for (self.contexts) |*context| context.deinit(self.allocator);
        if (self.contexts.len > 0) self.allocator.free(self.contexts);
    }
};

pub const Sink = struct {
    context: *anyopaque,
    on_file: *const fn (context: *anyopaque, file: ParsedFile) anyerror!void,
};

pub const Parser = struct {
    allocator: Allocator,
    root: []const u8,
    preview: search.PreviewOptions,
    max_results: usize,
    sink: Sink,
    json_arena: std.heap.ArenaAllocator,
    pending: std.array_list.Managed(u8),
    current: ?Builder = null,
    result_count: usize = 0,
    limit_hit: bool = false,
    malformed: bool = false,

    const Builder = struct {
        allocator: Allocator,
        path: []u8,
        matches: std.array_list.Managed(TextSearchMatch),
        contexts: std.array_list.Managed(TextSearchContext),
    };

    pub fn init(
        allocator: Allocator,
        root: []const u8,
        preview: search.PreviewOptions,
        max_results: usize,
        sink: Sink,
    ) Parser {
        return .{
            .allocator = allocator,
            .root = root,
            .preview = preview,
            .max_results = max_results,
            .sink = sink,
            .json_arena = std.heap.ArenaAllocator.init(allocator),
            .pending = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.discardCurrent();
        self.pending.deinit();
        self.json_arena.deinit();
    }

    pub fn handleData(self: *Parser, data: []const u8) !void {
        if (self.limit_hit) return;
        try self.pending.appendSlice(data);

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.pending.items, start, '\n')) |newline| {
            var line = self.pending.items[start..newline];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            start = newline + 1;
            if (line.len > 0) try self.handleLine(line);
            if (self.limit_hit) break;
        }
        if (start == 0) return;
        const remaining = self.pending.items.len - start;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[start..]);
        }
        self.pending.items.len = remaining;
    }

    pub fn flush(self: *Parser) !void {
        if (self.limit_hit) return;
        const line = std.mem.trim(u8, self.pending.items, " \t\r\n");
        if (line.len > 0) try self.handleLine(line);
        self.pending.clearRetainingCapacity();
        try self.flushCurrent();
    }

    fn handleLine(self: *Parser, line: []const u8) !void {
        _ = self.json_arena.reset(.retain_capacity);
        const value = std.json.parseFromSliceLeaky(std.json.Value, self.json_arena.allocator(), line, .{
            .allocate = .alloc_always,
        }) catch {
            self.malformed = true;
            return;
        };
        if (value != .object) return;
        const type_value = value.object.get("type") orelse return;
        const kind = type_value.string;
        const data = value.object.get("data") orelse return;
        if (data != .object) return;

        if (std.mem.eql(u8, kind, "match")) {
            try self.handleMatch(data.object);
        } else if (std.mem.eql(u8, kind, "context")) {
            try self.handleContext(data.object);
        }
    }

    fn handleMatch(self: *Parser, object: std.json.ObjectMap) !void {
        const path = bytesOrTextToString(self.json_arena.allocator(), object.get("path") orelse return) orelse return;
        const lines_value = object.get("lines") orelse return;
        const full_text = bytesOrTextToString(self.json_arena.allocator(), lines_value) orelse return;
        const line_number = integerField(object, "line_number") orelse return;
        if (line_number == 0) return;

        try self.ensureCurrent(path);
        const builder = if (self.current) |*current| current else return;

        var ranges = std.array_list.Managed(SearchRange).init(self.allocator);
        defer ranges.deinit();
        const empty_submatches = std.json.Array.init(self.json_arena.allocator());
        var submatches_value: std.json.Value = object.get("submatches") orelse .{ .array = empty_submatches };
        if (submatches_value != .array) submatches_value = .{ .array = empty_submatches };
        const submatches = submatches_value.array.items;

        var prev_match_end: usize = 0;
        var prev_match_end_col: usize = 0;
        var prev_match_end_line: usize = @intCast(line_number - 1);

        if (submatches.len == 0) {
            if (self.result_count >= self.max_results) {
                self.limit_hit = true;
                return;
            }
            self.result_count += 1;
            try ranges.append(.{
                .start_line_number = prev_match_end_line,
                .start_column = 0,
                .end_line_number = prev_match_end_line,
                .end_column = if (full_text.len > 0) 1 else 0,
            });
        } else {
            for (submatches) |submatch| {
                if (submatch != .object) continue;
                const start = integerField(submatch.object, "start") orelse continue;
                const end = integerField(submatch.object, "end") orelse continue;
                if (start > full_text.len or end > full_text.len or start > end) continue;
                if (self.result_count >= self.max_results) {
                    self.limit_hit = true;
                    break;
                }
                self.result_count += 1;

                const in_between = full_text[prev_match_end..start];
                const in_between_stats = numLinesAndLastLineLength(in_between);
                const start_line_number = prev_match_end_line + in_between_stats.num_lines;
                const start_col = if (in_between_stats.num_lines > 0)
                    in_between_stats.last_line_length
                else
                    in_between_stats.last_line_length + prev_match_end_col;

                const match_text = full_text[start..end];
                const stats = numLinesAndLastLineLength(match_text);
                const end_line_number = start_line_number + stats.num_lines;
                const end_col = if (stats.num_lines > 0)
                    stats.last_line_length
                else
                    stats.last_line_length + start_col;

                try ranges.append(.{
                    .start_line_number = start_line_number,
                    .start_column = start_col,
                    .end_line_number = end_line_number,
                    .end_column = end_col,
                });
                prev_match_end = end;
                prev_match_end_col = end_col;
                prev_match_end_line = end_line_number;
            }
        }

        if (ranges.items.len > 0) {
            const match = try TextSearchMatch.init(self.allocator, full_text, ranges.items, self.preview);
            errdefer @constCast(&match).deinit();
            try builder.matches.append(match);
        }
    }

    fn handleContext(self: *Parser, object: std.json.ObjectMap) !void {
        const path = bytesOrTextToString(self.json_arena.allocator(), object.get("path") orelse return) orelse return;
        const lines_value = object.get("lines") orelse return;
        const text = bytesOrTextToString(self.json_arena.allocator(), lines_value) orelse return;
        const line_number = integerField(object, "line_number") orelse return;
        if (line_number == 0) return;
        try self.ensureCurrent(path);
        const builder = if (self.current) |*current| current else return;

        const trimmed = trimContextNewline(text);
        var iterator = std.mem.splitScalar(u8, trimmed, '\n');
        var offset: usize = 0;
        while (iterator.next()) |line| : (offset += 1) {
            try builder.contexts.append(.{
                .text = try self.allocator.dupe(u8, line),
                .line_number = @intCast(line_number + offset),
            });
        }
    }

    fn ensureCurrent(self: *Parser, path: []const u8) !void {
        const normalized = stripDotSlash(path);
        if (self.current) |*current| {
            if (sameParsedPath(current.path, normalized)) return;
            try self.flushCurrent();
        }
        const copy = try self.allocator.dupe(u8, normalized);
        errdefer self.allocator.free(copy);
        for (copy) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
        self.current = .{
            .allocator = self.allocator,
            .path = copy,
            .matches = std.array_list.Managed(TextSearchMatch).init(self.allocator),
            .contexts = std.array_list.Managed(TextSearchContext).init(self.allocator),
        };
    }

    fn flushCurrent(self: *Parser) !void {
        var current = self.current orelse return;
        self.current = null;
        var file = ParsedFile{
            .allocator = current.allocator,
            .path = current.path,
            .matches = current.matches.toOwnedSlice() catch &.{},
            .contexts = current.contexts.toOwnedSlice() catch &.{},
        };
        current.matches.deinit();
        current.contexts.deinit();
        if (file.matches.len == 0 and file.contexts.len == 0) {
            file.deinit();
            return;
        }
        self.sink.on_file(self.sink.context, file) catch |err| return err;
    }

    fn discardCurrent(self: *Parser) void {
        const current = self.current orelse return;
        self.current = null;
        self.allocator.free(current.path);
        for (current.matches.items) |*match| match.deinit();
        current.matches.deinit();
        for (current.contexts.items) |*context| context.deinit(self.allocator);
        current.contexts.deinit();
    }
};

fn trimContextNewline(text: []const u8) []const u8 {
    if (std.mem.endsWith(u8, text, "\r\n")) return text[0 .. text.len - 2];
    if (std.mem.endsWith(u8, text, "\n")) return text[0 .. text.len - 1];
    return text;
}

/// rg reports platform separators, but the parser stores every path with `/`.
/// Compare against the stored form so matches for one file group into a single
/// result on Windows instead of one single-match result per line.
fn sameParsedPath(stored: []const u8, raw: []const u8) bool {
    if (stored.len != raw.len) return false;
    for (stored, raw) |left, right| {
        const normalized = if (right == '\\') @as(u8, '/') else right;
        if (left != normalized) return false;
    }
    return true;
}

fn stripDotSlash(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "./")) return path[2..];
    if (std.mem.startsWith(u8, path, ".\\")) return path[2..];
    return path;
}

const LineStats = struct {
    num_lines: usize,
    last_line_length: usize,
};

fn numLinesAndLastLineLength(text: []const u8) LineStats {
    if (text.len == 0) return .{ .num_lines = 0, .last_line_length = 0 };
    var num_lines: usize = 0;
    var last_newline: ?usize = null;
    for (text, 0..) |ch, index| {
        if (ch == '\n') {
            num_lines += 1;
            last_newline = index;
        }
    }
    const start = if (last_newline) |index| index + 1 else 0;
    return .{
        .num_lines = num_lines,
        .last_line_length = utf16Length(text[start..]),
    };
}

fn utf16Length(text: []const u8) usize {
    var index: usize = 0;
    var length: usize = 0;
    while (index < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch return length;
        if (index + sequence_length > text.len) return length;
        const code_point = std.unicode.utf8Decode(text[index .. index + sequence_length]) catch return length;
        length += if (code_point > 0xFFFF) 2 else 1;
        index += sequence_length;
    }
    return length;
}

fn bytesOrTextToString(arena: Allocator, value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("text")) |text_value| {
        if (text_value == .string) return text_value.string;
    }
    if (value.object.get("bytes")) |bytes_value| {
        if (bytes_value != .string) return null;
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(bytes_value.string) catch return null;
        const dest = arena.alloc(u8, size) catch return null;
        decoder.decode(dest, bytes_value.string) catch return null;
        return dest;
    }
    return null;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

// ---------------------------------------------------------------------------
// Argument construction
// ---------------------------------------------------------------------------

pub fn buildArgs(
    allocator: Allocator,
    query: *const search.TextQuery,
    folder_query: search.FolderQuery,
    options: ArgOptions,
) !Args {
    var args = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }

    try push(&args, allocator, "--hidden");
    try push(&args, allocator, "--no-require-git");
    try push(&args, allocator, if (query.is_case_sensitive) "--case-sensitive" else "--ignore-case");

    const ignore_case = query.ignore_glob_case or folder_query.ignore_glob_case;
    if (ignore_case) {
        try push(&args, allocator, "--glob-case-insensitive");
        try push(&args, allocator, "--ignore-file-case-insensitive");
    }

    if (options.exclude_exceptions) |exceptions| {
        const exception_globs = try ripgrep.getExcludeExceptionGlobs(allocator, exceptions);
        defer freeStrings(allocator, exception_globs);
        for (exception_globs) |glob_value| try pushGlob(&args, allocator, glob_value);
    } else {
        try pushIncludeGlobs(&args, allocator, if (options.include_pattern.len > 0)
            options.include_pattern
        else
            query.include_pattern);
        for (options.exclude_globs) |exclude| {
            if (std.mem.startsWith(u8, exclude, "!")) continue;
            const anchored = try ripgrep.anchorGlob(allocator, exclude);
            defer allocator.free(anchored);
            const prefixed = try std.fmt.allocPrint(allocator, "!{s}", .{anchored});
            defer allocator.free(prefixed);
            try pushGlob(&args, allocator, prefixed);
        }
    }

    if (query.max_file_size) |limit| {
        try push(&args, allocator, "--max-filesize");
        try push(&args, allocator, try std.fmt.allocPrint(allocator, "{d}", .{limit}));
    }

    const disregard_ignore = folder_query.disregard_ignore_files orelse !query.settings.use_ignore_files;
    const disregard_parent = folder_query.disregard_parent_ignore_files orelse !query.settings.use_parent_ignore_files;
    const disregard_global = folder_query.disregard_global_ignore_files orelse !query.settings.use_global_ignore_files;
    if (options.exclude_exceptions != null or disregard_ignore) {
        try push(&args, allocator, "--no-ignore");
    } else if (disregard_parent) {
        try push(&args, allocator, "--no-ignore-parent");
    }

    const follow = folder_query.ignore_symlinks orelse options.ignore_symlinks orelse !query.settings.follow_symlinks;
    if (!follow) try push(&args, allocator, "--follow");

    if (options.threads) |threads| {
        if (threads > 0) {
            try push(&args, allocator, "--threads");
            try push(&args, allocator, try std.fmt.allocPrint(allocator, "{d}", .{threads}));
        }
    }

    try push(&args, allocator, "--crlf");

    var pattern = try allocator.dupe(u8, query.pattern);
    errdefer allocator.free(pattern);
    var is_regex = query.is_regex;
    if (std.mem.eql(u8, pattern, "--")) {
        allocator.free(pattern);
        pattern = try allocator.dupe(u8, "\\-\\-");
        is_regex = true;
    }
    if (query.is_multiline and !is_regex) {
        const escaped = try escapeRegexLiteral(allocator, pattern);
        allocator.free(pattern);
        pattern = escaped;
        is_regex = true;
    }
    if (is_regex) {
        const converted = try unicodeEscapesToPCRE2(allocator, pattern);
        allocator.free(pattern);
        pattern = converted;
    }

    var word_pattern: ?[]u8 = null;
    defer if (word_pattern) |value| allocator.free(value);
    var search_pattern_after_dashes: ?[]const u8 = null;
    if (query.is_word_match) {
        word_pattern = try wholeWordPattern(allocator, pattern, is_regex);
        try push(&args, allocator, "--regexp");
        try push(&args, allocator, word_pattern.?);
        try push(&args, allocator, "--engine");
        try push(&args, allocator, "auto");
    } else if (is_regex) {
        try push(&args, allocator, "--engine");
        try push(&args, allocator, "auto");
        const fixed = try fixNewline(allocator, pattern);
        defer allocator.free(fixed);
        try push(&args, allocator, "--regexp");
        try push(&args, allocator, fixed);
    } else {
        search_pattern_after_dashes = pattern;
        try push(&args, allocator, "--fixed-strings");
    }

    try push(&args, allocator, "--no-config");
    if (disregard_global) try push(&args, allocator, "--no-ignore-global");

    try push(&args, allocator, "--json");
    if (query.is_multiline) try push(&args, allocator, "--multiline");
    if (query.surrounding_context > 0) {
        const count = try std.fmt.allocPrint(allocator, "{d}", .{query.surrounding_context});
        defer allocator.free(count);
        try push(&args, allocator, "--before-context");
        try push(&args, allocator, count);
        try push(&args, allocator, "--after-context");
        try push(&args, allocator, count);
    }

    try push(&args, allocator, "--");
    if (search_pattern_after_dashes) |value| try push(&args, allocator, value);
    try push(&args, allocator, ".");

    allocator.free(pattern);
    return .{ .allocator = allocator, .args = try args.toOwnedSlice() };
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

fn pushIncludeGlobs(
    args: *std.array_list.Managed([]const u8),
    allocator: Allocator,
    include_pattern: []const u8,
) !void {
    const pieces = try ripgrep.splitGlobList(allocator, include_pattern);
    defer freeStrings(allocator, pieces);
    if (pieces.len == 0) return;

    var double_star = std.array_list.Managed([]const u8).init(allocator);
    defer double_star.deinit();
    var other = std.array_list.Managed([]const u8).init(allocator);
    defer other.deinit();
    for (pieces) |piece| {
        if (piece.len == 0 or std.mem.startsWith(u8, piece, "!")) continue;
        if (std.mem.startsWith(u8, piece, "**")) {
            try double_star.append(piece);
        } else {
            try other.append(piece);
        }
    }

    if (other.items.len > 0) {
        try pushGlob(args, allocator, "!*");
        for (other.items) |include| {
            const components = try spreadGlobComponents(allocator, include);
            defer freeStrings(allocator, components);
            for (components) |component| {
                const anchored = try ripgrep.anchorGlob(allocator, component);
                defer allocator.free(anchored);
                try pushGlob(args, allocator, anchored);
            }
        }
    }
    for (double_star.items) |include| try pushGlob(args, allocator, include);
}

fn spreadGlobComponents(allocator: Allocator, value: []const u8) ![][]u8 {
    const expanded = try ripgrep.expandBraces(allocator, value);
    defer freeStrings(allocator, expanded);
    var result = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit();
    }
    for (expanded) |glob_value| {
        const segments = try ripgrep.splitGlobAware(allocator, glob_value, '/');
        defer freeStrings(allocator, segments);
        var joined = std.array_list.Managed(u8).init(allocator);
        defer joined.deinit();
        for (segments, 0..) |segment, index| {
            if (index > 0) try joined.append('/');
            try joined.appendSlice(segment);
            try result.append(try allocator.dupe(u8, joined.items));
        }
        const everything = try std.fmt.allocPrint(allocator, "{s}/**", .{glob_value});
        defer allocator.free(everything);
        try result.append(try allocator.dupe(u8, everything));
    }
    return result.toOwnedSlice();
}

fn escapeRegexLiteral(allocator: Allocator, pattern: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (pattern) |ch| {
        if (std.mem.indexOfScalar(u8, ".^$|?*+()[]{}", ch) != null) try out.append('\\');
        try out.append(ch);
    }
    return out.toOwnedSlice();
}

fn wholeWordPattern(allocator: Allocator, pattern: []const u8, is_regex: bool) ![]u8 {
    const source = if (is_regex) try allocator.dupe(u8, pattern) else try escapeRegexLiteral(allocator, pattern);
    defer allocator.free(source);
    const needs_start = source.len > 0 and isRegexWordChar(source[0]);
    const needs_end = source.len > 0 and isRegexWordChar(source[source.len - 1]);
    if (!needs_start and !needs_end) return allocator.dupe(u8, source);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        if (needs_start) "\\b" else "",
        source,
        if (needs_end) "\\b" else "",
    });
}

fn isRegexWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

pub fn unicodeEscapesToPCRE2(allocator: Allocator, pattern: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < pattern.len) {
        if (pattern[index] == '\\' and index + 1 < pattern.len and pattern[index + 1] == 'u') {
            const start = index;
            index += 2;
            if (index < pattern.len and pattern[index] == '{') {
                const close = std.mem.indexOfScalarPos(u8, pattern, index + 1, '}') orelse {
                    try out.appendSlice(pattern[start..index]);
                    continue;
                };
                const digits = pattern[index + 1 .. close];
                if (digits.len == 4 and allHex(digits)) {
                    try out.appendSlice("\\x{");
                    try out.appendSlice(digits);
                    try out.append('}');
                    index = close + 1;
                    continue;
                }
            } else if (index + 4 <= pattern.len) {
                const digits = pattern[index .. index + 4];
                if (allHex(digits)) {
                    try out.appendSlice("\\x{");
                    try out.appendSlice(digits);
                    try out.append('}');
                    index += 4;
                    continue;
                }
            }
            try out.appendSlice(pattern[start..index]);
            continue;
        }
        if (pattern[index] == '\\' and index + 1 < pattern.len) {
            try out.append(pattern[index]);
            try out.append(pattern[index + 1]);
            index += 2;
            continue;
        }
        try out.append(pattern[index]);
        index += 1;
    }
    return out.toOwnedSlice();
}

fn allHex(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

/// Replaces raw newlines in a regex source with `\r?\n`.
pub fn fixNewline(allocator: Allocator, pattern: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (pattern) |ch| {
        if (ch == '\n') {
            try out.appendSlice("\\r?\\n");
        } else {
            try out.append(ch);
        }
    }
    return out.toOwnedSlice();
}

pub const DisplayError = struct {
    text: []u8,
    kind: search.SearchMessageKind = .err,
};

/// Port of `rgErrorMsgForDisplay`, tolerant of rg version wording.
pub fn errorMessageForDisplay(allocator: Allocator, stderr: []const u8) ?DisplayError {
    const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
    if (trimmed.len == 0) return null;
    var first: []const u8 = "";
    var regex_error = false;
    var pcre2_line: []const u8 = "";
    var line_iterator = std.mem.splitScalar(u8, trimmed, '\n');
    while (line_iterator.next()) |line| {
        const value = std.mem.trim(u8, line, " \t\r");
        if (first.len == 0 and value.len > 0) first = value;
        if (std.mem.indexOf(u8, value, "regex parse error") != null) regex_error = true;
        if (std.mem.startsWith(u8, value, "PCRE2:")) pcre2_line = value;
        if (std.mem.startsWith(u8, value, "grep config error: unknown encoding:")) {
            const encoding = std.mem.trim(u8, value["grep config error: unknown encoding:".len..], " \t");
            return .{ .text = std.fmt.allocPrint(allocator, "Unknown encoding: {s}", .{encoding}) catch return null };
        }
    }
    if (regex_error) {
        var out = std.array_list.Managed(u8).init(allocator);
        out.appendSlice("Regex parse error") catch return null;
        if (pcre2_line.len > 0) {
            const without = std.mem.trim(u8, pcre2_line["PCRE2:".len..], " \t");
            out.appendSlice(": ") catch return null;
            out.appendSlice(without) catch return null;
        }
        return .{ .text = out.toOwnedSlice() catch return null };
    }
    if (std.mem.startsWith(u8, first, "error parsing glob")) {
        return .{ .text = uppercaseFirst(allocator, first) catch return null };
    }
    if (std.mem.startsWith(u8, first, "the literal")) {
        return .{ .text = uppercaseFirst(allocator, first) catch return null };
    }
    if (std.mem.startsWith(u8, first, "PCRE2: error compiling pattern")) {
        return .{ .text = allocator.dupe(u8, first) catch return null };
    }
    return .{ .text = allocator.dupe(u8, first) catch return null };
}

fn uppercaseFirst(allocator: Allocator, value: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, value);
    if (result.len > 0) result[0] = std.ascii.toUpper(result[0]);
    return result;
}
