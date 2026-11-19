// Port of `vscode-textmate/src/encodedTokenAttributes.ts`
// (microsoft/vscode-textmate v9.3.2).
//
// JS bitwise operators are 32-bit and the upstream code applies `>>> 0`;
// this port uses `u32` for the encoded attributes.
const std = @import("std");

pub const EncodedTokenAttributes = u32;

pub const FontStyle = struct {
    pub const not_set: i32 = -1;
    pub const none: i32 = 0;
    pub const italic: i32 = 1;
    pub const bold: i32 = 2;
    pub const underline: i32 = 4;
    pub const strikethrough: i32 = 8;
};

pub const StandardTokenType = struct {
    pub const other: u8 = 0;
    pub const comment: u8 = 1;
    pub const string: u8 = 2;
    pub const regex: u8 = 3;
};

pub const OptionalStandardTokenType = struct {
    pub const other: u8 = 0;
    pub const comment: u8 = 1;
    pub const string: u8 = 2;
    pub const regex: u8 = 3;
    /// Indicates that no token type is set.
    pub const not_set: u8 = 8;
};

pub const Constants = struct {
    pub const languageid_mask: u32 = 0b00000000000000000000000011111111;
    pub const token_type_mask: u32 = 0b00000000000000000000001100000000;
    pub const balanced_brackets_mask: u32 = 0b00000000000000000000010000000000;
    pub const font_style_mask: u32 = 0b00000000000000000111100000000000;
    pub const foreground_mask: u32 = 0b00000000111111111000000000000000;
    pub const background_mask: u32 = 0b11111111000000000000000000000000;

    pub const languageid_offset: u5 = 0;
    pub const token_type_offset: u5 = 8;
    pub const balanced_brackets_offset: u5 = 10;
    pub const font_style_offset: u5 = 11;
    pub const foreground_offset: u5 = 15;
    pub const background_offset: u5 = 24;
};

pub fn toBinaryStr(attributes: EncodedTokenAttributes) [32]u8 {
    var result: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const bit: u5 = @intCast(31 - i);
        result[i] = if ((attributes & (@as(u32, 1) << bit)) != 0) '1' else '0';
    }
    return result;
}

pub fn getLanguageId(attributes: EncodedTokenAttributes) u32 {
    return (attributes & Constants.languageid_mask) >> Constants.languageid_offset;
}

pub fn getTokenType(attributes: EncodedTokenAttributes) u8 {
    return @intCast((attributes & Constants.token_type_mask) >> Constants.token_type_offset);
}

pub fn containsBalancedBrackets(attributes: EncodedTokenAttributes) bool {
    return (attributes & Constants.balanced_brackets_mask) != 0;
}

pub fn getFontStyle(attributes: EncodedTokenAttributes) u32 {
    return (attributes & Constants.font_style_mask) >> Constants.font_style_offset;
}

pub fn getForeground(attributes: EncodedTokenAttributes) u32 {
    return (attributes & Constants.foreground_mask) >> Constants.foreground_offset;
}

pub fn getBackground(attributes: EncodedTokenAttributes) u32 {
    return (attributes & Constants.background_mask) >> Constants.background_offset;
}

/// Updates the fields. `language_id == 0`, `token_type == NotSet`,
/// `contains_balanced_brackets == null`, `font_style == NotSet`,
/// `foreground == 0`, and `background == 0` leave the corresponding field as
/// is.
pub fn set(
    attributes: EncodedTokenAttributes,
    language_id: u32,
    token_type: u8,
    contains_balanced_brackets_value: ?bool,
    font_style: i32,
    foreground: u32,
    background: u32,
) EncodedTokenAttributes {
    var result_language_id = getLanguageId(attributes);
    var result_token_type = getTokenType(attributes);
    var result_balanced_brackets = containsBalancedBrackets(attributes);
    var result_font_style = getFontStyle(attributes);
    var result_foreground = getForeground(attributes);
    var result_background = getBackground(attributes);

    if (language_id != 0) result_language_id = language_id;
    if (token_type != OptionalStandardTokenType.not_set) result_token_type = token_type;
    if (contains_balanced_brackets_value) |value| result_balanced_brackets = value;
    if (font_style != FontStyle.not_set) {
        result_font_style = if (font_style < 0) 0 else @intCast(font_style);
    }
    if (foreground != 0) result_foreground = foreground;
    if (background != 0) result_background = background;

    var result: u32 = 0;
    result |= (result_language_id & 0xFF) << Constants.languageid_offset;
    result |= (@as(u32, result_token_type) & 0x3) << Constants.token_type_offset;
    result |= (@as(u32, @intFromBool(result_balanced_brackets)) & 0x1) << Constants.balanced_brackets_offset;
    result |= (result_font_style & 0xF) << Constants.font_style_offset;
    result |= (result_foreground & 0x1FF) << Constants.foreground_offset;
    result |= (result_background & 0xFF) << Constants.background_offset;
    return result;
}

pub fn toOptionalTokenType(standard_type: u8) u8 {
    return standard_type;
}

test "encoded token attributes round trip" {
    const value = set(0, 1, OptionalStandardTokenType.regex, false, FontStyle.underline | FontStyle.bold, 101, 102);
    try std.testing.expectEqual(@as(u32, 1), getLanguageId(value));
    try std.testing.expectEqual(StandardTokenType.regex, getTokenType(value));
    try std.testing.expect(!containsBalancedBrackets(value));
    try std.testing.expectEqual(@as(u32, 6), getFontStyle(value));
    try std.testing.expectEqual(@as(u32, 101), getForeground(value));
    try std.testing.expectEqual(@as(u32, 102), getBackground(value));

    const changed = set(value, 2, OptionalStandardTokenType.not_set, true, FontStyle.not_set, 0, 0);
    try std.testing.expectEqual(@as(u32, 2), getLanguageId(changed));
    try std.testing.expectEqual(StandardTokenType.regex, getTokenType(changed));
    try std.testing.expect(containsBalancedBrackets(changed));
    try std.testing.expectEqual(@as(u32, 6), getFontStyle(changed));
}

test "encoded token attributes max values" {
    const value = set(0, 255, StandardTokenType.comment | StandardTokenType.other | StandardTokenType.regex | StandardTokenType.string, true, FontStyle.bold | FontStyle.italic | FontStyle.underline, 511, 254);
    try std.testing.expectEqual(@as(u32, 255), getLanguageId(value));
    try std.testing.expectEqual(@as(u8, 3), getTokenType(value));
    try std.testing.expect(containsBalancedBrackets(value));
    try std.testing.expectEqual(@as(u32, 7), getFontStyle(value));
    try std.testing.expectEqual(@as(u32, 511), getForeground(value));
    try std.testing.expectEqual(@as(u32, 254), getBackground(value));
}
