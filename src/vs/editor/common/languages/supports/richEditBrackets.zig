const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const StringHashMap = std.StringHashMap;
const RegExp = @import("../../../../../support/regexp.zig").RegExp;
const RegExpOptions = @import("../../../../../support/regexp.zig").Options;
const escapeRegExp = @import("../../../../../support/regexp.zig").escapeRegExp;
const Range = @import("../../core/range.zig").Range;
const CharacterPair = @import("../languageConfiguration.zig").CharacterPair;

const InternalBracket = struct {
    open: []const []const u8,
    close: []const []const u8,
};

/// Represents one group of colliding bracket pairs.
pub const RichEditBracket = struct {
    languageId: []const u8,
    index: usize,
    open: []const []const u8,
    close: []const []const u8,
    forwardRegex: RegExp,
    reversedRegex: RegExp,
    _openSet: StringHashMap(void),
    _closeSet: StringHashMap(void),

    pub fn isOpen(self: *const RichEditBracket, text: []const u8) bool {
        return self._openSet.contains(text);
    }

    pub fn isClose(self: *const RichEditBracket, text: []const u8) bool {
        return self._closeSet.contains(text);
    }
};

/// All bracket groups for one language, plus matching helpers.
pub const RichEditBrackets = struct {
    arena: std.heap.ArenaAllocator,
    brackets: []RichEditBracket,
    forwardRegex: RegExp,
    reversedRegex: RegExp,
    maxBracketLength: usize,
    textIsBracket: StringHashMap(*const RichEditBracket),
    textIsOpenBracket: StringHashMap(bool),

    pub fn init(allocator: Allocator, languageId: []const u8, raw_brackets: []const CharacterPair) !RichEditBrackets {
        if (raw_brackets.len == 0) return error.EmptyBrackets;
        for (raw_brackets) |pair| {
            if (pair[0].len == 0 or pair[1].len == 0) return error.EmptyBracket;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const groups = try groupFuzzyBrackets(a, raw_brackets);
        var brackets = try a.alloc(RichEditBracket, groups.len);
        var initialized: usize = 0;
        errdefer {
            for (brackets[0..initialized]) |*bracket| {
                bracket.forwardRegex.deinit();
                bracket.reversedRegex.deinit();
            }
        }

        for (groups, 0..) |group, index| {
            const open = try a.alloc([]const u8, group.open.len);
            for (group.open, 0..) |piece, i| open[i] = piece;
            const close = try a.alloc([]const u8, group.close.len);
            for (group.close, 0..) |piece, i| close[i] = piece;

            var openSet = StringHashMap(void).init(a);
            for (open) |piece| try openSet.put(piece, {});
            var closeSet = StringHashMap(void).init(a);
            for (close) |piece| try closeSet.put(piece, {});

            const forwardRegex = try createRegexForBracketPair(a, group.open, group.close, groups, index);
            const reversedRegex = createReversedRegexForBracketPair(a, group.open, group.close, groups, index) catch |err| {
                forwardRegex.deinit();
                return err;
            };

            brackets[index] = .{
                .languageId = languageId,
                .index = index,
                .open = open,
                .close = close,
                .forwardRegex = forwardRegex,
                .reversedRegex = reversedRegex,
                ._openSet = openSet,
                ._closeSet = closeSet,
            };
            initialized += 1;
        }

        const forwardRegex = try getRegexForBrackets(a, brackets);
        const reversedRegex = getReversedRegexForBrackets(a, brackets) catch |err| {
            forwardRegex.deinit();
            return err;
        };
        errdefer forwardRegex.deinit();
        errdefer reversedRegex.deinit();

        var textIsBracket = StringHashMap(*const RichEditBracket).init(a);
        var textIsOpenBracket = StringHashMap(bool).init(a);
        var maxBracketLength: usize = 0;

        for (brackets, 0..) |*bracket, index| {
            for (bracket.open) |piece| {
                try textIsBracket.put(piece, &brackets[index]);
                try textIsOpenBracket.put(piece, true);
                maxBracketLength = @max(maxBracketLength, piece.len);
            }
            for (bracket.close) |piece| {
                try textIsBracket.put(piece, &brackets[index]);
                try textIsOpenBracket.put(piece, false);
                maxBracketLength = @max(maxBracketLength, piece.len);
            }
        }

        return .{
            .arena = arena,
            .brackets = brackets,
            .forwardRegex = forwardRegex,
            .reversedRegex = reversedRegex,
            .maxBracketLength = maxBracketLength,
            .textIsBracket = textIsBracket,
            .textIsOpenBracket = textIsOpenBracket,
        };
    }

    pub fn deinit(self: *RichEditBrackets) void {
        for (self.brackets) |*bracket| {
            bracket.forwardRegex.deinit();
            bracket.reversedRegex.deinit();
        }
        self.forwardRegex.deinit();
        self.reversedRegex.deinit();
        self.arena.deinit();
    }
};

fn toLowercaseAlloc(allocator: Allocator, text: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, text.len);
    for (text, 0..) |ch, i| result[i] = std.ascii.toLower(ch);
    return result;
}

fn areOverlapping(a: CharacterPair, b: CharacterPair) bool {
    return std.mem.eql(u8, a[0], b[0]) or
        std.mem.eql(u8, a[0], b[1]) or
        std.mem.eql(u8, a[1], b[0]) or
        std.mem.eql(u8, a[1], b[1]);
}

fn mergeGroups(groups: []usize, g1: usize, g2: usize) void {
    const new_group = @min(g1, g2);
    const old_group = @max(g1, g2);
    for (groups) |*group| {
        if (group.* == old_group) group.* = new_group;
    }
}

fn groupFuzzyBrackets(allocator: Allocator, raw_brackets: []const CharacterPair) ![]InternalBracket {
    const count = raw_brackets.len;
    const brackets = try allocator.alloc(CharacterPair, count);
    for (raw_brackets, 0..) |pair, i| {
        brackets[i] = .{
            try toLowercaseAlloc(allocator, pair[0]),
            try toLowercaseAlloc(allocator, pair[1]),
        };
    }

    const groups = try allocator.alloc(usize, count);
    for (groups, 0..) |*group, i| group.* = i;

    for (0..count) |i| {
        for (i + 1..count) |j| {
            if (areOverlapping(brackets[i], brackets[j])) {
                mergeGroups(groups, groups[i], groups[j]);
            }
        }
    }

    var result = ArrayList(InternalBracket).init(allocator);
    errdefer result.deinit();
    for (0..count) |group_index| {
        var open = ArrayList([]const u8).init(allocator);
        errdefer open.deinit();
        var close = ArrayList([]const u8).init(allocator);
        errdefer close.deinit();

        for (0..count) |i| {
            if (groups[i] != group_index) continue;
            try open.append(brackets[i][0]);
            try close.append(brackets[i][1]);
        }

        if (open.items.len == 0) continue;
        try result.append(.{
            .open = try open.toOwnedSlice(),
            .close = try close.toOwnedSlice(),
        });
    }

    return try result.toOwnedSlice();
}

fn collectSuperstrings(pieces: *ArrayList([]const u8), brackets: []const InternalBracket, current_index: usize) !void {
    // Only inspect the original delimiters. The longer matches appended
    // below already contain one of them.
    for (0..pieces.items.len) |i| {
        const piece = pieces.items[i];
        for (brackets, 0..) |bracket, index| {
            if (index == current_index) continue;
            for (bracket.open) |candidate| {
                if (std.mem.indexOf(u8, candidate, piece) != null) try pieces.append(candidate);
            }
            for (bracket.close) |candidate| {
                if (std.mem.indexOf(u8, candidate, piece) != null) try pieces.append(candidate);
            }
        }
    }
}

fn uniquePieces(allocator: Allocator, pieces: []const []const u8) ![][]const u8 {
    var seen = StringHashMap(void).init(allocator);
    var result = ArrayList([]const u8).init(allocator);
    errdefer result.deinit();
    for (pieces) |piece| {
        if (seen.contains(piece)) continue;
        try seen.put(piece, {});
        try result.append(piece);
    }
    return try result.toOwnedSlice();
}

fn compareByLength(_: void, a: []const u8, b: []const u8) bool {
    return a.len < b.len;
}

fn bracketPieces(
    allocator: Allocator,
    open: []const []const u8,
    close: []const []const u8,
    brackets: []const InternalBracket,
    current_index: usize,
) ![][]const u8 {
    var pieces = ArrayList([]const u8).init(allocator);
    defer pieces.deinit();
    try pieces.appendSlice(open);
    try pieces.appendSlice(close);
    try collectSuperstrings(&pieces, brackets, current_index);

    const unique = try uniquePieces(allocator, pieces.items);
    std.sort.heap([]const u8, unique, {}, compareByLength);
    std.mem.reverse([]const u8, unique);
    return unique;
}

fn reversedString(allocator: Allocator, text: []const u8) ![]const u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    var i = text.len;
    while (i > 0) {
        var start = i - 1;
        while (start > 0 and (text[start] & 0xC0) == 0x80) start -= 1;
        try result.appendSlice(text[start..i]);
        i = start;
    }
    return try result.toOwnedSlice();
}

fn reversedPieces(allocator: Allocator, pieces: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, pieces.len);
    for (pieces, 0..) |piece, i| result[i] = try reversedString(allocator, piece);
    return result;
}

fn createRegexForBracketPair(
    allocator: Allocator,
    open: []const []const u8,
    close: []const []const u8,
    brackets: []const InternalBracket,
    current_index: usize,
) !RegExp {
    const pieces = try bracketPieces(allocator, open, close, brackets, current_index);
    return createBracketOrRegExp(allocator, pieces, .{});
}

fn createReversedRegexForBracketPair(
    allocator: Allocator,
    open: []const []const u8,
    close: []const []const u8,
    brackets: []const InternalBracket,
    current_index: usize,
) !RegExp {
    const pieces = try bracketPieces(allocator, open, close, brackets, current_index);
    const reversed = try reversedPieces(allocator, pieces);
    return createBracketOrRegExp(allocator, reversed, .{});
}

fn allBracketPieces(allocator: Allocator, brackets: []const RichEditBracket) !ArrayList([]const u8) {
    var result = ArrayList([]const u8).init(allocator);
    errdefer result.deinit();
    for (brackets) |bracket| {
        try result.appendSlice(bracket.open);
        try result.appendSlice(bracket.close);
    }
    return result;
}

fn getRegexForBrackets(allocator: Allocator, brackets: []const RichEditBracket) !RegExp {
    var pieces = try allBracketPieces(allocator, brackets);
    defer pieces.deinit();
    const unique = try uniquePieces(allocator, pieces.items);
    return createBracketOrRegExp(allocator, unique, .{});
}

fn getReversedRegexForBrackets(allocator: Allocator, brackets: []const RichEditBracket) !RegExp {
    var pieces = try allBracketPieces(allocator, brackets);
    defer pieces.deinit();
    const unique = try uniquePieces(allocator, pieces.items);
    const reversed = try reversedPieces(allocator, unique);
    return createBracketOrRegExp(allocator, reversed, .{});
}

fn prepareBracketForRegExp(allocator: Allocator, text: []const u8) !ArrayList(u8) {
    if (text.len == 0) return error.EmptyBracket;
    // This bracket pair uses letters like e.g. "begin" - "end"
    var wordReg = try RegExp.init("^[\\w ]+$", .{});
    defer wordReg.deinit();
    const insertWordBoundaries = wordReg.isMatch(text);
    var escaped = try escapeRegExp(allocator, text);
    if (insertWordBoundaries) {
        try escaped.insertSlice(0, "\\b");
        try escaped.appendSlice("\\b");
    }
    return escaped;
}

pub fn createBracketOrRegExp(allocator: Allocator, pieces: []const []const u8, options: RegExpOptions) !RegExp {
    if (pieces.len == 0) return error.EmptyBrackets;

    var regexStr = ArrayList(u8).init(allocator);
    defer regexStr.deinit();

    try regexStr.append('(');
    for (pieces, 0..) |piece, index| {
        if (index > 0) try regexStr.appendSlice(")|(");
        var escaped = try prepareBracketForRegExp(allocator, piece);
        defer escaped.deinit();
        try regexStr.appendSlice(escaped.items);
    }
    try regexStr.append(')');

    return RegExp.init(regexStr.items, options);
}

pub const BracketsUtils = struct {
    pub fn findPrevBracketInRange(
        allocator: Allocator,
        reversedBracketRegex: *const RegExp,
        lineNumber: usize,
        lineText: []const u8,
        startOffset: usize,
        endOffset: usize,
    ) !?Range {
        if (startOffset > endOffset or endOffset > lineText.len) return null;

        const reversed = try reversedString(allocator, lineText[startOffset..endOffset]);
        defer allocator.free(reversed);
        const match = reversedBracketRegex.search(reversed) orelse return null;
        const matchOffset = reversed.len - match.index();
        const absoluteMatchOffset = startOffset + matchOffset;
        const matchLength = match.length();

        return Range.init(
            lineNumber,
            absoluteMatchOffset - matchLength + 1,
            lineNumber,
            absoluteMatchOffset + 1,
        );
    }

    pub fn findNextBracketInRange(
        bracketRegex: *const RegExp,
        lineNumber: usize,
        lineText: []const u8,
        startOffset: usize,
        endOffset: usize,
    ) ?Range {
        if (startOffset >= endOffset or endOffset > lineText.len) return null;
        const match = bracketRegex.search(lineText[startOffset..endOffset]) orelse return null;
        if (match.length() == 0) return null;

        const absoluteMatchOffset = startOffset + match.index();
        return Range.init(
            lineNumber,
            absoluteMatchOffset + 1,
            lineNumber,
            absoluteMatchOffset + 1 + match.length(),
        );
    }
};
