// Port of the `stripIcons`/`escapeIcons` subset of
// `src/vs/base/common/iconLabels.ts`. The fuzzy-matching helpers of that file
// are not ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const regexp = @import("../../../support/regexp.zig");

const icon_pattern = "\\$\\([A-Za-z0-9-]+(?:~[A-Za-z]+)?\\)";
const escape_pattern = "(\\\\)?" ++ icon_pattern;
// Note: `icon_pattern` contains no capturing groups, so groups 1/2 are the
// optional whitespace and escape marker.
const strip_pattern = "(\\s)?(\\\\)?" ++ icon_pattern ++ "(\\s)?";

/// Removes `$(iconId)` markers, keeping escaped markers and collapsing the
/// whitespace that surrounded a removed icon.
pub fn stripIcons(allocator: Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, text, "$(") == null) return allocator.dupe(u8, text);

    var regex = try regexp.RegExp.init(strip_pattern, .{});
    defer regex.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var index: usize = 0;
    var search_index: usize = 0;
    while (regex.searchFrom(text, search_index)) |result| {
        defer result.deinit();
        const start = result.index();
        try out.writer.writeAll(text[index..start]);
        const escaped = result.groupNOrNull(2) != null;
        if (escaped) {
            try out.writer.writeAll(result.groupN(0));
        } else {
            const pre = result.groupNOrNull(1) orelse "";
            const post = result.groupNOrNull(3) orelse "";
            if (pre.len == 0 and post.len > 0) {
                try out.writer.writeAll(post);
            } else if (pre.len > 0) {
                try out.writer.writeAll(pre);
            }
        }
        index = start + result.length();
        search_index = index;
    }
    try out.writer.writeAll(text[index..]);
    return out.toOwnedSlice();
}

/// Escapes icon markers with a backslash.
pub fn escapeIcons(allocator: Allocator, text: []const u8) ![]u8 {
    var regex = try regexp.RegExp.init(escape_pattern, .{});
    defer regex.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var index: usize = 0;
    var search_index: usize = 0;
    while (regex.searchFrom(text, search_index)) |result| {
        defer result.deinit();
        const start = result.index();
        try out.writer.writeAll(text[index..start]);
        if (result.groupNOrNull(1) == null) try out.writer.writeAll("\\");
        try out.writer.writeAll(result.groupN(0));
        index = start + result.length();
        search_index = index;
    }
    try out.writer.writeAll(text[index..]);
    return out.toOwnedSlice();
}
