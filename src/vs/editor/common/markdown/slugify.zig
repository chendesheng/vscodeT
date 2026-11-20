//! GitHub-style heading slugs, a port of
//! `vscode/extensions/markdown-language-features/src/slugify.ts`.
//!
//! Ambient Unicode case mapping is not available in this port, so ASCII is
//! lowercased and non-ASCII code points are retained unchanged. This keeps
//! Latin/CJK headings stable; the upstream regex removes some exotic
//! punctuation that this implementation preserves.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Stateful slug builder for one document. Duplicate headings get `-1`, `-2`,
/// exactly like `githubSlugifier.createBuilder()`.
pub const SlugBuilder = struct {
    allocator: Allocator,
    counts: std.StringHashMap(usize),

    pub fn init(allocator: Allocator) SlugBuilder {
        return .{
            .allocator = allocator,
            .counts = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *SlugBuilder) void {
        self.counts.deinit();
    }

    pub fn add(self: *SlugBuilder, heading: []const u8) ![]const u8 {
        const base = try slugify(self.allocator, heading);
        const entry = try self.counts.getOrPut(base);
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
            return base;
        }
        entry.value_ptr.* += 1;
        return std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ base, entry.value_ptr.* });
    }
};

/// Converts a heading's plain text to the fragment used by `#heading` links.
pub fn slugify(allocator: Allocator, heading: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, heading, " \t\r\n");
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var offset: usize = 0;
    while (offset < trimmed.len) {
        const decoded = decodeAt(trimmed, offset);
        if (decoded.len == 0) break;
        offset += decoded.len;
        const cp = decoded.cp;
        if (cp < 0x80) {
            if (cp >= 'A' and cp <= 'Z') {
                try out.append(@intCast(cp - 'A' + 'a'));
            } else if ((cp >= 'a' and cp <= 'z') or (cp >= '0' and cp <= '9') or cp == '-' or cp == '_') {
                try out.append(@intCast(cp));
            } else if (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r') {
                try out.append('-');
            }
            continue;
        }
        try out.appendSlice(trimmed[offset - decoded.len .. offset]);
    }
    return try out.toOwnedSlice();
}

/// Normalizes a link fragment (`#Usage` -> `usage`) for lookup.
pub fn normalizeFragment(allocator: Allocator, fragment: []const u8) ![]const u8 {
    const value = if (fragment.len > 0 and fragment[0] == '#') fragment[1..] else fragment;
    const out = try allocator.dupe(u8, value);
    for (out) |*byte| {
        if (byte.* >= 'A' and byte.* <= 'Z') byte.* = byte.* - 'A' + 'a';
    }
    return out;
}

const Decoded = struct { cp: u21, len: usize };

fn decodeAt(text: []const u8, offset: usize) Decoded {
    if (offset >= text.len) return .{ .cp = 0, .len = 0 };
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch return .{ .cp = text[offset], .len = 1 };
    if (offset + len > text.len) return .{ .cp = text[offset], .len = 1 };
    const cp = std.unicode.utf8Decode(text[offset .. offset + len]) catch return .{ .cp = text[offset], .len = 1 };
    return .{ .cp = cp, .len = len };
}

test "slugify: lowercases, strips punctuation and keeps non-ASCII" {
    const allocator = std.testing.allocator;
    const ready = try slugify(allocator, "  Hello, World!  ");
    defer allocator.free(ready);
    try std.testing.expectEqualStrings("hello-world", ready);

    const cjk = try slugify(allocator, "入门 Guide");
    defer allocator.free(cjk);
    try std.testing.expectEqualStrings("入门-guide", cjk);
}

test "slugify: duplicate headings get numeric suffixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = SlugBuilder.init(arena.allocator());

    const first = try builder.add("Usage");
    const second = try builder.add("Usage");
    const third = try builder.add("usage");
    try std.testing.expectEqualStrings("usage", first);
    try std.testing.expectEqualStrings("usage-1", second);
    try std.testing.expectEqualStrings("usage-2", third);
}

test "slugify: fragments normalize case and leading hash" {
    const allocator = std.testing.allocator;
    const value = try normalizeFragment(allocator, "#My-Section");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("my-section", value);
}
