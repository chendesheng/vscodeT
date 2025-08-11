const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Set = @import("../../basics/set.zig").Set;
const CachedFunction = @import("../../basics/cache.zig").CachedFunction;
const RegExp = @import("../../basics/RegExp.zig").RegExp;
const LanguageConfiguration = @import("../languageConfiguration.zig").LanguageConfiguration;
const CharacterPair = @import("../languageConfiguration.zig").CharacterPair;
const RegExpOptions = @import("../../basics/RegExp.zig").Options;
const Pair = @import("../../basics/utils.zig").Pair;
const pair = @import("../../basics/utils.zig").pair;
const createBracketOrRegExp = @import("richEditBrackets.zig").createBracketOrRegExp;

// Captures all bracket related configurations for a single language.
// Immutable.

pub const LanguageBracketsConfiguration = struct {
    const Self = @This();

    var ID: u32 = 0;

    id: u32,
    _openingBrackets: StringHashMap(OpeningBracketKind),
    _closingBrackets: StringHashMap(ClosingBracketKind),
    languageId: []const u8,
    config: LanguageConfiguration,

    pub fn init(allocator: Allocator, languageId: []const u8, config: LanguageConfiguration) !Self {
        const bracketPairs: ArrayList(CharacterPair) = if (config.brackets) |brackets|
            try filterValidBrackets(allocator, brackets)
        else
            ArrayList(CharacterPair).init(allocator);
        defer bracketPairs.deinit();

        ID += 1;
        var self = Self{
            .id = ID,
            .languageId = languageId,
            .config = config,
            ._openingBrackets = StringHashMap(OpeningBracketKind).init(allocator),
            ._closingBrackets = StringHashMap(ClosingBracketKind).init(allocator),
        };
        const openingBracketInfos = CachedFunction([]const u8, OpeningBracketKindInfo, Self).init(
            allocator,
            self,
            struct {
                fn f(bracket: []const u8, this: Self) OpeningBracketKindInfo {
                    const closing = Set(ClosingBracketKind).init();
                    return OpeningBracketKindInfo{
                        .info = OpeningBracketKind.init(this, bracket, closing),
                        .closing = closing,
                    };
                }
            }.f,
            null,
        );
        defer openingBracketInfos.deinit();

        const closingBracketInfos = CachedFunction([]const u8, ClosingBracketKindInfo, Self).init(
            allocator,
            self,
            struct {
                fn f(bracket: []const u8, this: Self) ClosingBracketKindInfo {
                    const opening = Set(OpeningBracketKind).init();
                    const openingColorized = Set(OpeningBracketKind).init();
                    return ClosingBracketKindInfo{
                        .info = ClosingBracketKind.init(this, bracket, opening, openingColorized),
                        .opening = opening,
                        .openingColorized = openingColorized,
                    };
                }
            }.f,
        );
        defer closingBracketInfos.deinit();

        for (bracketPairs.items) |p| {
            const opening = try openingBracketInfos.get(p[0]);
            const closing = try closingBracketInfos.get(p[1]);

            try opening.closing.add(closing.info);
            try closing.opening.add(opening.info);
        }

        // Treat colorized brackets as brackets, and mark them as colorized.
        const colorizedBracketPairs =
            if (config.colorizedBracketPairs) |colorizedBracketPairs|
                try filterValidBrackets(allocator, colorizedBracketPairs)
            else
                // If not configured: Take all brackets except `<` ... `>`
                // Many languages set < ... > as bracket pair, even though they also use it as comparison operator.
                // This leads to problems when colorizing this bracket, so we exclude it if not explicitly configured otherwise.
                // https://github.com/microsoft/vscode/issues/132476
                try filterOutAngleBrackets(allocator, bracketPairs.items);
        defer colorizedBracketPairs.deinit();
        for (colorizedBracketPairs) |p| {
            const opening = try openingBracketInfos.get(p[0]);
            const closing = try closingBracketInfos.get(p[1]);

            try opening.closing.add(closing.info);
            try closing.openingColorized.add(opening.info);
            try closing.opening.add(opening.info);
        }

        var openingBracketInfosValueIter = openingBracketInfos.cachedValues().valueIterator();
        while (openingBracketInfosValueIter.next()) |v| {
            try self._openingBrackets.put(v.info.bracketText, v.info);
        }
        var closingBracketInfosValueIter = closingBracketInfos.cachedValues().valueIterator();
        while (closingBracketInfosValueIter.next()) |v| {
            try self._closingBrackets.put(v.info.bracketText, v.info);
        }

        return self;
    }

    // No two brackets have the same bracket text.
    pub fn openingBrackets(self: *const Self) []const OpeningBracketKind {
        return self._openingBrackets.values();
    }

    // No two brackets have the same bracket text.
    pub fn closingBrackets(self: *const Self) []const ClosingBracketKind {
        return self._closingBrackets.values();
    }

    pub fn getOpeningBracketInfo(self: *const Self, bracketText: []const u8) ?OpeningBracketKind {
        return self._openingBrackets.get(bracketText);
    }

    pub fn getClosingBracketInfo(self: *const Self, bracketText: []const u8) ?ClosingBracketKind {
        return self._closingBrackets.get(bracketText);
    }

    pub fn getBracketInfo(self: *const Self, bracketText: []const u8) ?BracketKind {
        if (self.getOpeningBracketInfo(bracketText)) |bracketInfo|
            BracketKind{ .openingBracketKind = bracketInfo }
        else if (self.getClosingBracketInfo(bracketText)) |bracketInfo|
            BracketKind{ .closingBracketKind = bracketInfo }
        else
            null;
    }

    pub fn getBracketRegExp(self: *const Self, options: ?RegExpOptions) !RegExp {
        const allocator = self._openingBrackets.allocator;
        const brackets = std.ArrayList(Pair(OpeningBracketKind, ClosingBracketKind)).init(allocator);
        for (self._openingBrackets.keys()) |key| {
            brackets.append(pair(self._openingBrackets.get(key).?, self._closingBrackets.get(key).?));
        }
        return try createBracketOrRegExp(allocator, brackets.items(), options);
    }
};

fn filterValidBrackets(allocator: Allocator, bracketPairs: []const CharacterPair) !ArrayList(CharacterPair) {
    var result = ArrayList(CharacterPair).init(allocator);
    for (bracketPairs) |p| {
        if (p[0].len > 0 and p[1].len > 0) {
            try result.append(p[0]);
            try result.append(p[1]);
        }
    }
    return result;
}

fn filterOutAngleBrackets(allocator: Allocator, bracketPairs: []const CharacterPair) !ArrayList(CharacterPair) {
    var result = ArrayList(CharacterPair).init(allocator);
    for (bracketPairs) |p| {
        if (p[0].len > 0 and p[1].len > 0 and p[0][0] != '<' and p[1][0] != '>') {
            try result.append(p);
        }
    }
    return result;
}

pub const BracketKind = union {
    openingBracketKind: OpeningBracketKind,
    closingBracketKind: ClosingBracketKind,

    pub fn languageId(self: *const BracketKind) []const u8 {
        return switch (self) {
            .openingBracketKind => self.openingBracketKind.languageId(),
            .closingBracketKind => self.closingBracketKind.languageId(),
        };
    }
};

pub const OpeningBracketKind = struct {
    isOpeningBracket: bool = true,
    config: LanguageBracketsConfiguration,
    bracketText: []const u8,
    openedBrackets: Set(ClosingBracketKind),

    pub fn init(
        config: LanguageBracketsConfiguration,
        bracketText: []const u8,
        openedBrackets: Set(ClosingBracketKind),
    ) OpeningBracketKind {
        return OpeningBracketKind{
            .config = config,
            .bracketText = bracketText,
            .openedBrackets = openedBrackets,
        };
    }

    pub fn languageId(self: *const OpeningBracketKind) []const u8 {
        return self.config.languageId;
    }
};

const OpeningBracketKindInfo = struct {
    info: OpeningBracketKind,
    closing: Set(ClosingBracketKind),
};

const ClosingBracketKindInfo = struct {
    info: ClosingBracketKind,
    opening: Set(OpeningBracketKind),
    openingColorized: Set(OpeningBracketKind),
};

pub const ClosingBracketKind = struct {
    isOpeningBracket: bool = false,
    config: LanguageBracketsConfiguration,
    bracketText: []const u8,
    openingBrackets: Set(OpeningBracketKind),
    openingColorizedBrackets: Set(OpeningBracketKind),

    pub fn init(
        config: LanguageBracketsConfiguration,
        bracketText: []const u8,
        openingBrackets: Set(OpeningBracketKind),
        openingColorizedBrackets: Set(OpeningBracketKind),
    ) ClosingBracketKind {
        return ClosingBracketKind{
            .config = config,
            .bracketText = bracketText,
            .openingBrackets = openingBrackets,
            .openingColorizedBrackets = openingColorizedBrackets,
        };
    }

    // Checks if this bracket closes the given other bracket.
    // If the bracket infos come from different configurations, this method will return false.
    pub fn closes(self: *const ClosingBracketKind, other: OpeningBracketKind) bool {
        if (other.config.id != self.config.id) {
            return false;
        }
        return self.openingBrackets.has(other);
    }

    pub fn closesColorized(self: *const ClosingBracketKind, other: OpeningBracketKind) bool {
        if (other.config.id != self.config.id) {
            return false;
        }
        return self.openingColorizedBrackets.has(other);
    }

    pub fn getOpeningBrackets(self: *const ClosingBracketKind) []const OpeningBracketKind {
        return self.openingBrackets.items();
    }

    pub fn languageId(self: *const ClosingBracketKind) []const u8 {
        return self.config.languageId;
    }
};
