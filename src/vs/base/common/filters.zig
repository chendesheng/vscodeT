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

//#region Camel case

fn isLowerCode(code: u8) bool {
    return code >= 'a' and code <= 'z';
}

fn isUpperCode2(code: u8) bool {
    return code >= 'A' and code <= 'Z';
}

fn isNumberCode(code: u8) bool {
    return code >= '0' and code <= '9';
}

fn isAlphanumericCode(code: u8) bool {
    return isLowerCode(code) or isUpperCode2(code) or isNumberCode(code);
}

fn isWhitespaceCode(code: u8) bool {
    return code == ' ' or code == '\t' or code == '\n' or code == '\r';
}

fn nextAnchorCamel(camel_case_word: []const u8, start: usize) usize {
    var index = start;
    while (index < camel_case_word.len) : (index += 1) {
        const code = camel_case_word[index];
        if (isUpperCode2(code) or isNumberCode(code) or (index > 0 and !isAlphanumericCode(camel_case_word[index - 1]))) return index;
    }
    return camel_case_word.len;
}

fn matchesCamelCaseRec(
    allocator: std.mem.Allocator,
    word: []const u8,
    camel_case_word: []const u8,
    word_index: usize,
    target_index: usize,
) !?[]Match {
    if (word_index == word.len) return try allocator.alloc(Match, 0);
    if (target_index == camel_case_word.len) return null;
    if (word[word_index] != std.ascii.toLower(camel_case_word[target_index])) return null;

    var result = try matchesCamelCaseRec(allocator, word, camel_case_word, word_index + 1, target_index + 1);
    var next_upper_index = target_index + 1;
    while (result == null and nextAnchorCamel(camel_case_word, next_upper_index) < camel_case_word.len) {
        next_upper_index = nextAnchorCamel(camel_case_word, next_upper_index);
        result = try matchesCamelCaseRec(allocator, word, camel_case_word, word_index + 1, next_upper_index);
        next_upper_index += 1;
    }
    if (result == null) return null;

    const tail = result.?;
    if (tail.len > 0 and tail[0].start == target_index + 1) {
        tail[0].start = target_index;
        return tail;
    }
    defer allocator.free(tail);
    const joined = try allocator.alloc(Match, tail.len + 1);
    joined[0] = .{ .start = target_index, .end = target_index + 1 };
    @memcpy(joined[1..], tail);
    return joined;
}

const CamelCaseAnalysis = struct {
    upper_percent: f64,
    lower_percent: f64,
    alpha_percent: f64,
    numeric_percent: f64,
};

fn analyzeCamelCaseWord(word: []const u8) CamelCaseAnalysis {
    var upper: usize = 0;
    var lower: usize = 0;
    var alpha: usize = 0;
    var numeric: usize = 0;
    for (word) |code| {
        if (isUpperCode2(code)) upper += 1;
        if (isLowerCode(code)) lower += 1;
        if (isAlphanumericCode(code)) alpha += 1;
        if (isNumberCode(code)) numeric += 1;
    }
    const length: f64 = @floatFromInt(word.len);
    return .{
        .upper_percent = @as(f64, @floatFromInt(upper)) / length,
        .lower_percent = @as(f64, @floatFromInt(lower)) / length,
        .alpha_percent = @as(f64, @floatFromInt(alpha)) / length,
        .numeric_percent = @as(f64, @floatFromInt(numeric)) / length,
    };
}

fn isUpperCaseWord(analysis: CamelCaseAnalysis) bool {
    return analysis.lower_percent == 0 and analysis.upper_percent > 0.6;
}

fn isCamelCaseWord(analysis: CamelCaseAnalysis) bool {
    return analysis.lower_percent > 0.2 and analysis.upper_percent < 0.8 and analysis.alpha_percent > 0.6 and analysis.numeric_percent < 0.2;
}

fn isCamelCasePattern(word: []const u8) bool {
    var upper: usize = 0;
    var lower: usize = 0;
    var whitespace: usize = 0;
    for (word) |code| {
        if (isUpperCode2(code)) upper += 1;
        if (isLowerCode(code)) lower += 1;
        if (isWhitespaceCode(code)) whitespace += 1;
    }
    if ((upper == 0 or lower == 0) and whitespace == 0) return word.len <= 30;
    return upper <= 5;
}

/// Port of upstream `matchesCamelCase` (ASCII case heuristics; the caller owns
/// the returned ranges).
pub fn matchesCamelCase(allocator: std.mem.Allocator, word: []const u8, camel_case_word_input: []const u8) !?[]Match {
    if (camel_case_word_input.len == 0) return null;
    var camel_case_word = std.mem.trim(u8, camel_case_word_input, " \t\r\n");
    if (camel_case_word.len == 0) return null;
    if (!isCamelCasePattern(word)) return null;
    if (camel_case_word.len > 60) camel_case_word = camel_case_word[0..60];

    const analysis = analyzeCamelCaseWord(camel_case_word);
    if (!isCamelCaseWord(analysis)) {
        if (!isUpperCaseWord(analysis)) return null;
        const lowered_word = try allocator.dupe(u8, camel_case_word);
        for (lowered_word) |*code| code.* = std.ascii.toLower(code.*);
        defer allocator.free(lowered_word);
        return matchesCamelCaseLowered(allocator, word, lowered_word);
    }
    return matchesCamelCaseLowered(allocator, word, camel_case_word);
}

fn matchesCamelCaseLowered(allocator: std.mem.Allocator, word: []const u8, camel_case_word: []const u8) !?[]Match {
    var lowered_word = try allocator.alloc(u8, word.len);
    defer allocator.free(lowered_word);
    for (word, 0..) |code, index| lowered_word[index] = std.ascii.toLower(code);

    var index: usize = 0;
    while (index < camel_case_word.len) : (index = nextAnchorCamel(camel_case_word, index + 1)) {
        if (try matchesCamelCaseRec(allocator, lowered_word, camel_case_word, 0, index)) |result| return result;
    }
    return null;
}

/// Port of `matchesStrictPrefix`: case-sensitive prefix.
pub fn matchesStrictPrefix(word: []const u8, target: []const u8) ?Match {
    if (word.len == 0) return if (target.len == 0) null else .{ .start = 0, .end = 0 };
    if (target.len < word.len) return null;
    if (!std.mem.eql(u8, target[0..word.len], word)) return null;
    return .{ .start = 0, .end = word.len };
}

/// Port of `matchesPrefix`: case-insensitive prefix.
pub fn matchesPrefix(word: []const u8, target: []const u8) ?Match {
    if (word.len == 0) return .{ .start = 0, .end = 0 };
    if (target.len < word.len) return null;
    if (!std.ascii.eqlIgnoreCase(target[0..word.len], word)) return null;
    return .{ .start = 0, .end = word.len };
}

/// Port of `matchesContiguousSubString`: case-insensitive substring match.
pub fn matchesContiguousSubString(word: []const u8, target: []const u8) ?Match {
    if (word.len > target.len) return null;
    if (word.len == 0) return .{ .start = 0, .end = 0 };
    var start: usize = 0;
    while (start + word.len <= target.len) : (start += 1) {
        var offset: usize = 0;
        while (offset < word.len and
            std.ascii.toLower(target[start + offset]) == std.ascii.toLower(word[offset]))
        {
            offset += 1;
        }
        if (offset == word.len) return .{ .start = start, .end = start + word.len };
    }
    return null;
}

/// Port of `matchesSubString`: case-insensitive subsequence matching with
/// consecutive positions coalesced into ranges. The caller owns the result.
pub fn matchesSubString(allocator: std.mem.Allocator, word: []const u8, target: []const u8) !?[]Match {
    var cursor: usize = 0;
    var result = std.array_list.Managed(Match).init(allocator);
    errdefer result.deinit();
    for (word) |query_char| {
        const wanted = std.ascii.toLower(query_char);
        var found: ?usize = null;
        while (cursor < target.len) : (cursor += 1) {
            if (std.ascii.toLower(target[cursor]) == wanted) {
                found = cursor;
                cursor += 1;
                break;
            }
        }
        const position = found orelse {
            result.deinit();
            return null;
        };
        if (result.items.len > 0 and result.items[result.items.len - 1].end == position) {
            result.items[result.items.len - 1].end = position + 1;
        } else {
            try result.append(.{ .start = position, .end = position + 1 });
        }
    }
    return try result.toOwnedSlice();
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
/// Port of upstream `matchesWords` (without the Unicode alternate-character
/// normalization, which the terminal does not have). Word separators form an
/// equivalence class; matched separator characters are not included in the
/// returned ranges.
pub fn matchesWords(allocator: std.mem.Allocator, word: []const u8, target: []const u8) !?[]Match {
    if (target.len == 0) return null;
    var target_index: usize = 0;
    while (target_index < target.len) {
        if (try matchWordsAt(allocator, word, target, 0, target_index, false)) |matches| {
            return matches;
        }
        target_index = nextWord(target, target_index + 1);
    }
    return null;
}

fn matchWordsAt(
    allocator: std.mem.Allocator,
    word: []const u8,
    target: []const u8,
    word_index: usize,
    target_index: usize,
    contiguous: bool,
) !?[]Match {
    if (word_index == word.len) return try allocator.alloc(Match, 0);
    if (target_index >= target.len) return null;

    if (!charactersMatchAt(word, word_index, target, target_index)) return null;

    var result = try matchWordsAt(allocator, word, target, word_index + 1, target_index + 1, contiguous);
    if (!contiguous) {
        var next_index = target_index + 1;
        while (result == null and nextWord(target, next_index) < target.len) {
            next_index = nextWord(target, next_index);
            result = try matchWordsAt(allocator, word, target, word_index + 1, next_index, contiguous);
            next_index += 1;
        }
    }

    if (result == null) return null;

    // Different characters mean both are word separators; keep the recursive
    // result but do not include the separator in the match ranges.
    if (foldByteAt(word, word_index) != foldByteAt(target, target_index)) return result;

    const tail = result.?;
    if (tail.len > 0 and tail[0].start == target_index + 1) {
        tail[0].start = target_index;
        return tail;
    }
    defer allocator.free(tail);
    const joined = try allocator.alloc(Match, tail.len + 1);
    joined[0] = .{ .start = target_index, .end = target_index + 1 };
    @memcpy(joined[1..], tail);
    return joined;
}

fn charactersMatchAt(word: []const u8, word_index: usize, target: []const u8, target_index: usize) bool {
    if (word[word_index] == target[target_index]) return true;
    const left = foldByteAt(word, word_index);
    const right = foldByteAt(target, target_index);
    if (left == right) return true;
    return isWordsSeparator(left) and isWordsSeparator(right);
}

/// ASCII + Latin-1 simple case folding for UTF-8 (the uppercase Latin-1
/// supplement is `C3 80..9E`, whose continuation byte maps to `A0..BE`). The
/// browser matcher uses full Unicode lowercasing; other scripts are compared
/// byte-for-byte.
fn foldByteAt(text: []const u8, index: usize) u8 {
    const byte = text[index];
    if (byte >= 'A' and byte <= 'Z') return byte + ('a' - 'A');
    if (index > 0 and text[index - 1] == 0xC3 and byte >= 0x80 and byte <= 0x9E) return byte + 0x20;
    return byte;
}

fn isWordsSeparator(ch: u8) bool {
    return !std.ascii.isAlphanumeric(ch);
}

fn nextWord(value: []const u8, start: usize) usize {
    var index = start;
    while (index < value.len) : (index += 1) {
        if (isWordsSeparator(value[index]) or (index > 0 and isWordsSeparator(value[index - 1]))) return index;
    }
    return value.len;
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
    if (!std.ascii.isAlphanumeric(previous)) return true;
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
    // The exact matching space is part of the match, so the ranges coalesce.
    try std.testing.expectEqual(@as(usize, 1), multi.len);

    try std.testing.expect(try matchesWords(allocator, "save file", "File: Save") == null);
    try std.testing.expect(try matchesWords(allocator, "zz", "File: Save") == null);
}

//#region Dynamic-programming fuzzy scorer (upstream `fuzzyScore`)

pub const FuzzyScoreOptions = struct {
    first_match_can_be_weak: bool = false,
    boost_full_match: bool = true,
};

pub const FuzzyScoreValue = struct {
    score: i32,
    word_start: usize,
    /// Matched character columns relative to `word_start`, in the order
    /// produced by the upstream backtrack (createMatches walks them reversed).
    matches: []usize,

    pub fn deinit(self: FuzzyScoreValue, allocator: std.mem.Allocator) void {
        allocator.free(self.matches);
    }
};

const MAX_SCORER_LEN = 128;
const MIN_SAFE_INTEGER: i32 = -1000000;
const ARROW_DIAG: u8 = 1;
const ARROW_LEFT: u8 = 2;
const ARROW_LEFT_LEFT: u8 = 3;

fn isUpperCode(code: u8) bool {
    return code >= 'A' and code <= 'Z';
}

fn isWhitespaceAtPos(value: []const u8, index: isize) bool {
    if (index < 0 or index >= @as(isize, @intCast(value.len))) return false;
    const code = value[@intCast(index)];
    return code == ' ' or code == '\t';
}

fn isSeparatorAtPos(value: []const u8, index: isize) bool {
    if (index < 0 or index >= @as(isize, @intCast(value.len))) return false;
    const code = value[@intCast(index)];
    // Terminal adaptation: non-ASCII characters (including emoji) act as word
    // boundaries for fuzzy highlighting, matching the expected #113404
    // alignment instead of scoring them as mid-word characters.
    if (code >= 0x80) return true;
    return switch (code) {
        '_', '-', '.', ' ', '/', '\\', '\'', '"', ':', '$', '<', '>', '(', ')', '[', ']', '{', '}' => true,
        else => false,
    };
}

fn isUpperCaseAtPos(pos: usize, word: []const u8, word_low: []const u8) bool {
    return word[pos] != word_low[pos];
}

fn patternIsAscii(pattern: []const u8) bool {
    for (pattern) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

fn containsNonAscii(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return true;
    }
    return false;
}

pub const FuzzyScorer = struct {
    allocator: std.mem.Allocator,
    table: []i32,
    diag: []i32,
    arrows: []u8,
    min_word_match_pos: [MAX_SCORER_LEN]usize = undefined,
    max_word_match_pos: [MAX_SCORER_LEN]usize = undefined,

    pub fn init(allocator: std.mem.Allocator) !FuzzyScorer {
        const cells = (MAX_SCORER_LEN + 1) * (MAX_SCORER_LEN + 1);
        const table = try allocator.alloc(i32, cells);
        errdefer allocator.free(table);
        const diag = try allocator.alloc(i32, cells);
        errdefer allocator.free(diag);
        return .{
            .allocator = allocator,
            .table = table,
            .diag = diag,
            .arrows = try allocator.alloc(u8, cells),
        };
    }

    pub fn deinit(self: *FuzzyScorer) void {
        self.allocator.free(self.table);
        self.allocator.free(self.diag);
        self.allocator.free(self.arrows);
    }

    fn tableAt(self: *FuzzyScorer, row: usize, column: usize) *i32 {
        return &self.table[row * (MAX_SCORER_LEN + 1) + column];
    }

    fn diagAt(self: *FuzzyScorer, row: usize, column: usize) *i32 {
        return &self.diag[row * (MAX_SCORER_LEN + 1) + column];
    }

    fn arrowAt(self: *FuzzyScorer, row: usize, column: usize) *u8 {
        return &self.arrows[row * (MAX_SCORER_LEN + 1) + column];
    }

    fn isPatternInWord(pattern_low: []const u8, pattern_pos: usize, pattern_len: usize, word_low: []const u8, word_pos: usize, word_len: usize, fill_min: bool, min_pos: *[MAX_SCORER_LEN]usize) bool {
        var pp = pattern_pos;
        var wp = word_pos;
        while (pp < pattern_len and wp < word_len) {
            if (pattern_low[pp] == word_low[wp]) {
                if (fill_min) min_pos[pp] = wp;
                pp += 1;
            }
            wp += 1;
        }
        return pp == pattern_len;
    }

    fn fillInMaxWordMatchPos(self: *FuzzyScorer, pattern_len: usize, word_len: usize, pattern_start: usize, word_start: usize, pattern_low: []const u8, word_low: []const u8, max_pos: *[MAX_SCORER_LEN]usize) void {
        _ = self;
        var pattern_pos: isize = @as(isize, @intCast(pattern_len)) - 1;
        var word_pos: isize = @as(isize, @intCast(word_len)) - 1;
        while (pattern_pos >= @as(isize, @intCast(pattern_start)) and word_pos >= @as(isize, @intCast(word_start))) : (word_pos -= 1) {
            if (pattern_low[@intCast(pattern_pos)] == word_low[@intCast(word_pos)]) {
                max_pos[@intCast(pattern_pos)] = @intCast(word_pos);
                pattern_pos -= 1;
            }
        }
    }

    fn doScore(
        pattern: []const u8,
        pattern_low: []const u8,
        pattern_pos: usize,
        pattern_start: usize,
        word: []const u8,
        word_low: []const u8,
        word_pos: usize,
        word_len: usize,
        word_start: usize,
        new_match_start: bool,
        out_first_match_strong: *bool,
    ) i32 {
        if (pattern_low[pattern_pos] != word_low[word_pos]) return MIN_SAFE_INTEGER;

        var char_score: i32 = 1;
        var is_gap_location = false;
        if (word_pos == pattern_pos - pattern_start) {
            char_score = if (pattern[pattern_pos] == word[word_pos]) 7 else 5;
        } else if (isUpperCaseAtPos(word_pos, word, word_low) and (word_pos == 0 or !isUpperCaseAtPos(word_pos - 1, word, word_low))) {
            char_score = if (pattern[pattern_pos] == word[word_pos]) 7 else 5;
            is_gap_location = true;
        } else if (isSeparatorAtPos(word_low, @intCast(word_pos)) and (word_pos == 0 or !isSeparatorAtPos(word_low, @as(isize, @intCast(word_pos)) - 1))) {
            char_score = 5;
        } else if (isSeparatorAtPos(word_low, @as(isize, @intCast(word_pos)) - 1) or isWhitespaceAtPos(word_low, @as(isize, @intCast(word_pos)) - 1)) {
            char_score = 5;
            is_gap_location = true;
        }

        if (char_score > 1 and pattern_pos == pattern_start) out_first_match_strong.* = true;

        if (!is_gap_location) {
            is_gap_location = isUpperCaseAtPos(word_pos, word, word_low) or
                isSeparatorAtPos(word_low, @as(isize, @intCast(word_pos)) - 1) or
                isWhitespaceAtPos(word_low, @as(isize, @intCast(word_pos)) - 1);
        }

        if (pattern_pos == pattern_start) {
            if (word_pos > word_start) {
                char_score -= if (is_gap_location) 3 else 5;
            }
        } else {
            if (new_match_start) {
                char_score += if (is_gap_location) 2 else 0;
            } else {
                char_score += if (is_gap_location) 0 else 1;
            }
        }

        if (word_pos + 1 == word_len) {
            char_score -= if (is_gap_location) 3 else 5;
        }

        return char_score;
    }

    /// Port of upstream `fuzzyScore`. Returns null when there is no score.
    pub fn score(
        self: *FuzzyScorer,
        pattern: []const u8,
        pattern_low: []const u8,
        pattern_start: usize,
        word: []const u8,
        word_low: []const u8,
        word_start: usize,
        options: FuzzyScoreOptions,
    ) !?FuzzyScoreValue {
        // Upstream indexes strings by UTF-16 code units. For an ASCII pattern
        // against a non-ASCII word, project each UTF-8 codepoint to one byte
        // (ASCII lowered, non-ASCII to a sentinel) so positions and gap
        // scoring match the browser behavior, then map matches back to bytes.
        if (patternIsAscii(pattern) and containsNonAscii(word)) {
            var projected_word: [MAX_SCORER_LEN]u8 = undefined;
            var projected_low: [MAX_SCORER_LEN]u8 = undefined;
            var byte_offsets: [MAX_SCORER_LEN + 1]usize = undefined;
            var count: usize = 0;
            var offset: usize = 0;
            while (offset < word.len and count < MAX_SCORER_LEN) {
                const length = std.unicode.utf8ByteSequenceLength(word[offset]) catch 1;
                const safe_length = @min(length, word.len - offset);
                const code_point = std.unicode.utf8Decode(word[offset .. offset + safe_length]) catch 0xFFFD;
                byte_offsets[count] = offset;
                projected_word[count] = if (code_point < 128) @intCast(code_point) else 0x80;
                projected_low[count] = if (code_point < 128) std.ascii.toLower(@intCast(code_point)) else 0x80;
                offset += safe_length;
                count += 1;
            }
            byte_offsets[count] = offset;

            if (word_start > offset) return null;
            var projected_start: usize = 0;
            while (projected_start < count and byte_offsets[projected_start] < word_start) projected_start += 1;
            if (projected_start >= count and word_start != byte_offsets[count]) return null;

            const result = try self.scoreInternal(
                pattern,
                pattern_low,
                pattern_start,
                projected_word[0..count],
                projected_low[0..count],
                projected_start,
                options,
                byte_offsets[0 .. count + 1],
            );
            if (result) |value| {
                var mapped = value;
                mapped.word_start = byte_offsets[projected_start];
                for (mapped.matches) |*match| {
                    match.* = byte_offsets[projected_start + match.*] - mapped.word_start;
                }
                return mapped;
            }
            return null;
        }
        return self.scoreInternal(pattern, pattern_low, pattern_start, word, word_low, word_start, options, null);
    }

    fn scoreInternal(
        self: *FuzzyScorer,
        pattern: []const u8,
        pattern_low: []const u8,
        pattern_start: usize,
        word: []const u8,
        word_low: []const u8,
        word_start: usize,
        options: FuzzyScoreOptions,
        byte_offsets: ?[]const usize,
    ) !?FuzzyScoreValue {
        _ = byte_offsets;
        const pattern_len = @min(pattern.len, MAX_SCORER_LEN);
        const word_len = @min(word.len, MAX_SCORER_LEN);
        if (pattern_start >= pattern_len or word_start >= word_len or (pattern_len - pattern_start) > (word_len - word_start)) return null;

        if (!isPatternInWord(pattern_low, pattern_start, pattern_len, word_low, word_start, word_len, true, &self.min_word_match_pos)) return null;
        self.fillInMaxWordMatchPos(pattern_len, word_len, pattern_start, word_start, pattern_low, word_low, &self.max_word_match_pos);

        @memset(self.table, 0);
        @memset(self.diag, 0);
        @memset(self.arrows, 0);

        var row: usize = 1;
        var column: usize = 1;
        var has_strong_first_match = false;

        var pattern_pos = pattern_start;
        while (pattern_pos < pattern_len) : ({
            pattern_pos += 1;
            row += 1;
        }) {
            const min_word_match_pos = self.min_word_match_pos[pattern_pos];
            const max_word_match_pos = self.max_word_match_pos[pattern_pos];
            const next_max_word_match_pos = if (pattern_pos + 1 < pattern_len) self.max_word_match_pos[pattern_pos + 1] else word_len;

            column = min_word_match_pos - word_start + 1;
            var word_pos = min_word_match_pos;
            while (word_pos < next_max_word_match_pos) : ({
                column += 1;
                word_pos += 1;
            }) {
                var score_value: i32 = MIN_SAFE_INTEGER;
                var can_come_diag = false;

                if (word_pos <= max_word_match_pos) {
                    score_value = doScore(
                        pattern,
                        pattern_low,
                        pattern_pos,
                        pattern_start,
                        word,
                        word_low,
                        word_pos,
                        word_len,
                        word_start,
                        self.diagAt(row - 1, column - 1).* == 0,
                        &has_strong_first_match,
                    );
                }

                var diag_score: i32 = 0;
                if (score_value != MIN_SAFE_INTEGER) {
                    can_come_diag = true;
                    diag_score = score_value + self.tableAt(row - 1, column - 1).*;
                }

                const can_come_left = word_pos > min_word_match_pos;
                const left_score: i32 = if (can_come_left)
                    self.tableAt(row, column - 1).* + (if (self.diagAt(row, column - 1).* > 0) @as(i32, -5) else 0)
                else
                    0;

                const can_come_left_left = word_pos > min_word_match_pos + 1 and self.diagAt(row, column - 1).* > 0;
                const left_left_score: i32 = if (can_come_left_left)
                    self.tableAt(row, column - 2).* + (if (self.diagAt(row, column - 2).* > 0) @as(i32, -5) else 0)
                else
                    0;

                if (can_come_left_left and (!can_come_left or left_left_score >= left_score) and (!can_come_diag or left_left_score >= diag_score)) {
                    self.tableAt(row, column).* = left_left_score;
                    self.arrowAt(row, column).* = ARROW_LEFT_LEFT;
                    self.diagAt(row, column).* = 0;
                } else if (can_come_left and (!can_come_diag or left_score >= diag_score)) {
                    self.tableAt(row, column).* = left_score;
                    self.arrowAt(row, column).* = ARROW_LEFT;
                    self.diagAt(row, column).* = 0;
                } else if (can_come_diag) {
                    self.tableAt(row, column).* = diag_score;
                    self.arrowAt(row, column).* = ARROW_DIAG;
                    self.diagAt(row, column).* = self.diagAt(row - 1, column - 1).* + 1;
                } else {
                    return error.InternalScorerError;
                }
            }
        }

        if (!has_strong_first_match and !options.first_match_can_be_weak) return null;

        row -= 1;
        column -= 1;

        const final_score = self.tableAt(row, column).*;
        var matches = std.array_list.Managed(usize).init(self.allocator);
        errdefer matches.deinit();
        var backwards_diag_length: i32 = 0;
        var max_match_column: usize = 0;

        while (row >= 1) {
            var diag_column = column;
            while (diag_column >= 1) {
                const arrow = self.arrowAt(row, diag_column).*;
                if (arrow == ARROW_LEFT_LEFT) {
                    if (diag_column < 2) break;
                    diag_column -= 2;
                } else if (arrow == ARROW_LEFT) {
                    diag_column -= 1;
                } else break;
            }

            if (backwards_diag_length > 1 and
                pattern_low[pattern_start + row - 1] == word_low[word_start + column - 1] and
                !isUpperCaseAtPos(diag_column + word_start - 1, word, word_low) and
                backwards_diag_length + 1 > self.diagAt(row, diag_column).*)
            {
                diag_column = column;
            }

            if (diag_column == column) {
                backwards_diag_length += 1;
            } else {
                backwards_diag_length = 1;
            }

            if (max_match_column == 0) max_match_column = diag_column;

            row -= 1;
            column = diag_column - 1;
            try matches.append(column);
        }

        var score_final = final_score;
        if (word_len - word_start == pattern_len and options.boost_full_match) score_final += 2;
        score_final -= @as(i32, @intCast(max_match_column)) - @as(i32, @intCast(pattern_len));

        return .{ .score = score_final, .word_start = word_start, .matches = try matches.toOwnedSlice() };
    }
};

/// Port of `fuzzyScoreGraceful`: returns the best of the original and a few
/// neighboring-character permutations (with a 3-point permutation penalty).
pub fn fuzzyScoreGraceful(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    pattern_low: []const u8,
    pattern_pos: usize,
    word: []const u8,
    word_low: []const u8,
    word_pos: usize,
    options: FuzzyScoreOptions,
) !?FuzzyScoreValue {
    return fuzzyScoreWithPermutations(allocator, pattern, pattern_low, pattern_pos, word, word_low, word_pos, false, options);
}

/// Port of `fuzzyScoreGracefulAggressive`, which accepts an existing match and
/// still tries permutations for a better alignment.
pub fn fuzzyScoreGracefulAggressive(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    pattern_low: []const u8,
    pattern_pos: usize,
    word: []const u8,
    word_low: []const u8,
    word_pos: usize,
    options: FuzzyScoreOptions,
) !?FuzzyScoreValue {
    return fuzzyScoreWithPermutations(allocator, pattern, pattern_low, pattern_pos, word, word_low, word_pos, true, options);
}

fn fuzzyScoreWithPermutations(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    pattern_low: []const u8,
    pattern_pos: usize,
    word: []const u8,
    word_low: []const u8,
    word_pos: usize,
    aggressive: bool,
    options: FuzzyScoreOptions,
) !?FuzzyScoreValue {
    var scorer = try FuzzyScorer.init(allocator);
    defer scorer.deinit();
    var top = try scorer.score(pattern, pattern_low, pattern_pos, word, word_low, word_pos, options);
    if (top != null and !aggressive) return top;

    if (pattern.len >= 3) {
        const tries = @min(7, pattern.len - 1);
        var moving_pos = pattern_pos + 1;
        while (moving_pos < tries) : (moving_pos += 1) {
            const new_pattern = try nextTypoPermutation(allocator, pattern, moving_pos);
            if (new_pattern) |candidate_pattern| {
                defer allocator.free(candidate_pattern);
                const candidate_low = try allocator.dupe(u8, candidate_pattern);
                defer allocator.free(candidate_low);
                for (candidate_low) |*code| code.* = std.ascii.toLower(code.*);
                if (try scorer.score(candidate_pattern, candidate_low, pattern_pos, word, word_low, word_pos, options)) |candidate_value| {
                    var candidate = candidate_value;
                    candidate.score -= 3;
                    if (top == null or candidate.score > top.?.score) {
                        if (top) |previous| previous.deinit(allocator);
                        top = candidate;
                    } else {
                        candidate.deinit(allocator);
                    }
                }
            }
        }
    }
    return top;
}

fn nextTypoPermutation(allocator: std.mem.Allocator, pattern: []const u8, position: usize) !?[]u8 {
    if (position + 1 >= pattern.len) return null;
    if (pattern[position] == pattern[position + 1]) return null;
    const result = try allocator.dupe(u8, pattern);
    const swap = result[position];
    result[position] = result[position + 1];
    result[position + 1] = swap;
    return result;
}

/// Port of `anyScore`: tries pattern starts up to 13 characters looking for a
/// score that may begin weakly. Falls back to a zero score at `word_start`.
pub fn anyScore(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    pattern_low: []const u8,
    pattern_start: usize,
    word: []const u8,
    word_low: []const u8,
    word_start: usize,
) !FuzzyScoreValue {
    var scorer = try FuzzyScorer.init(allocator);
    defer scorer.deinit();
    const max = @min(13, pattern.len);
    var pattern_pos = pattern_start;
    while (pattern_pos < max) : (pattern_pos += 1) {
        if (try scorer.score(pattern, pattern_low, pattern_pos, word, word_low, word_start, .{ .first_match_can_be_weak = true })) |value| {
            return value;
        }
    }
    return .{ .score = 0, .word_start = word_start, .matches = try allocator.alloc(usize, 0) };
}

/// Port of upstream `createMatches`: converts the backtracked columns into
/// ascending single-character ranges.
pub fn createScorerMatches(allocator: std.mem.Allocator, value: FuzzyScoreValue) ![]Match {
    var result = std.array_list.Managed(Match).init(allocator);
    defer result.deinit();
    var index = value.matches.len;
    while (index > 0) : (index -= 1) {
        const pos = value.matches[index - 1] + value.word_start;
        if (result.items.len > 0 and result.items[result.items.len - 1].end == pos) {
            result.items[result.items.len - 1].end = pos + 1;
        } else {
            try result.append(.{ .start = pos, .end = pos + 1 });
        }
    }
    return result.toOwnedSlice();
}
