// Port of `src/vs/base/common/numbers.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

pub fn clamp(value: f64, min: f64, max: f64) f64 {
    return @min(@max(value, min), max);
}

test "clamp" {
    try std.testing.expectEqual(@as(f64, 2), clamp(5, 1, 2));
    try std.testing.expectEqual(@as(f64, 1), clamp(0, 1, 2));
    try std.testing.expectEqual(@as(f64, 1.5), clamp(1.5, 1, 2));
}

/// Formats a token count for compact display (e.g. `128K`, `1M`, `1.5M`).
pub fn formatTokenCount(allocator: Allocator, count: u64) ![]u8 {
    if (count >= 1_000_000) {
        const value: f64 = @floatFromInt(count);
        const floored = @floor(value / 1_000_000 * 10) / 10;
        if (@mod(floored, 1) == 0) {
            return std.fmt.allocPrint(allocator, "{d}M", .{@as(u64, @intFromFloat(floored))});
        }
        return std.fmt.allocPrint(allocator, "{d:.1}M", .{floored});
    }
    if (count > 900_000) {
        return allocator.dupe(u8, "1M");
    }
    if (count >= 1000) {
        const rounded = (count + 500) / 1000;
        return std.fmt.allocPrint(allocator, "{d}K", .{rounded});
    }
    return std.fmt.allocPrint(allocator, "{d}", .{count});
}

test "formatTokenCount" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { count: u64, expected: []const u8 }{
        .{ .count = 0, .expected = "0" },
        .{ .count = 999, .expected = "999" },
        .{ .count = 1000, .expected = "1K" },
        .{ .count = 1001, .expected = "1K" },
        .{ .count = 1500, .expected = "2K" },
        .{ .count = 128_000, .expected = "128K" },
        .{ .count = 900_001, .expected = "1M" },
        .{ .count = 1_000_000, .expected = "1M" },
        .{ .count = 1_500_000, .expected = "1.5M" },
        .{ .count = 1_450_000, .expected = "1.4M" },
    };
    for (cases) |case| {
        const actual = try formatTokenCount(allocator, case.count);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

/// `(modulo + (index % modulo)) % modulo`, i.e. a modulo that stays positive for
/// negative indexes.
pub fn rot(index: i64, modulo: i64) i64 {
    return @mod(@mod(index, modulo) + modulo, modulo);
}

test "rot" {
    try std.testing.expectEqual(@as(i64, 2), rot(5, 3));
    try std.testing.expectEqual(@as(i64, 1), rot(-2, 3));
    try std.testing.expectEqual(@as(i64, 0), rot(-3, 3));
}

pub const Counter = struct {
    _next: u64 = 0,

    pub fn getNext(self: *Counter) u64 {
        const result = self._next;
        self._next += 1;
        return result;
    }
};

test "Counter" {
    var counter = Counter{};
    try std.testing.expectEqual(@as(u64, 0), counter.getNext());
    try std.testing.expectEqual(@as(u64, 1), counter.getNext());
    try std.testing.expectEqual(@as(u64, 2), counter.getNext());
}

pub const MovingAverage = struct {
    _n: f64 = 1,
    _val: f64 = 0,

    pub fn update(self: *MovingAverage, new_value: f64) f64 {
        self._val = self._val + (new_value - self._val) / self._n;
        self._n += 1;
        return self._val;
    }

    pub fn value(self: MovingAverage) f64 {
        return self._val;
    }
};

test "MovingAverage" {
    var average = MovingAverage{};
    try std.testing.expectEqual(@as(f64, 0), average.value());
    try std.testing.expectEqual(@as(f64, 10), average.update(10));
    try std.testing.expectEqual(@as(f64, 15), average.update(20));
    try std.testing.expectEqual(@as(f64, 20), average.update(30));
    try std.testing.expectEqual(@as(f64, 20), average.value());
}

pub const SlidingWindowAverage = struct {
    allocator: Allocator,
    _n: f64 = 0,
    _val: f64 = 0,
    _values: []f64,
    _index: usize = 0,
    _sum: f64 = 0,

    pub fn init(allocator: Allocator, size: usize) !SlidingWindowAverage {
        const values = try allocator.alloc(f64, size);
        @memset(values, 0);
        return .{ .allocator = allocator, ._values = values };
    }

    pub fn deinit(self: *SlidingWindowAverage) void {
        self.allocator.free(self._values);
    }

    pub fn update(self: *SlidingWindowAverage, new_value: f64) f64 {
        const old_value = self._values[self._index];
        self._values[self._index] = new_value;
        self._index = (self._index + 1) % self._values.len;

        self._sum -= old_value;
        self._sum += new_value;

        if (self._n < @as(f64, @floatFromInt(self._values.len))) {
            self._n += 1;
        }

        self._val = self._sum / self._n;
        return self._val;
    }

    pub fn value(self: SlidingWindowAverage) f64 {
        return self._val;
    }
};

test "SlidingWindowAverage" {
    const allocator = std.testing.allocator;
    var average = try SlidingWindowAverage.init(allocator, 3);
    defer average.deinit();

    try std.testing.expectEqual(@as(f64, 0), average.value());
    try std.testing.expectEqual(@as(f64, 1), average.update(1));
    try std.testing.expectEqual(@as(f64, 1.5), average.update(2));
    try std.testing.expectEqual(@as(f64, 2), average.update(3));
    // The window slides: the oldest value (1) is replaced by 4.
    try std.testing.expectEqual(@as(f64, 3), average.update(4));
    try std.testing.expectEqual(@as(f64, 3), average.value());
}

/// Returns whether the point is within the triangle formed by the following
/// 6 x/y point pairs.
pub fn isPointWithinTriangle(
    x: f64,
    y: f64,
    ax: f64,
    ay: f64,
    bx: f64,
    by: f64,
    cx: f64,
    cy: f64,
) bool {
    const v0x = cx - ax;
    const v0y = cy - ay;
    const v1x = bx - ax;
    const v1y = by - ay;
    const v2x = x - ax;
    const v2y = y - ay;

    const dot00 = v0x * v0x + v0y * v0y;
    const dot01 = v0x * v1x + v0y * v1y;
    const dot02 = v0x * v2x + v0y * v2y;
    const dot11 = v1x * v1x + v1y * v1y;
    const dot12 = v1x * v2x + v1y * v2y;

    const inv_denom = 1 / (dot00 * dot11 - dot01 * dot01);
    const u = (dot11 * dot02 - dot01 * dot12) * inv_denom;
    const v = (dot00 * dot12 - dot01 * dot02) * inv_denom;

    return u >= 0 and v >= 0 and u + v < 1;
}

test "isPointWithinTriangle" {
    try std.testing.expect(isPointWithinTriangle(1, 1, 0, 0, 4, 0, 0, 4));
    try std.testing.expect(isPointWithinTriangle(0.5, 0.5, 0, 0, 4, 0, 0, 4));
    try std.testing.expect(!isPointWithinTriangle(3, 3, 0, 0, 4, 0, 0, 4));
    try std.testing.expect(!isPointWithinTriangle(-1, 1, 0, 0, 4, 0, 0, 4));
}

pub const RandomChance = struct {
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) RandomChance {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    /// Whether a random number in `[0, 1)` is smaller than `p`.
    pub fn randomChance(self: *RandomChance, p: f64) bool {
        std.debug.assert(p >= 0 and p <= 1);
        return self.prng.random().float(f64) < p;
    }
};

test "randomChance" {
    var chance = RandomChance.init(42);
    var hits: usize = 0;
    for (0..1000) |_| {
        if (chance.randomChance(0.25)) hits += 1;
    }
    // A quarter of a thousand coin flips lands close to 250.
    try std.testing.expect(hits > 150 and hits < 350);
}
