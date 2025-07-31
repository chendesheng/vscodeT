const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// Open ended enum at runtime
pub const LanguageId = enum(u8) { Null = 0, PlainText = 1 };

// A font style. Values are 2^x such that a bit mask can be used.
pub const FontStyle = packed struct(u4) {
    italic: bool,
    bold: bool,
    underline: bool,
    strikethrough: bool,
};

// Open ended enum at runtime
pub const ColorId = enum(u9) {
    None = 0,
    DefaultForeground = 1,
    DefaultBackground = 2,
    Mask = 0b111111111,
};

// A standard token type.
pub const StandardTokenType = enum(u2) { Other = 0, Comment = 1, String = 2, RegEx = 3 };

// Helpers to manage the "collapsed" metadata of an entire StackElement stack.
// The following assumptions have been made:
//  - languageId < 256 => needs 8 bits
//  - unique color count < 512 => needs 9 bits
//
// The binary format is:
// - -------------------------------------------
//     3322 2222 2222 1111 1111 1100 0000 0000
//     1098 7654 3210 9876 5432 1098 7654 3210
// - -------------------------------------------
//     xxxx xxxx xxxx xxxx xxxx xxxx xxxx xxxx
//     bbbb bbbb ffff ffff fFFF FBTT LLLL LLLL
// - -------------------------------------------
//  - L = LanguageId (8 bits)
//  - T = StandardTokenType (2 bits)
//  - B = Balanced bracket (1 bit)
//  - F = FontStyle (4 bits)
//  - f = foreground color (9 bits)
//  - b = background color (8 bits)
// LANGUAGEID_MASK /*            */ = 0b00000000_00000000_00000000_11111111,
// TOKEN_TYPE_MASK /*            */ = 0b00000000_00000000_00000011_00000000,
// BALANCED_BRACKETS_MASK /*     */ = 0b00000000_00000000_00000100_00000000,
// FONT_STYLE_MASK /*            */ = 0b00000000_00000000_01111000_00000000,
// FOREGROUND_MASK /*            */ = 0b00000000_11111111_10000000_00000000,
// BACKGROUND_MASK /*            */ = 0b11111111_00000000_00000000_00000000,

// ITALIC_MASK /*                */ = 0b00000000_00000000_00001000_00000000,
// BOLD_MASK /*                  */ = 0b00000000_00000000_00010000_00000000,
// UNDERLINE_MASK /*             */ = 0b00000000_00000000_00100000_00000000,
// STRIKETHROUGH_MASK /*         */ = 0b00000000_00000000_01000000_00000000,

// // Semantic tokens cannot set the language id, so we can
// // use the first 8 bits for control purposes
// SEMANTIC_USE_ITALIC /*        */ = 0b00000000_00000000_00000000_00000001,
// SEMANTIC_USE_BOLD /*          */ = 0b00000000_00000000_00000000_00000010,
// SEMANTIC_USE_UNDERLINE  /*    */ = 0b00000000_00000000_00000000_00000100,
// SEMANTIC_USE_STRIKETHROUGH /* */ = 0b00000000_00000000_00000000_00001000,
// SEMANTIC_USE_FOREGROUND /*    */ = 0b00000000_00000000_00000000_00010000,
// SEMANTIC_USE_BACKGROUND /*    */ = 0b00000000_00000000_00000000_00100000,

// LANGUAGEID_OFFSET = 0,
// TOKEN_TYPE_OFFSET = 8,
// BALANCED_BRACKETS_OFFSET = 10,
// FONT_STYLE_OFFSET = 11,
// FOREGROUND_OFFSET = 15,
// BACKGROUND_OFFSET = 24
pub const SemanticMetadata = packed struct(u8) {
    useItalic: bool,
    useBold: bool,
    useUnderline: bool,
    useStrikethrough: bool,
    useForeground: bool,
    useBackground: bool,
};
pub const TokenMetadata = packed struct(u32) {
    languageId: u8,
    tokenType: StandardTokenType,
    balancedBrackets: bool,
    fontStyle: FontStyle,
    foreground: ColorId,
    background: u8,

    pub const default = TokenMetadata{
        .languageId = 0,
        .tokenType = .Other,
        .balancedBrackets = false,
        .fontStyle = .{ .italic = false, .bold = false, .underline = false, .strikethrough = false },
        .foreground = .DefaultForeground,
        .background = @intCast(ColorId.DefaultBackground),
    };

    pub fn getClassNameFromMetadata(self: TokenMetadata, allocator: Allocator) !ArrayList(u8) {
        const foreground = self.foreground;
        var className = ArrayList(u8).init(allocator);
        try className.appendSlice("mtk");

        const foregroundStr = try std.fmt.allocPrint(allocator, "{d}", .{foreground});
        defer allocator.free(foregroundStr);
        try className.appendSlice(foregroundStr);

        const fontStyle = self.fontStyle;
        if (fontStyle.italic) {
            try className.appendSlice(" mtki");
        }
        if (fontStyle.bold) {
            try className.appendSlice(" mtkb");
        }
        if (fontStyle.underline) {
            try className.appendSlice(" mtku");
        }
        if (fontStyle.strikethrough) {
            try className.appendSlice(" mtks");
        }

        return className;
    }

    pub fn getInlineStyleFromMetadata(self: TokenMetadata, allocator: Allocator, colorMap: []const []const u8) !ArrayList(u8) {
        const foreground = self.foreground;
        const fontStyle = self.fontStyle;

        var result = ArrayList(u8).init(allocator);
        result.appendSlice("color: ");
        result.appendSlice(colorMap[@as(usize, @intCast(foreground))]);
        result.appendSlice(";");
        if (fontStyle.italic) {
            result.appendSlice("font-style: italic;");
        }
        if (fontStyle.bold) {
            result.appendSlice("font-weight: bold;");
        }

        var textDecoration = ArrayList(u8).init(allocator);
        defer textDecoration.deinit();
        if (fontStyle.underline) {
            textDecoration.appendSlice(" underline");
        }
        if (fontStyle.strikethrough) {
            textDecoration.appendSlice(" line-through");
        }
        if (textDecoration.items.len > 0) {
            result.appendSlice("text-decoration: ");
            result.appendSlice(textDecoration.items);
            result.appendSlice(";");
        }
        return result;
    }

    pub fn getPresentationFromMetadata(self: TokenMetadata) TokenPresentation {
        return .{
            .foreground = self.foreground,
            .italic = self.fontStyle.italic,
            .bold = self.fontStyle.bold,
            .underline = self.fontStyle.underline,
            .strikethrough = self.fontStyle.strikethrough,
        };
    }
};

pub const TokenPresentation = struct {
    foreground: ColorId,
    italic: bool,
    bold: bool,
    underline: bool,
    strikethrough: bool,
};

test "TokenMetadata" {
    const metadata = TokenMetadata{
        .languageId = 1,
        .tokenType = .Comment,
        .balancedBrackets = true,
        .fontStyle = .{ .italic = true, .bold = true, .underline = true, .strikethrough = true },
        .foreground = .DefaultForeground,
        .background = 0,
    };
    const presentation = metadata.getPresentationFromMetadata();
    try std.testing.expectEqual(presentation.foreground, .DefaultForeground);
}
