const std = @import("std");
const StringHashMap = std.StringHashMap;
const Set = @import("../../basics/set.zig").Set;
const CachedFunction = @import("../../basics/cache.zig").CachedFunction;
const RegExp = @import("../../basics/RegExp.zig").RegExp;
const LanguageConfiguration = @import("../languageConfiguration.zig").LanguageConfiguration;
const CharacterPair = @import("../languageConfiguration.zig").CharacterPair;
const createBracketOrRegExp = @import("./richEditBrackets.zig").createBracketOrRegExp;

 // Captures all bracket related configurations for a single language.
 // Immutable.

pub const LanguageBracketsConfiguration = struct {
    const Self = @This();

    _openingBrackets: StringHashMap(OpeningBracketKind),
    _closingBrackets: StringHashMap(ClosingBracketKind),
    languageId: []const u8,
    config: LanguageConfiguration,

    pub fn init(languageId: []const u8, config: LanguageConfiguration) Self {
        const bracketPairs = if (config.brackets) |brackets| filterValidBrackets(brackets) else &[_]CharacterPair{};

        const openingBracketInfos = CachedFunction([]const u8, OpeningBracketKindInfo).init(
            struct {
                fn f(bracket: []const u8) OpeningBracketKindInfo {
                    const closing = Set(ClosingBracketKind).init();
                    return OpeningBracketKindInfo{
                        .info = OpeningBracketKind.init(self, bracket, closing),
                        .closing = closing,
                    };
                }
            }.f,
        );

        const closingBracketInfos = CachedFunction([]const u8, ClosingBracketKindInfo).init(
            struct {
                fn f(bracket: []const u8) ClosingBracketKindInfo {
                    const opening = Set(OpeningBracketKind).init();
                    const openingColorized = Set(OpeningBracketKind).init();
                    return ClosingBracketKindInfo{
                        .info = ClosingBracketKind.init(self, bracket, opening, openingColorized),
                        .opening = opening,
                        .openingColorized = openingColorized,
                    };
                }
            }.f,
        );

        for (bracketPairs) |pair| {
            const opening = try openingBracketInfos.get(pair[0]);
            const closing = try closingBracketInfos.get(pair[1]);

            try opening.closing.add(closing.info);
            try closing.opening.add(opening.info);
        }

        // Treat colorized brackets as brackets, and mark them as colorized.
        const colorizedBracketPairs = 
            if (config.colorizedBracketPairs) |colorizedBracketPairs|
                filterValidBrackets(colorizedBracketPairs)
            else
                // If not configured: Take all brackets except `<` ... `>`
                // Many languages set < ... > as bracket pair, even though they also use it as comparison operator.
                // This leads to problems when colorizing this bracket, so we exclude it if not explicitly configured otherwise.
                // https://github.com/microsoft/vscode/issues/132476
                null; // bracketPairs.filter((p) => !(p[0] == '<' and p[1] == '>'));
        for (colorizedBracketPairs) |pair| {
            const opening = try openingBracketInfos.get(pair[0]);
            const closing = try closingBracketInfos.get(pair[1]);

            try opening.closing.add(closing.info);
            try closing.openingColorized.add(opening.info);
            try closing.opening.add(opening.info);
        }

        return .{
            .languageId = languageId,
            .config = config,
            // ._openingBrackets = new Map([...openingBracketInfos.cachedValues()].map(([k, v]) => [k, v.info])),
            // ._closingBrackets = new Map([...closingBracketInfos.cachedValues()].map(([k, v]) => [k, v.info])),
        };
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

    pub fn getBracketRegExp(self: *const Self, options: ?RegExpOptions) RegExp {
        const brackets = std.ArrayList(Pair(OpeningBracketKind, ClosingBracketKind)).init(self._openingBrackets.allocator);
        for (self._openingBrackets.keys()) |key| {
            brackets.append(pair(self._openingBrackets.get(key).?, self._closingBrackets.get(key).?));
        }
        return createBracketOrRegExp(brackets.items(), options);
    }
};


fn filterValidBrackets(bracketPairs: []const CharacterPair) []const CharacterPair {
    return bracketPairs.filter((p) => p[0].len > 0 and p[1].len > 0);
}

pub const BracketKind = union {
    openingBracketKind: OpeningBracketKind,
    closingBracketKind: ClosingBracketKind,

    pub fn languageId(self: *const Self) []const u8 {
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
		bracketText: string,
		openedBrackets: Set(ClosingBracketKind),
	) OpeningBracketKind {
		return OpeningBracketKind{
			.config = config,
			.bracketText = bracketText,
			.openedBrackets = openedBrackets,
		};
	}

    pub fn languageId(self: *const Self) []const u8 {
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
	pub fn closes(self: *const Self, other: OpeningBracketKind) bool {
		if (other.config != self.config) {
			return false;
		}
		return self.openingBrackets.has(other);
	}

	pub fn closesColorized(self: *const Self, other: OpeningBracketKind) bool {
		if (other.config != self.config) {
			return false;
		}
		return self.openingColorizedBrackets.has(other);
	}

	pub fn getOpeningBrackets(self: *const Self) []const OpeningBracketKind {
		return self.openingBrackets.items();
	}

    pub fn languageId(self: *const Self) []const u8 {
        return self.config.languageId;
    }
};