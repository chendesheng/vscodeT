// Port of the `AmbiguousCharacters` and `InvisibleCharacters` parts of
// `src/vs/base/common/strings.ts`.
//
// The data tables live in `unicodeCharactersData.zig`, which is generated from
// the JSON embedded in the upstream file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const data = @import("./unicodeCharactersData.zig");

fn localeData(locale: []const u8) ?[]const u32 {
    if (std.mem.eql(u8, locale, "_default")) return &data.ambiguous_default;
    for (data.ambiguous_locales) |entry| {
        if (std.mem.eql(u8, entry.locale, locale)) return entry.data;
    }
    return null;
}

const ConfusableMap = std.AutoHashMapUnmanaged(u32, u32);

fn arrayToMap(allocator: Allocator, arr: []const u32) !ConfusableMap {
    var result = ConfusableMap{};
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i + 1 < arr.len) : (i += 2) {
        try result.put(allocator, arr[i], arr[i + 1]);
    }
    return result;
}

/// Keeps only the entries of `base` whose keys are also present in `other`,
/// preserving `base`'s values. Both maps are consumed.
fn intersectMaps(allocator: Allocator, base: ConfusableMap, other: ConfusableMap) !ConfusableMap {
    var result = ConfusableMap{};
    errdefer result.deinit(allocator);
    var it = base.iterator();
    while (it.next()) |entry| {
        if (other.contains(entry.key_ptr.*)) {
            try result.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    var base_mut = base;
    base_mut.deinit(allocator);
    var other_mut = other;
    other_mut.deinit(allocator);
    return result;
}

/// Characters that look like an ASCII character, and the ASCII character they
/// are confusable with. The exact set depends on the allowed locales.
pub const AmbiguousCharacters = struct {
    allocator: Allocator,
    map: ConfusableMap,

    pub fn getInstance(allocator: Allocator, locales: []const []const u8) !AmbiguousCharacters {
        var filtered = ArrayList([]const u8).init(allocator);
        defer filtered.deinit();
        for (locales) |locale| {
            if (locale.len > 0 and locale[0] == '_') continue;
            if (localeData(locale) != null) try filtered.append(locale);
        }

        const default_locales = [_][]const u8{"_default"};
        const effective: []const []const u8 = if (filtered.items.len == 0) &default_locales else filtered.items;

        var language_specific: ?ConfusableMap = null;
        for (effective) |locale| {
            const locale_map = try arrayToMap(allocator, localeData(locale).?);
            if (language_specific) |previous| {
                language_specific = try intersectMaps(allocator, previous, locale_map);
            } else {
                language_specific = locale_map;
            }
        }

        var result = try arrayToMap(allocator, &data.ambiguous_common);
        errdefer result.deinit(allocator);
        if (language_specific) |language_map| {
            var language_map_mut = language_map;
            defer language_map_mut.deinit(allocator);
            var it = language_map_mut.iterator();
            while (it.next()) |entry| {
                try result.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        return .{ .allocator = allocator, .map = result };
    }

    pub fn deinit(self: *AmbiguousCharacters) void {
        self.map.deinit(self.allocator);
    }

    pub fn isAmbiguous(self: *const AmbiguousCharacters, codePoint: u32) bool {
        return self.map.contains(codePoint);
    }

    /// Returns the ASCII code point `codePoint` is confusable with.
    pub fn getPrimaryConfusable(self: *const AmbiguousCharacters, codePoint: u32) ?u32 {
        return self.map.get(codePoint);
    }

    /// The returned slice is owned by the caller.
    pub fn getConfusableCodePoints(self: *const AmbiguousCharacters, allocator: Allocator) ![]u32 {
        var result = try allocator.alloc(u32, self.map.count());
        var i: usize = 0;
        var it = self.map.keyIterator();
        while (it.next()) |key| : (i += 1) {
            result[i] = key.*;
        }
        return result;
    }

    /// All locales that have language specific data.
    pub fn getLocales() []const []const u8 {
        // The data table stores locale names alongside their arrays, so expose a
        // parallel view without allocating.
        const Locales = struct {
            var locales: [data.ambiguous_locales.len][]const u8 = undefined;
            var initialized = false;
        };
        if (!Locales.initialized) {
            for (data.ambiguous_locales, 0..) |entry, i| {
                Locales.locales[i] = entry.locale;
            }
            Locales.initialized = true;
        }
        return &Locales.locales;
    }
};

/// Characters that are not visible on their own (control characters, combining
/// marks, variation selectors, ...).
pub const InvisibleCharacters = struct {
    pub fn isInvisibleCharacter(codePoint: u32) bool {
        const items = &data.invisible_code_points;
        var low: usize = 0;
        var high: usize = items.len;
        while (low < high) {
            const mid = (low + high) / 2;
            if (items[mid] == codePoint) return true;
            if (items[mid] < codePoint) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return false;
    }

    pub fn containsInvisibleCharacter(str: []const u8) bool {
        var view = std.unicode.Utf8View.initUnchecked(str);
        var it = view.iterator();
        while (it.nextCodepoint()) |code_point| {
            if (isInvisibleCharacter(code_point) or code_point == 0x20) return true;
        }
        return false;
    }

    pub fn codePoints() []const u32 {
        return &data.invisible_code_points;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "InvisibleCharacters recognises control and format characters" {
    try testing.expect(InvisibleCharacters.isInvisibleCharacter(0x0B)); // vertical tab
    try testing.expect(InvisibleCharacters.isInvisibleCharacter(0x7F)); // delete
    try testing.expect(InvisibleCharacters.isInvisibleCharacter(0x200B)); // zero width space
    try testing.expect(InvisibleCharacters.isInvisibleCharacter(0xFE0F)); // variation selector 16
    try testing.expect(InvisibleCharacters.isInvisibleCharacter(0xE0001)); // language tag

    try testing.expect(!InvisibleCharacters.isInvisibleCharacter('a'));
    try testing.expect(!InvisibleCharacters.isInvisibleCharacter(' '));
    try testing.expect(!InvisibleCharacters.isInvisibleCharacter(0x1F600)); // emoji
}

test "InvisibleCharacters scans strings" {
    try testing.expect(InvisibleCharacters.containsInvisibleCharacter("a\u{200B}b"));
    try testing.expect(InvisibleCharacters.containsInvisibleCharacter("a b"));
    try testing.expect(!InvisibleCharacters.containsInvisibleCharacter("abc"));
    try testing.expect(!InvisibleCharacters.containsInvisibleCharacter(""));
}

test "AmbiguousCharacters finds confusables" {
    const allocator = testing.allocator;
    // Cyrillic "а" (U+0430) looks like ASCII "a".
    var characters = try AmbiguousCharacters.getInstance(allocator, &.{});
    defer characters.deinit();

    try testing.expect(characters.isAmbiguous(0x0430));
    try testing.expectEqual(@as(u32, 'a'), characters.getPrimaryConfusable(0x0430).?);
    try testing.expect(!characters.isAmbiguous('a'));

    // The full-width Latin letters are part of the common data.
    try testing.expect(characters.isAmbiguous(0xFF41)); // fullwidth a
    try testing.expectEqual(@as(u32, 'a'), characters.getPrimaryConfusable(0xFF41).?);

    const code_points = try characters.getConfusableCodePoints(allocator);
    defer allocator.free(code_points);
    try testing.expect(code_points.len > 1000);
}

test "AmbiguousCharacters narrows the set for language specific locales" {
    const allocator = testing.allocator;

    var default_set = try AmbiguousCharacters.getInstance(allocator, &.{});
    defer default_set.deinit();
    var russian_set = try AmbiguousCharacters.getInstance(allocator, &.{"ru"});
    defer russian_set.deinit();
    var czech_set = try AmbiguousCharacters.getInstance(allocator, &.{"cs"});
    defer czech_set.deinit();

    // A character that is only ambiguous in some locales.
    try testing.expect(default_set.isAmbiguous(0x0430));
    // "ru" does not list it as ambiguous: Cyrillic is expected there.
    try testing.expect(!russian_set.isAmbiguous(0x0430));
    // But a Cyrillic "о" is ambiguous in the czech locale.
    try testing.expect(czech_set.isAmbiguous(0x043E));

    // Unknown locales fall back to the default data set.
    var unknown = try AmbiguousCharacters.getInstance(allocator, &.{"xx"});
    defer unknown.deinit();
    try testing.expect(unknown.isAmbiguous(0x0430));
}

test "AmbiguousCharacters exposes its locales" {
    const locales = AmbiguousCharacters.getLocales();
    try testing.expect(locales.len > 0);
    var found_ru = false;
    for (locales) |locale| {
        if (std.mem.eql(u8, locale, "ru")) found_ru = true;
        try testing.expect(locale.len > 0);
        try testing.expect(locale[0] != '_');
    }
    try testing.expect(found_ru);
}
