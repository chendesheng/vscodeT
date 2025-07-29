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
pub const ColorId = enum(u8) { None = 0, DefaultForeground = 1, DefaultBackground = 2 };

pub const ForegroundColorId = enum(u9) { None = 0, DefaultForeground = 1, DefaultBackground = 2 };

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
pub const MetadataConsts = packed struct {
    languageId: u8,
    tokenType: StandardTokenType,
    balancedBrackets: bool,
    fontStyle: FontStyle,
    foreground: ColorId,
    foregroundExtra: u1,
    background: ColorId,
};
