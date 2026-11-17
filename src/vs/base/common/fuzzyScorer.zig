// Port of the query-normalizer region of `src/vs/base/common/fuzzyScorer.ts`.
//
// Terminal adaptations: path separators are POSIX-only (`/`, backslashes are
// normalized to `/`), lowercasing is ASCII (the terminal matcher scores ASCII
// identifiers), and `scoreFuzzy2` derives its ranges from the ported matrix
// scorer instead of `filters.fuzzyScore` (the filters DP scorer is not ported).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PreparedQueryPiece = struct {
    original: []const u8,
    originalLowercase: []const u8,
    pathNormalized: []const u8,
    normalized: []const u8,
    normalizedLowercase: []const u8,
    expectContiguousMatch: bool,
};

pub const PreparedQuery = struct {
    original: []const u8,
    originalLowercase: []const u8,
    pathNormalized: []const u8,
    normalized: []const u8,
    normalizedLowercase: []const u8,
    values: ?[]PreparedQueryPiece,
    containsPathSeparator: bool,
    expectContiguousMatch: bool,

    /// Frees every slice owned by the prepared query (and its pieces).
    pub fn deinit(self: *const PreparedQuery, allocator: Allocator) void {
        allocator.free(self.original);
        allocator.free(self.originalLowercase);
        allocator.free(self.pathNormalized);
        allocator.free(self.normalized);
        allocator.free(self.normalizedLowercase);
        if (self.values) |values| {
            for (values) |piece| freePiece(allocator, piece);
            allocator.free(values);
        }
    }

    fn freePiece(allocator: Allocator, piece: PreparedQueryPiece) void {
        allocator.free(piece.original);
        allocator.free(piece.originalLowercase);
        allocator.free(piece.pathNormalized);
        allocator.free(piece.normalized);
        allocator.free(piece.normalizedLowercase);
    }
};

fn lower(allocator: Allocator, text: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, text.len);
    for (text, 0..) |character, index| result[index] = std.ascii.toLower(character);
    return result;
}

fn queryExpectsExactMatch(query: []const u8) bool {
    return query.len >= 2 and query[0] == '"' and query[query.len - 1] == '"';
}

const Normalized = struct {
    path_normalized: []u8,
    normalized: []u8,
    normalized_lowercase: []u8,
};

fn normalizeQuery(allocator: Allocator, original: []const u8) !Normalized {
    const path_normalized = try allocator.dupe(u8, original);
    for (path_normalized) |*character| {
        if (character.* == '\\') character.* = '/';
    }

    var filtered = std.array_list.Managed(u8).init(allocator);
    defer filtered.deinit();
    for (path_normalized) |character| {
        if (character == '*' or character == '"') continue;
        if (std.ascii.isWhitespace(character)) continue;
        if (std.mem.eql(u8, &.{ character, 0xE2, 0x80, 0xA6 }, "…")) continue;
        try filtered.append(character);
    }
    // Remove an ellipsis (U+2026) as a UTF-8 sequence.
    var without_ellipsis = std.array_list.Managed(u8).init(allocator);
    defer without_ellipsis.deinit();
    var index: usize = 0;
    while (index < filtered.items.len) {
        if (index + 2 < filtered.items.len and filtered.items[index] == 0xE2 and filtered.items[index + 1] == 0x80 and filtered.items[index + 2] == 0xA6) {
            index += 3;
            continue;
        }
        try without_ellipsis.append(filtered.items[index]);
        index += 1;
    }
    // Strip a trailing `#` query modifier, but only when something precedes it.
    if (without_ellipsis.items.len > 1 and without_ellipsis.items[without_ellipsis.items.len - 1] == '#') {
        _ = without_ellipsis.pop();
    }

    const normalized = try allocator.dupe(u8, without_ellipsis.items);
    errdefer allocator.free(normalized);
    return .{
        .path_normalized = path_normalized,
        .normalized = normalized,
        .normalized_lowercase = try lower(allocator, normalized),
    };
}

pub fn prepareQuery(allocator: Allocator, original_input: []const u8) !PreparedQuery {
    const original = try allocator.dupe(u8, original_input);
    errdefer allocator.free(original);
    const original_lowercase = try lower(allocator, original);
    errdefer allocator.free(original_lowercase);
    const normalized = try normalizeQuery(allocator, original);
    errdefer {
        allocator.free(normalized.path_normalized);
        allocator.free(normalized.normalized);
        allocator.free(normalized.normalized_lowercase);
    }

    var values: ?[]PreparedQueryPiece = null;
    var pieces = std.array_list.Managed(PreparedQueryPiece).init(allocator);
    defer pieces.deinit();
    var split = std.mem.splitScalar(u8, original, ' ');
    var split_count: usize = 0;
    while (split.next()) |_| split_count += 1;
    if (split_count > 1) {
        split = std.mem.splitScalar(u8, original, ' ');
        while (split.next()) |original_piece| {
            if (original_piece.len == 0) continue;
            const piece_normalized = try normalizeQuery(allocator, original_piece);
            if (piece_normalized.normalized.len == 0) {
                allocator.free(piece_normalized.path_normalized);
                allocator.free(piece_normalized.normalized);
                allocator.free(piece_normalized.normalized_lowercase);
                continue;
            }
            try pieces.append(.{
                .original = try allocator.dupe(u8, original_piece),
                .originalLowercase = try lower(allocator, original_piece),
                .pathNormalized = piece_normalized.path_normalized,
                .normalized = piece_normalized.normalized,
                .normalizedLowercase = piece_normalized.normalized_lowercase,
                .expectContiguousMatch = queryExpectsExactMatch(original_piece),
            });
        }
        if (pieces.items.len > 0) values = try pieces.toOwnedSlice();
    }

    return .{
        .original = original,
        .originalLowercase = original_lowercase,
        .pathNormalized = normalized.path_normalized,
        .normalized = normalized.normalized,
        .normalizedLowercase = normalized.normalized_lowercase,
        .values = values,
        .containsPathSeparator = std.mem.indexOfScalar(u8, normalized.path_normalized, '/') != null,
        .expectContiguousMatch = queryExpectsExactMatch(original),
    };
}

pub fn pieceToQuery(allocator: Allocator, pieces: []const PreparedQueryPiece) !PreparedQuery {
    var joined = std.array_list.Managed(u8).init(allocator);
    defer joined.deinit();
    for (pieces, 0..) |piece, index| {
        if (index > 0) try joined.append(' ');
        try joined.appendSlice(piece.original);
    }
    return prepareQuery(allocator, joined.items);
}

pub fn singlePieceToQuery(allocator: Allocator, piece: PreparedQueryPiece) !PreparedQuery {
    return prepareQuery(allocator, piece.original);
}

//#region Fuzzy scoring

pub const FuzzyScore = struct {
    score: i64,
    positions: []usize,

    pub fn deinit(self: *const FuzzyScore, allocator: Allocator) void {
        allocator.free(self.positions);
    }
};

const NO_MATCH: i64 = 0;

fn considerAsEqual(a: u8, b: u8) bool {
    if (a == b) return true;
    if (a == '/' or a == '\\') return b == '/' or b == '\\';
    return false;
}

fn scoreSeparatorAtPos(char_code: u8) i64 {
    return switch (char_code) {
        '/', '\\' => 5,
        '_', '-', '.', ' ', '\'', '"', ':' => 4,
        else => 0,
    };
}

fn computeCharScore(
    query_char: u8,
    query_lower_char: u8,
    target: []const u8,
    target_lower: []const u8,
    target_index: usize,
    matches_sequence_length: i64,
) i64 {
    if (!considerAsEqual(query_lower_char, target_lower[target_index])) return 0;
    var score: i64 = 1;
    if (matches_sequence_length > 0) {
        score += @min(matches_sequence_length, 3) * 6;
        score += @max(@as(i64, 0), matches_sequence_length - 3) * 3;
    }
    if (query_char == target[target_index]) score += 1;
    if (target_index == 0) {
        score += 8;
    } else {
        const separator_bonus = scoreSeparatorAtPos(target[target_index - 1]);
        if (separator_bonus > 0) {
            score += separator_bonus;
        } else if (std.ascii.isUpper(target[target_index]) and matches_sequence_length == 0) {
            score += 2;
        }
    }
    return score;
}

fn targetLowercase(allocator: Allocator, target: []const u8) ![]u8 {
    const lower_target = try allocator.alloc(u8, target.len);
    for (target, 0..) |character, index| lower_target[index] = std.ascii.toLower(character);
    return lower_target;
}

pub fn scoreFuzzy(
    allocator: Allocator,
    target: []const u8,
    query: []const u8,
    query_lower: []const u8,
    allow_non_contiguous_matches: bool,
) !FuzzyScore {
    if (target.len == 0 or query.len == 0 or target.len < query.len) {
        return .{ .score = 0, .positions = try allocator.alloc(usize, 0) };
    }
    const target_length = target.len;
    const query_length = query.len;
    const lower_target = try targetLowercase(allocator, target);
    defer allocator.free(lower_target);

    const matrix_len = query_length * target_length;
    const scores = try allocator.alloc(i64, matrix_len);
    defer allocator.free(scores);
    const matches = try allocator.alloc(i64, matrix_len);
    defer allocator.free(matches);

    var query_index: usize = 0;
    while (query_index < query_length) : (query_index += 1) {
        const query_offset = query_index * target_length;
        const query_previous_offset = if (query_index > 0) query_offset - target_length else 0;
        const query_gt_null = query_index > 0;
        const query_char = query[query_index];
        const query_lower_char = query_lower[query_index];

        var target_index: usize = 0;
        while (target_index < target_length) : (target_index += 1) {
            const target_gt_null = target_index > 0;
            const current_index = query_offset + target_index;
            const left_index = if (current_index > 0) current_index - 1 else 0;
            const diag_index = if (query_gt_null and target_gt_null) query_previous_offset + target_index - 1 else 0;

            const left_score: i64 = if (target_gt_null) scores[left_index] else 0;
            const diag_score: i64 = if (query_gt_null and target_gt_null) scores[diag_index] else 0;
            const matches_sequence_length: i64 = if (query_gt_null and target_gt_null) matches[diag_index] else 0;

            var score: i64 = 0;
            if (!(diag_score == 0 and query_gt_null)) {
                score = computeCharScore(query_char, query_lower_char, target, lower_target, target_index, matches_sequence_length);
            }

            const valid_score = score != 0 and diag_score + score >= left_score;
            const contiguous_ok = allow_non_contiguous_matches or query_gt_null or std.mem.startsWith(u8, lower_target[target_index..], query_lower);
            if (valid_score and contiguous_ok) {
                matches[current_index] = matches_sequence_length + 1;
                scores[current_index] = diag_score + score;
            } else {
                matches[current_index] = NO_MATCH;
                scores[current_index] = left_score;
            }
        }
    }

    var positions = std.array_list.Managed(usize).init(allocator);
    errdefer positions.deinit();
    var qi: isize = @as(isize, @intCast(query_length)) - 1;
    var ti: isize = @as(isize, @intCast(target_length)) - 1;
    while (qi >= 0 and ti >= 0) {
        const current_index: usize = @as(usize, @intCast(qi)) * target_length + @as(usize, @intCast(ti));
        if (matches[current_index] == NO_MATCH) {
            ti -= 1;
        } else {
            try positions.append(@intCast(ti));
            qi -= 1;
            ti -= 1;
        }
    }
    std.mem.reverse(usize, positions.items);
    return .{
        .score = scores[query_length * target_length - 1],
        .positions = try positions.toOwnedSlice(),
    };
}

//#region Alternate fuzzy scorer (scoreFuzzy2)

pub const FuzzyScore2 = struct {
    score: ?i64,
    matches: []Match,

    pub fn deinit(self: *const FuzzyScore2, allocator: Allocator) void {
        allocator.free(self.matches);
    }
};

pub const Match = struct {
    start: usize,
    end: usize,
};

fn matchesFromPositions(allocator: Allocator, positions: []const usize) ![]Match {
    var matches = std.array_list.Managed(Match).init(allocator);
    errdefer matches.deinit();
    var index: usize = 0;
    while (index < positions.len) : (index += 1) {
        var end = index + 1;
        while (end < positions.len and positions[end] == positions[end - 1] + 1) end += 1;
        try matches.append(.{ .start = positions[index], .end = positions[end - 1] + 1 });
        index = end - 1;
    }
    return matches.toOwnedSlice();
}

fn normalizeMatches(allocator: Allocator, matches: []Match) ![]Match {
    var normalized = std.array_list.Managed(Match).init(allocator);
    errdefer normalized.deinit();
    var index: usize = 0;
    while (index < matches.len) : (index += 1) {
        const current = matches[index];
        if (normalized.items.len == 0) {
            try normalized.append(current);
            continue;
        }
        const last = &normalized.items[normalized.items.len - 1];
        if (current.start <= last.end) {
            last.end = @max(last.end, current.end);
        } else {
            try normalized.append(current);
        }
    }
    return normalized.toOwnedSlice();
}

fn doScoreFuzzy2Single(
    allocator: Allocator,
    target: []const u8,
    piece: PreparedQueryPiece,
    pattern_start: usize,
    word_start: usize,
) !FuzzyScore2 {
    _ = pattern_start;
    const score_value = try scoreFuzzy(allocator, target[word_start..], piece.normalized, piece.normalizedLowercase, true);
    defer score_value.deinit(allocator);
    if (score_value.score == 0) return .{ .score = null, .matches = try allocator.alloc(Match, 0) };
    for (score_value.positions) |*position| position.* += word_start;
    return .{ .score = score_value.score, .matches = try matchesFromPositions(allocator, score_value.positions) };
}

pub fn scoreFuzzy2(
    allocator: Allocator,
    target: []const u8,
    query: *const PreparedQuery,
    pattern_start: usize,
    word_start: usize,
) !FuzzyScore2 {
    if (query.values) |values| {
        if (values.len > 1) {
            var total_score: i64 = 0;
            var all_matches = std.array_list.Managed(Match).init(allocator);
            defer all_matches.deinit();
            for (values) |piece| {
                const single = try doScoreFuzzy2Single(allocator, target, piece, pattern_start, word_start);
                defer single.deinit(allocator);
                if (single.score == null) {
                    return .{ .score = null, .matches = try allocator.alloc(Match, 0) };
                }
                total_score += single.score.?;
                try all_matches.appendSlice(single.matches);
            }
            std.mem.sort(Match, all_matches.items, {}, struct {
                fn lessThan(_: void, a: Match, b: Match) bool {
                    return a.start < b.start;
                }
            }.lessThan);
            return .{ .score = total_score, .matches = try normalizeMatches(allocator, all_matches.items) };
        }
    }
    const piece = PreparedQueryPiece{
        .original = query.original,
        .originalLowercase = query.originalLowercase,
        .pathNormalized = query.pathNormalized,
        .normalized = query.normalized,
        .normalizedLowercase = query.normalizedLowercase,
        .expectContiguousMatch = query.expectContiguousMatch,
    };
    return doScoreFuzzy2Single(allocator, target, piece, pattern_start, word_start);
}
