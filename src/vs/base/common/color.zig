// Port of the parts of `src/vs/base/common/color.ts` that this port needs.
//
// Supported input is `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA`; the upstream
// class also parses `rgba()`/`hsla()` strings and supports several output
// formats. `HSLA` is ported far enough to convert an HSL color to RGB.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Color = struct {
    // Red: integer in [0-255]
    r: u8,
    // Green: integer in [0-255]
    g: u8,
    // Blue: integer in [0-255]
    b: u8,
    // Alpha: float in [0-1]
    a: f32,

    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 1 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };

    /// Parses `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`; the leading `#` is
    /// optional.
    pub fn fromHex(hex: []const u8) !Color {
        const digits = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
        switch (digits.len) {
            3 => {
                const r = try parseHexNibble(digits[0]);
                const g = try parseHexNibble(digits[1]);
                const b = try parseHexNibble(digits[2]);
                return .{ .r = r * 17, .g = g * 17, .b = b * 17, .a = 1 };
            },
            4 => {
                const r = try parseHexNibble(digits[0]);
                const g = try parseHexNibble(digits[1]);
                const b = try parseHexNibble(digits[2]);
                const a = try parseHexNibble(digits[3]);
                return .{
                    .r = r * 17,
                    .g = g * 17,
                    .b = b * 17,
                    .a = @as(f32, @floatFromInt(a * 17)) / 255.0,
                };
            },
            6 => {
                const rgb = try parseHexTriplet(digits);
                return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 1 };
            },
            8 => {
                const rgb = try parseHexTriplet(digits[0..6]);
                const alpha = try parseHexByte(digits[6..8]);
                return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = @as(f32, @floatFromInt(alpha)) / 255.0 };
            },
            else => return error.InvalidColorFormat,
        }
    }

    /// Returns `#RRGGBB` (uppercase). The alpha channel is dropped, which is
    /// enough for token theme colors; those are always opaque.
    pub fn toCssString(self: Color, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "#{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b });
    }

    /// Returns `#RRGGBBAA`.
    pub fn toHexString(self: Color, allocator: Allocator) ![]u8 {
        const alpha: u8 = @intFromFloat(@round(self.a * 255.0));
        return std.fmt.allocPrint(allocator, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b, alpha });
    }

    /// Returns the WCAG relative luminance of the opaque part of the color, in
    /// `[0, 1]`.
    pub fn getRelativeLuminance(self: Color) f64 {
        const r = relativeLuminanceForComponent(self.r);
        const g = relativeLuminanceForComponent(self.g);
        const b = relativeLuminanceForComponent(self.b);
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    fn relativeLuminanceForComponent(color: u8) f64 {
        const c = @as(f64, @floatFromInt(color)) / 255.0;
        return if (c <= 0.03928) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
    }
};

fn parseHexTriplet(digits: []const u8) ![3]u8 {
    return .{
        try parseHexByte(digits[0..2]),
        try parseHexByte(digits[2..4]),
        try parseHexByte(digits[4..6]),
    };
}

fn parseHexByte(digits: []const u8) !u8 {
    var value: u8 = 0;
    for (digits) |digit| {
        value = value * 16 + try parseHexNibble(digit);
    }
    return value;
}

fn parseHexNibble(digit: u8) !u8 {
    return switch (digit) {
        '0'...'9' => digit - '0',
        'a'...'f' => digit - 'a' + 10,
        'A'...'F' => digit - 'A' + 10,
        else => error.InvalidColorFormat,
    };
}

/// An HSL color: hue in [0, 360], saturation, luminosity and alpha in [0, 1].
pub const HSLA = struct {
    h: f32,
    s: f32,
    l: f32,
    a: f32,

    pub fn init(h: f32, s: f32, l: f32, a: f32) HSLA {
        return .{
            .h = @floatFromInt(@as(i32, @intFromFloat(std.math.clamp(h, 0, 360)))),
            .s = roundFloat(std.math.clamp(s, 0, 1), 3),
            .l = roundFloat(std.math.clamp(l, 0, 1), 3),
            .a = roundFloat(std.math.clamp(a, 0, 1), 3),
        };
    }

    fn hue2rgb(p: f32, q: f32, t_in: f32) f32 {
        var t = t_in;
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
        if (t < 1.0 / 2.0) return q;
        if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
        return p;
    }

    /// Converts an HSL color to RGB. Adapted from the Wikipedia formula, like
    /// `HSLA.toRGBA` upstream.
    pub fn toRGBA(self: HSLA) Color {
        const h = self.h / 360;
        var r: f32 = undefined;
        var g: f32 = undefined;
        var b: f32 = undefined;

        if (self.s == 0) {
            r = self.l; // achromatic
            g = self.l;
            b = self.l;
        } else {
            const q = if (self.l < 0.5) self.l * (1 + self.s) else self.l + self.s - self.l * self.s;
            const p = 2 * self.l - q;
            r = hue2rgb(p, q, h + 1.0 / 3.0);
            g = hue2rgb(p, q, h);
            b = hue2rgb(p, q, h - 1.0 / 3.0);
        }

        return .{
            .r = @intFromFloat(@round(r * 255)),
            .g = @intFromFloat(@round(g * 255)),
            .b = @intFromFloat(@round(b * 255)),
            .a = self.a,
        };
    }
};

fn roundFloat(value: f32, decimals: u32) f32 {
    const factor = std.math.pow(f32, 10, @floatFromInt(decimals));
    return @round(value * factor) / factor;
}

test "Color.fromHex: parses #RRGGBB" {
    const color = try Color.fromHex("#FF8800");
    try std.testing.expectEqual(@as(u8, 0xFF), color.r);
    try std.testing.expectEqual(@as(u8, 0x88), color.g);
    try std.testing.expectEqual(@as(u8, 0x00), color.b);
    try std.testing.expectEqual(@as(f32, 1), color.a);
}

test "Color.fromHex: the leading # is optional" {
    const color = try Color.fromHex("010203");
    try std.testing.expectEqual(@as(u8, 1), color.r);
    try std.testing.expectEqual(@as(u8, 2), color.g);
    try std.testing.expectEqual(@as(u8, 3), color.b);
}

test "Color.fromHex: parses #RRGGBBAA" {
    const color = try Color.fromHex("#00000080");
    try std.testing.expectEqual(@as(u8, 0), color.r);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), color.a, 1e-6);
}

test "Color.fromHex: expands the short forms" {
    const color = try Color.fromHex("#F80");
    try std.testing.expectEqual(@as(u8, 0xFF), color.r);
    try std.testing.expectEqual(@as(u8, 0x88), color.g);
    try std.testing.expectEqual(@as(u8, 0x00), color.b);
    try std.testing.expectEqual(@as(f32, 1), color.a);

    const with_alpha = try Color.fromHex("#F808");
    try std.testing.expectApproxEqAbs(@as(f32, 0x88.0 / 255.0), with_alpha.a, 1e-6);
}

test "HSLA.toRGBA: converts the way upstream does" {
    const red = HSLA.init(0, 1, 0.5, 1).toRGBA();
    try std.testing.expectEqual(@as(u8, 255), red.r);
    try std.testing.expectEqual(@as(u8, 0), red.g);
    try std.testing.expectEqual(@as(u8, 0), red.b);

    const grey = HSLA.init(0, 0, 0.5, 1).toRGBA();
    try std.testing.expectEqual(@as(u8, 128), grey.r);
    try std.testing.expectEqual(@as(u8, 128), grey.g);
    try std.testing.expectEqual(@as(u8, 128), grey.b);

    const blue = HSLA.init(240, 1, 0.5, 0.5).toRGBA();
    try std.testing.expectEqual(@as(u8, 0), blue.r);
    try std.testing.expectEqual(@as(u8, 0), blue.g);
    try std.testing.expectEqual(@as(u8, 255), blue.b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), blue.a, 1e-6);

    // The constructor clamps and rounds hue and clamps saturation.
    const clamped = HSLA.init(400, 2, -1, 2);
    try std.testing.expectEqual(@as(f32, 360), clamped.h);
    try std.testing.expectEqual(@as(f32, 1), clamped.s);
    try std.testing.expectEqual(@as(f32, 0), clamped.l);
    try std.testing.expectEqual(@as(f32, 1), clamped.a);
}

test "Color.fromHex: rejects invalid input" {
    try std.testing.expectError(error.InvalidColorFormat, Color.fromHex("#FF"));
    try std.testing.expectError(error.InvalidColorFormat, Color.fromHex("#FFFFF"));
    try std.testing.expectError(error.InvalidColorFormat, Color.fromHex("#GGGGGG"));
    try std.testing.expectError(error.InvalidColorFormat, Color.fromHex(""));
}

test "Color.toCssString and toHexString" {
    const allocator = std.testing.allocator;

    const color = try Color.fromHex("#0a0b0c");
    const css = try color.toCssString(allocator);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("#0A0B0C", css);

    const hex = try color.toHexString(allocator);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings("#0A0B0CFF", hex);
}
