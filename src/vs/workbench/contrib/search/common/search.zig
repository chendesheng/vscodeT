// Port of the portable subset of
// `src/vs/workbench/contrib/search/common/search.ts`.
//
// The terminal workbench has no context-key service, so `SearchStateKey` is
// exposed as the upstream key name and `SearchUIState` is carried by the search
// view controller. Workspace-symbol providers, notebook priority helpers and
// configuration-registry nodes are not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../../../../editor/common/core/range.zig").Range;

pub const SearchUIState = enum { idle, searching, slow_search };

pub const SearchStateKey = "searchState";

pub const IFilterAndRange = struct {
    /// Owned by the caller.
    filter: []u8,
    range: Range,
};

/// Port of `extractRangeFromFilter`: parses trailing `file:line`,
/// `file:line:column` and range suffixes (`20-40`, `20:3-40:5`, `(19,20)`,
/// `#20#3-40,5`). Returns null when the filter has no range suffix.
pub fn extractRangeFromFilter(
    allocator: Allocator,
    filter: []const u8,
    unless: []const []const u8,
) !?IFilterAndRange {
    if (filter.len == 0) return null;

    for (unless) |value| {
        if (value.len == 0) continue;
        if (std.mem.indexOf(u8, filter, value)) |position| {
            if (position == 0) return null;
            if (!containsRangeSuffix(filter[position + 1 ..])) return null;
        }
    }

    var index: usize = 0;
    while (index < filter.len) : (index += 1) {
        if (filter[index] != ':' and filter[index] != '#' and filter[index] != '(') continue;
        var start = index;
        if (start > 0 and filter[start - 1] == ' ') start -= 1;
        const range = parseSuffixRange(filter[index..]) orelse continue;
        const prefix = std.mem.trimEnd(u8, filter[0..start], " \t\r\n");
        return .{
            .filter = try allocator.dupe(u8, prefix),
            .range = range,
        };
    }
    return null;
}

fn containsRangeSuffix(text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != ':' and text[index] != '#' and text[index] != '(') continue;
        if (parseSuffixRange(text[index..]) != null) return true;
    }
    return false;
}

fn parseSuffixRange(suffix: []const u8) ?Range {
    var cursor: usize = 0;
    if (cursor >= suffix.len) return null;
    if (suffix[cursor] != ':' and suffix[cursor] != '#' and suffix[cursor] != '(') return null;
    cursor += 1;
    if (std.mem.startsWith(u8, suffix[cursor..], "line ")) cursor += 5;

    const start_line = parseNumber(suffix, &cursor);
    var start_column: ?usize = null;
    var end_line: ?usize = null;
    var end_column: ?usize = null;

    if (cursor < suffix.len and isSeparator(suffix[cursor])) {
        cursor += 1;
        start_column = parseNumber(suffix, &cursor);
    }
    if (cursor < suffix.len and suffix[cursor] == '-') {
        cursor += 1;
        end_line = parseNumber(suffix, &cursor);
        if (cursor < suffix.len and isSeparator(suffix[cursor])) {
            cursor += 1;
            end_column = parseNumber(suffix, &cursor);
        }
    }
    if (cursor < suffix.len and suffix[cursor] == ')') cursor += 1;
    if (cursor < suffix.len and suffix[cursor] == ':') cursor += 1;
    if (cursor != suffix.len) return null;

    var line = start_line orelse 1;
    var column = start_column orelse 1;
    if (line == 0) line = 1;
    if (column == 0) column = 1;
    var end = line;
    var end_column_value = column;
    if (end_line) |value| {
        end = if (value == 0) 1 else value;
        end_column_value = end_column orelse 1;
        if (end_column_value == 0) end_column_value = 1;
    }

    return Range.init(line, column, end, end_column_value);
}

fn parseNumber(text: []const u8, cursor: *usize) ?usize {
    const start = cursor.*;
    var value: usize = 0;
    while (cursor.* < text.len and std.ascii.isDigit(text[cursor.*])) : (cursor.* += 1) {
        value = value * 10 + (text[cursor.*] - '0');
    }
    if (cursor.* == start) return null;
    return value;
}

fn isSeparator(character: u8) bool {
    return character == ':' or character == '#' or character == ',';
}
