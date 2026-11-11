// Portable subset of `src/vs/base/common/filters.ts`: a fuzzy subsequence
// scorer used by the suggest completion model. String transforms, regex and
// highlight ranges are not ported.

const std = @import("std");

/// Scores `pattern` against `word` as a case-insensitive subsequence.
/// Higher is better; null means no match. Matches at word starts, camel-case
/// boundaries and consecutive runs score higher.
pub fn fuzzyScore(pattern: []const u8, word: []const u8) ?i32 {
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

test "filters: fuzzy subsequence and boundaries" {
    try std.testing.expect((fuzzyScore("al", "alpha") orelse -999) > 0);
    try std.testing.expect(fuzzyScore("al", "beta") == null);
    const alpha = fuzzyScore("al", "alpha").?;
    const alphabet = fuzzyScore("al", "alphabet").?;
    try std.testing.expect(alpha >= alphabet);
    try std.testing.expect(fuzzyScore("fb", "fooBar") != null);
    try std.testing.expect(fuzzyScore("", "anything") == 0);
}
