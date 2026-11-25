// Port of shorten in src/vs/base/common/labels.ts.
const std = @import("std");

/// Paths and shortened labels are borrowed from the input or the caller's arena.
/// A null label stays null. Both native path separators and URL labels are supported.
pub fn shorten(arena: std.mem.Allocator, paths: []const ?[]const u8, default_separator: u8) ![]?[]const u8 {
    const labels = try arena.alloc(?[]const u8, paths.len);
    for (paths, labels, 0..) |maybe_path, *label, index| {
        const path = maybe_path orelse {
            label.* = null;
            continue;
        };
        if (path.len == 0) {
            label.* = try arena.dupe(u8, &.{ '.', default_separator });
            continue;
        }
        const scheme = std.mem.indexOfAny(u8, path, ":/\\?#");
        const url = if (scheme) |end| end > 0 and std.mem.startsWith(u8, path[end..], "://") else false;
        const separator = if (url) '/' else default_separator;
        const prefix_len = if (url) scheme.? + 3 else if (std.mem.startsWith(u8, path, "\\\\")) @as(usize, 2) else if (path[0] == separator or path[0] == '~') @as(usize, 1) else 0;
        const prefix = path[0..prefix_len];
        const trimmed = path[prefix_len..];
        var segments: std.ArrayList(usize) = .empty;
        try segments.append(arena, 0);
        for (trimmed, 0..) |c, at| if (c == separator) {
            try segments.append(arena, at + 1);
        };
        const first = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, separator) orelse trimmed.len];
        label.* = path;
        // Prefer the shortest unique subpath, checking suffixes first.
        outer: for (1..segments.items.len + 1) |length| {
            var start = segments.items.len - length + 1;
            while (start != 0) {
                start -= 1;
                const end = start + length;
                const stop = if (end == segments.items.len) trimmed.len else segments.items[end] - 1;
                const subpath = trimmed[segments.items[start]..stop];
                for (paths, 0..) |other_path, other_index| {
                    const other = other_path orelse continue;
                    if (index == other_index or other.len == 0 or std.mem.indexOf(u8, other, subpath) == null) continue;
                    if (end != segments.items.len) break;
                    // Match an entire last segment when the other path has directories.
                    const suffix = if (start > 0 and std.mem.indexOfScalar(u8, other, separator) != null) trimmed[segments.items[start] - 1 .. stop] else subpath;
                    if (std.mem.endsWith(u8, other, suffix)) break;
                } else {
                    var result: std.ArrayList(u8) = .empty;
                    var from = start;
                    if (prefix.len != 0 or std.mem.endsWith(u8, first, ":")) {
                        try result.appendSlice(arena, prefix);
                        if (from == 1) from = 0;
                        if (from > 0) {
                            try result.appendSlice(arena, first);
                            try result.append(arena, separator);
                        }
                    }
                    if (from > 0) {
                        try result.appendSlice(arena, "…");
                        try result.append(arena, separator);
                    }
                    try result.appendSlice(arena, trimmed[segments.items[from]..stop]);
                    if (end < segments.items.len) {
                        try result.append(arena, separator);
                        if (end + 1 != segments.items.len or segments.getLast() != trimmed.len) try result.appendSlice(arena, "…");
                    }
                    label.* = result.items;
                    break :outer;
                }
            }
        }
    }
    return labels;
}
