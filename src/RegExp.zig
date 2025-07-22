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
    UndefinedNameReference,
};

const max_encoders = 30;
const Encoding = c.OnigEncoding;
var encondings: [max_encoders]Encoding = undefined;

pub fn initialize(defaultSyntax: ?OnigSyntax) !void {
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
    if (res < 0) {
        return Error.InitializeFailed;
    }

    if (defaultSyntax) |syntax| {
        _ = c.onig_set_default_syntax(syntax);
    }
}

pub fn uninitialize() void {
    _ = c.onig_end();
}

pub const Options = packed struct(c_int) {
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

pub const DefaultOption: Options = @bitCast(c.ONIG_OPTION_DEFAULT);

pub const OnigSyntax = *c.OnigSyntaxType;
pub var OnigSyntaxASIS: OnigSyntax = &c.OnigSyntaxASIS;
pub var OnigSyntaxPosixBasic: OnigSyntax = &c.OnigSyntaxPosixBasic;
pub var OnigSyntaxPosixExtended: OnigSyntax = &c.OnigSyntaxPosixExtended;
pub var OnigSyntaxEmacs: OnigSyntax = &c.OnigSyntaxEmacs;
pub var OnigSyntaxGrep: OnigSyntax = &c.OnigSyntaxGrep;
pub var OnigSyntaxGnuRegex: OnigSyntax = &c.OnigSyntaxGnuRegex;
pub var OnigSyntaxJava: OnigSyntax = &c.OnigSyntaxJava;
pub var OnigSyntaxPerl: OnigSyntax = &c.OnigSyntaxPerl;
pub var OnigSyntaxPerl_NG: OnigSyntax = &c.OnigSyntaxPerl_NG;
pub var OnigSyntaxRuby: OnigSyntax = &c.OnigSyntaxRuby;
pub var OnigSyntaxPython: OnigSyntax = &c.OnigSyntaxPython;
pub var OnigSyntaxOniguruma: OnigSyntax = &c.OnigSyntaxOniguruma;

pub const RegExp = struct {
    regex: c.OnigRegex,

    pub fn init(pattern: []const u8, option: Options) !RegExp {
        return try initWithSyntax(pattern, option, c.OnigDefaultSyntax);
    }

    pub fn initWithSyntax(pattern: []const u8, option: Options, syntax_: OnigSyntax) !RegExp {
        var regex: c.OnigRegex = undefined;
        var errorInfos: c.OnigErrorInfo = undefined;
        const res = c.onig_new(&regex, pattern.ptr, pattern.ptr + pattern.len, @bitCast(option), encondings[0], syntax_, &errorInfos);
        errdefer c.onig_free(regex);
        if (res != c.ONIG_NORMAL) {
            return Error.InvalidRegex;
        }

        return RegExp{
            .regex = regex,
            .lastIndex = null,
        };
    }

    pub fn deinit(self: *const RegExp) void {
        c.onig_free(self.regex);
    }

    pub fn isMatch(self: *const RegExp, input: []const u8) bool {
        const r = c.onig_search(
            self.regex,
            input.ptr,
            input.ptr + input.len,
            input.ptr,
            input.ptr + input.len,
            null,
            c.ONIG_OPTION_DEFAULT,
        );
        if (r == c.ONIG_MISMATCH) {
            return false;
        }
        return true;
    }

    pub fn exec(self: *RegExp, input: []const u8) ?RegExpExecResult {
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
            return null;
        }

        return RegExpExecResult{
            .matches = region,
            .captures = region,
            .index = 0,
        };
    }

    pub fn search(self: *const RegExp, input: []const u8) ?Region {
        const region = Region.init(input, self);

        const r = c.onig_search(self.regex, input.ptr, input.ptr + input.len, input.ptr, input.ptr + input.len, region._region, c.ONIG_OPTION_DEFAULT);
        if (r == c.ONIG_MISMATCH) {
            region.deinit();
            return null;
        }

        return region;
    }

    pub fn encoding(self: *const RegExp) Encoding {
        return c.onig_get_encoding(self.regex);
    }

    pub fn syntax(self: *const RegExp) OnigSyntax {
        return c.onig_get_syntax(self.regex);
    }

    pub fn options(self: *const RegExp) Options {
        return @bitCast(c.onig_get_options(self.regex));
    }

    fn numberOfNames(self: *const RegExp) usize {
        return @intCast(c.onig_number_of_names(self.regex));
    }

    fn nameToGroupNumbers(self: *const RegExp, name: []const u8) Error![]const u32 {
        var nums: [*c]u32 = undefined;
        const res = c.onig_name_to_group_numbers(self.regex, name.ptr, name.ptr + name.len, &nums);
        if (res < 0) {
            return Error.UndefinedNameReference;
        }
        // I don't like return u32 type.
        // I think we should avoid having duplicate group names.
        return nums[0..@intCast(res)];
    }

    fn nameToGroupNumber(self: *const RegExp, name: []const u8) Error!usize {
        const nums = try self.nameToGroupNumbers(name);
        return @intCast(nums[0]);
    }
};

pub const Region = struct {
    _region: *c.OnigRegion,
    _str: []const u8, // borrowed
    _regex: *const RegExp, // borrowed

    pub fn init(input: []const u8, regex: *const RegExp) Region {
        return Region{ ._region = c.onig_region_new(), ._str = input, ._regex = regex };
    }

    pub fn deinit(self: *const Region) void {
        c.onig_region_free(self._region, 1);
    }

    pub fn index(self: *const Region) usize {
        return @intCast(self._region.beg[0]);
    }

    pub fn count(self: *const Region) usize {
        return @intCast(self._region.num_regs);
    }

    pub fn groupN(self: *const Region, n: usize) []const u8 {
        if (n >= self.count()) {
            unreachable;
        }
        const beg: usize = @intCast(self._region.beg[n]);
        const end: usize = @intCast(self._region.end[n]);
        return self._str[beg..end];
    }

    pub fn group(self: *const Region, name: []const u8) ![]const u8 {
        const num = try self._regex.nameToGroupNumber(name);
        return self.groupN(num);
    }
};

pub const RegExpExecResult = struct {
    index: usize,
    input: []const u8,
    groups: ?StringHashMap([]const u8),
};

test "numberOfNames" {
    try initialize(null);
    defer uninitialize();

    const regex = try RegExp.init("abc(?<name>[a-z]*)f", .{});
    defer regex.deinit();

    try std.testing.expectEqual(1, regex.numberOfNames());
    const num = regex.nameToGroupNumber("name") catch unreachable;
    try std.testing.expectEqual(1, num);
}

test "isMatch" {
    try initialize(null);
    defer uninitialize();

    const regex = try RegExp.init("abc[a-z]*f", .{ .ignore_case = true });
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("Abcdefg"));
}

test "search" {
    try initialize(null);
    defer uninitialize();

    const regex = try RegExp.init("abc([a-z]*)f", .{ .ignore_case = true });
    defer regex.deinit();

    const region = regex.search("Abcdefg");
    try std.testing.expect(region != null);
    try std.testing.expectEqual(2, region.?.count());
    try std.testing.expectEqualStrings("Abcdef", region.?.groupN(0));
    try std.testing.expectEqualStrings("de", region.?.groupN(1));
}

test "search2" {
    try initialize(null);
    defer uninitialize();

    const regex = try RegExp.init("abc(?<name>[a-z]*)f", .{ .ignore_case = true });
    defer regex.deinit();

    const region = regex.search("111Abcdefg");
    try std.testing.expect(region != null);
    try std.testing.expectEqual(2, region.?.count());
    try std.testing.expectEqualStrings("Abcdef", region.?.groupN(0));
    try std.testing.expectEqualStrings("de", region.?.groupN(1));
    try std.testing.expectEqualStrings("de", region.?.group("name") catch unreachable);
}
