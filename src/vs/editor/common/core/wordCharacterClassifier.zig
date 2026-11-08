const std = @import("std");
const Allocator = std.mem.Allocator;
const CharacterClassifier = @import("./characterClassifier.zig").CharacterClassifier;

pub const WordCharacterClass = enum(u2) {
    Regular = 0,
    Whitespace = 1,
    WordSeparator = 2,
};

pub const DefaultWordSeparators = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?";

pub const WordCharacterClassifier = struct {
    _classifier: CharacterClassifier(WordCharacterClass),

    pub fn init(allocator: Allocator, wordSeparators: []const u8) !WordCharacterClassifier {
        var self = WordCharacterClassifier{
            ._classifier = CharacterClassifier(WordCharacterClass).init(allocator, WordCharacterClass.Regular),
        };

        for (wordSeparators) |char| {
            try self._classifier.set(@intCast(char), WordCharacterClass.WordSeparator);
        }

        try self._classifier.set(' ', WordCharacterClass.Whitespace);
        try self._classifier.set('\t', WordCharacterClass.Whitespace);

        return self;
    }

    pub fn deinit(self: *WordCharacterClassifier) void {
        self._classifier.deinit();
    }

    pub fn get(self: *const WordCharacterClassifier, charCode: u21) WordCharacterClass {
        return self._classifier.get(charCode);
    }

    pub fn set(self: *WordCharacterClassifier, charCode: u21, value: WordCharacterClass) void {
        self._classifier.set(charCode, value);
    }

    pub fn clear(self: *WordCharacterClassifier) void {
        self._classifier.clear();
    }
};

test "WordCharacterClassifier" {
    const allocator = std.testing.allocator;
    var classifier = try WordCharacterClassifier.init(allocator, ".,;");
    defer classifier.deinit();
    try std.testing.expect(classifier.get(' ') == WordCharacterClass.Whitespace);
    try std.testing.expect(classifier.get(',') == WordCharacterClass.WordSeparator);
}

var wordClassifierCache: ?std.StringHashMap(WordCharacterClassifier) = null;

pub fn freeWordClassifierCache() void {
    if (wordClassifierCache) |*cache| {
        var iter = cache.valueIterator();
        while (iter.next()) |value| {
            value.deinit();
        }
        cache.clearAndFree();
        cache.deinit();
        wordClassifierCache = null;
    }
}

pub fn getMapForWordSeparators(allocator: Allocator, wordSeparators: []const u8) !*WordCharacterClassifier {
    if (wordClassifierCache == null) {
        wordClassifierCache = std.StringHashMap(WordCharacterClassifier).init(allocator);
    }

    if (wordClassifierCache) |*cache| {
        const res = try cache.getOrPut(wordSeparators);
        if (!res.found_existing) {
            res.value_ptr.* = try WordCharacterClassifier.init(allocator, wordSeparators);
        }
        return res.value_ptr;
    }

    unreachable;
}

test "getMapForWordSeparators" {
    const allocator = std.testing.allocator;
    defer freeWordClassifierCache();
    const classifier1 = try getMapForWordSeparators(allocator, ".,;");
    const classifier2 = try getMapForWordSeparators(allocator, ".,;");
    try std.testing.expect(classifier1 == classifier2);
}
