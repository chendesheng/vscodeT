// Port of `src/vs/base/common/hash.ts`.
//
// All hashes are 32 bit signed integers with wrapping (two's complement)
// arithmetic, matching the `| 0` / `Math.imul` semantics of the TypeScript
// implementation.
const std = @import("std");

/// Equivalent of `hashVal * 31 + val`, kept as an int32.
pub fn numberHash(val: i32, initial_hash_val: i32) i32 {
    return (initial_hash_val *% 31) +% val;
}

pub fn numberHashU(val: u32, initial_hash_val: i32) i32 {
    return numberHash(@bitCast(val), initial_hash_val);
}

fn booleanHash(b: bool, initial_hash_val: i32) i32 {
    return numberHash(if (b) 433 else 863, initial_hash_val);
}

pub fn boolHash(b: bool) i32 {
    return booleanHash(b, 0);
}

pub fn stringHash(s: []const u8, hash_val: i32) i32 {
    var h = numberHash(149417, hash_val);
    for (s) |ch| {
        h = numberHash(@as(i32, ch), h);
    }
    return h;
}

/// `stringHash` reinterpreted as an unsigned 32 bit value (the `>>> 0` of
/// the TypeScript implementation).
pub fn stringHashU32(s: []const u8) u32 {
    return @bitCast(stringHash(s, 0));
}

/// `doHash` for numbers, i.e. the `number` branch of the TypeScript switch.
pub fn doHashNumber(obj: u64, hash_val: i32) i32 {
    // JS numbers are doubles, but every value fed to this helper upstream is an
    // integer identity hash, so truncating to 32 bits matches.
    return numberHashU(@truncate(obj), hash_val);
}

/// Returns whether a string belongs to a stable percentage sample.
pub fn isStringInSample(value: []const u8, sample_percentage: u32) bool {
    std.debug.assert(sample_percentage <= 100);
    return (stringHashU32(value) % 100) < sample_percentage;
}

/// Precomputes the affine transform of `stringHash` for a fixed string and
/// int32 accumulators.
pub const ConstantStringHash = struct {
    multiplier: i32,
    addend: i32,

    pub fn init(value: []const u8) ConstantStringHash {
        // accounts for the seed step of `stringHash`
        var multiplier: i32 = 31;
        for (value) |_| {
            multiplier = multiplier *% 31;
        }
        return .{ .multiplier = multiplier, .addend = stringHash(value, 0) };
    }

    /// Equivalent to `stringHash(value, hashVal)` for int32 `hashVal`.
    pub fn apply(self: ConstantStringHash, hash_val: i32) i32 {
        return (hash_val *% self.multiplier) +% self.addend;
    }
};

/// Seed mixed in by `arrayHash` before hashing the array elements.
pub const ARRAY_HASH_SEED: i32 = 104579;

/// Seed mixed in by `objectHash` before hashing the object entries.
pub const OBJECT_HASH_SEED: i32 = 181387;

pub fn arrayHashStrings(strings: []const []const u8, initial_hash_val: i32) i32 {
    var h = numberHash(ARRAY_HASH_SEED, initial_hash_val);
    for (strings) |s| {
        h = stringHash(s, h);
    }
    return h;
}

pub fn arrayHashNums(values: []const i32, initial_hash_val: i32) i32 {
    var h = numberHash(ARRAY_HASH_SEED, initial_hash_val);
    for (values) |v| {
        h = numberHash(v, h);
    }
    return h;
}

test "numberHash" {
    // h' = 31 * h + val (mod 2^32)
    try std.testing.expectEqual(@as(i32, 31), numberHash(31, 0));
    try std.testing.expectEqual(@as(i32, 0), numberHash(0, 0));
    // Wrapping: `31 * h` overflows into the sign bit like `| 0` does.
    try std.testing.expectEqual(@as(i32, 31), numberHash(0, 1));
    try std.testing.expectEqual(@as(i32, 0), numberHash(-31, 1));
    // 0x40000000 * 31 == 0x7c0000000 which truncates to 0xc0000000 (-2^30).
    try std.testing.expectEqual(@as(i32, -1073741824), numberHash(0, 0x40000000));
}

test "stringHash" {
    const empty = stringHash("", 0);
    try std.testing.expectEqual(numberHash(149417, 0), empty);
    try std.testing.expectEqual(numberHash('a', empty), stringHash("a", 0));
    try std.testing.expectEqual(numberHash('b', numberHash('a', empty)), stringHash("ab", 0));

    // Chained hashing primes the accumulator with the previous value.
    try std.testing.expectEqual(numberHash(149417, 42), stringHash("", 42));

    // Different strings, different hashes.
    try std.testing.expect(stringHash("hello", 0) != stringHash("hallo", 0));
}

test "stringHashU32" {
    const h = stringHash("some string with a long tail", 0);
    try std.testing.expectEqual(@as(u32, @bitCast(h)), stringHashU32("some string with a long tail"));
}

test "isStringInSample" {
    try std.testing.expect(isStringInSample("anything", 100));
    try std.testing.expect(!isStringInSample("anything", 0));
}

test "ConstantStringHash matches stringHash" {
    const values = [_][]const u8{ "", "a", "abc", "the quick brown fox jumps over the lazy dog" };
    for (values) |value| {
        const constant = ConstantStringHash.init(value);
        for ([_]i32{ 0, 1, -1, 42, 123456789, -2000000000 }) |seed| {
            try std.testing.expectEqual(stringHash(value, seed), constant.apply(seed));
        }
    }
}

test "arrayHash" {
    const values = [_][]const u8{ "a", "b", "c" };
    const h = arrayHashStrings(&values, 0);
    var expected = numberHash(ARRAY_HASH_SEED, 0);
    for (values) |v| {
        expected = stringHash(v, expected);
    }
    try std.testing.expectEqual(expected, h);

    const nums = [_]i32{ 1, 2, 3 };
    var num_expected = numberHash(ARRAY_HASH_SEED, 0);
    for (nums) |n| {
        num_expected = numberHash(n, num_expected);
    }
    try std.testing.expectEqual(num_expected, arrayHashNums(&nums, 0));
}

test "booleanHash" {
    try std.testing.expectEqual(numberHash(433, 0), boolHash(true));
    try std.testing.expectEqual(numberHash(863, 0), boolHash(false));
}
