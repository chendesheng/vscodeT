// Port of the query-normalizer region of `src/vs/base/common/fuzzyScorer.ts`.
//
// Terminal adaptations: path separators are POSIX-only (`/`, backslashes are
// normalized to `/`), and lowercasing is ASCII (the terminal matcher scores
// ASCII identifiers); the scoring functions are not ported yet.
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
