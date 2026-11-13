// Port of the text-search types and preview behavior from
// `src/vs/workbench/services/search/common/search.ts`.
//
// Terminal adaptation: resources are canonical path strings instead of URIs,
// and the search service is an incremental job rather than an asynchronous
// `ISearchService.textSearch` promise. The query and result shapes otherwise
// follow upstream so the search tree model can mirror `searchView.ts`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DEFAULT_MAX_SEARCH_RESULTS: usize = 20_000;

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
    extra_files: [][]u8,
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

        return .{
            .allocator = allocator,
            .pattern = pattern_copy,
            .folder_queries = queries,
            .folder_paths = folders,
            .include_pattern = include_copy,
            .exclude_pattern = exclude_copy,
            .extra_files = extras,
        };
    }

    pub fn deinit(self: *TextQuery) void {
        self.allocator.free(self.pattern);
        self.allocator.free(self.include_pattern);
        self.allocator.free(self.exclude_pattern);
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
