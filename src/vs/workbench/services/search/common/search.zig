// Port of the text-search types and preview behavior from
// `src/vs/workbench/services/search/common/search.ts`.
//
// Terminal adaptation: resources are canonical path strings instead of URIs,
// and the search service is an incremental job rather than an asynchronous
// `ISearchService.textSearch` promise. The query and result shapes otherwise
// follow upstream so the search tree model can mirror `searchView.ts`.

const std = @import("std");
const glob = @import("../../../../base/common/glob.zig");
const strings = @import("../../../../base/common/strings.zig");
const Allocator = std.mem.Allocator;
const configuration = @import("../../../../platform/configuration/common/configuration.zig");

pub const DEFAULT_MAX_SEARCH_RESULTS: usize = 20_000;
pub const SEARCH_EXCLUDE_CONFIG = "search.exclude";

/// Port of upstream `ViewMode`.
pub const ViewMode = enum {
    list,
    tree,

    pub fn fromString(value: []const u8) ViewMode {
        return if (std.mem.eql(u8, value, "tree")) .tree else .list;
    }

    pub fn toString(self: ViewMode) []const u8 {
        return switch (self) {
            .list => "list",
            .tree => "tree",
        };
    }
};

/// Port of upstream `SearchSortOrder`.
pub const SearchSortOrder = enum {
    default,
    file_names,
    type,
    modified,
    count_descending,
    count_ascending,

    pub fn fromString(value: []const u8) SearchSortOrder {
        if (std.mem.eql(u8, value, "fileNames")) return .file_names;
        if (std.mem.eql(u8, value, "type")) return .type;
        if (std.mem.eql(u8, value, "modified")) return .modified;
        if (std.mem.eql(u8, value, "countDescending")) return .count_descending;
        if (std.mem.eql(u8, value, "countAscending")) return .count_ascending;
        return .default;
    }

    pub fn toString(self: SearchSortOrder) []const u8 {
        return switch (self) {
            .default => "default",
            .file_names => "fileNames",
            .type => "type",
            .modified => "modified",
            .count_descending => "countDescending",
            .count_ascending => "countAscending",
        };
    }
};

pub const SEARCH_ELIDED_PREFIX = "⟪ ";
pub const SEARCH_ELIDED_SUFFIX = " characters skipped ⟫";
pub const SEARCH_ELIDED_MIN_LEN = (SEARCH_ELIDED_PREFIX.len + SEARCH_ELIDED_SUFFIX.len + 5) * 2;

pub const PreviewOptions = struct {
    match_lines: usize = 1,
    chars_per_line: usize = 1000,
};

pub const PatternInfo = struct {
    pattern: []const u8,
    is_regex: bool = false,
    is_word_match: bool = false,
    is_case_sensitive: bool = false,
    word_separators: ?[]const u8 = null,
};

pub const FolderQuery = struct {
    folder: []const u8,
};

/// Options that upstream's query builder attaches to a text query. The
/// terminal service applies `exclude_entries` through
/// `glob.ParsedExcludeExpression` and uses `use_ignore_files` to decide whether
/// `.gitignore`/`.ignore` files are loaded.
pub const TextQueryOptions = struct {
    preview: PreviewOptions = .{},
    max_results: usize = DEFAULT_MAX_SEARCH_RESULTS,
    use_ignore_files: bool = true,
    exclude_entries: []const glob.ExcludeEntry = &.{},
};

/// Owned text query. The view builds it from the inputs and workspace; the
/// search model keeps it alive for the duration of the job and result heading.
pub const TextQuery = struct {
    allocator: Allocator,
    pattern: []u8,
    is_regex: bool = false,
    is_word_match: bool = false,
    is_case_sensitive: bool = false,
    folder_queries: []FolderQuery,
    folder_paths: [][]u8,
    include_pattern: []u8,
    exclude_pattern: []u8,
    exclude_entries: []glob.ExcludeEntry,
    extra_files: [][]u8,
    use_ignore_files: bool = true,
    preview: PreviewOptions = .{},
    max_results: usize = DEFAULT_MAX_SEARCH_RESULTS,

    pub fn init(
        allocator: Allocator,
        pattern: []const u8,
        folder_paths: []const []const u8,
        include_pattern: []const u8,
        exclude_pattern: []const u8,
        extra_files: []const []const u8,
    ) !TextQuery {
        return initWithOptions(
            allocator,
            pattern,
            folder_paths,
            include_pattern,
            exclude_pattern,
            extra_files,
            .{},
        );
    }

    pub fn initWithOptions(
        allocator: Allocator,
        pattern: []const u8,
        folder_paths: []const []const u8,
        include_pattern: []const u8,
        exclude_pattern: []const u8,
        extra_files: []const []const u8,
        options: TextQueryOptions,
    ) !TextQuery {
        const pattern_copy = try allocator.dupe(u8, pattern);
        errdefer allocator.free(pattern_copy);
        const include_copy = try allocator.dupe(u8, include_pattern);
        errdefer allocator.free(include_copy);
        const exclude_copy = try allocator.dupe(u8, exclude_pattern);
        errdefer allocator.free(exclude_copy);

        const folders = try allocator.alloc([]u8, folder_paths.len);
        errdefer allocator.free(folders);
        var copied: usize = 0;
        errdefer for (folders[0..copied]) |path| allocator.free(path);
        for (folder_paths, 0..) |path, index| {
            folders[index] = try allocator.dupe(u8, path);
            copied += 1;
        }

        const extras = try allocator.alloc([]u8, extra_files.len);
        errdefer allocator.free(extras);
        var extra_copied: usize = 0;
        errdefer for (extras[0..extra_copied]) |path| allocator.free(path);
        for (extra_files, 0..) |path, index| {
            extras[index] = try allocator.dupe(u8, path);
            extra_copied += 1;
        }

        const queries = try allocator.alloc(FolderQuery, folders.len);
        errdefer allocator.free(queries);
        for (folders, 0..) |path, index| {
            queries[index] = .{ .folder = path };
        }

        const exclude_entries = try allocator.alloc(glob.ExcludeEntry, options.exclude_entries.len);
        errdefer allocator.free(exclude_entries);
        var entries_copied: usize = 0;
        errdefer for (exclude_entries[0..entries_copied]) |entry| {
            allocator.free(entry.pattern);
            if (entry.when) |when| allocator.free(when);
        };
        for (options.exclude_entries, 0..) |entry, index| {
            const entry_pattern = try allocator.dupe(u8, entry.pattern);
            errdefer allocator.free(entry_pattern);
            const when = if (entry.when) |value| try allocator.dupe(u8, value) else null;
            exclude_entries[index] = .{
                .pattern = entry_pattern,
                .enabled = entry.enabled,
                .when = when,
            };
            entries_copied += 1;
        }

        return .{
            .allocator = allocator,
            .pattern = pattern_copy,
            .folder_queries = queries,
            .folder_paths = folders,
            .include_pattern = include_copy,
            .exclude_pattern = exclude_copy,
            .exclude_entries = exclude_entries,
            .extra_files = extras,
            .use_ignore_files = options.use_ignore_files,
            .preview = options.preview,
            .max_results = options.max_results,
        };
    }

    pub fn deinit(self: *TextQuery) void {
        self.allocator.free(self.pattern);
        self.allocator.free(self.include_pattern);
        self.allocator.free(self.exclude_pattern);
        for (self.exclude_entries) |entry| {
            self.allocator.free(entry.pattern);
            if (entry.when) |when| self.allocator.free(when);
        }
        self.allocator.free(self.exclude_entries);
        for (self.folder_paths) |path| self.allocator.free(path);
        self.allocator.free(self.folder_paths);
        self.allocator.free(self.folder_queries);
        for (self.extra_files) |path| self.allocator.free(path);
        self.allocator.free(self.extra_files);
    }

    pub fn patternInfo(self: *const TextQuery) PatternInfo {
        return .{
            .pattern = self.pattern,
            .is_regex = self.is_regex,
            .is_word_match = self.is_word_match,
            .is_case_sensitive = self.is_case_sensitive,
        };
    }
};

/// Port of upstream `getExcludes`: merges `files.exclude` and `search.exclude`
/// into the ordered entries consumed by `glob.ParsedExcludeExpression`.
/// `search.exclude` wins for duplicate patterns.
pub fn getExcludes(
    allocator: Allocator,
    file_excludes: ?*const configuration.Value,
    search_excludes: ?*const configuration.Value,
) ![]glob.ExcludeEntry {
    var entries = std.array_list.Managed(glob.ExcludeEntry).init(allocator);
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.pattern);
            if (entry.when) |when| allocator.free(when);
        }
        entries.deinit();
    }

    if (file_excludes) |value| try appendExcludeEntries(allocator, &entries, value);
    if (search_excludes) |value| try appendExcludeEntries(allocator, &entries, value);
    return try entries.toOwnedSlice();
}

fn appendExcludeEntries(
    allocator: Allocator,
    entries: *std.array_list.Managed(glob.ExcludeEntry),
    value: *const configuration.Value,
) !void {
    if (value.* != .object) return;
    var iterator = value.object.iterator();
    while (iterator.next()) |item| {
        if (std.mem.eql(u8, item.key_ptr.*, "__proto__")) continue;
        var enabled = true;
        var when: ?[]const u8 = null;
        switch (item.value_ptr.*) {
            .bool => |enabled_value| enabled = enabled_value,
            .object => |object| {
                if (object.get("when")) |clause| {
                    if (clause == .string) when = clause.string;
                }
            },
            else => continue,
        }

        const pattern = try allocator.dupe(u8, item.key_ptr.*);
        errdefer allocator.free(pattern);
        const clause = if (when) |string_value| try allocator.dupe(u8, string_value) else null;
        errdefer if (clause) |clause_text| allocator.free(clause_text);

        var replaced = false;
        for (entries.items) |*existing| {
            if (!std.mem.eql(u8, existing.pattern, item.key_ptr.*)) continue;
            allocator.free(existing.pattern);
            if (existing.when) |old| allocator.free(old);
            existing.* = .{
                .pattern = pattern,
                .enabled = enabled,
                .when = clause,
            };
            replaced = true;
            break;
        }
        if (replaced) continue;

        try entries.append(.{
            .pattern = pattern,
            .enabled = enabled,
            .when = clause,
        });
    }
}

pub fn freeExcludes(allocator: Allocator, entries: []glob.ExcludeEntry) void {
    if (entries.len == 0) return;
    for (entries) |entry| {
        allocator.free(entry.pattern);
        if (entry.when) |when| allocator.free(when);
    }
    allocator.free(entries);
}

pub const SearchRange = struct {
    start_line_number: usize,
    start_column: usize,
    end_line_number: usize,
    end_column: usize,

    pub fn init(start_line: usize, start_column: usize, end_line: usize, end_column: usize) SearchRange {
        return .{
            .start_line_number = start_line,
            .start_column = start_column,
            .end_line_number = end_line,
            .end_column = end_column,
        };
    }
};

pub const OneLineRange = struct {
    line_number: usize,
    start_column: usize,
    end_column: usize,

    pub fn init(line_number: usize, start_column: usize, end_column: usize) OneLineRange {
        return .{ .line_number = line_number, .start_column = start_column, .end_column = end_column };
    }
};

pub const RangeLocation = struct {
    source: SearchRange,
    preview: SearchRange,
};

/// Port of upstream `TextSearchMatch`, including the one-line preview elision
/// rules. `preview_text` and `range_locations` are owned.
pub const TextSearchMatch = struct {
    allocator: Allocator,
    preview_text: []u8,
    range_locations: []RangeLocation,

    pub fn init(
        allocator: Allocator,
        text: []const u8,
        ranges: []const SearchRange,
        preview_options: ?PreviewOptions,
    ) !TextSearchMatch {
        if (preview_options != null and preview_options.?.match_lines == 1 and isSingleLineRangeList(ranges)) {
            const line = getNLines(text, preview_options.?.match_lines);
            const chars = preview_options.?.chars_per_line;
            const leading_chars = chars / 5;

            var preview = std.array_list.Managed(u8).init(allocator);
            defer preview.deinit();
            var locations = std.array_list.Managed(RangeLocation).init(allocator);
            defer locations.deinit();

            var shift: isize = 0;
            var last_end: usize = 0;
            for (ranges) |range| {
                const preview_start = if (range.start_column > leading_chars) range.start_column - leading_chars else 0;
                const preview_end = @min(line.len, range.start_column + chars);
                if (preview_start > last_end + leading_chars + SEARCH_ELIDED_MIN_LEN) {
                    var number_buffer: [32]u8 = undefined;
                    const number = std.fmt.bufPrint(&number_buffer, "{d}", .{preview_start - last_end}) catch "0";
                    try preview.appendSlice(SEARCH_ELIDED_PREFIX);
                    try preview.appendSlice(number);
                    try preview.appendSlice(SEARCH_ELIDED_SUFFIX);
                    const elision_len = SEARCH_ELIDED_PREFIX.len + number.len + SEARCH_ELIDED_SUFFIX.len;
                    shift += @as(isize, @intCast(preview_start)) - @as(isize, @intCast(last_end + elision_len));
                    if (preview_start <= line.len) try preview.appendSlice(line[preview_start..preview_end]);
                } else {
                    if (last_end <= line.len and last_end <= preview_end) {
                        try preview.appendSlice(line[last_end..preview_end]);
                    }
                }
                last_end = preview_end;
                try locations.append(.{
                    .source = range,
                    .preview = SearchRange.init(
                        0,
                        stableColumn(range.start_column, shift),
                        0,
                        stableColumn(range.end_column, shift),
                    ),
                });
            }

            return .{
                .allocator = allocator,
                .preview_text = try preview.toOwnedSlice(),
                .range_locations = try locations.toOwnedSlice(),
            };
        }

        const first_match_line = if (ranges.len > 0) ranges[0].start_line_number else 0;
        const locations = try allocator.alloc(RangeLocation, ranges.len);
        errdefer allocator.free(locations);
        for (ranges, 0..) |range, index| {
            locations[index] = .{
                .source = range,
                .preview = SearchRange.init(
                    range.start_line_number -| first_match_line,
                    range.start_column,
                    range.end_line_number -| first_match_line,
                    range.end_column,
                ),
            };
        }
        return .{
            .allocator = allocator,
            .preview_text = try allocator.dupe(u8, text),
            .range_locations = locations,
        };
    }

    pub fn deinit(self: *TextSearchMatch) void {
        self.allocator.free(self.preview_text);
        self.allocator.free(self.range_locations);
    }

    pub fn firstSource(self: *const TextSearchMatch) ?SearchRange {
        if (self.range_locations.len == 0) return null;
        return self.range_locations[0].source;
    }
};

fn stableColumn(value: usize, shift: isize) usize {
    const adjusted: isize = @as(isize, @intCast(value)) - shift;
    return if (adjusted < 0) 0 else @intCast(adjusted);
}

pub fn isSingleLineRangeList(ranges: []const SearchRange) bool {
    if (ranges.len == 0) return false;
    const line = ranges[0].start_line_number;
    for (ranges) |range| {
        if (range.start_line_number != line or range.end_line_number != line) return false;
    }
    return true;
}

pub fn getNLines(text: []const u8, lines: usize) []const u8 {
    if (lines == 0) return "";
    var seen: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\n') {
            seen += 1;
            if (seen >= lines) {
                var end = index;
                if (end > 0 and text[end - 1] == '\r') end -= 1;
                return text[0..end];
            }
        }
    }
    var end = text.len;
    if (end > 0 and text[end - 1] == '\r') end -= 1;
    return text[0..end];
}

pub const SearchFileResult = struct {
    allocator: Allocator,
    resource: []u8,
    results: []TextSearchMatch,

    pub fn deinit(self: *SearchFileResult) void {
        self.allocator.free(self.resource);
        for (self.results) |*result| result.deinit();
        self.allocator.free(self.results);
    }
};

pub const SearchStep = struct {
    results: []SearchFileResult,
    done: bool,
    limit_hit: bool,
};

pub const ISearchJob = struct {
    context: *anyopaque,
    step: *const fn (context: *anyopaque, allocator: Allocator, max_files: usize) anyerror!SearchStep,
    cancel: *const fn (context: *anyopaque) void,
    deinit: *const fn (context: *anyopaque) void,
};

pub const ISearchService = struct {
    context: *anyopaque,
    start_text_search: *const fn (context: *anyopaque, query: *const TextQuery) anyerror!ISearchJob,
};

pub const FileContentProvider = struct {
    context: *anyopaque,
    /// Returns owned content for an open editor, or null to read from disk.
    read: ?*const fn (context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8 = null,
    /// Returns owned paths for open files outside the workspace.
    extra_files: ?*const fn (context: *anyopaque, allocator: Allocator) anyerror![][]u8 = null,
    free_paths: ?*const fn (context: *anyopaque, allocator: Allocator, paths: [][]u8) void = null,
};

pub fn resultIsMatch(result: anytype) bool {
    _ = result;
    return true;
}

test "TextSearchMatch: single line preview" {
    const allocator = std.testing.allocator;
    const ranges = [_]SearchRange{SearchRange.init(5, 4, 5, 7)};
    var result = try TextSearchMatch.init(allocator, "foo bar", &ranges, .{ .match_lines = 1, .chars_per_line = 100 });
    defer result.deinit();
    try std.testing.expectEqualStrings("foo bar", result.preview_text);
    try std.testing.expectEqual(@as(usize, 1), result.range_locations.len);
    const range = result.range_locations[0].preview;
    try std.testing.expectEqualStrings("bar", result.preview_text[range.start_column..range.end_column]);
}

test "TextSearchMatch: multiline preview keeps relative ranges" {
    const allocator = std.testing.allocator;
    const ranges = [_]SearchRange{SearchRange.init(5, 4, 6, 3)};
    var result = try TextSearchMatch.init(allocator, "foo bar\nfoo bar", &ranges, .{ .match_lines = 1, .chars_per_line = 10000 });
    defer result.deinit();
    try std.testing.expectEqualStrings("foo bar\nfoo bar", result.preview_text);
    try std.testing.expectEqual(@as(usize, 4), result.range_locations[0].preview.start_column);
    try std.testing.expectEqual(@as(usize, 1), result.range_locations[0].preview.end_line_number);
}

test "TextSearchMatch: multi-range preview and line endings" {
    const allocator = std.testing.allocator;
    const ranges = [_]SearchRange{
        SearchRange.init(0, 4, 0, 7),
        SearchRange.init(0, 8, 0, 11),
    };
    var result = try TextSearchMatch.init(allocator, "foo bar baz", &ranges, .{ .match_lines = 1, .chars_per_line = 100 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.range_locations.len);
    try std.testing.expectEqualStrings("bar", result.preview_text[result.range_locations[0].preview.start_column..result.range_locations[0].preview.end_column]);
    try std.testing.expectEqualStrings("baz", result.preview_text[result.range_locations[1].preview.start_column..result.range_locations[1].preview.end_column]);

    var trimmed = try TextSearchMatch.init(allocator, "foo bar\r\n", &[_]SearchRange{SearchRange.init(0, 4, 0, 7)}, .{ .match_lines = 1, .chars_per_line = 1000 });
    defer trimmed.deinit();
    try std.testing.expectEqualStrings("foo bar", trimmed.preview_text);
}

/// Port of `isFilePatternMatch`: fuzzy sequence match or glob match, honoring
/// `ignoreCase`.
pub fn isFilePatternMatch(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    search_path: ?[]const u8,
    file_pattern: []const u8,
    fuzzy: bool,
    ignore_case: bool,
) !bool {
    const path_to_match = search_path orelse relative_path;
    if (fuzzy) return strings.fuzzyContains(path_to_match, file_pattern);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var expression = try glob.Expression.init(arena.allocator(), &.{file_pattern}, .{ .ignore_case = ignore_case });
    return expression.matches(path_to_match);
}
