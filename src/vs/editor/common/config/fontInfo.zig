const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const is_macintosh = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

/// Determined from empirical observations.
pub const GOLDEN_LINE_HEIGHT_RATIO: f64 = if (is_macintosh) 1.5 else 1.35;

pub const MINIMUM_LINE_HEIGHT: f64 = 8;

pub const FONT_VARIATION_OFF = "normal";
pub const FONT_VARIATION_TRANSLATE = "translate";

pub const DEFAULT_WINDOWS_FONT_FAMILY = "Consolas, 'Courier New', monospace";
pub const DEFAULT_MAC_FONT_FAMILY = "Menlo, Monaco, 'Courier New', monospace";
pub const DEFAULT_LINUX_FONT_FAMILY = "'Droid Sans Mono', monospace";

pub const EDITOR_FONT_DEFAULTS = struct {
    pub const fontFamily = if (is_macintosh)
        DEFAULT_MAC_FONT_FAMILY
    else if (is_windows)
        DEFAULT_WINDOWS_FONT_FAMILY
    else
        DEFAULT_LINUX_FONT_FAMILY;
    pub const fontWeight = "normal";
    pub const fontSize: f64 = if (is_macintosh) 12 else 14;
    pub const lineHeight: f64 = 0;
    pub const letterSpacing: f64 = 0;
};

pub const BareFontInfoOptions = struct {
    pixelRatio: f64,
    fontFamily: []const u8,
    fontWeight: []const u8,
    fontSize: f64,
    fontFeatureSettings: []const u8,
    fontVariationSettings: []const u8,
    lineHeight: f64,
    letterSpacing: f64,
};

pub const BareFontInfo = struct {
    pixelRatio: f64,
    fontFamily: []const u8,
    fontWeight: []const u8,
    fontSize: f64,
    fontFeatureSettings: []const u8,
    fontVariationSettings: []const u8,
    lineHeight: i32,
    letterSpacing: f64,

    pub fn init(opts: BareFontInfoOptions) BareFontInfo {
        return .{
            .pixelRatio = opts.pixelRatio,
            .fontFamily = opts.fontFamily,
            .fontWeight = opts.fontWeight,
            .fontSize = opts.fontSize,
            .fontFeatureSettings = opts.fontFeatureSettings,
            .fontVariationSettings = opts.fontVariationSettings,
            .lineHeight = @intFromFloat(@trunc(opts.lineHeight)),
            .letterSpacing = opts.letterSpacing,
        };
    }

    pub fn getId(self: *const BareFontInfo, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{d}-{s}-{s}-{d}-{s}-{s}-{d}-{d}", .{
            self.pixelRatio,
            self.fontFamily,
            self.fontWeight,
            self.fontSize,
            self.fontFeatureSettings,
            self.fontVariationSettings,
            self.lineHeight,
            self.letterSpacing,
        });
    }

    pub fn getMassagedFontFamily(self: *const BareFontInfo, allocator: Allocator) ![]u8 {
        const fallbackFontFamily = EDITOR_FONT_DEFAULTS.fontFamily;
        const fontFamily = try wrapInQuotes(allocator, self.fontFamily);
        if (fallbackFontFamily.len > 0 and !std.mem.eql(u8, self.fontFamily, fallbackFontFamily)) {
            const result = try std.fmt.allocPrint(allocator, "{s}, {s}", .{ fontFamily, fallbackFontFamily });
            allocator.free(fontFamily);
            return result;
        }
        return fontFamily;
    }

    fn wrapInQuotes(allocator: Allocator, fontFamily: []const u8) ![]u8 {
        if (std.mem.indexOfAny(u8, fontFamily, ",\"'") != null) {
            // Looks like the font family might be already escaped.
            return allocator.dupe(u8, fontFamily);
        }
        if (std.mem.indexOfAny(u8, fontFamily, "+ ") != null) {
            // Wrap a font family using + or <space> with quotes.
            return std.fmt.allocPrint(allocator, "\"{s}\"", .{fontFamily});
        }
        return allocator.dupe(u8, fontFamily);
    }
};

// Change this whenever `FontInfo` members are changed.
pub const SERIALIZED_FONT_INFO_VERSION = 2;

pub const FontInfoOptions = struct {
    pixelRatio: f64,
    fontFamily: []const u8,
    fontWeight: []const u8,
    fontSize: f64,
    fontFeatureSettings: []const u8,
    fontVariationSettings: []const u8,
    lineHeight: f64,
    letterSpacing: f64,
    isMonospace: bool,
    typicalHalfwidthCharacterWidth: f64,
    typicalFullwidthCharacterWidth: f64,
    canUseHalfwidthRightwardsArrow: bool,
    spaceWidth: f64,
    middotWidth: f64,
    wsmiddotWidth: f64,
    maxDigitWidth: f64,
};

pub const FontInfo = struct {
    pixelRatio: f64,
    fontFamily: []const u8,
    fontWeight: []const u8,
    fontSize: f64,
    fontFeatureSettings: []const u8,
    fontVariationSettings: []const u8,
    lineHeight: i32,
    letterSpacing: f64,

    version: i32 = SERIALIZED_FONT_INFO_VERSION,
    isTrusted: bool,
    isMonospace: bool,
    typicalHalfwidthCharacterWidth: f64,
    typicalFullwidthCharacterWidth: f64,
    canUseHalfwidthRightwardsArrow: bool,
    spaceWidth: f64,
    middotWidth: f64,
    wsmiddotWidth: f64,
    maxDigitWidth: f64,

    pub fn init(opts: FontInfoOptions, isTrusted: bool) FontInfo {
        return .{
            .pixelRatio = opts.pixelRatio,
            .fontFamily = opts.fontFamily,
            .fontWeight = opts.fontWeight,
            .fontSize = opts.fontSize,
            .fontFeatureSettings = opts.fontFeatureSettings,
            .fontVariationSettings = opts.fontVariationSettings,
            .lineHeight = @intFromFloat(@trunc(opts.lineHeight)),
            .letterSpacing = opts.letterSpacing,
            .isTrusted = isTrusted,
            .isMonospace = opts.isMonospace,
            .typicalHalfwidthCharacterWidth = opts.typicalHalfwidthCharacterWidth,
            .typicalFullwidthCharacterWidth = opts.typicalFullwidthCharacterWidth,
            .canUseHalfwidthRightwardsArrow = opts.canUseHalfwidthRightwardsArrow,
            .spaceWidth = opts.spaceWidth,
            .middotWidth = opts.middotWidth,
            .wsmiddotWidth = opts.wsmiddotWidth,
            .maxDigitWidth = opts.maxDigitWidth,
        };
    }

    pub fn toBare(self: *const FontInfo) BareFontInfo {
        return BareFontInfo.init(.{
            .pixelRatio = self.pixelRatio,
            .fontFamily = self.fontFamily,
            .fontWeight = self.fontWeight,
            .fontSize = self.fontSize,
            .fontFeatureSettings = self.fontFeatureSettings,
            .fontVariationSettings = self.fontVariationSettings,
            .lineHeight = @floatFromInt(self.lineHeight),
            .letterSpacing = self.letterSpacing,
        });
    }

    pub fn equals(self: *const FontInfo, other: *const FontInfo) bool {
        return std.mem.eql(u8, self.fontFamily, other.fontFamily) and
            std.mem.eql(u8, self.fontWeight, other.fontWeight) and
            self.fontSize == other.fontSize and
            std.mem.eql(u8, self.fontFeatureSettings, other.fontFeatureSettings) and
            std.mem.eql(u8, self.fontVariationSettings, other.fontVariationSettings) and
            self.lineHeight == other.lineHeight and
            self.letterSpacing == other.letterSpacing and
            self.typicalHalfwidthCharacterWidth == other.typicalHalfwidthCharacterWidth and
            self.typicalFullwidthCharacterWidth == other.typicalFullwidthCharacterWidth and
            self.canUseHalfwidthRightwardsArrow == other.canUseHalfwidthRightwardsArrow and
            self.spaceWidth == other.spaceWidth and
            self.middotWidth == other.middotWidth and
            self.wsmiddotWidth == other.wsmiddotWidth and
            self.maxDigitWidth == other.maxDigitWidth;
    }
};

fn baseFontInfoOptions() BareFontInfoOptions {
    return .{
        .pixelRatio = 2,
        .fontFamily = "Test Font",
        .fontWeight = "normal",
        .fontSize = 14,
        .fontFeatureSettings = "",
        .fontVariationSettings = "",
        .lineHeight = 20,
        .letterSpacing = 0,
    };
}

test "fontInfo: bare font info accessors" {
    const allocator = std.testing.allocator;
    const info = BareFontInfo.init(baseFontInfoOptions());
    try std.testing.expectEqual(@as(i32, 20), info.lineHeight);
    try std.testing.expectEqual(true, std.mem.eql(u8, "Test Font", info.fontFamily));

    const id = try info.getId(allocator);
    defer allocator.free(id);
    try std.testing.expect(std.mem.startsWith(u8, id, "2-Test Font-normal-14-"));

    const massaged = try info.getMassagedFontFamily(allocator);
    defer allocator.free(massaged);
    try std.testing.expect(std.mem.startsWith(u8, massaged, "\"Test Font\""));
    try std.testing.expect(std.mem.indexOf(u8, massaged, EDITOR_FONT_DEFAULTS.fontFamily) != null);
}

test "fontInfo: line height is truncated" {
    var opts = baseFontInfoOptions();
    opts.lineHeight = 20.9;
    const info = BareFontInfo.init(opts);
    try std.testing.expectEqual(@as(i32, 20), info.lineHeight);
}

test "fontInfo: equals compares measured values" {
    const opts = FontInfoOptions{
        .pixelRatio = 2,
        .fontFamily = "Test Font",
        .fontWeight = "normal",
        .fontSize = 14,
        .fontFeatureSettings = "",
        .fontVariationSettings = "",
        .lineHeight = 20,
        .letterSpacing = 0,
        .isMonospace = true,
        .typicalHalfwidthCharacterWidth = 8,
        .typicalFullwidthCharacterWidth = 16,
        .canUseHalfwidthRightwardsArrow = true,
        .spaceWidth = 8,
        .middotWidth = 4,
        .wsmiddotWidth = 5,
        .maxDigitWidth = 8,
    };

    const a = FontInfo.init(opts, true);
    const b = FontInfo.init(opts, false);
    try std.testing.expect(a.equals(&b));
    try std.testing.expectEqual(true, a.isTrusted);
    try std.testing.expectEqual(false, b.isTrusted);
    try std.testing.expectEqual(@as(i32, SERIALIZED_FONT_INFO_VERSION), a.version);

    var opts2 = opts;
    opts2.spaceWidth = 9;
    const c = FontInfo.init(opts2, true);
    try std.testing.expect(!a.equals(&c));
}

test "fontInfo: default font family per platform" {
    if (is_macintosh) {
        try std.testing.expectEqualStrings(DEFAULT_MAC_FONT_FAMILY, EDITOR_FONT_DEFAULTS.fontFamily);
        try std.testing.expectEqual(@as(f64, 12), EDITOR_FONT_DEFAULTS.fontSize);
    } else if (is_windows) {
        try std.testing.expectEqualStrings(DEFAULT_WINDOWS_FONT_FAMILY, EDITOR_FONT_DEFAULTS.fontFamily);
        try std.testing.expectEqual(@as(f64, 14), EDITOR_FONT_DEFAULTS.fontSize);
    } else {
        try std.testing.expectEqualStrings(DEFAULT_LINUX_FONT_FAMILY, EDITOR_FONT_DEFAULTS.fontFamily);
        try std.testing.expectEqual(@as(f64, 14), EDITOR_FONT_DEFAULTS.fontSize);
    }
}
