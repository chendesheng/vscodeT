// Portable subset of `src/vs/base/common/filters.ts`: a fuzzy subsequence
// scorer used by the suggest completion model, plus the substring/word-start
// matchers and match ranges used by the quick access pickers. String
// transforms, regex, Unicode alternate-codepoint matching and the browser's
// icon-aware matching are not ported.

const std = @import("std");

/// A half-open range inside the matched string. Mirrors upstream `IMatch`.
pub const Match = struct {
    start: usize,
    end: usize,
};

pub const FuzzyPositions = struct {
    score: i32,
    /// Byte positions matched by `pattern`, in ascending order.
    positions: []usize,

    pub fn deinit(self: FuzzyPositions, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
    }
};

/// Scores `pattern` against `word` as a case-insensitive subsequence.
/// Higher is better; null means no match. Matches at word starts, camel-case
/// boundaries and consecutive runs score higher.
pub fn fuzzyScore(pattern: []const u8, word: []const u8) ?i32 {
    return fuzzyScoreInternal(pattern, word, null);
}

/// Like `fuzzyScore`, but also returns the matched byte positions so the
/// quick pick can highlight them. The caller owns the returned positions.
pub fn fuzzyScoreWithPositions(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    word: []const u8,
) !?FuzzyPositions {
    if (pattern.len == 0) {
        return .{ .score = 0, .positions = try allocator.alloc(usize, 0) };
    }
    if (pattern.len > word.len) return null;

    var positions = std.array_list.Managed(usize).init(allocator);
    errdefer positions.deinit();
    const score = fuzzyScoreInternal(pattern, word, &positions) orelse return null;
    return .{ .score = score, .positions = try positions.toOwnedSlice() };
}

fn fuzzyScoreInternal(
    pattern: []const u8,
    word: []const u8,
    positions: ?*std.array_list.Managed(usize),
) ?i32 {
    if (pattern.len == 0) return 0;
    if (pattern.len > word.len) return null;

    var score: i32 = 0;
    var pattern_index: usize = 0;
    var word_index: usize = 0;
    var last_match: ?usize = null;

    while (pattern_index < pattern.len and word_index < word.len) {
        const wanted = std.ascii.toLower(pattern[pattern_index]);
        const current = std.ascii.toLower(word[word_index]);
        if (wanted != current) {
            word_index += 1;
            // Penalize gaps a little, but not enough to reject a match.
            score -= 1;
            continue;
        }

        score += 8;
        if (word_index == 0 or isBoundary(word[word_index - 1], word[word_index])) score += 12;
        if (last_match) |previous| {
            if (previous + 1 == word_index) {
                score += 6;
            } else {
                score -= @intCast(@min(word_index - previous - 1, 8));
            }
        }
        last_match = word_index;
        if (positions) |list| list.append(word_index) catch return null;
        pattern_index += 1;
        word_index += 1;
    }

    if (pattern_index != pattern.len) return null;

    // Prefer shorter words when the match quality is otherwise equal.
    score -= @intCast(@min(word.len - pattern.len, 20));
    if (std.ascii.eqlIgnoreCase(pattern, word)) score += 20;
    return score;
}

fn isBoundary(previous: u8, current: u8) bool {
    if (previous == '_' or previous == '-' or previous == '.' or previous == ' ') return true;
    return std.ascii.isLower(previous) and std.ascii.isUpper(current);
}

/// Port of `matchesBaseContiguousSubString`: a case-insensitive contiguous
/// substring match. Returns the single matched range.
pub fn matchesBaseContiguousSubString(word: []const u8, target: []const u8) ?Match {
    if (word.len > target.len) return null;
    if (word.len == 0) return .{ .start = 0, .end = 0 };

    var start: usize = 0;
    while (start + word.len <= target.len) : (start += 1) {
        var offset: usize = 0;
        while (offset < word.len and
            std.ascii.toLower(word[offset]) == std.ascii.toLower(target[start + offset]))
        {
            offset += 1;
        }
        if (offset == word.len) return .{ .start = start, .end = start + word.len };
    }
    return null;
}

/// Portable subset of `matchesWords`: every whitespace-separated query word
/// must match at a word start of `target`, in order. Used by the command
/// picker, where labels are words such as `File: Save`.
///
/// Unlike upstream this is ASCII-only (no alternate-codepoint tables) and
/// does not memoize the recursive matcher; command labels are short.
pub fn matchesWords(
    allocator: std.mem.Allocator,
    word: []const u8,
    target: []const u8,
) !?[]Match {
    if (target.len == 0) return null;

    var visited = std.array_list.Managed(usize).init(allocator);
    defer visited.deinit();

    var cursor: usize = 0;
    var force_next_word = false;
    for (word) |query_char| {
        if (query_char == ' ' or query_char == '\t') {
            force_next_word = true;
            continue;
        }

        const wanted = std.ascii.toLower(query_char);
        var matched: ?usize = null;

        // Consecutive matching is allowed even without a word boundary, which
        // is what makes prefixes such as "git" match "Git".
        if (!force_next_word and cursor < target.len and
            std.ascii.toLower(target[cursor]) == wanted)
        {
            matched = cursor;
        } else {
            // Otherwise jump to the next word start.
            const start = if (force_next_word)
                nextWordStart(target, cursor)
            else
                nextWordStart(target, cursor +| 1);
            var index = start;
            while (index < target.len) : (index = nextWordStart(target, index + 1)) {
                if (std.ascii.toLower(target[index]) == wanted) {
                    matched = index;
                    break;
                }
            }
        }

        const position = matched orelse return null;
        try visited.append(position);
        cursor = position + 1;
        force_next_word = false;
    }

    // Coalesce consecutive positions into ranges.
    var result = std.array_list.Managed(Match).init(allocator);
    errdefer result.deinit();
    for (visited.items) |position| {
        if (result.items.len > 0 and result.items[result.items.len - 1].end == position) {
            result.items[result.items.len - 1].end = position + 1;
        } else {
            try result.append(.{ .start = position, .end = position + 1 });
        }
    }
    return try result.toOwnedSlice();
}

fn nextWordStart(target: []const u8, from: usize) usize {
    var index = from;
    while (index < target.len) : (index += 1) {
        if (isWordStart(target, index)) return index;
    }
    return target.len;
}

fn isWordStart(target: []const u8, index: usize) bool {
    if (index == 0) return true;
    const previous = target[index - 1];
    if (previous == ' ' or previous == '\t' or previous == '_' or previous == '-' or
        previous == '.' or previous == ':' or previous == '/' or previous == '\\') return true;
    return std.ascii.isLower(previous) and std.ascii.isUpper(target[index]);
}

test "filters: fuzzy subsequence and boundaries" {
    try std.testing.expect((fuzzyScore("al", "alpha") orelse -999) > 0);
    try std.testing.expect(fuzzyScore("al", "beta") == null);
    const alpha = fuzzyScore("al", "alpha").?;
    const alphabet = fuzzyScore("al", "alphabet").?;
    try std.testing.expect(alpha >= alphabet);
    try std.testing.expect(fuzzyScore("fb", "fooBar") != null);
    try std.testing.expect(fuzzyScore("", "anything") == 0);
}

test "filters: fuzzy positions are ascending byte offsets" {
    const allocator = std.testing.allocator;
    const result = (try fuzzyScoreWithPositions(allocator, "fb", "fooBar")) orelse unreachable;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.positions.len);
    try std.testing.expectEqual(@as(usize, 0), result.positions[0]);
    try std.testing.expectEqual(@as(usize, 3), result.positions[1]);

    try std.testing.expect(try fuzzyScoreWithPositions(allocator, "zz", "fooBar") == null);
}

test "filters: contiguous substring match" {
    try std.testing.expectEqual(Match{ .start = 6, .end = 10 }, matchesBaseContiguousSubString("save", "File: Save").?);
    try std.testing.expectEqual(Match{ .start = 0, .end = 0 }, matchesBaseContiguousSubString("", "anything").?);
    try std.testing.expect(matchesBaseContiguousSubString("zz", "File: Save") == null);
}

test "filters: word-start matching" {
    const allocator = std.testing.allocator;
    const matches = (try matchesWords(allocator, "gp", "Git: Pull")) orelse unreachable;
    defer allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(usize, 0), matches[0].start);
    try std.testing.expectEqual(@as(usize, 5), matches[1].start);

    const multi = (try matchesWords(allocator, "save file", "Save File")) orelse unreachable;
    defer allocator.free(multi);
    try std.testing.expectEqual(@as(usize, 2), multi.len);

    try std.testing.expect(try matchesWords(allocator, "save file", "File: Save") == null);
    try std.testing.expect(try matchesWords(allocator, "zz", "File: Save") == null);
}
