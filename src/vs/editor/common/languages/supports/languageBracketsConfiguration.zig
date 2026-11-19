const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const StringHashMap = std.StringHashMap;
const CachedFunction = @import("../../../../base/common/cache.zig").CachedFunction;
const RegExp = @import("../../../../../support/regexp.zig").RegExp;
const LanguageConfiguration = @import("../languageConfiguration.zig").LanguageConfiguration;
const CharacterPair = @import("../languageConfiguration.zig").CharacterPair;
const RegExpOptions = @import("../../../../../support/regexp.zig").Options;
const Pair = @import("../../../../base/common/utils.zig").Pair;
const pair = @import("../../../../base/common/utils.zig").pair;
const createBracketOrRegExp = @import("./richEditBrackets.zig").createBracketOrRegExp;

fn BracketKindSet(comptime T: type) type {
    return struct {
        const Self = @This();
        list: ArrayList(T),

        pub fn init(allocator: Allocator) Self {
            return .{ .list = ArrayList(T).init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.list.deinit();
        }

        pub fn add(self: *Self, item: T) !void {
            if (self.has(&item)) return;
            try self.list.append(item);
        }

        pub fn has(self: *const Self, item: *const T) bool {
            for (self.list.items) |existing| {
                if (existing.config_id == item.config_id and std.mem.eql(u8, existing.bracketText, item.bracketText)) return true;
            }
            return false;
        }

        pub fn values(self: *const Self) []const T {
            return self.list.items;
        }
    };
}

// Captures all bracket related configurations for a single language.
// Immutable.

pub const LanguageBracketsConfiguration = struct {
    const Self = @This();

    var ID: u32 = 0;

    id: u32,
    allocator: Allocator,
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
            .allocator = allocator,
            .languageId = languageId,
            .config = config,
            ._openingBrackets = StringHashMap(OpeningBracketKind).init(allocator),
            ._closingBrackets = StringHashMap(ClosingBracketKind).init(allocator),
        };
        errdefer self.deinit();

        for (bracketPairs.items) |p| {
            if (!self._openingBrackets.contains(p[0])) {
                const opened = try allocator.create(BracketKindSet(ClosingBracketKind));
                opened.* = BracketKindSet(ClosingBracketKind).init(allocator);
                try self._openingBrackets.put(p[0], .{
                    .config_id = self.id,
                    .language_id = languageId,
                    .bracketText = p[0],
                    ._openedBrackets = opened,
                });
            }
            if (!self._closingBrackets.contains(p[1])) {
                const opening = try allocator.create(BracketKindSet(OpeningBracketKind));
                opening.* = BracketKindSet(OpeningBracketKind).init(allocator);
                const opening_colorized = try allocator.create(BracketKindSet(OpeningBracketKind));
                opening_colorized.* = BracketKindSet(OpeningBracketKind).init(allocator);
                try self._closingBrackets.put(p[1], .{
                    .config_id = self.id,
                    .language_id = languageId,
                    .bracketText = p[1],
                    .openingBrackets = opening,
                    .openingColorizedBrackets = opening_colorized,
                });
            }
        }

        for (bracketPairs.items) |p| {
            const opening = self._openingBrackets.getPtr(p[0]).?;
            const closing = self._closingBrackets.getPtr(p[1]).?;
            try openedBracketsMut(opening).add(closing.*);
            try closingOpeningBracketsMut(closing).add(opening.*);
        }

        // Treat colorized brackets as brackets and mark them as colorized.
        // Without an explicit list, all brackets except `<` ... `>` are
        // colorized (https://github.com/microsoft/vscode/issues/132476).
        for (bracketPairs.items) |p| {
            const colorized = if (config.colorizedBracketPairs) |pairs| blk: {
                var found = false;
                for (pairs) |colorized_pair| {
                    if (std.mem.eql(u8, colorized_pair[0], p[0]) and std.mem.eql(u8, colorized_pair[1], p[1])) {
                        found = true;
                        break;
                    }
                }
                break :blk found;
            } else !(p[0].len > 0 and p[0][0] == '<');
            if (!colorized) continue;

            const opening = self._openingBrackets.getPtr(p[0]).?;
            const closing = self._closingBrackets.getPtr(p[1]).?;
            try closingOpeningColorizedMut(closing).add(opening.*);
        }

        return self;
    }

    /// Frees the bracket sets. The registry builds configurations in an arena,
    /// where `free` is a no-op.
    pub fn deinit(self: *Self) void {
        var opening_iterator = self._openingBrackets.valueIterator();
        while (opening_iterator.next()) |kind| {
            const set = openedBracketsMut(kind);
            set.deinit();
            self.allocator.destroy(set);
        }
        var closing_iterator = self._closingBrackets.valueIterator();
        while (closing_iterator.next()) |kind| {
            const opening = closingOpeningBracketsMut(kind);
            opening.deinit();
            self.allocator.destroy(opening);
            const colorized = closingOpeningColorizedMut(kind);
            colorized.deinit();
            self.allocator.destroy(colorized);
        }
        self._openingBrackets.deinit();
        self._closingBrackets.deinit();
    }

    pub fn openingBracketCount(self: *const Self) usize {
        return self._openingBrackets.count();
    }

    pub fn closingBracketCount(self: *const Self) usize {
        return self._closingBrackets.count();
    }

    // No two brackets have the same bracket text.
    pub fn openingBrackets(self: *const Self, allocator: Allocator) !ArrayList(OpeningBracketKind) {
        var result = ArrayList(OpeningBracketKind).init(allocator);
        errdefer result.deinit();
        var iterator = self._openingBrackets.valueIterator();
        while (iterator.next()) |value| {
            try result.append(value.*);
        }
        return result;
    }

    // No two brackets have the same bracket text.
    pub fn closingBrackets(self: *const Self, allocator: Allocator) !ArrayList(ClosingBracketKind) {
        var result = ArrayList(ClosingBracketKind).init(allocator);
        errdefer result.deinit();
        var iterator = self._closingBrackets.valueIterator();
        while (iterator.next()) |value| {
            try result.append(value.*);
        }
        return result;
    }

    pub fn getOpeningBracketInfo(self: *const Self, bracketText: []const u8) ?OpeningBracketKind {
        return self._openingBrackets.get(bracketText);
    }

    pub fn getClosingBracketInfo(self: *const Self, bracketText: []const u8) ?ClosingBracketKind {
        return self._closingBrackets.get(bracketText);
    }

    pub fn getBracketInfo(self: *const Self, bracketText: []const u8) ?BracketKind {
        if (self.getOpeningBracketInfo(bracketText)) |bracketInfo| {
            return BracketKind{ .openingBracketKind = bracketInfo };
        }
        if (self.getClosingBracketInfo(bracketText)) |bracketInfo| {
            return BracketKind{ .closingBracketKind = bracketInfo };
        }
        return null;
    }

    pub fn getBracketRegExp(self: *const Self, options: ?RegExpOptions) !RegExp {
        const allocator = self._openingBrackets.allocator;
        var brackets = ArrayList([]const u8).init(allocator);
        defer brackets.deinit();

        var opening_iterator = self._openingBrackets.valueIterator();
        while (opening_iterator.next()) |opening| {
            try brackets.append(opening.bracketText);
        }
        var closing_iterator = self._closingBrackets.valueIterator();
        while (closing_iterator.next()) |closing| {
            try brackets.append(closing.bracketText);
        }

        return try createBracketOrRegExp(allocator, brackets.items, options orelse .{});
    }
};

fn filterValidBrackets(allocator: Allocator, bracketPairs: []const CharacterPair) !ArrayList(CharacterPair) {
    var result = ArrayList(CharacterPair).init(allocator);
    for (bracketPairs) |p| {
        if (p[0].len > 0 and p[1].len > 0) {
            try result.append(p);
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

fn openedBracketsMut(kind: *OpeningBracketKind) *BracketKindSet(ClosingBracketKind) {
    return @ptrCast(@alignCast(@constCast(kind._openedBrackets)));
}

fn closingOpeningBracketsMut(kind: *ClosingBracketKind) *BracketKindSet(OpeningBracketKind) {
    return @ptrCast(@alignCast(@constCast(kind.openingBrackets)));
}

fn closingOpeningColorizedMut(kind: *ClosingBracketKind) *BracketKindSet(OpeningBracketKind) {
    return @ptrCast(@alignCast(@constCast(kind.openingColorizedBrackets)));
}

pub const BracketKind = union(enum) {
    openingBracketKind: OpeningBracketKind,
    closingBracketKind: ClosingBracketKind,

    pub fn languageId(self: *const BracketKind) []const u8 {
        return switch (self.*) {
            .openingBracketKind => |opening| opening.languageId(),
            .closingBracketKind => |closing| closing.languageId(),
        };
    }
};

pub const OpeningBracketKind = struct {
    isOpeningBracket: bool = true,
    config_id: u32,
    language_id: []const u8,
    bracketText: []const u8,
    _openedBrackets: *const anyopaque,

    pub fn init(
        config_id: u32,
        language_id: []const u8,
        bracketText: []const u8,
        openedBrackets_: *const BracketKindSet(ClosingBracketKind),
    ) OpeningBracketKind {
        return OpeningBracketKind{
            .config_id = config_id,
            .language_id = language_id,
            .bracketText = bracketText,
            ._openedBrackets = openedBrackets_,
        };
    }

    pub fn openedBrackets(self: *const OpeningBracketKind) *const BracketKindSet(ClosingBracketKind) {
        return @ptrCast(@alignCast(self._openedBrackets));
    }

    pub fn languageId(self: *const OpeningBracketKind) []const u8 {
        return self.language_id;
    }
};

pub const ClosingBracketKind = struct {
    isOpeningBracket: bool = false,
    config_id: u32,
    language_id: []const u8,
    bracketText: []const u8,
    openingBrackets: *const BracketKindSet(OpeningBracketKind),
    openingColorizedBrackets: *const BracketKindSet(OpeningBracketKind),

    pub fn init(
        config_id: u32,
        language_id: []const u8,
        bracketText: []const u8,
        openingBrackets: *const BracketKindSet(OpeningBracketKind),
        openingColorizedBrackets: *const BracketKindSet(OpeningBracketKind),
    ) ClosingBracketKind {
        return ClosingBracketKind{
            .config_id = config_id,
            .language_id = language_id,
            .bracketText = bracketText,
            .openingBrackets = openingBrackets,
            .openingColorizedBrackets = openingColorizedBrackets,
        };
    }

    // Checks if this bracket closes the given other bracket.
    // If the bracket infos come from different configurations, this method will return false.
    pub fn closes(self: *const ClosingBracketKind, other: *const OpeningBracketKind) bool {
        if (other.config_id != self.config_id) {
            return false;
        }
        return self.openingBrackets.has(other);
    }

    pub fn closesColorized(self: *const ClosingBracketKind, other: *const OpeningBracketKind) bool {
        if (other.config_id != self.config_id) {
            return false;
        }
        return self.openingColorizedBrackets.has(other);
    }

    pub fn getOpeningBrackets(self: *const ClosingBracketKind) []const OpeningBracketKind {
        return self.openingBrackets.values();
    }

    pub fn languageId(self: *const ClosingBracketKind) []const u8 {
        return self.language_id;
    }
};
