const std = @import("std");
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;
const unicode = std.unicode;
const ArrayList = std.array_list.Managed;
const BUILD_MODE = @import("builtin").mode;

// oniguruma.zig
const c = @cImport({
    @cInclude("oniguruma.h");
});

pub const Error = error{
    ValueIsNotSet,
    Mismatch,
    NoSupportConfig,
    Abort,
    ErrMemory,
    ErrTypeBug,
    ErrParserBug,
    ErrStackBug,
    ErrUnexpectedBytecode,
    ErrMatchStackLimitOver,
    ErrParseDepthLimitOver,
    ErrRetryLimitInMatchOver,
    ErrRetryLimitInSearchOver,
    ErrSubexpCallLimitInSearchOver,
    ErrDefaultEncodingIsNotSet,
    ErrSpecifiedEncodingCantConvertToWideChar,
    ErrFailToInitialize,
    ErrInvalidArgument,
    ErrEndPatternAtLeftBrace,
    ErrEndPatternAtLeftBracket,
    ErrEmptyCharClass,
    ErrPrematureEndOfCharClass,
    ErrEndPatternAtEscape,
    ErrEndPatternAtMeta,
    ErrEndPatternAtControl,
    ErrMetaCodeSyntax,
    ErrControlCodeSyntax,
    ErrCharClassValueAtEndOfRange,
    ErrCharClassValueAtStartOfRange,
    ErrUnmatchedRangeSpecifierInCharClass,
    ErrTargetOfRepeatOperatorNotSpecified,
    ErrTargetOfRepeatOperatorInvalid,
    ErrNestedRepeatOperator,
    ErrUnmatchedCloseParenthesis,
    ErrEndPatternWithUnmatchedParenthesis,
    ErrEndPatternInGroup,
    ErrUndefinedGroupOption,
    ErrInvalidGroupOption,
    ErrInvalidPosixBracketType,
    ErrInvalidLookBehindPattern,
    ErrInvalidRepeatRangePattern,
    ErrTooBigNumber,
    ErrTooBigNumberForRepeatRange,
    ErrUpperSmallerThanLowerInRepeatRange,
    ErrEmptyRangeInCharClass,
    ErrMismatchCodeLengthInClassRange,
    ErrTooManyMultiByteRanges,
    ErrTooShortMultiByteString,
    ErrTooBigBackrefNumber,
    ErrInvalidBackref,
    ErrNumberedBackrefOrCallNotAllowed,
    ErrTooManyCaptures,
    ErrTooLongWideCharValue,
    ErrUndefinedOperator,
    ErrEmptyGroupName,
    ErrInvalidGroupName,
    ErrInvalidCharInGroupName,
    ErrUndefinedNameReference,
    ErrUndefinedGroupReference,
    ErrMultiplexDefinedName,
    ErrMultiplexDefinitionNameCall,
    ErrNeverEndingRecursion,
    ErrGroupNumberOverForCaptureHistory,
    ErrInvalidCharPropertyName,
    ErrInvalidIfElseSyntax,
    ErrInvalidAbsentGroupPattern,
    ErrInvalidAbsentGroupGeneratorPattern,
    ErrInvalidCalloutPattern,
    ErrInvalidCalloutName,
    ErrUndefinedCalloutName,
    ErrInvalidCalloutBody,
    ErrInvalidCalloutTagName,
    ErrInvalidCalloutArg,
    ErrInvalidCodePointValue,
    ErrTooBigWideCharValue,
    ErrNotSupportedEncodingCombination,
    ErrInvalidCombinationOfOptions,
    ErrTooManyUserDefinedObjects,
    ErrTooLongPropertyName,
    ErrVeryInefficientPattern,
    ErrLibraryIsNotInitialized,
    UnknownError,
};

pub fn errorCodeToError(code: c_int) Error {
    return switch (code) {
        c.ONIG_VALUE_IS_NOT_SET => Error.ValueIsNotSet,
        c.ONIG_MISMATCH => Error.Mismatch,
        c.ONIG_NO_SUPPORT_CONFIG => Error.NoSupportConfig,
        c.ONIG_ABORT => Error.Abort,
        c.ONIGERR_MEMORY => Error.ErrMemory,
        c.ONIGERR_TYPE_BUG => Error.ErrTypeBug,
        c.ONIGERR_PARSER_BUG => Error.ErrParserBug,
        c.ONIGERR_STACK_BUG => Error.ErrStackBug,
        c.ONIGERR_UNEXPECTED_BYTECODE => Error.ErrUnexpectedBytecode,
        c.ONIGERR_MATCH_STACK_LIMIT_OVER => Error.ErrMatchStackLimitOver,
        c.ONIGERR_PARSE_DEPTH_LIMIT_OVER => Error.ErrParseDepthLimitOver,
        c.ONIGERR_RETRY_LIMIT_IN_MATCH_OVER => Error.ErrRetryLimitInMatchOver,
        c.ONIGERR_RETRY_LIMIT_IN_SEARCH_OVER => Error.ErrRetryLimitInSearchOver,
        c.ONIGERR_SUBEXP_CALL_LIMIT_IN_SEARCH_OVER => Error.ErrSubexpCallLimitInSearchOver,
        c.ONIGERR_DEFAULT_ENCODING_IS_NOT_SET => Error.ErrDefaultEncodingIsNotSet,
        c.ONIGERR_SPECIFIED_ENCODING_CANT_CONVERT_TO_WIDE_CHAR => Error.ErrSpecifiedEncodingCantConvertToWideChar,
        c.ONIGERR_FAIL_TO_INITIALIZE => Error.ErrFailToInitialize,
        c.ONIGERR_INVALID_ARGUMENT => Error.ErrInvalidArgument,
        c.ONIGERR_END_PATTERN_AT_LEFT_BRACE => Error.ErrEndPatternAtLeftBrace,
        c.ONIGERR_END_PATTERN_AT_LEFT_BRACKET => Error.ErrEndPatternAtLeftBracket,
        c.ONIGERR_EMPTY_CHAR_CLASS => Error.ErrEmptyCharClass,
        c.ONIGERR_PREMATURE_END_OF_CHAR_CLASS => Error.ErrPrematureEndOfCharClass,
        c.ONIGERR_END_PATTERN_AT_ESCAPE => Error.ErrEndPatternAtEscape,
        c.ONIGERR_END_PATTERN_AT_META => Error.ErrEndPatternAtMeta,
        c.ONIGERR_END_PATTERN_AT_CONTROL => Error.ErrEndPatternAtControl,
        c.ONIGERR_META_CODE_SYNTAX => Error.ErrMetaCodeSyntax,
        c.ONIGERR_CONTROL_CODE_SYNTAX => Error.ErrControlCodeSyntax,
        c.ONIGERR_CHAR_CLASS_VALUE_AT_END_OF_RANGE => Error.ErrCharClassValueAtEndOfRange,
        c.ONIGERR_CHAR_CLASS_VALUE_AT_START_OF_RANGE => Error.ErrCharClassValueAtStartOfRange,
        c.ONIGERR_UNMATCHED_RANGE_SPECIFIER_IN_CHAR_CLASS => Error.ErrUnmatchedRangeSpecifierInCharClass,
        c.ONIGERR_TARGET_OF_REPEAT_OPERATOR_NOT_SPECIFIED => Error.ErrTargetOfRepeatOperatorNotSpecified,
        c.ONIGERR_TARGET_OF_REPEAT_OPERATOR_INVALID => Error.ErrTargetOfRepeatOperatorInvalid,
        c.ONIGERR_NESTED_REPEAT_OPERATOR => Error.ErrNestedRepeatOperator,
        c.ONIGERR_UNMATCHED_CLOSE_PARENTHESIS => Error.ErrUnmatchedCloseParenthesis,
        c.ONIGERR_END_PATTERN_WITH_UNMATCHED_PARENTHESIS => Error.ErrEndPatternWithUnmatchedParenthesis,
        c.ONIGERR_END_PATTERN_IN_GROUP => Error.ErrEndPatternInGroup,
        c.ONIGERR_UNDEFINED_GROUP_OPTION => Error.ErrUndefinedGroupOption,
        c.ONIGERR_INVALID_GROUP_OPTION => Error.ErrInvalidGroupOption,
        c.ONIGERR_INVALID_POSIX_BRACKET_TYPE => Error.ErrInvalidPosixBracketType,
        c.ONIGERR_INVALID_LOOK_BEHIND_PATTERN => Error.ErrInvalidLookBehindPattern,
        c.ONIGERR_INVALID_REPEAT_RANGE_PATTERN => Error.ErrInvalidRepeatRangePattern,
        c.ONIGERR_TOO_BIG_NUMBER => Error.ErrTooBigNumber,
        c.ONIGERR_TOO_BIG_NUMBER_FOR_REPEAT_RANGE => Error.ErrTooBigNumberForRepeatRange,
        c.ONIGERR_UPPER_SMALLER_THAN_LOWER_IN_REPEAT_RANGE => Error.ErrUpperSmallerThanLowerInRepeatRange,
        c.ONIGERR_EMPTY_RANGE_IN_CHAR_CLASS => Error.ErrEmptyRangeInCharClass,
        c.ONIGERR_MISMATCH_CODE_LENGTH_IN_CLASS_RANGE => Error.ErrMismatchCodeLengthInClassRange,
        c.ONIGERR_TOO_MANY_MULTI_BYTE_RANGES => Error.ErrTooManyMultiByteRanges,
        c.ONIGERR_TOO_SHORT_MULTI_BYTE_STRING => Error.ErrTooShortMultiByteString,
        c.ONIGERR_TOO_BIG_BACKREF_NUMBER => Error.ErrTooBigBackrefNumber,
        c.ONIGERR_INVALID_BACKREF => Error.ErrInvalidBackref,
        c.ONIGERR_NUMBERED_BACKREF_OR_CALL_NOT_ALLOWED => Error.ErrNumberedBackrefOrCallNotAllowed,
        c.ONIGERR_TOO_MANY_CAPTURES => Error.ErrTooManyCaptures,
        c.ONIGERR_TOO_LONG_WIDE_CHAR_VALUE => Error.ErrTooLongWideCharValue,
        c.ONIGERR_UNDEFINED_OPERATOR => Error.ErrUndefinedOperator,
        c.ONIGERR_EMPTY_GROUP_NAME => Error.ErrEmptyGroupName,
        c.ONIGERR_INVALID_GROUP_NAME => Error.ErrInvalidGroupName,
        c.ONIGERR_INVALID_CHAR_IN_GROUP_NAME => Error.ErrInvalidCharInGroupName,
        c.ONIGERR_UNDEFINED_NAME_REFERENCE => Error.ErrUndefinedNameReference,
        c.ONIGERR_UNDEFINED_GROUP_REFERENCE => Error.ErrUndefinedGroupReference,
        c.ONIGERR_MULTIPLEX_DEFINED_NAME => Error.ErrMultiplexDefinedName,
        c.ONIGERR_MULTIPLEX_DEFINITION_NAME_CALL => Error.ErrMultiplexDefinitionNameCall,
        c.ONIGERR_NEVER_ENDING_RECURSION => Error.ErrNeverEndingRecursion,
        c.ONIGERR_GROUP_NUMBER_OVER_FOR_CAPTURE_HISTORY => Error.ErrGroupNumberOverForCaptureHistory,
        c.ONIGERR_INVALID_CHAR_PROPERTY_NAME => Error.ErrInvalidCharPropertyName,
        c.ONIGERR_INVALID_IF_ELSE_SYNTAX => Error.ErrInvalidIfElseSyntax,
        c.ONIGERR_INVALID_ABSENT_GROUP_PATTERN => Error.ErrInvalidAbsentGroupPattern,
        c.ONIGERR_INVALID_ABSENT_GROUP_GENERATOR_PATTERN => Error.ErrInvalidAbsentGroupGeneratorPattern,
        c.ONIGERR_INVALID_CALLOUT_PATTERN => Error.ErrInvalidCalloutPattern,
        c.ONIGERR_INVALID_CALLOUT_NAME => Error.ErrInvalidCalloutName,
        c.ONIGERR_UNDEFINED_CALLOUT_NAME => Error.ErrUndefinedCalloutName,
        c.ONIGERR_INVALID_CALLOUT_BODY => Error.ErrInvalidCalloutBody,
        c.ONIGERR_INVALID_CALLOUT_TAG_NAME => Error.ErrInvalidCalloutTagName,
        c.ONIGERR_INVALID_CALLOUT_ARG => Error.ErrInvalidCalloutArg,
        c.ONIGERR_INVALID_CODE_POINT_VALUE => Error.ErrInvalidCodePointValue,
        c.ONIGERR_TOO_BIG_WIDE_CHAR_VALUE => Error.ErrTooBigWideCharValue,
        c.ONIGERR_NOT_SUPPORTED_ENCODING_COMBINATION => Error.ErrNotSupportedEncodingCombination,
        c.ONIGERR_INVALID_COMBINATION_OF_OPTIONS => Error.ErrInvalidCombinationOfOptions,
        c.ONIGERR_TOO_MANY_USER_DEFINED_OBJECTS => Error.ErrTooManyUserDefinedObjects,
        c.ONIGERR_TOO_LONG_PROPERTY_NAME => Error.ErrTooLongPropertyName,
        c.ONIGERR_VERY_INEFFICIENT_PATTERN => Error.ErrVeryInefficientPattern,
        c.ONIGERR_LIBRARY_IS_NOT_INITIALIZED => Error.ErrLibraryIsNotInitialized,
        else => Error.UnknownError,
    };
}

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
        printError(res, null);
        return errorCodeToError(res);
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

fn printError(res: c_int, errorInfos: ?*const c.OnigErrorInfo) void {
    if (BUILD_MODE != .Debug and BUILD_MODE != .DebugSafe) {
        return;
    }

    var s: [c.ONIG_MAX_ERROR_MESSAGE_LEN]u8 = undefined;
    _ = c.onig_error_code_to_str(&s, res, if (errorInfos) |i| i else null);
    const p: [*:0]const u8 = @ptrCast(&s);
    std.debug.print("RegExp Error: {s}\n", .{std.mem.span(p)});
}

pub const RegExp = struct {
    regex: c.OnigRegex,

    pub fn init(pattern: []const u8, option: Options) !RegExp {
        return try initWithSyntax(pattern, option, c.OnigDefaultSyntax);
    }

    pub fn initWithSyntax(pattern: []const u8, option: Options, syntax_: OnigSyntax) !RegExp {
        var regex: c.OnigRegex = undefined;
        var errorInfos: c.OnigErrorInfo = undefined;
        const res = c.onig_new(&regex, pattern.ptr, pattern.ptr + pattern.len, @bitCast(option), &c.OnigEncodingUTF8, syntax_, &errorInfos);
        errdefer c.onig_free(regex);
        if (res != c.ONIG_NORMAL) {
            // printError(res, &errorInfos);
            return errorCodeToError(res);
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
        if (start > input.len) {
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

    fn nameToGroupNumbers(self: *const RegExp, name: []const u8) ![]const u32 {
        var nums: [*c]u32 = undefined;
        const res = c.onig_name_to_group_numbers(self.regex, name.ptr, name.ptr + name.len, &nums);
        if (res < 0) {
            return errorCodeToError(res);
        }
        return nums[0..@intCast(res)];
    }

    fn nameToGroupNumber(self: *const RegExp, name: []const u8) !usize {
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

    pub fn reset(self: *SearchResultIterator, input: []const u8, offset: usize) void {
        self._input = input;
        self._lastIndex = offset;
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

        const matchLen = current.length();

        // For non-empty matches, advance past the match end
        if (matchLen > 0) {
            const matchEnd = index + matchLen;
            // If we're not at end of input, return match end position
            if (matchEnd < input.len) {
                return matchEnd;
            }
            // We're at end, prevent matching empty string here
            return input.len + 1;
        }

        const rest = input[index..];
        if (rest.len == 0) {
            return input.len + 1;
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

    // Non-overlapping: only "123" matches, "45" is too short
    try std.testing.expectEqual(1, matches.items.len);
    try std.testing.expectEqualSlices(u8, "123", matches.items[0]);
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

test "utf8" {
    try initialize(null);
    defer uninitialize();

    const regex = try RegExp.init("\\w", .{});
    defer regex.deinit();

    const input = "世界world和平peace";
    var iter = regex.searchIterator(input, 0);
    var utf8Iter = unicode.Utf8Iterator{ .bytes = input, .i = 0 };
    var n: usize = 0;
    while (iter.next()) |m| {
        defer m.deinit();
        const slice = utf8Iter.nextCodepointSlice() orelse unreachable;
        try std.testing.expectEqualStrings(slice, m.groupN(0));
        n += 1;
    }

    try std.testing.expectEqual(unicode.utf8CountCodepoints(input), n);
}

test "error" {
    try initialize(null);
    defer uninitialize();

    std.debug.print("\n", .{});
    try std.testing.expectError(Error.ErrEndPatternWithUnmatchedParenthesis, RegExp.init("(aa", .{}));
}

pub fn escapeRegExp(allocator: Allocator, input: []const u8) !ArrayList(u8) {
    var result = ArrayList(u8).init(allocator);

    for (input) |ch| {
        if (ch == '(' or ch == ')' or ch == '[' or ch == ']' or ch == '{' or ch == '}' or ch == '.' or ch == '+' or ch == '?' or ch == '|' or ch == '\\' or ch == '^' or ch == '$') {
            try result.append('\\');
        }
        try result.append(ch);
    }

    return result;
}

test "escapeRegExp" {
    try initialize(null);
    defer uninitialize();

    const escaped = try escapeRegExp(std.testing.allocator, "ab(c)");
    defer escaped.deinit();
    try std.testing.expectEqualStrings("ab\\(c\\)", escaped.items);
}
