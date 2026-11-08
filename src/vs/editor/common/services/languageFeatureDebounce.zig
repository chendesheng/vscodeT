// Port of `src/vs/editor/common/services/languageFeatureDebounce.ts`
//
// Upstream resolves the debounce key by hashing the identity of every language
// feature registered for a model. That registry is not ported yet, so callers
// pass the identity hashes in through `ModelRef`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const doHashNumber = @import("../../../base/common/hash.zig").doHashNumber;
const map = @import("../../../base/common/map.zig");
const numbers = @import("../../../base/common/numbers.zig");

const LRUCache = map.LRUCache;
const MovingAverage = numbers.MovingAverage;
const SlidingWindowAverage = numbers.SlidingWindowAverage;
const clamp = numbers.clamp;

/// Identifies a text model for debounce bookkeeping.
pub const ModelRef = struct {
    /// `ITextModel.id`.
    id: u64,
    /// `IdentityHash.of` of each language feature registered for the model.
    feature_hashes: []const u32,
};

const DebounceKey = struct {
    id: u64,
    features_hash: i32,
};

fn keyOf(model: ModelRef) DebounceKey {
    var hash_val: i32 = 0;
    for (model.feature_hashes) |feature_hash| {
        hash_val = doHashNumber(feature_hash, hash_val);
    }
    return .{ .id = model.id, .features_hash = hash_val };
}

pub const IFeatureDebounceInformation = union(enum) {
    feature: *FeatureDebounceInformation,
    null_info: *NullDebounceInformation,

    pub fn get(self: IFeatureDebounceInformation, model: ModelRef) f64 {
        return switch (self) {
            .feature => |info| info.get(model),
            .null_info => |info| info.get(model),
        };
    }

    pub fn update(self: IFeatureDebounceInformation, model: ModelRef, value: f64) !f64 {
        return switch (self) {
            .feature => |info| info.update(model, value),
            .null_info => |info| info.update(model, value),
        };
    }

    pub fn default(self: IFeatureDebounceInformation) f64 {
        return switch (self) {
            .feature => |info| info.default(),
            .null_info => |info| info.default(),
        };
    }

    pub fn destroy(self: IFeatureDebounceInformation) void {
        switch (self) {
            .feature => |info| info.destroy(),
            .null_info => |info| info.destroy(),
        }
    }
};

/// A debounce information that always reports the same value. Used while
/// developing, so that language features do not appear artificially delayed.
pub const NullDebounceInformation = struct {
    allocator: Allocator,
    _default: f64,

    pub fn init(allocator: Allocator, default_: f64) !*NullDebounceInformation {
        const self = try allocator.create(NullDebounceInformation);
        self.* = .{ .allocator = allocator, ._default = default_ };
        return self;
    }

    pub fn destroy(self: *NullDebounceInformation) void {
        self.allocator.destroy(self);
    }

    pub fn get(self: *const NullDebounceInformation, model: ModelRef) f64 {
        _ = model;
        return self._default;
    }

    pub fn update(self: *const NullDebounceInformation, model: ModelRef, value: f64) f64 {
        _ = model;
        _ = value;
        return self._default;
    }

    pub fn default(self: *const NullDebounceInformation) f64 {
        return self._default;
    }
};

fn deinitSlidingWindow(_: Allocator, value: SlidingWindowAverage) void {
    var copy = value;
    copy.deinit();
}

/// Keeps a sliding-window average of the time a language feature needs, per
/// model and set of registered features.
pub const FeatureDebounceInformation = struct {
    allocator: Allocator,
    _cache: LRUCache(DebounceKey, SlidingWindowAverage),
    _name: []const u8,
    _default: f64,
    _min: f64,
    _max: f64,

    pub fn init(
        allocator: Allocator,
        name_: []const u8,
        default_: f64,
        min: f64,
        max: f64,
    ) !*FeatureDebounceInformation {
        const self = try allocator.create(FeatureDebounceInformation);
        self.* = .{
            .allocator = allocator,
            ._cache = LRUCache(DebounceKey, SlidingWindowAverage).init(allocator, 50, 0.7),
            ._name = name_,
            ._default = default_,
            ._min = min,
            ._max = max,
        };
        // The cache owns the sliding windows and must release them on eviction.
        self._cache.map.value_deinit = deinitSlidingWindow;
        return self;
    }

    pub fn destroy(self: *FeatureDebounceInformation) void {
        self._cache.deinit();
        self.allocator.destroy(self);
    }

    pub fn get(self: *FeatureDebounceInformation, model: ModelRef) f64 {
        const avg = self._cache.get(keyOf(model)) orelse return self.default();
        return clamp(avg.value(), self._min, self._max);
    }

    pub fn update(self: *FeatureDebounceInformation, model: ModelRef, value: f64) !f64 {
        const key = keyOf(model);
        if (self._cache.get(key)) |existing| {
            var avg = existing;
            const new_value = clamp(avg.update(value), self._min, self._max);
            try self._cache.set(key, avg);
            return new_value;
        }

        var avg = try SlidingWindowAverage.init(self.allocator, 6);
        errdefer avg.deinit();
        const new_value = clamp(avg.update(value), self._min, self._max);
        try self._cache.set(key, avg);
        return new_value;
    }

    fn overall(self: *FeatureDebounceInformation) f64 {
        var result = MovingAverage{};
        var it = self._cache.map.iterator();
        while (it.next()) |entry| {
            _ = result.update(entry.value.value());
        }
        return result.value();
    }

    /// The average over all tracked models, clamped to `[min, max]`. Falls back
    /// to `_default` while nothing is tracked yet.
    pub fn default(self: *FeatureDebounceInformation) f64 {
        const value = @trunc(self.overall());
        const effective = if (value == 0) self._default else value;
        return clamp(effective, self._min, self._max);
    }

    pub fn name(self: *const FeatureDebounceInformation) []const u8 {
        return self._name;
    }

    pub fn trackedModelCount(self: *const FeatureDebounceInformation) usize {
        return self._cache.size();
    }
};

pub const LanguageFeatureDebounceService = struct {
    allocator: Allocator,
    _data: std.StringHashMap(IFeatureDebounceInformation),
    _isDev: bool,

    pub const Config = struct {
        min: ?f64 = null,
        max: ?f64 = null,
        key: ?[]const u8 = null,
    };

    /// `is_dev` mirrors `envService.isExtensionDevelopment || !envService.isBuilt`.
    pub fn init(allocator: Allocator, is_dev: bool) LanguageFeatureDebounceService {
        return .{
            .allocator = allocator,
            ._data = std.StringHashMap(IFeatureDebounceInformation).init(allocator),
            ._isDev = is_dev,
        };
    }

    pub fn deinit(self: *LanguageFeatureDebounceService) void {
        var it = self._data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.destroy();
        }
        self._data.deinit();
    }

    /// Returns the debounce information for `feature`. The entry is created on
    /// first use and reused for the same feature/min/extra combination.
    pub fn for_(
        self: *LanguageFeatureDebounceService,
        feature: u64,
        name: []const u8,
        config: ?Config,
    ) !IFeatureDebounceInformation {
        const cfg = config orelse Config{};
        const min = cfg.min orelse 50;
        const max = cfg.max orelse min * min;
        const min_as_int: i64 = @intFromFloat(@round(min));

        const key = if (cfg.key) |extra|
            try std.fmt.allocPrint(self.allocator, "{d},{d},{s}", .{ feature, min_as_int, extra })
        else
            try std.fmt.allocPrint(self.allocator, "{d},{d}", .{ feature, min_as_int });

        if (self._data.get(key)) |existing| {
            self.allocator.free(key);
            return existing;
        }
        errdefer self.allocator.free(key);

        const info: IFeatureDebounceInformation = if (self._isDev)
            .{ .null_info = try NullDebounceInformation.init(self.allocator, min * 1.5) }
        else blk: {
            // Default is the overall average, or derived from the minimum.
            const overall = @trunc(self.overallAverage());
            const default_value = if (overall == 0) min * 1.5 else overall;
            break :blk .{ .feature = try FeatureDebounceInformation.init(self.allocator, name, default_value, min, max) };
        };
        errdefer info.destroy();

        try self._data.put(key, info);
        return info;
    }

    fn overallAverage(self: *LanguageFeatureDebounceService) f64 {
        var result = MovingAverage{};
        var it = self._data.valueIterator();
        while (it.next()) |info| {
            _ = result.update(info.default());
        }
        return result.value();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "NullDebounceInformation always reports its default" {
    const info = try NullDebounceInformation.init(testing.allocator, 75);
    defer info.destroy();

    const model = ModelRef{ .id = 1, .feature_hashes = &.{} };
    try testing.expectEqual(@as(f64, 75), info.get(model));
    try testing.expectEqual(@as(f64, 75), info.update(model, 1000));
    try testing.expectEqual(@as(f64, 75), info.default());
}

test "FeatureDebounceInformation tracks a sliding average" {
    const allocator = testing.allocator;
    const info = try FeatureDebounceInformation.init(allocator, "test", 25, 10, 100);
    defer info.destroy();

    const model = ModelRef{ .id = 1, .feature_hashes = &.{ 1, 2 } };

    // Nothing tracked yet: the default is reported.
    try testing.expectEqual(@as(f64, 25), info.get(model));
    try testing.expectEqual(@as(f64, 25), info.default());

    // Values below the minimum are clamped up to it.
    try testing.expectEqual(@as(f64, 10), try info.update(model, 1));
    // Values above the maximum are clamped down to it.
    try testing.expectEqual(@as(f64, 100), try info.update(model, 1000));

    // A steady stream settles on that value.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try info.update(model, 40);
    }
    try testing.expectEqual(@as(f64, 40), info.get(model));
    try testing.expectEqual(@as(f64, 40), info.default());
    try testing.expectEqual(@as(usize, 1), info.trackedModelCount());
}

test "FeatureDebounceInformation keys models by id and feature hashes" {
    const allocator = testing.allocator;
    const info = try FeatureDebounceInformation.init(allocator, "test", 30, 1, 1000);
    defer info.destroy();

    const first = ModelRef{ .id = 1, .feature_hashes = &.{7} };
    const same = ModelRef{ .id = 1, .feature_hashes = &.{7} };
    const other_model = ModelRef{ .id = 2, .feature_hashes = &.{7} };
    const other_features = ModelRef{ .id = 1, .feature_hashes = &.{ 8, 9 } };

    _ = try info.update(first, 50);
    try testing.expectEqual(@as(usize, 1), info.trackedModelCount());

    // The same identity hits the same cache entry.
    _ = try info.update(same, 50);
    try testing.expectEqual(@as(usize, 1), info.trackedModelCount());

    _ = try info.update(other_model, 80);
    _ = try info.update(other_features, 90);
    try testing.expectEqual(@as(usize, 3), info.trackedModelCount());

    try testing.expectEqual(@as(f64, 50), info.get(first));
    try testing.expectEqual(@as(f64, 80), info.get(other_model));
}

test "LanguageFeatureDebounceService reuses entries per feature and minimum" {
    const allocator = testing.allocator;
    var service = LanguageFeatureDebounceService.init(allocator, false);
    defer service.deinit();

    const base = try service.for_(1, "feature", null);
    try testing.expectEqual(@as(f64, 75), base.default()); // min * 1.5 == 50 * 1.5

    // Same feature and minimum: same entry.
    const again = try service.for_(1, "feature", .{});
    try testing.expectEqual(base.default(), again.default());
    try testing.expectEqual(@as(usize, 1), service._data.count());

    // A different minimum creates a separate entry.
    const with_min = try service.for_(1, "feature", .{ .min = 100, .max = 200 });
    try testing.expectEqual(@as(usize, 2), service._data.count());
    // Its default is seeded from the overall average (75), which is then
    // clamped up to that entry's minimum of 100.
    try testing.expectEqual(@as(f64, 100), with_min.default());

    // A different feature creates a separate entry.
    _ = try service.for_(2, "feature", null);
    try testing.expectEqual(@as(usize, 3), service._data.count());

    // The extra key also distinguishes entries.
    _ = try service.for_(1, "feature", .{ .key = "extra" });
    try testing.expectEqual(@as(usize, 4), service._data.count());
}

test "LanguageFeatureDebounceService is inert in development mode" {
    const allocator = testing.allocator;
    var service = LanguageFeatureDebounceService.init(allocator, true);
    defer service.deinit();

    const info = try service.for_(1, "feature", .{ .min = 100 });
    const model = ModelRef{ .id = 1, .feature_hashes = &.{} };
    // In development the value is fixed at min * 1.5 and never learns.
    try testing.expectEqual(@as(f64, 150), info.get(model));
    try testing.expectEqual(@as(f64, 150), try info.update(model, 5000));
    try testing.expectEqual(@as(f64, 150), info.get(model));
}
