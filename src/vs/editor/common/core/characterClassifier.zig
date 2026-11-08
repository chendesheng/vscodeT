const std = @import("std");
const Allocator = std.mem.Allocator;
const HashMap = std.AutoHashMap;

// A fast character classifier that uses a compact array for ASCII values.
pub fn CharacterClassifier(comptime T: type) type {
    const ASCII_MAP_SIZE = 256;
    return struct {
        const Self = @This();

        // Maintain a compact (fully initialized ASCII map for quickly classifying ASCII characters - used more often in code).
        _asciiMap: [ASCII_MAP_SIZE]T,

        // The entire map (sparse array).
        _map: HashMap(u21, T),

        _defaultValue: T,

        pub fn init(allocator: Allocator, defaultValue: T) Self {
            const self = Self{
                ._defaultValue = defaultValue,
                ._asciiMap = @splat(defaultValue),
                ._map = HashMap(u21, T).init(allocator),
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self._map.deinit();
        }

        pub fn set(self: *Self, charCode: u21, value: T) !void {
            if (charCode < ASCII_MAP_SIZE) {
                self._asciiMap[@intCast(charCode)] = value;
            } else {
                try self._map.put(charCode, value);
            }
        }

        pub fn get(self: *const Self, charCode: u21) T {
            if (charCode < ASCII_MAP_SIZE) {
                return self._asciiMap[@intCast(charCode)];
            } else {
                return self._map.get(charCode) orelse self._defaultValue;
            }
        }

        pub fn clear(self: *Self) void {
            self._asciiMap = @splat(self._defaultValue);
            self._map.clearRetainingCapacity();
        }
    };
}

test "CharacterClassifier" {
    const allocator = std.testing.allocator;
    var classifier = CharacterClassifier(Boolean).init(allocator, Boolean.False);
    defer classifier.deinit();
    try std.testing.expect(classifier.get(65) == Boolean.False);
    try classifier.set(65, Boolean.True);
    try std.testing.expect(classifier.get(65) == Boolean.True);
    classifier.clear();
    try std.testing.expect(classifier.get(65) == Boolean.False);
    try std.testing.expect(classifier.get('中') == Boolean.False);
}

const Boolean = enum(u1) {
    False = 0,
    True = 1,
};

pub const CharacterSet = struct {
    _actual: CharacterClassifier(Boolean),

    pub fn init(allocator: Allocator) CharacterSet {
        return CharacterSet{
            ._actual = CharacterClassifier(Boolean).init(allocator, Boolean.False),
        };
    }

    pub fn deinit(self: *CharacterSet) void {
        self._actual.deinit();
    }

    pub fn add(self: *CharacterSet, charCode: u21) !void {
        try self._actual.set(charCode, Boolean.True);
    }

    pub fn has(self: *CharacterSet, charCode: u21) bool {
        return (self._actual.get(charCode) == Boolean.True);
    }

    pub fn clear(self: *CharacterSet) void {
        self._actual.clear();
    }
};

test "CharacterSet" {
    const allocator = std.testing.allocator;
    var set = CharacterSet.init(allocator);
    defer set.deinit();
    try set.add(65);
    try std.testing.expect(set.has(65));
    set.clear();
    try std.testing.expect(!set.has(65));
    try set.add('中');
    try std.testing.expect(set.has('中'));
}
