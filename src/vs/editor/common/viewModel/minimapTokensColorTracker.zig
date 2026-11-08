// Port of `src/vs/editor/common/viewModel/minimapTokensColorTracker.ts`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Emitter = @import("../../../base/common/event.zig").Emitter;
const Color = @import("../../../base/common/color.zig").Color;
const RGBA8 = @import("../core/misc/rgba.zig").RGBA8;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const TokenizationRegistry = @import("../tokenizationRegistry.zig").TokenizationRegistry;
const TokenizationSupportChangedEvent = @import("../languages.zig").TokenizationSupportChangedEvent;

/// Tracks the RGBA8 version of the token color map, so that the minimap can
/// upload it to the GPU without touching the theme objects.
///
/// Upstream this is a `Disposable` singleton; here instances are created
/// explicitly (see `create` / `getInstance`) so that the listener can be
/// registered against a stable address.
pub const MinimapTokensColorTracker = struct {
    allocator: Allocator,
    _colors: ArrayList(RGBA8),
    _backgroundIsLight: bool,
    _onDidChange: Emitter(void),
    _registryListener: ?Emitter(TokenizationSupportChangedEvent).ListenerId,

    /// Creates a tracker that follows `TokenizationRegistry.instance`.
    /// Release it with `destroy`.
    pub fn create(allocator: Allocator) !*MinimapTokensColorTracker {
        const self = try allocator.create(MinimapTokensColorTracker);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            ._colors = ArrayList(RGBA8).init(allocator),
            ._backgroundIsLight = true,
            ._onDidChange = Emitter(void).init(allocator),
            ._registryListener = null,
        };
        try self.updateColorMap(TokenizationRegistry.instance.getColorMap());
        self._registryListener = try TokenizationRegistry.instance.onDidChange(self, onRegistryDidChange);
        return self;
    }

    pub fn destroy(self: *MinimapTokensColorTracker) void {
        if (self._registryListener) |id| TokenizationRegistry.instance.unsubscribe(id);
        self._onDidChange.deinit();
        self._colors.deinit();
        self.allocator.destroy(self);
    }

    fn onRegistryDidChange(e: TokenizationSupportChangedEvent, tracker: *MinimapTokensColorTracker) anyerror!void {
        if (e.changedColorMap) {
            try tracker.updateColorMap(TokenizationRegistry.instance.getColorMap());
        }
    }

    /// Rebuilds the color cache from `color_map`. A `null` map means "no color
    /// map yet": every id up to `DefaultBackground` maps to an empty color.
    pub fn updateColorMap(self: *MinimapTokensColorTracker, color_map: ?[]const Color) !void {
        self._colors.clearRetainingCapacity();

        const map = color_map orelse {
            var i: usize = 0;
            while (i <= ColorId.DefaultBackground) : (i += 1) {
                try self._colors.append(RGBA8.empty);
            }
            self._backgroundIsLight = true;
            return;
        };

        try self._colors.append(RGBA8.empty);
        var color_id: usize = 1;
        while (color_id < map.len) : (color_id += 1) {
            const source = map[color_id];
            // Use a VM friendly data-type.
            try self._colors.append(RGBA8.init(
                @intCast(source.r),
                @intCast(source.g),
                @intCast(source.b),
                @intFromFloat(@round(@as(f64, source.a) * 255.0)),
            ));
        }

        if (map.len > ColorId.DefaultBackground) {
            const background_luminosity = map[ColorId.DefaultBackground].getRelativeLuminance();
            self._backgroundIsLight = background_luminosity >= 0.5;
        } else {
            self._backgroundIsLight = true;
        }

        self._onDidChange.fire({}) catch {};
    }

    /// Returns the cached color for `color_id`, falling back to the default
    /// background color (basically invisible) for unknown ids.
    pub fn getColor(self: *const MinimapTokensColorTracker, color_id: u9) RGBA8 {
        var id: usize = color_id;
        if (id < 1 or id >= self._colors.items.len) {
            id = ColorId.DefaultBackground;
        }
        if (id >= self._colors.items.len) return RGBA8.empty;
        return self._colors.items[id];
    }

    pub fn backgroundIsLight(self: *const MinimapTokensColorTracker) bool {
        return self._backgroundIsLight;
    }

    pub fn onDidChange(self: *MinimapTokensColorTracker, ctx: anytype, callback: fn (ctx: @TypeOf(ctx)) anyerror!void) !Emitter(void).ListenerId {
        return try self._onDidChange.listen(ctx, struct {
            fn cb(_: void, ctx_: @TypeOf(ctx)) anyerror!void {
                return callback(ctx_);
            }
        }.cb);
    }

    pub fn unsubscribe(self: *MinimapTokensColorTracker, id: Emitter(void).ListenerId) void {
        self._onDidChange.unlisten(id);
    }

    /// The number of cached colors (mostly useful for tests).
    pub fn colorCount(self: *const MinimapTokensColorTracker) usize {
        return self._colors.items.len;
    }
};

var instance: ?*MinimapTokensColorTracker = null;

/// Returns the process-wide tracker, creating it on first use.
pub fn getInstance(allocator: Allocator) !*MinimapTokensColorTracker {
    if (instance) |existing| return existing;
    instance = try MinimapTokensColorTracker.create(allocator);
    return instance.?;
}

/// Releases the process-wide tracker, if any.
pub fn destroyInstance() void {
    if (instance) |existing| {
        existing.destroy();
        instance = null;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "MinimapTokensColorTracker without a color map" {
    const allocator = testing.allocator;
    const tracker = try MinimapTokensColorTracker.create(allocator);
    defer tracker.destroy();

    // Not even the registry has colors installed yet, but the tracker still has
    // the three reserved ids.
    try testing.expect(tracker.colorCount() >= 3);
    try testing.expect(tracker.backgroundIsLight());
    try testing.expect(RGBA8.empty.equals(tracker.getColor(ColorId.DefaultForeground)));
    // Out-of-range ids fall back to the default background.
    try testing.expect(RGBA8.empty.equals(tracker.getColor(300)));
    try testing.expect(RGBA8.empty.equals(tracker.getColor(0)));
}

test "MinimapTokensColorTracker maps a color map to RGBA8" {
    const allocator = testing.allocator;
    const tracker = try MinimapTokensColorTracker.create(allocator);
    defer tracker.destroy();

    const colors = [_]Color{
        Color{ .r = 1, .g = 2, .b = 3, .a = 1 }, // 0: unused
        Color{ .r = 10, .g = 20, .b = 30, .a = 0.5 }, // 1: DefaultForeground
        Color{ .r = 255, .g = 255, .b = 255, .a = 1 }, // 2: DefaultBackground
        Color{ .r = 0, .g = 0, .b = 0, .a = 1 }, // 3
    };
    try tracker.updateColorMap(&colors);

    try testing.expectEqual(@as(usize, 4), tracker.colorCount());

    const foreground = tracker.getColor(ColorId.DefaultForeground);
    try testing.expectEqual(@as(i32, 10), foreground.r);
    try testing.expectEqual(@as(i32, 20), foreground.g);
    try testing.expectEqual(@as(i32, 30), foreground.b);
    // Alpha is expanded to 0..255.
    try testing.expectEqual(@as(i32, 128), foreground.a);

    // A white background is light.
    try testing.expect(tracker.backgroundIsLight());

    // Unknown ids fall back to the default background (white here).
    const fallback = tracker.getColor(50);
    try testing.expectEqual(@as(i32, 255), fallback.r);

    // A near-black background is dark.
    const dark = [_]Color{
        Color.black,
        Color.white,
        Color{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    try tracker.updateColorMap(&dark);
    try testing.expect(!tracker.backgroundIsLight());
}

test "MinimapTokensColorTracker fires onDidChange when the map changes" {
    const allocator = testing.allocator;
    const tracker = try MinimapTokensColorTracker.create(allocator);
    defer tracker.destroy();

    const Counter = struct {
        fn callback(count: *usize) anyerror!void {
            count.* += 1;
        }
    };

    var count: usize = 0;
    const listener = try tracker.onDidChange(&count, Counter.callback);
    defer tracker.unsubscribe(listener);

    const colors = [_]Color{ Color.black, Color.white, Color.white };
    try tracker.updateColorMap(&colors);
    try testing.expectEqual(@as(usize, 1), count);
}
