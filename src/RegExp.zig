const std = @import("std");
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;
const unicode = std.unicode;
const ArrayList = std.ArrayList;

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

    pub fn search(self: *const RegExp, input: []const u8) ?SearchResult {
        return self.searchFrom(input, 0);
    }

    pub fn searchFrom(self: *const RegExp, input: []const u8, start: usize) ?SearchResult {
        if (start >= input.len) {
            return null;
        }

        const region = Region.init();

        const r = c.onig_search(self.regex, input.ptr, input.ptr + input.len, input.ptr + start, input.ptr + input.len, region._region, c.ONIG_OPTION_DEFAULT);
        if (r == c.ONIG_MISMATCH) {
            region.deinit();
            return null;
        }

        return SearchResult{
            ._region = region,
            ._input = input,
            ._regex = self,
        };
    }

    pub fn searchIterator(self: *const RegExp, input: []const u8, start: usize) SearchResultIterator {
        return SearchResultIterator.init(self, input, start);
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
        return nums[0..@intCast(res)];
    }

    fn nameToGroupNumber(self: *const RegExp, name: []const u8) Error!usize {
        const nums = try self.nameToGroupNumbers(name);
        return @intCast(nums[0]);
    }
};

pub const SearchResult = struct {
    _region: Region,
    _input: []const u8,
    _regex: *const RegExp,

    pub fn deinit(self: *const SearchResult) void {
        self._region.deinit();
    }

    pub fn index(self: *const SearchResult) usize {
        return self._region.index();
    }

    pub fn length(self: *const SearchResult) usize {
        return self._region.length();
    }

    pub fn numberOfGroups(self: *const SearchResult) usize {
        return self._region.count();
    }

    pub fn groupN(self: *const SearchResult, n: usize) []const u8 {
        if (n >= self.numberOfGroups()) {
            unreachable;
        }
        const rg = self._region.range(n);
        return self._input[rg[0]..rg[1]];
    }

    // FIXME: group name is not unique
    pub fn group(self: *const SearchResult, name: []const u8) ![]const u8 {
        const num = try self._regex.nameToGroupNumber(name);
        return self.groupN(num);
    }
};

pub const SearchResultIterator = struct {
    _regex: *const RegExp,
    _input: []const u8,
    _lastIndex: usize,

    pub fn init(regex: *const RegExp, input: []const u8, start: usize) SearchResultIterator {
        return SearchResultIterator{
            ._regex = regex,
            ._input = input,
            ._lastIndex = start,
        };
    }

    pub fn next(self: *SearchResultIterator) ?SearchResult {
        if (self._regex.searchFrom(self._input, self._lastIndex)) |res| {
            self._lastIndex = nextIndex(&res);
            return res;
        }
        return null;
    }

    fn nextIndex(current: *const SearchResult) usize {
        const input = current._input;
        const index = current.index();
        const rest = input[index..];
        if (rest.len == 0) {
            return input.len;
        }
        const len = unicode.utf8ByteSequenceLength(rest[0]) catch {
            return input.len;
        };
        if (rest.len <= len) {
            return input.len;
        }
        return index + len;
    }
};

pub const Region = struct {
    _region: *c.OnigRegion,

    pub fn init() Region {
        return Region{ ._region = c.onig_region_new() };
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

    pub fn length(self: *const Region) usize {
        const rg = self.range(0);
        return rg[1] - rg[0];
    }

    pub fn range(self: *const Region, n: usize) [2]usize {
        if (n >= self.count()) {
            unreachable;
        }
        const beg: usize = @intCast(self._region.beg[n]);
        const end: usize = @intCast(self._region.end[n]);
        return [2]usize{ beg, end };
    }
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

    const regex = try RegExp.init("abc(?<name>[a-z]*)f", .{ .ignore_case = true });
    defer regex.deinit();

    const result = regex.search("111Abcdefg");

    try std.testing.expect(result != null);

    const res = result.?;
    defer res.deinit();
    try std.testing.expectEqual(2, res.numberOfGroups());
    try std.testing.expectEqual(3, res.index());
    try std.testing.expectEqualStrings("Abcdef", res.groupN(0));
    try std.testing.expectEqualStrings("de", res.groupN(1));
    try std.testing.expectEqualStrings("de", res.group("name") catch unreachable);
}

test "searchFrom" {
    try initialize(null);
    defer uninitialize();

    const regex = try RegExp.init("[0-9]{3}", .{ .ignore_case = true });
    defer regex.deinit();

    if (regex.searchFrom("12345", 2)) |result| {
        try std.testing.expectEqualStrings("345", result.groupN(0));
    } else {
        unreachable;
    }
}

test "SearchResultIterator" {
    try initialize(null);
    defer uninitialize();

    const regex = try RegExp.init("[0-9]{3}", .{ .ignore_case = true });
    defer regex.deinit();

    var iter = regex.searchIterator("12345", 0);

    var matches = ArrayList([]const u8).init(std.testing.allocator);
    defer matches.deinit();
    while (iter.next()) |current| {
        defer current.deinit();
        try matches.append(current.groupN(0));
    }

    try std.testing.expectEqual(3, matches.items.len);
    try std.testing.expectEqualSlices(u8, "123", matches.items[0]);
    try std.testing.expectEqualSlices(u8, "234", matches.items[1]);
    try std.testing.expectEqualSlices(u8, "345", matches.items[2]);
}

test "SearchResultIterator not match" {
    try initialize(null);
    defer uninitialize();

    const regex = try RegExp.init("[0-9]{3}", .{ .ignore_case = true });
    defer regex.deinit();

    var iter = regex.searchIterator("abc", 0);
    try std.testing.expect(iter.next() == null);
}

test "SearchResultIterator match empty string" {
    try initialize(null);
    defer uninitialize();

    const regex = try RegExp.init("[0-9]?", .{ .ignore_case = true });
    defer regex.deinit();

    var iter = regex.searchIterator("abc", 0);
    while (iter.next()) |current| {
        defer current.deinit();
        try std.testing.expectEqualStrings("", current.groupN(0));
    }
}
