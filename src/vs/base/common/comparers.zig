// Subset of `src/vs/base/common/comparers.ts`.
//
// The browser uses `Intl.Collator` with numeric sorting and locale-sensitive
// case folding. The terminal port implements the portable ordering rules that
// the search tree needs: case-insensitive natural filename comparison with
// numeric runs, extension comparison and path-segment comparison. Locale-
// specific collation is not available without a Unicode collator.

const std = @import("std");

/// Case-insensitive natural comparison with numeric runs. Returns a negative
/// value when `one` sorts before `other`.
pub fn compareFileNames(one: []const u8, other: []const u8) i32 {
    var i: usize = 0;
    var j: usize = 0;
    while (i < one.len and j < other.len) {
        const a = one[i];
        const b = other[j];
        if (isDigit(a) and isDigit(b)) {
            var ai = i;
            var bj = j;
            while (ai < one.len and isDigit(one[ai])) : (ai += 1) {}
            while (bj < other.len and isDigit(other[bj])) : (bj += 1) {}
            const a_start = i;
            const b_start = j;
            while (i < ai and one[i] == '0') : (i += 1) {}
            while (j < bj and other[j] == '0') : (j += 1) {}
            const a_digits = ai - i;
            const b_digits = bj - j;
            if (a_digits != b_digits) return if (a_digits < b_digits) -1 else 1;
            for (one[i..ai], other[j..bj]) |ca, cb| {
                if (ca != cb) return if (ca < cb) -1 else 1;
            }
            if (ai - a_start != bj - b_start) return if (ai - a_start < bj - b_start) -1 else 1;
            i = ai;
            j = bj;
            continue;
        }
        const al = std.ascii.toLower(a);
        const bl = std.ascii.toLower(b);
        if (al != bl) return if (al < bl) -1 else 1;
        i += 1;
        j += 1;
    }
    if (i < one.len) return 1;
    if (j < other.len) return -1;
    if (one.len != other.len) return if (one.len < other.len) -1 else 1;
    return 0;
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn extractNameAndExtension(name: []const u8) struct { name: []const u8, extension: []const u8 } {
    if (name.len == 0 or name[0] == '.') return .{ .name = name, .extension = "" };
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse
        return .{ .name = name, .extension = "" };
    return .{ .name = name[0..dot], .extension = name[dot + 1 ..] };
}

pub fn compareFileExtensions(one: []const u8, other: []const u8) i32 {
    const a = extractNameAndExtension(one);
    const b = extractNameAndExtension(other);
    const ext = compareFileNames(a.extension, b.extension);
    if (ext != 0) return ext;
    return compareFileNames(a.name, b.name);
}

/// Compares paths component by component, then the final component
/// naturally. This mirrors the ordering used by the search tree.
pub fn comparePaths(one: []const u8, other: []const u8) i32 {
    var a = std.mem.splitScalar(u8, one, '/');
    var b = std.mem.splitScalar(u8, other, '/');
    while (true) {
        const next_a = a.next();
        const next_b = b.next();
        if (next_a == null and next_b == null) return 0;
        if (next_a == null) return -1;
        if (next_b == null) return 1;
        const result = compareFileNames(next_a.?, next_b.?);
        if (result != 0) return result;
    }
}

test "comparers: numeric names and paths" {
    try std.testing.expect(compareFileNames("foo1", "foo2") < 0);
    try std.testing.expect(compareFileNames("foo10", "foo2") > 0);
    try std.testing.expect(compareFileNames("Foo", "foo") == 0);
    try std.testing.expect(comparePaths("/a/b", "/a/c") < 0);
    try std.testing.expect(compareFileExtensions("a.zig", "b.ts") > 0);
}

/// Port of `compareByPrefix` (ASCII case folding; terminal has no locale).
pub fn compareByPrefix(one: []const u8, other: []const u8, look_for: []const u8) i32 {
    const prefix_a = startsWithIgnoreCase(one, look_for);
    const prefix_b = startsWithIgnoreCase(other, look_for);
    if (prefix_a != prefix_b) return if (prefix_a) -1 else 1;
    if (prefix_a and prefix_b) {
        if (one.len < other.len) return -1;
        if (one.len > other.len) return 1;
    }
    return 0;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn lowerCompare(a: []const u8, b: []const u8) i32 {
    const length = @min(a.len, b.len);
    for (0..length) |index| {
        const ca = std.ascii.toLower(a[index]);
        const cb = std.ascii.toLower(b[index]);
        if (ca != cb) return if (ca < cb) -1 else 1;
    }
    if (a.len == b.len) return 0;
    return if (a.len < b.len) -1 else 1;
}

/// Port of `compareAnything`: prefix matches first, then suffix matches, then
/// file-name aware comparison, then case-insensitive lexical order.
pub fn compareAnything(one: []const u8, other: []const u8, look_for: []const u8) i32 {
    const prefix_compare = compareByPrefix(one, other, look_for);
    if (prefix_compare != 0) return prefix_compare;

    const suffix_a = endsWithIgnoreCase(one, look_for);
    const suffix_b = endsWithIgnoreCase(other, look_for);
    if (suffix_a != suffix_b) return if (suffix_a) -1 else 1;

    const file_compare = compareFileNames(one, other);
    if (file_compare != 0) return file_compare;
    return lowerCompare(one, other);
}

test "compareAnything prefers prefixes and suffixes" {
    try std.testing.expect(compareAnything("foo.ts", "barfoo.ts", "foo") < 0);
    try std.testing.expect(compareAnything("barfoo.ts", "foo.ts", "foo") > 0);
    try std.testing.expect(compareAnything("abcfoo", "fooabc", "foo") > 0);
    try std.testing.expect(compareAnything("x/foo", "y/foo", "foo") < 0);
}
