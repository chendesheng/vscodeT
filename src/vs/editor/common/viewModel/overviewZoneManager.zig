// Port of `src/vs/editor/common/viewModel/overviewZoneManager.ts`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const MINIMUM_HEIGHT: f64 = 4;

fn truncI32(value: f64) i32 {
    const truncated = @trunc(value);
    if (truncated >= 2147483647.0) return std.math.maxInt(i32);
    if (truncated <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(truncated);
}

pub const ColorZone = struct {
    from: i32,
    to: i32,
    colorId: i32,

    pub fn init(from: f64, to: f64, colorId: i32) ColorZone {
        return .{
            .from = truncI32(from),
            .to = truncI32(to),
            .colorId = colorId,
        };
    }

    pub fn compare(a: ColorZone, b: ColorZone) i32 {
        if (a.colorId == b.colorId) {
            if (a.from == b.from) return a.to - b.to;
            return a.from - b.from;
        }
        return a.colorId - b.colorId;
    }
};

/// A zone in the overview ruler.
pub const OverviewRulerZone = struct {
    startLineNumber: usize,
    endLineNumber: usize,
    /// If set to 0, the height in lines is determined based on `endLineNumber`.
    heightInLines: f64,
    /// Borrowed: the string must outlive the zone.
    color: []const u8,

    _colorZone: ?ColorZone,

    pub fn init(startLineNumber: usize, endLineNumber: usize, heightInLines: f64, color: []const u8) OverviewRulerZone {
        return .{
            .startLineNumber = startLineNumber,
            .endLineNumber = endLineNumber,
            .heightInLines = heightInLines,
            .color = color,
            ._colorZone = null,
        };
    }

    pub fn compare(a: OverviewRulerZone, b: OverviewRulerZone) i32 {
        if (std.mem.eql(u8, a.color, b.color)) {
            if (a.startLineNumber == b.startLineNumber) {
                if (a.heightInLines == b.heightInLines) {
                    return @intCast(@as(isize, @intCast(a.endLineNumber)) - @as(isize, @intCast(b.endLineNumber)));
                }
                return if (a.heightInLines < b.heightInLines) -1 else 1;
            }
            return @intCast(@as(isize, @intCast(a.startLineNumber)) - @as(isize, @intCast(b.startLineNumber)));
        }
        return switch (std.mem.order(u8, a.color, b.color)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }

    pub fn setColorZone(self: *OverviewRulerZone, colorZone: ColorZone) void {
        self._colorZone = colorZone;
    }

    pub fn getColorZones(self: *const OverviewRulerZone) ?ColorZone {
        return self._colorZone;
    }
};

/// Provides the vertical offset (in pixels) of a line number.
pub const LineOffsetProvider = struct {
    context: *anyopaque,
    getVerticalOffsetForLine: *const fn (context: *anyopaque, lineNumber: usize) f64,

    pub fn offset(self: LineOffsetProvider, line_number: usize) f64 {
        return self.getVerticalOffsetForLine(self.context, line_number);
    }
};

pub const OverviewZoneManager = struct {
    allocator: Allocator,
    _getVerticalOffsetForLine: LineOffsetProvider,
    _zones: ArrayList(OverviewRulerZone),
    _colorZonesInvalid: bool,
    _lineHeight: f64,
    _domWidth: f64,
    _domHeight: f64,
    _outerHeight: f64,
    _pixelRatio: f64,
    _lastAssignedId: i32,
    _color2Id: std.StringHashMap(i32),
    _id2Color: ArrayList([]const u8),

    pub fn init(allocator: Allocator, getVerticalOffsetForLine: LineOffsetProvider) OverviewZoneManager {
        var id2color = ArrayList([]const u8).init(allocator);
        // Index 0 is never assigned; the first real color gets id 1.
        id2color.append("") catch unreachable;
        return .{
            .allocator = allocator,
            ._getVerticalOffsetForLine = getVerticalOffsetForLine,
            ._zones = ArrayList(OverviewRulerZone).init(allocator),
            ._colorZonesInvalid = false,
            ._lineHeight = 0,
            ._domWidth = 0,
            ._domHeight = 0,
            ._outerHeight = 0,
            ._pixelRatio = 1,
            ._lastAssignedId = 0,
            ._color2Id = std.StringHashMap(i32).init(allocator),
            ._id2Color = id2color,
        };
    }

    pub fn deinit(self: *OverviewZoneManager) void {
        self._zones.deinit();
        self._color2Id.deinit();
        self._id2Color.deinit();
    }

    pub fn getId2Color(self: *const OverviewZoneManager) []const []const u8 {
        return self._id2Color.items;
    }

    pub fn setZones(self: *OverviewZoneManager, newZones: []const OverviewRulerZone) !void {
        self._zones.clearRetainingCapacity();
        try self._zones.appendSlice(newZones);
        std.mem.sort(OverviewRulerZone, self._zones.items, {}, zoneLessThan);
    }

    fn zoneLessThan(_: void, a: OverviewRulerZone, b: OverviewRulerZone) bool {
        return OverviewRulerZone.compare(a, b) < 0;
    }

    pub fn setLineHeight(self: *OverviewZoneManager, lineHeight: f64) bool {
        if (self._lineHeight == lineHeight) return false;
        self._lineHeight = lineHeight;
        self._colorZonesInvalid = true;
        return true;
    }

    pub fn setPixelRatio(self: *OverviewZoneManager, pixelRatio: f64) void {
        self._pixelRatio = pixelRatio;
        self._colorZonesInvalid = true;
    }

    pub fn getDOMWidth(self: *const OverviewZoneManager) f64 {
        return self._domWidth;
    }

    pub fn getCanvasWidth(self: *const OverviewZoneManager) f64 {
        return self._domWidth * self._pixelRatio;
    }

    pub fn setDOMWidth(self: *OverviewZoneManager, width: f64) bool {
        if (self._domWidth == width) return false;
        self._domWidth = width;
        self._colorZonesInvalid = true;
        return true;
    }

    pub fn getDOMHeight(self: *const OverviewZoneManager) f64 {
        return self._domHeight;
    }

    pub fn getCanvasHeight(self: *const OverviewZoneManager) f64 {
        return self._domHeight * self._pixelRatio;
    }

    pub fn setDOMHeight(self: *OverviewZoneManager, height: f64) bool {
        if (self._domHeight == height) return false;
        self._domHeight = height;
        self._colorZonesInvalid = true;
        return true;
    }

    pub fn getOuterHeight(self: *const OverviewZoneManager) f64 {
        return self._outerHeight;
    }

    pub fn setOuterHeight(self: *OverviewZoneManager, outerHeight: f64) bool {
        if (self._outerHeight == outerHeight) return false;
        self._outerHeight = outerHeight;
        self._colorZonesInvalid = true;
        return true;
    }

    /// Resolves all zones into pixel rectangles. The returned slice is owned by
    /// the caller; the color ids it references stay valid as long as the manager
    /// lives.
    pub fn resolveColorZones(self: *OverviewZoneManager, allocator: Allocator) ![]ColorZone {
        const color_zones_invalid = self._colorZonesInvalid;
        const line_height = @floor(self._lineHeight);
        const total_height = @floor(self.getCanvasHeight());
        const outer_height = @floor(self._outerHeight);
        const height_ratio: f64 = if (outer_height == 0) 0 else total_height / outer_height;
        const half_minimum_height = @floor(MINIMUM_HEIGHT * self._pixelRatio / 2);

        var all_color_zones = ArrayList(ColorZone).init(allocator);
        errdefer all_color_zones.deinit();

        for (self._zones.items) |*zone| {
            if (!color_zones_invalid) {
                if (zone.getColorZones()) |color_zone| {
                    try all_color_zones.append(color_zone);
                    continue;
                }
            }

            const offset1 = self._getVerticalOffsetForLine.offset(zone.startLineNumber);
            const offset2 = if (zone.heightInLines == 0)
                self._getVerticalOffsetForLine.offset(zone.endLineNumber) + line_height
            else
                offset1 + zone.heightInLines * line_height;

            const y1 = @floor(height_ratio * offset1);
            const y2 = @floor(height_ratio * offset2);

            var ycenter = @floor((y1 + y2) / 2);
            var half_height = y2 - ycenter;

            if (half_height < half_minimum_height) {
                half_height = half_minimum_height;
            }

            if (ycenter - half_height < 0) {
                ycenter = half_height;
            }
            if (ycenter + half_height > total_height) {
                ycenter = total_height - half_height;
            }

            const color = zone.color;
            var color_id: i32 = self._color2Id.get(color) orelse 0;
            if (color_id == 0) {
                self._lastAssignedId += 1;
                color_id = self._lastAssignedId;
                try self._color2Id.put(color, color_id);
                try self._id2Color.append(color);
            }
            const color_zone = ColorZone.init(ycenter - half_height, ycenter + half_height, color_id);

            zone.setColorZone(color_zone);
            try all_color_zones.append(color_zone);
        }

        self._colorZonesInvalid = false;

        std.mem.sort(ColorZone, all_color_zones.items, {}, colorZoneLessThan);
        return all_color_zones.toOwnedSlice();
    }

    fn colorZoneLessThan(_: void, a: ColorZone, b: ColorZone) bool {
        return ColorZone.compare(a, b) < 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestOffsets = struct {
    fn getVerticalOffsetForLine(_: *anyopaque, line_number: usize) f64 {
        return @floatFromInt((line_number - 1) * 10);
    }

    fn provider() LineOffsetProvider {
        return .{
            .context = @ptrFromInt(@alignOf(usize)),
            .getVerticalOffsetForLine = getVerticalOffsetForLine,
        };
    }
};

test "ColorZone.compare orders by color, then from, then to" {
    const a = ColorZone{ .from = 0, .to = 10, .colorId = 2 };
    const b = ColorZone{ .from = 5, .to = 10, .colorId = 2 };
    const c = ColorZone{ .from = 0, .to = 20, .colorId = 2 };
    const d = ColorZone{ .from = 0, .to = 10, .colorId = 1 };

    try testing.expect(ColorZone.compare(a, b) < 0);
    try testing.expect(ColorZone.compare(a, c) < 0);
    try testing.expect(ColorZone.compare(a, d) > 0);
    try testing.expectEqual(@as(i32, 0), ColorZone.compare(a, a));
}

test "OverviewRulerZone.compare orders by color, start line, height and end line" {
    const a = OverviewRulerZone.init(1, 2, 0, "red");
    const b = OverviewRulerZone.init(2, 2, 0, "red");
    const c = OverviewRulerZone.init(1, 5, 0, "red");
    const d = OverviewRulerZone.init(1, 2, 3, "red");
    const e = OverviewRulerZone.init(1, 2, 0, "blue");

    try testing.expect(OverviewRulerZone.compare(a, b) < 0);
    try testing.expect(OverviewRulerZone.compare(a, c) < 0);
    try testing.expect(OverviewRulerZone.compare(a, d) < 0);
    try testing.expect(OverviewRulerZone.compare(a, e) > 0);
    try testing.expectEqual(@as(i32, 0), OverviewRulerZone.compare(a, a));
}

test "OverviewZoneManager resolves color zones" {
    const allocator = testing.allocator;
    var manager = OverviewZoneManager.init(allocator, TestOffsets.provider());
    defer manager.deinit();

    try testing.expectEqual(@as(f64, 0), manager.getDOMWidth());
    try testing.expect(manager.setLineHeight(10));
    try testing.expect(!manager.setLineHeight(10));
    manager.setPixelRatio(2);
    try testing.expect(manager.setDOMWidth(20));
    try testing.expect(manager.setDOMHeight(100));
    try testing.expect(manager.setOuterHeight(100));

    // Canvas dimensions scale the DOM dimensions by the pixel ratio.
    try testing.expectEqual(@as(f64, 40), manager.getCanvasWidth());
    try testing.expectEqual(@as(f64, 200), manager.getCanvasHeight());

    const zones = [_]OverviewRulerZone{
        OverviewRulerZone.init(1, 1, 0, "red"),
        OverviewRulerZone.init(5, 5, 0, "red"),
        OverviewRulerZone.init(3, 3, 0, "blue"),
    };
    try manager.setZones(&zones);

    const color_zones = try manager.resolveColorZones(allocator);
    defer allocator.free(color_zones);

    // `setZones` sorts by color first, so "blue" is discovered before "red"
    // and therefore gets the lower color id. The result is then sorted by
    // color id, then by `from`.
    try testing.expectEqual(@as(usize, 3), color_zones.len);

    try testing.expectEqual(@as(i32, 1), color_zones[0].colorId);
    try testing.expectEqual(@as(i32, 40), color_zones[0].from);
    try testing.expectEqual(@as(i32, 60), color_zones[0].to);

    try testing.expectEqual(@as(i32, 2), color_zones[1].colorId);
    try testing.expectEqual(@as(i32, 0), color_zones[1].from);
    try testing.expectEqual(@as(i32, 20), color_zones[1].to);

    try testing.expectEqual(@as(i32, 2), color_zones[2].colorId);
    try testing.expectEqual(@as(i32, 80), color_zones[2].from);
    try testing.expectEqual(@as(i32, 100), color_zones[2].to);

    // Color ids are handed out in discovery order and stay stable.
    try testing.expectEqual(@as(usize, 3), manager.getId2Color().len);
    try testing.expectEqualStrings("blue", manager.getId2Color()[1]);
    try testing.expectEqualStrings("red", manager.getId2Color()[2]);

    // Second call reuses the cached color zones.
    const cached = try manager.resolveColorZones(allocator);
    defer allocator.free(cached);
    try testing.expectEqual(@as(usize, 3), cached.len);
    try testing.expectEqual(@as(i32, 40), cached[0].from);
}

test "OverviewZoneManager honours heightInLines and minimum height" {
    const allocator = testing.allocator;
    var manager = OverviewZoneManager.init(allocator, TestOffsets.provider());
    defer manager.deinit();

    _ = manager.setLineHeight(10);
    _ = manager.setDOMWidth(20);
    _ = manager.setDOMHeight(100);
    _ = manager.setOuterHeight(100); // heightRatio == 1, canvas height 100

    // A single-line zone covers 10px; with a pixel ratio of 1 the minimum height
    // is 4px, so it is not inflated.
    const zones = [_]OverviewRulerZone{
        OverviewRulerZone.init(1, 1, 0, "red"),
        // heightInLines = 2 means offset1 + 2 * lineHeight.
        OverviewRulerZone.init(6, 100, 2, "red"),
    };
    try manager.setZones(&zones);

    const color_zones = try manager.resolveColorZones(allocator);
    defer allocator.free(color_zones);

    try testing.expectEqual(@as(usize, 2), color_zones.len);
    // First zone: y1 = 0, y2 = 10, center 5, half 5.
    try testing.expectEqual(@as(i32, 0), color_zones[0].from);
    try testing.expectEqual(@as(i32, 10), color_zones[0].to);
    // Second zone: offset1 = 50, offset2 = 70, center 60, half 10.
    try testing.expectEqual(@as(i32, 50), color_zones[1].from);
    try testing.expectEqual(@as(i32, 70), color_zones[1].to);
}

test "OverviewZoneManager clamps zones to the canvas" {
    const allocator = testing.allocator;
    var manager = OverviewZoneManager.init(allocator, TestOffsets.provider());
    defer manager.deinit();

    _ = manager.setLineHeight(10);
    _ = manager.setDOMWidth(20);
    _ = manager.setDOMHeight(100);
    _ = manager.setOuterHeight(100);
    // A big pixel ratio inflates the minimum height so the clamping kicks in.
    manager.setPixelRatio(10);

    const zones = [_]OverviewRulerZone{
        // offset 0..10, canvas 0..1000, heightRatio 10 → y1 = 0, y2 = 100,
        // center 50, half 50; halfMinimumHeight = 20.
        OverviewRulerZone.init(1, 1, 0, "red"),
    };
    try manager.setZones(&zones);

    const color_zones = try manager.resolveColorZones(allocator);
    defer allocator.free(color_zones);

    try testing.expectEqual(@as(usize, 1), color_zones.len);
    try testing.expectEqual(@as(i32, 0), color_zones[0].from);
    try testing.expectEqual(@as(i32, 100), color_zones[0].to);
}
