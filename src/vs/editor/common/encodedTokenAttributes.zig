const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

// Open ended enum at runtime
pub const LanguageId = enum(u8) { Null = 0, PlainText = 1, _ };

// A font style. Values are 2^x such that a bit mask can be used.
pub const FontStyle = packed struct(u4) {
    italic: bool,
    bold: bool,
    underline: bool,
    strikethrough: bool,

    pub const None = FontStyle{
        .italic = false,
        .bold = false,
        .underline = false,
        .strikethrough = false,
    };

    pub const Italic = FontStyle{
        .italic = true,
        .bold = false,
        .underline = false,
        .strikethrough = false,
    };

    pub const Bold = FontStyle{
        .italic = false,
        .bold = true,
        .underline = false,
        .strikethrough = false,
    };

    pub const Underline = FontStyle{
        .italic = false,
        .bold = false,
        .underline = true,
        .strikethrough = false,
    };

    pub const Strikethrough = FontStyle{
        .italic = false,
        .bold = false,
        .underline = false,
        .strikethrough = true,
    };

    pub const ItalicBold = FontStyle{
        .italic = true,
        .bold = true,
        .underline = false,
        .strikethrough = false,
    };

    pub const ItalicUnderline = FontStyle{
        .italic = true,
        .bold = false,
        .underline = true,
        .strikethrough = false,
    };

    pub const ItalicStrikethrough = FontStyle{
        .italic = true,
        .bold = false,
        .underline = false,
        .strikethrough = true,
    };
};

// Open ended enum at runtime
pub const ColorId = struct {
    pub const None: u9 = 0;
    pub const DefaultForeground: u9 = 1;
    pub const DefaultBackground: u9 = 2;
    pub const Mask: u9 = 0b111111111;
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
    _padding: u2,

    pub const UseForeground = SemanticMetadata{
        .useItalic = false,
        .useBold = false,
        .useUnderline = false,
        .useStrikethrough = false,
        .useForeground = true,
        .useBackground = false,
        ._padding = 0,
    };

    pub const UseBackground = SemanticMetadata{
        .useItalic = false,
        .useBold = false,
        .useUnderline = false,
        .useStrikethrough = false,
        .useForeground = false,
        .useBackground = true,
        ._padding = 0,
    };

    pub const UseItalic = SemanticMetadata{
        .useItalic = true,
        .useBold = false,
        .useUnderline = false,
        .useStrikethrough = false,
        .useForeground = false,
        .useBackground = false,
        ._padding = 0,
    };

    pub const UseBold = SemanticMetadata{
        .useItalic = false,
        .useBold = true,
        .useUnderline = false,
        .useStrikethrough = false,
        .useForeground = false,
        .useBackground = false,
        ._padding = 0,
    };

    pub const UseUnderline = SemanticMetadata{
        .useItalic = false,
        .useBold = false,
        .useUnderline = true,
        .useStrikethrough = false,
        .useForeground = false,
        .useBackground = false,
    };

    pub const UseStrikethrough = SemanticMetadata{
        .useItalic = false,
        .useBold = false,
        .useUnderline = false,
        .useStrikethrough = true,
        .useForeground = false,
        .useBackground = false,
        ._padding = 0,
    };
};

pub const TokenMetadata = packed struct(u32) {
    languageId: u8,
    tokenType: StandardTokenType,
    balancedBrackets: bool,
    fontStyle: FontStyle,
    foreground: u9,
    background: u8,

    pub const default = TokenMetadata{
        .languageId = 0,
        .tokenType = .Other,
        .balancedBrackets = false,
        .fontStyle = .{ .italic = false, .bold = false, .underline = false, .strikethrough = false },
        .foreground = ColorId.DefaultForeground,
        .background = @intCast(ColorId.DefaultBackground),
    };

    pub fn getClassNameFromMetadata(self: TokenMetadata, allocator: Allocator) !ArrayList(u8) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll("mtk");
        try out.writer.print("{d}", .{self.foreground});

        const fontStyle = self.fontStyle;
        if (fontStyle.italic) try out.writer.writeAll(" mtki");
        if (fontStyle.bold) try out.writer.writeAll(" mtkb");
        if (fontStyle.underline) try out.writer.writeAll(" mtku");
        if (fontStyle.strikethrough) try out.writer.writeAll(" mtks");

        return ArrayList(u8).fromOwnedSlice(allocator, try out.toOwnedSlice());
    }

    pub fn getInlineStyleFromMetadata(self: TokenMetadata, allocator: Allocator, colorMap: []const []const u8) !ArrayList(u8) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll("color: ");
        try out.writer.writeAll(colorMap[@as(usize, @intCast(self.foreground))]);
        try out.writer.writeAll(";");
        if (self.fontStyle.italic) try out.writer.writeAll("font-style: italic;");
        if (self.fontStyle.bold) try out.writer.writeAll("font-weight: bold;");

        var hasDecoration = false;
        if (self.fontStyle.underline) {
            try out.writer.writeAll(if (hasDecoration) " underline" else "text-decoration: underline");
            hasDecoration = true;
        }
        if (self.fontStyle.strikethrough) {
            try out.writer.writeAll(if (hasDecoration) " line-through" else "text-decoration: line-through");
            hasDecoration = true;
        }
        if (hasDecoration) try out.writer.writeAll(";");
        return ArrayList(u8).fromOwnedSlice(allocator, try out.toOwnedSlice());
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
    foreground: u9,
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
        .foreground = ColorId.DefaultForeground,
        .background = 0,
    };
    const presentation = metadata.getPresentationFromMetadata();
    try std.testing.expectEqual(presentation.foreground, ColorId.DefaultForeground);
}
