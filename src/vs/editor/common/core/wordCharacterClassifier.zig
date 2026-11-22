// Port of `src/vs/editor/common/core/wordCharacterClassifier.ts`.
//
// Divergences:
//  * `Intl.Segmenter` is a browser API; the `findPrevIntlWord*` /
//    `findNextIntlWord*` methods and `intlSegmenterLocales` are not ported
//    (nothing in this port consumes them).
//  * The process-wide cache is a bounded FIFO of 10 entries rather than an
//    LRU; eviction never changes classification results.
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

        var view = std.unicode.Utf8View.init(wordSeparators) catch return error.InvalidUtf8;
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |code_point| {
            try self._classifier.set(code_point, WordCharacterClass.WordSeparator);
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

    pub fn set(self: *WordCharacterClassifier, charCode: u21, value: WordCharacterClass) !void {
        try self._classifier.set(charCode, value);
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

    // Non-ASCII separators are classified by code point, not by UTF-8 byte.
    var unicode_classifier = try WordCharacterClassifier.init(allocator, "。");
    defer unicode_classifier.deinit();
    try std.testing.expect(unicode_classifier.get(0x3002) == WordCharacterClass.WordSeparator);
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
    // The cache is process-lifetime by design; it must not retain an allocator
    // owned by a short-lived editor or test.
    _ = allocator;
    const cache_allocator = std.heap.page_allocator;
    if (wordClassifierCache == null) {
        wordClassifierCache = std.StringHashMap(WordCharacterClassifier).init(cache_allocator);
    }

    if (wordClassifierCache) |*cache| {
        if (cache.getPtr(wordSeparators)) |value| return value;

        // Bound the process-wide cache like upstream's LRUCache(10). The
        // eviction order is insertion order, which is sufficient here because
        // a miss only costs re-classification.
        if (cache.count() >= 10) {
            var victim_key: ?[]const u8 = null;
            var victim: ?WordCharacterClassifier = null;
            var iterator = cache.iterator();
            if (iterator.next()) |entry| {
                victim_key = entry.key_ptr.*;
                victim = entry.value_ptr.*;
            }
            if (victim_key) |key| {
                _ = cache.remove(key);
                if (victim) |*value| value.deinit();
                cache_allocator.free(key);
            }
        }

        // Callers pass transient editor-owned slices, so the cache must own its
        // keys; a borrowed key would dangle after the editor is destroyed.
        const key = try cache_allocator.dupe(u8, wordSeparators);
        errdefer cache_allocator.free(key);
        const classifier = try WordCharacterClassifier.init(cache_allocator, wordSeparators);
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

test "getMapForWordSeparators: cache is bounded" {
    const allocator = std.testing.allocator;
    defer freeWordClassifierCache();

    for (0..25) |i| {
        var separators: [3]u8 = .{ '.', ',', @intCast('a' + i) };
        _ = try getMapForWordSeparators(allocator, &separators);
    }
    try std.testing.expect(wordClassifierCache.?.count() <= 10);
}
