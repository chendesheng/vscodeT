// Port of the query-normalizer region of `src/vs/base/common/fuzzyScorer.ts`.
//
// Terminal adaptations: path separators are POSIX-only (`/`, backslashes are
// normalized to `/`), lowercasing is ASCII (the terminal matcher scores ASCII
// identifiers), and `scoreFuzzy2` derives its ranges from the ported matrix
// scorer instead of `filters.fuzzyScore` (the filters DP scorer is not ported).
const std = @import("std");
const Allocator = std.mem.Allocator;
const comparers = @import("./comparers.zig");

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

//#region Item (label, description, path) scorer

pub const ItemScore = struct {
    score: i64,
    label_match: ?[]Match,
    description_match: ?[]Match,

    pub fn deinit(self: *const ItemScore, allocator: Allocator) void {
        if (self.label_match) |matches| allocator.free(matches);
        if (self.description_match) |matches| allocator.free(matches);
    }
};

pub const ItemAccessor = struct {
    context: *anyopaque,
    get_item_label: *const fn (context: *anyopaque, item: *const anyopaque) ?[]const u8,
    get_item_description: *const fn (context: *anyopaque, item: *const anyopaque) ?[]const u8,
    get_item_path: *const fn (context: *anyopaque, item: *const anyopaque) ?[]const u8,
};

const PATH_IDENTITY_SCORE: i64 = 1 << 18;
const LABEL_PREFIX_SCORE_THRESHOLD: i64 = 1 << 17;
const LABEL_SCORE_THRESHOLD: i64 = 1 << 16;

fn matchesPrefix(word: []const u8, target: []const u8) ?Match {
    if (target.len < word.len) return null;
    if (!std.ascii.eqlIgnoreCase(target[0..word.len], word)) return null;
    return .{ .start = 0, .end = word.len };
}

fn createMatchesFromPositions(allocator: Allocator, positions: []const usize) ![]Match {
    return matchesFromPositions(allocator, positions);
}

fn scoreSingleItem(
    allocator: Allocator,
    label: []const u8,
    description: ?[]const u8,
    path: ?[]const u8,
    piece: PreparedQueryPiece,
    prefer_label_matches: bool,
    allow_non_contiguous_matches: bool,
) !ItemScore {
    if (prefer_label_matches or description == null) {
        const label_score = try scoreFuzzy(allocator, label, piece.normalized, piece.normalizedLowercase, allow_non_contiguous_matches and !piece.expectContiguousMatch);
        defer label_score.deinit(allocator);
        if (label_score.score != 0) {
            const prefix_match = matchesPrefix(piece.normalized, label);
            var base_score = LABEL_SCORE_THRESHOLD;
            if (prefix_match != null) {
                base_score = LABEL_PREFIX_SCORE_THRESHOLD;
                const prefix_length_boost = @divTrunc(@as(i64, @intCast(piece.normalized.len)) * 100, @as(i64, @intCast(label.len)));
                base_score += prefix_length_boost;
            }
            const matches = if (prefix_match) |prefix| blk: {
                const result = try allocator.alloc(Match, 1);
                result[0] = prefix;
                break :blk result;
            } else try createMatchesFromPositions(allocator, label_score.positions);
            return .{ .score = base_score + label_score.score, .label_match = matches, .description_match = null };
        }
    }

    if (description) |description_value| {
        var prefix = std.array_list.Managed(u8).init(allocator);
        defer prefix.deinit();
        try prefix.appendSlice(description_value);
        if (path != null) try prefix.append('/');
        const description_prefix_length = prefix.items.len;
        try prefix.appendSlice(label);
        const combined = prefix.items;
        const combined_score = try scoreFuzzy(allocator, combined, piece.normalized, piece.normalizedLowercase, allow_non_contiguous_matches and !piece.expectContiguousMatch);
        defer combined_score.deinit(allocator);
        if (combined_score.score != 0) {
            const all_matches = try createMatchesFromPositions(allocator, combined_score.positions);
            defer allocator.free(all_matches);
            var label_matches = std.array_list.Managed(Match).init(allocator);
            var description_matches = std.array_list.Managed(Match).init(allocator);
            for (all_matches) |match| {
                if (match.start < description_prefix_length and match.end > description_prefix_length) {
                    try label_matches.append(.{ .start = 0, .end = match.end - description_prefix_length });
                    try description_matches.append(.{ .start = match.start, .end = description_prefix_length });
                } else if (match.start >= description_prefix_length) {
                    try label_matches.append(.{ .start = match.start - description_prefix_length, .end = match.end - description_prefix_length });
                } else {
                    try description_matches.append(match);
                }
            }
            return .{
                .score = combined_score.score,
                .label_match = try label_matches.toOwnedSlice(),
                .description_match = try description_matches.toOwnedSlice(),
            };
        }
    }

    return .{ .score = 0, .label_match = try allocator.alloc(Match, 0), .description_match = null };
}

pub fn scoreItemFuzzy(
    allocator: Allocator,
    item: *const anyopaque,
    query: *const PreparedQuery,
    allow_non_contiguous_matches: bool,
    accessor: ItemAccessor,
) !ItemScore {
    if (query.normalized.len == 0) return .{ .score = 0, .label_match = null, .description_match = null };
    const label = accessor.get_item_label(accessor.context, item) orelse return .{ .score = 0, .label_match = null, .description_match = null };
    const description = accessor.get_item_description(accessor.context, item);
    const path = accessor.get_item_path(accessor.context, item);
    const prefer_label_matches = path == null or !query.containsPathSeparator;

    if (path) |path_value| {
        if (std.mem.eql(u8, query.pathNormalized, path_value)) {
            const label_match = try allocator.alloc(Match, 1);
            label_match[0] = .{ .start = 0, .end = label.len };
            var description_match: ?[]Match = null;
            if (description) |description_value| {
                const matches = try allocator.alloc(Match, 1);
                matches[0] = .{ .start = 0, .end = description_value.len };
                description_match = matches;
            }
            return .{ .score = PATH_IDENTITY_SCORE, .label_match = label_match, .description_match = description_match };
        }
    }

    if (query.values) |values| {
        if (values.len > 1) {
            var total_score: i64 = 0;
            var label_matches = std.array_list.Managed(Match).init(allocator);
            defer label_matches.deinit();
            var description_matches = std.array_list.Managed(Match).init(allocator);
            defer description_matches.deinit();
            for (values) |piece| {
                const single = try scoreSingleItem(allocator, label, description, path, piece, prefer_label_matches, allow_non_contiguous_matches);
                defer single.deinit(allocator);
                if (single.score == 0) return .{ .score = 0, .label_match = null, .description_match = null };
                total_score += single.score;
                if (single.label_match) |matches| try label_matches.appendSlice(matches);
                if (single.description_match) |matches| try description_matches.appendSlice(matches);
            }
            std.mem.sort(Match, label_matches.items, {}, struct {
                fn lessThan(_: void, a: Match, b: Match) bool {
                    return a.start < b.start;
                }
            }.lessThan);
            std.mem.sort(Match, description_matches.items, {}, struct {
                fn lessThan(_: void, a: Match, b: Match) bool {
                    return a.start < b.start;
                }
            }.lessThan);
            return .{
                .score = total_score,
                .label_match = try normalizeMatches(allocator, label_matches.items),
                .description_match = try normalizeMatches(allocator, description_matches.items),
            };
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
    return scoreSingleItem(allocator, label, description, path, piece, prefer_label_matches, allow_non_contiguous_matches);
}

fn compareByMatchLength(matches_a: ?[]const Match, matches_b: ?[]const Match) i32 {
    const len_a = if (matches_a) |matches| matches.len else 0;
    const len_b = if (matches_b) |matches| matches.len else 0;
    if (len_a == 0 and len_b == 0) return 0;
    if (len_b == 0) return -1;
    if (len_a == 0) return 1;
    const match_length_a = matches_a.?[matches_a.?.len - 1].end - matches_a.?[0].start;
    const match_length_b = matches_b.?[matches_b.?.len - 1].end - matches_b.?[0].start;
    if (match_length_a == match_length_b) return 0;
    return if (match_length_b < match_length_a) 1 else -1;
}

fn matchDistance(item: *const anyopaque, score: ItemScore, accessor: ItemAccessor) i64 {
    var match_start: i64 = -1;
    var match_end: i64 = -1;
    const has_description = score.description_match != null and score.description_match.?.len > 0;
    const has_label = score.label_match != null and score.label_match.?.len > 0;
    if (has_description) {
        match_start = @intCast(score.description_match.?[0].start);
    } else if (has_label) {
        match_start = @intCast(score.label_match.?[0].start);
    }
    if (has_label) {
        match_end = @intCast(score.label_match.?[score.label_match.?.len - 1].end);
        if (has_description) {
            if (accessor.get_item_description(accessor.context, item)) |description| {
                match_end += @intCast(description.len);
            }
        }
    } else if (has_description) {
        match_end = @intCast(score.description_match.?[score.description_match.?.len - 1].end);
    }
    return match_end - match_start;
}

pub fn compareItemsByFuzzyScore(
    allocator: Allocator,
    item_a: *const anyopaque,
    item_b: *const anyopaque,
    query: *const PreparedQuery,
    allow_non_contiguous_matches: bool,
    accessor: ItemAccessor,
) !i32 {
    const score_a = try scoreItemFuzzy(allocator, item_a, query, allow_non_contiguous_matches, accessor);
    defer score_a.deinit(allocator);
    const score_b = try scoreItemFuzzy(allocator, item_b, query, allow_non_contiguous_matches, accessor);
    defer score_b.deinit(allocator);

    // 1) identity matches
    if (score_a.score == PATH_IDENTITY_SCORE or score_b.score == PATH_IDENTITY_SCORE) {
        if (score_a.score != score_b.score) return if (score_a.score == PATH_IDENTITY_SCORE) -1 else 1;
    }

    // 2) label matches
    if (score_a.score > LABEL_SCORE_THRESHOLD or score_b.score > LABEL_SCORE_THRESHOLD) {
        if (score_a.score != score_b.score) return if (score_a.score > score_b.score) -1 else 1;
        if (score_a.score < LABEL_PREFIX_SCORE_THRESHOLD and score_b.score < LABEL_PREFIX_SCORE_THRESHOLD) {
            const by_length = compareByMatchLength(score_a.label_match, score_b.label_match);
            if (by_length != 0) return by_length;
        }
        const label_a = accessor.get_item_label(accessor.context, item_a) orelse "";
        const label_b = accessor.get_item_label(accessor.context, item_b) orelse "";
        if (label_a.len != label_b.len) return @intCast(@as(isize, @intCast(label_a.len)) - @as(isize, @intCast(label_b.len)));
    }

    // 3) label+description score
    if (score_a.score != score_b.score) return if (score_a.score > score_b.score) -1 else 1;

    // 4) label matches preferred
    const a_has_label = score_a.label_match != null and score_a.label_match.?.len > 0;
    const b_has_label = score_b.label_match != null and score_b.label_match.?.len > 0;
    if (a_has_label and !b_has_label) return -1;
    if (b_has_label and !a_has_label) return 1;

    // 5) more compact matches
    const distance_a = matchDistance(item_a, score_a, accessor);
    const distance_b = matchDistance(item_b, score_b, accessor);
    if (distance_a >= 0 and distance_b >= 0 and distance_a != distance_b) return if (distance_b > distance_a) -1 else 1;

    // 6) fallback: label/description length, path length, label compare
    const label_a = accessor.get_item_label(accessor.context, item_a) orelse "";
    const label_b = accessor.get_item_label(accessor.context, item_b) orelse "";
    const description_a = accessor.get_item_description(accessor.context, item_a);
    const description_b = accessor.get_item_description(accessor.context, item_b);
    const length_a = label_a.len + (if (description_a) |value| value.len else 0);
    const length_b = label_b.len + (if (description_b) |value| value.len else 0);
    if (length_a != length_b) return @intCast(@as(isize, @intCast(length_a)) - @as(isize, @intCast(length_b)));

    const path_a = accessor.get_item_path(accessor.context, item_a);
    const path_b = accessor.get_item_path(accessor.context, item_b);
    if (path_a != null and path_b != null and path_a.?.len != path_b.?.len) {
        return @intCast(@as(isize, @intCast(path_a.?.len)) - @as(isize, @intCast(path_b.?.len)));
    }
    if (!std.mem.eql(u8, label_a, label_b)) return comparers.compareAnything(label_a, label_b, query.normalized);
    if (description_a != null and description_b != null and !std.mem.eql(u8, description_a.?, description_b.?)) {
        return comparers.compareAnything(description_a.?, description_b.?, query.normalized);
    }
    if (path_a != null and path_b != null and !std.mem.eql(u8, path_a.?, path_b.?)) {
        return comparers.compareAnything(path_a.?, path_b.?, query.normalized);
    }
    return 0;
}

/// Optional scorer cache keyed by the scoring inputs (label, description,
/// match mode and normalized query pieces). Upstream hashes these inputs; the
/// terminal key is a readable composite so it stays debuggable.
pub const FuzzyScorerCache = std.StringHashMap(ItemScore);

fn cloneMatches(allocator: Allocator, matches: ?[]Match) !?[]Match {
    if (matches) |value| return try allocator.dupe(Match, value);
    return null;
}

pub fn cloneItemScore(allocator: Allocator, score: ItemScore) !ItemScore {
    return .{
        .score = score.score,
        .label_match = try cloneMatches(allocator, score.label_match),
        .description_match = try cloneMatches(allocator, score.description_match),
    };
}

pub fn deinitItemScoreCache(cache: *FuzzyScorerCache, allocator: Allocator) void {
    var iterator = cache.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    cache.deinit();
}

fn cacheKey(allocator: Allocator, label: []const u8, description: ?[]const u8, allow_non_contiguous_matches: bool, query: *const PreparedQuery) ![]u8 {
    var key = std.array_list.Managed(u8).init(allocator);
    defer key.deinit();
    try key.appendSlice(if (allow_non_contiguous_matches) "1|" else "0|");
    try key.appendSlice(label);
    try key.append('|');
    if (description) |value| try key.appendSlice(value);
    try key.append('|');
    try key.appendSlice(query.normalized);
    try key.append('|');
    if (query.values) |values| {
        for (values) |piece| {
            try key.appendSlice(piece.normalized);
            try key.append(if (piece.expectContiguousMatch) '1' else '0');
        }
    }
    return key.toOwnedSlice();
}

/// Cached variant of `scoreItemFuzzy`. Returned scores own their matches; the
/// cache keeps an independent copy.
pub fn scoreItemFuzzyCached(
    allocator: Allocator,
    item: *const anyopaque,
    query: *const PreparedQuery,
    allow_non_contiguous_matches: bool,
    accessor: ItemAccessor,
    cache: *FuzzyScorerCache,
) !ItemScore {
    if (query.normalized.len == 0) return .{ .score = 0, .label_match = null, .description_match = null };
    const label = accessor.get_item_label(accessor.context, item) orelse return .{ .score = 0, .label_match = null, .description_match = null };
    const description = accessor.get_item_description(accessor.context, item);
    const key = try cacheKey(allocator, label, description, allow_non_contiguous_matches, query);
    if (cache.get(key)) |cached| {
        allocator.free(key);
        return cloneItemScore(allocator, cached);
    }
    errdefer allocator.free(key);
    const score = try scoreItemFuzzy(allocator, item, query, allow_non_contiguous_matches, accessor);
    errdefer {
        var mutable = score;
        mutable.deinit(allocator);
    }
    try cache.put(key, try cloneItemScore(allocator, score));
    return score;
}
