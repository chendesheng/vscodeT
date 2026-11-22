// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/brackets.ts`.
//
// The port keeps a per-language delimiter table (`LanguageBrackets`) rather
// than upstream's `BracketTokens` map and does matching without a RegExp.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const LanguageConfiguration = @import("../../../languages/languageConfiguration.zig").LanguageConfiguration;

pub const BracketDef = struct {
    open: []const u8,
    close: []const u8,
    colorized: bool,
};

pub const LanguageBrackets = struct {
    defs: ArrayList(BracketDef),
    all: ArrayList([]const u8),
};

pub fn buildLanguageBrackets(allocator: Allocator, config: LanguageConfiguration) !LanguageBrackets {
    var defs = ArrayList(BracketDef).init(allocator);
    errdefer defs.deinit();
    var all = ArrayList([]const u8).init(allocator);
    errdefer all.deinit();

    // Upstream treats `colorizedBracketPairs` as bracket pairs as well, and
    // marks the (open, close) relation colorized. A closing bracket can be
    // colorized for some openings and not for others.
    if (config.brackets) |brackets| {
        for (brackets) |pair| try addBracketDef(&defs, &all, pair[0], pair[1], false);
    }
    if (config.colorizedBracketPairs) |pairs| {
        for (pairs) |pair| try addBracketDef(&defs, &all, pair[0], pair[1], true);
    } else if (config.brackets) |brackets| {
        for (brackets) |pair| {
            // Many languages use < and > as brackets even though they are
            // comparison operators; upstream excludes that exact pair from
            // colorization unless it is configured explicitly.
            if (std.mem.eql(u8, pair[0], "<") and std.mem.eql(u8, pair[1], ">")) continue;
            try addBracketDef(&defs, &all, pair[0], pair[1], true);
        }
    }
    return .{ .defs = defs, .all = all };
}

fn addBracketDef(defs: *ArrayList(BracketDef), all: *ArrayList([]const u8), open: []const u8, close: []const u8, colorized: bool) !void {
    if (open.len == 0 or close.len == 0) return;
    for (defs.items) |*def| {
        if (std.mem.eql(u8, def.open, open) and std.mem.eql(u8, def.close, close)) {
            def.colorized = def.colorized or colorized;
            return;
        }
    }
    try defs.append(.{ .open = open, .close = close, .colorized = colorized });
    try all.append(open);
    try all.append(close);
}

/// Upstream `BracketTokens.getToken` matching: case-insensitive and bounded by
/// the current token. Word-like delimiters get `\b` boundaries in the upstream
/// regex, reproduced here.
pub fn matchAt(text: []const u8, pos: usize, max_end: usize, brackets: *LanguageBrackets, opening: bool) ?[]const u8 {
    var best: ?[]const u8 = null;
    const end_limit = @min(text.len, max_end);
    for (brackets.defs.items) |def| {
        const candidate = if (opening) def.open else def.close;
        if (candidate.len == 0 or pos + candidate.len > end_limit) continue;
        if (!std.ascii.eqlIgnoreCase(text[pos .. pos + candidate.len], candidate)) continue;
        if (!wordBoundariesMatch(text, pos, candidate)) continue;
        if (best == null or candidate.len > best.?.len) best = candidate;
    }
    return best;
}

fn isWordCharacter(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Mirrors `prepareBracketForRegExp`: a delimiter starting/ending with a word
/// character or space gets a `\b` assertion at that edge.
fn wordBoundariesMatch(text: []const u8, pos: usize, candidate: []const u8) bool {
    if (candidate.len == 0) return false;
    if (isWordCharacter(candidate[0]) or candidate[0] == ' ') {
        const previous_word = pos > 0 and isWordCharacter(text[pos - 1]);
        if (isWordCharacter(candidate[0])) {
            if (previous_word) return false;
        } else {
            if (!previous_word) return false;
        }
    }
    const last = candidate[candidate.len - 1];
    if (isWordCharacter(last) or last == ' ') {
        const end = pos + candidate.len;
        const next_word = end < text.len and isWordCharacter(text[end]);
        if (isWordCharacter(last)) {
            if (next_word) return false;
        } else {
            if (!next_word) return false;
        }
    }
    return true;
}

fn utf8Len(text: []const u8) usize {
    if (text.len == 0) return 1;
    return std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
}
