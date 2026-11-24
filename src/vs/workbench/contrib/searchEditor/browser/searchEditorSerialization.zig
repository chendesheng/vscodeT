// Port of the text-result snapshot in
// `src/vs/workbench/contrib/searchEditor/browser/searchEditorSerialization.ts`.
// The terminal preserves editor byte columns and serializes the current
// workspace matches with zero context, as Open Results in Editor requests.

const std = @import("std");
const tree = @import("../../search/browser/searchTreeModel/searchTreeCommon.zig");
const compare = @import("../../search/browser/searchCompare.zig");
const results_view = @import("../../search/browser/searchResultsView.zig");
const SearchSortOrder = @import("../../../services/search/common/search.zig").SearchSortOrder;
const Range = @import("../../../../editor/common/core/range.zig").Range;

pub const Snapshot = struct {
    text: []const u8,
    match_ranges: []const Range,

    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.match_ranges);
    }
};

pub fn serializeSearchResultForEditor(
    allocator: std.mem.Allocator,
    result: *tree.SearchResult,
    sort_order: SearchSortOrder,
    limit_hit: bool,
) !Snapshot {
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(allocator);

    const count = result.count();
    const files_count = result.fileCount();
    if (count == 0) {
        try text.writer.writeAll("No Results\n");
    } else {
        try text.writer.print("{d} {s} - {d} {s}\n", .{
            count,       if (count == 1) "result" else "results",
            files_count, if (files_count == 1) "file" else "files",
        });
    }

    var line: usize = 3;
    if (limit_hit) {
        try text.writer.writeAll("The result set only contains a subset of all matches. Be more specific in your search to narrow down the results.\n");
        line += 1;
    }
    if (count > 0) try text.writer.writeByte('\n');
    const multi_root = if (result.query) |query| query.folder_paths.len > 1 else false;
    var wrote_file = false;
    const folders = try result.folderMatches(allocator);
    defer allocator.free(folders);
    std.sort.heap(*tree.FolderMatch, folders, sort_order, folderLessThan);
    for (folders) |folder| {
        const files = try folder.allDownstreamFiles(allocator);
        defer allocator.free(files);
        std.sort.heap(*tree.FileMatch, files, sort_order, fileLessThan);
        for (files) |file| {
            if (file.count() == 0) continue;
            if (wrote_file) {
                try text.writer.writeByte('\n');
                line += 1;
            }
            if (multi_root and !folder.is_other) try text.writer.print("{s}/", .{folder.name});
            try fileMatchToSearchResultFormat(allocator, &text.writer, &ranges, file, &line);
            wrote_file = true;
        }
    }

    const contents = try text.toOwnedSlice();
    errdefer allocator.free(contents);
    return .{ .text = contents, .match_ranges = try ranges.toOwnedSlice(allocator) };
}

fn fileMatchToSearchResultFormat(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    ranges: *std.ArrayList(Range),
    file: *tree.FileMatch,
    line: *usize,
) !void {
    const matches = try allocator.dupe(*tree.Match, file.textMatches());
    defer allocator.free(matches);
    std.sort.heap(*tree.Match, matches, {}, matchLessThan);
    if (matches.len == 0) return;
    const last_line = matches[matches.len - 1].range().endLineNumber;
    const digits = digitCount(last_line);
    try writer.print("{s}:\n", .{results_view.relativePath(file)});
    line.* += 1;

    var seen_lines: std.AutoHashMap(usize, usize) = .init(allocator);
    defer seen_lines.deinit();
    for (matches) |match| {
        const lines = try match.fullPreviewLines(allocator);
        defer allocator.free(lines);
        const preview_range = match.rangeInPreview();
        for (lines, 0..) |raw_source, index| {
            const source = std.mem.trimEnd(u8, raw_source, "\r\n");
            const source_line = match.range().startLineNumber + index;
            const entry = try seen_lines.getOrPut(source_line);
            const padding = digits -| digitCount(source_line);
            const prefix_len = 2 + padding + digitCount(source_line) + 2;
            if (!entry.found_existing) {
                entry.value_ptr.* = line.*;
                try writer.splatByteAll(' ', 2 + padding);
                try writer.print("{d}: {s}\n", .{ source_line, source });
                line.* += 1;
            }
            const start = if (index == 0) preview_range.start_column -| 1 else 0;
            const end = if (index + 1 == lines.len) preview_range.end_column -| 1 else source.len;
            try ranges.append(allocator, Range.init(
                entry.value_ptr.*,
                prefix_len + 1 + @min(start, source.len),
                entry.value_ptr.*,
                prefix_len + 1 + @min(end, source.len),
            ));
        }
    }
}

fn digitCount(line: usize) usize {
    return if (line == 0) 1 else std.math.log10_int(line) + 1;
}

fn folderLessThan(sort_order: SearchSortOrder, a: *tree.FolderMatch, b: *tree.FolderMatch) bool {
    return compare.searchMatchComparer(.{ .folder = a }, .{ .folder = b }, sort_order) < 0;
}

fn fileLessThan(sort_order: SearchSortOrder, a: *tree.FileMatch, b: *tree.FileMatch) bool {
    return compare.searchMatchComparer(.{ .file = a }, .{ .file = b }, sort_order) < 0;
}

fn matchLessThan(_: void, a: *tree.Match, b: *tree.Match) bool {
    return compare.searchMatchComparer(.{ .match = a }, .{ .match = b }, .default) < 0;
}
