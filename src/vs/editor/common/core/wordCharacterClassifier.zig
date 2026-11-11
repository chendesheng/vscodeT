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

/// The classifier cache lives for the process, matching upstream's global LRU.
/// Long-running hosts must call this at shutdown so a leak-checking allocator
/// sees the map, keys and per-classifier hash maps released.
pub fn freeWordClassifierCache() void {
    if (wordClassifierCache) |*cache| {
        // The map owns the separator strings it copied on insertion; free them
        // before dropping the map itself.
        var keys = cache.keyIterator();
        while (keys.next()) |key| {
            cache.allocator.free(key.*);
        }
        var iter = cache.valueIterator();
        while (iter.next()) |value| {
            value.deinit();
        }
        cache.deinit();
        wordClassifierCache = null;
    }
}

pub fn getMapForWordSeparators(allocator: Allocator, wordSeparators: []const u8) !*WordCharacterClassifier {
    if (wordClassifierCache == null) {
        wordClassifierCache = std.StringHashMap(WordCharacterClassifier).init(allocator);
    }

    if (wordClassifierCache) |*cache| {
        if (cache.getPtr(wordSeparators)) |value| return value;

        // Callers pass transient editor-owned slices, so the cache must own its
        // keys; a borrowed key would dangle after the editor is destroyed.
        const key = try allocator.dupe(u8, wordSeparators);
        errdefer allocator.free(key);
        const classifier = try WordCharacterClassifier.init(allocator, wordSeparators);
        errdefer {
            var owned = classifier;
            owned.deinit();
        }
        try cache.put(key, classifier);
        return cache.getPtr(key).?;
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
