const std = @import("std");
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;

// oniguruma.zig
const c = @cImport({
    @cInclude("oniguruma.h");
});

pub const Error = error{
    InitializeFailed,
    InvalidRegex,
};

const max_encoders = 30;
var encondings: [max_encoders]c.OnigEncoding = undefined;

pub fn initialize() !void {
    encondings[0] = &c.OnigEncodingASCII;
    encondings[1] = &c.OnigEncodingISO_8859_1;
    encondings[2] = &c.OnigEncodingISO_8859_2;
    encondings[3] = &c.OnigEncodingISO_8859_3;
    encondings[4] = &c.OnigEncodingISO_8859_4;
    encondings[5] = &c.OnigEncodingISO_8859_5;
    encondings[6] = &c.OnigEncodingISO_8859_6;
    encondings[7] = &c.OnigEncodingISO_8859_7;
    encondings[8] = &c.OnigEncodingISO_8859_8;
    encondings[9] = &c.OnigEncodingISO_8859_9;
    encondings[10] = &c.OnigEncodingISO_8859_10;
    encondings[11] = &c.OnigEncodingISO_8859_11;
    encondings[12] = &c.OnigEncodingISO_8859_13;
    encondings[13] = &c.OnigEncodingISO_8859_14;
    encondings[14] = &c.OnigEncodingISO_8859_15;
    encondings[15] = &c.OnigEncodingISO_8859_16;
    encondings[16] = &c.OnigEncodingUTF8;
    encondings[17] = &c.OnigEncodingUTF16_BE;
    encondings[18] = &c.OnigEncodingUTF16_LE;
    encondings[19] = &c.OnigEncodingUTF32_BE;
    encondings[20] = &c.OnigEncodingUTF32_LE;
    encondings[21] = &c.OnigEncodingEUC_JP;
    encondings[22] = &c.OnigEncodingEUC_TW;
    encondings[23] = &c.OnigEncodingEUC_KR;
    encondings[24] = &c.OnigEncodingEUC_CN;
    encondings[25] = &c.OnigEncodingSJIS;
    encondings[26] = &c.OnigEncodingKOI8_R;
    encondings[27] = &c.OnigEncodingCP1251;
    encondings[28] = &c.OnigEncodingBIG5;
    encondings[29] = &c.OnigEncodingGB18030;
    //encondings[30] = &c.OnigEncodingKOI8;

    const res = c.onig_initialize(&encondings, max_encoders);
    if (res != c.ONIG_NORMAL) {
        return Error.InitializeFailed;
    }
}

pub fn uninitialize() void {
    _ = c.onig_end();
}

pub const Option = packed struct(c_int) {
    ignore_case: bool = false,
    extend: bool = false,
    multiline: bool = false,
    singleline: bool = false,
    find_longest: bool = false,
    not_empty: bool = false,
    negate_singleline: bool = false,
    dont_capture_group: bool = false,
    capture_group: bool = false,
    not_bol: bool = false,
    posix_region: bool = false,
    check_validity_of_string: bool = false,
    ignorecase_is_ascii: bool = false,
    word_is_ascii: bool = false,
    digit_is_ascii: bool = false,
    space_is_ascii: bool = false,
    posix_is_ascii: bool = false,
    text_segment_extended_grapheme_cluster: bool = false,
    text_segment_word: bool = false,
    not_begin_string: bool = false,
    not_end_string: bool = false,
    not_begin_position: bool = false,
    callback_each_match: bool = false,
    match_whole_string: bool = false,
    _rest_bits: u8 = 0,
};

pub const DefaultOption: Option = @bitCast(c.ONIG_OPTION_DEFAULT);

pub const RegExp = struct {
    regex: c.OnigRegex,

    pub fn init(pattern: []const u8, option: Option) !RegExp {
        var regex: c.OnigRegex = undefined;
        var errorInfos: c.OnigErrorInfo = undefined;
        const res = c.onig_new(&regex, pattern.ptr, pattern.ptr + pattern.len, @bitCast(option), encondings[0], c.ONIG_SYNTAX_DEFAULT(), &errorInfos);
        if (res != c.ONIG_NORMAL) {
            return Error.InvalidRegex;
        }

        return RegExp{
            .regex = regex,
        };
    }

    pub fn isMatch(self: *const RegExp, input: []const u8) bool {
        const region = c.onig_region_new();
        defer c.onig_region_free(region, 1);

        const r = c.onig_search(
            self.regex,
            input.ptr,
            input.ptr + input.len,
            input.ptr,
            input.ptr + input.len,
            region,
            c.ONIG_OPTION_DEFAULT,
        );
        if (r == c.ONIG_MISMATCH) {
            return false;
        }
        return true;
    }

    pub fn exec(self: *const RegExp, input: []const u8) !?RegExpExecResult {
        const region = c.onig_region_new();
        defer c.onig_region_free(region, 1);

        const r = c.onig_search(
            self.regex,
            input.ptr,
            input.ptr + input.len,
            region,
            c.ONIG_OPTION_DEFAULT,
        );
        if (r == c.ONIG_MISMATCH) {
            return null;
        }

        return RegExpExecResult{
            .matches = region,
            .captures = region,
            .index = 0,
        };
    }
};

pub const RegExpExecResult = struct {
    matches: []const []const u8,
    index: usize,
    groups: ?StringHashMap([]const u8),
};

test "isMatch" {
    try initialize();
    defer uninitialize();

    const regex = try RegExp.init("abc[a-z]*f", .{ .ignore_case = true });
    try std.testing.expect(regex.isMatch("Abcdefg"));
}
