// Port of src/vs/workbench/services/search/common/searchHelpers.ts.
// FileMatch owns matches and surrounding-context rows in separate collections.
const std = @import("std");
const search = @import("search.zig");
const FindMatch = @import("../../../../editor/common/model.zig").FindMatch;

pub fn editorMatchesToTextSearchResults(allocator: std.mem.Allocator, matches: []const FindMatch, model: anytype, preview: ?search.PreviewOptions) ![]search.TextSearchMatch {
    var results: std.ArrayList(search.TextSearchMatch) = .empty;
    errdefer {
        for (results.items) |*result| result.deinit();
        results.deinit(allocator);
    }
    var start: usize = 0;
    while (start < matches.len) {
        var end = start + 1;
        while (end < matches.len and matches[end].range.startLineNumber == matches[end - 1].range.endLineNumber) end += 1;
        var lines: std.ArrayList(u8) = .empty;
        defer lines.deinit(allocator);
        for (matches[start].range.startLineNumber..matches[end - 1].range.endLineNumber + 1) |number| {
            var line = try model.getLineContent(number);
            defer line.deinit();
            try lines.appendSlice(allocator, line.items);
            try lines.append(allocator, '\n');
        }
        const ranges = try allocator.alloc(search.SearchRange, end - start);
        defer allocator.free(ranges);
        for (matches[start..end], ranges) |match, *range| {
            const r = match.range;
            range.* = .init(r.startLineNumber - 1, r.startColumn - 1, r.endLineNumber - 1, r.endColumn - 1);
        }
        try results.ensureUnusedCapacity(allocator, 1);
        results.appendAssumeCapacity(try .init(allocator, lines.items, ranges, preview));
        start = end;
    }
    return results.toOwnedSlice(allocator);
}

pub fn getTextSearchMatchWithModelContext(allocator: std.mem.Allocator, matches: []const search.TextSearchMatch, model: anytype, surrounding: usize) ![]search.TextSearchContext {
    var rows: std.ArrayList(search.TextSearchContext) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var previous_end: usize = 0;
    for (matches, 0..) |match, i| {
        const ranges = match.range_locations;
        const start = ranges[0].source.start_line_number + 1;
        const end = ranges[ranges.len - 1].source.end_line_number + 1;
        const before = @max(previous_end + 1, start -| surrounding);
        for (before..start) |line| try appendContext(&rows, allocator, model, line);
        const next = if (i + 1 < matches.len) matches[i + 1].range_locations[0].source.start_line_number else model.getLineCount();
        const after = @min(next, end +| surrounding, model.getLineCount());
        for (end..after) |line| try appendContext(&rows, allocator, model, line + 1);
        previous_end = end;
    }
    return rows.toOwnedSlice(allocator);
}

fn appendContext(rows: *std.ArrayList(search.TextSearchContext), allocator: std.mem.Allocator, model: anytype, line: usize) !void {
    var text = try model.getLineContent(line);
    defer text.deinit();
    try rows.ensureUnusedCapacity(allocator, 1);
    rows.appendAssumeCapacity(.{ .text = try allocator.dupe(u8, text.items), .line_number = line });
}
