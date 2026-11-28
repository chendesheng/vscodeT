// Port of `src/vs/editor/common/services/unicodeTextModelHighlighter.ts`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Range = @import("../core/range.zig").Range;
const strings = @import("../../../base/common/strings.zig");
const unicodeCharacters = @import("../../../base/common/unicodeCharacters.zig");
const wordHelper = @import("../core/wordHelper.zig");
const RegExp = @import("../../../../support/regexp.zig").RegExp;

/// The subset of `ITextModel` the highlighter needs.
pub const IUnicodeCharacterSearcherTarget = struct {
    context: *anyopaque,
    getLineCount: *const fn (context: *anyopaque) usize,
    getLineContent: *const fn (context: *anyopaque, lineNumber: usize) []const u8,

    pub fn lineCount(self: IUnicodeCharacterSearcherTarget) usize {
        return self.getLineCount(self.context);
    }

    pub fn lineContent(self: IUnicodeCharacterSearcherTarget, line_number: usize) []const u8 {
        return self.getLineContent(self.context, line_number);
    }
};

pub const UnicodeHighlighterOptions = struct {
    nonBasicASCII: bool,
    ambiguousCharacters: bool,
    invisibleCharacters: bool,
    includeComments: bool,
    includeStrings: bool,
    /// Code points that were explicitly allowed, e.g. from `editor.unicodeHighlight.allowedCharacters`.
    allowedCodePoints: []const u32 = &.{},
    /// Locales that consider the characters unambiguous.
    allowedLocales: []const []const u8 = &.{},
};

pub const IUnicodeHighlightsResult = struct {
    allocator: Allocator,
    ranges: []Range,
    hasMore: bool,
    ambiguousCharacterCount: usize,
    invisibleCharacterCount: usize,
    nonBasicAsciiCharacterCount: usize,

    pub fn deinit(self: *IUnicodeHighlightsResult) void {
        self.allocator.free(self.ranges);
    }
};

pub const UnicodeHighlighterReasonKind = enum {
    Ambiguous,
    Invisible,
    NonBasicAscii,
};

pub const UnicodeHighlighterReason = union(UnicodeHighlighterReasonKind) {
    /// `confusableWith` is the ASCII code point the character can be confused
    /// with (upstream returns it as a one-character string).
    Ambiguous: struct {
        confusableWith: u32,
        notAmbiguousInLocales: []const []const u8,
    },
    Invisible: void,
    NonBasicAscii: void,
};

const SimpleHighlightReason = enum {
    None,
    NonBasicASCII,
    Invisible,
    Ambiguous,
};

const MAX_RESULT_LENGTH = 1000;

fn isAllowedInvisibleCodePoint(code_point: u32) bool {
    return code_point == 0x20 or code_point == '\n' or code_point == '\t';
}

fn isAllowedInvisibleCharacter(character: []const u8) bool {
    return std.mem.eql(u8, character, " ") or std.mem.eql(u8, character, "\n") or std.mem.eql(u8, character, "\t");
}

fn decodeFirstCodePoint(str: []const u8) u32 {
    const length = std.unicode.utf8ByteSequenceLength(str[0]) catch return str[0];
    if (str.len < length) return str[0];
    return std.unicode.utf8Decode(str[0..length]) catch str[0];
}

const CodePointHighlighter = struct {
    allocator: Allocator,
    options: UnicodeHighlighterOptions,
    allowed_code_points: std.AutoHashMapUnmanaged(u32, void),
    ambiguous_characters: unicodeCharacters.AmbiguousCharacters,

    fn init(allocator: Allocator, options: UnicodeHighlighterOptions) !CodePointHighlighter {
        var allowed = std.AutoHashMapUnmanaged(u32, void){};
        errdefer allowed.deinit(allocator);
        for (options.allowedCodePoints) |code_point| {
            try allowed.put(allocator, code_point, {});
        }
        return .{
            .allocator = allocator,
            .options = options,
            .allowed_code_points = allowed,
            .ambiguous_characters = try unicodeCharacters.AmbiguousCharacters.getInstance(allocator, options.allowedLocales),
        };
    }

    fn deinit(self: *CodePointHighlighter) void {
        self.allowed_code_points.deinit(self.allocator);
        self.ambiguous_characters.deinit();
    }

    /// Returns the candidate code points, or `null` to signal "all non basic
    /// ASCII characters". The returned slice is owned by the caller.
    fn getCandidateCodePoints(self: *CodePointHighlighter, allocator: Allocator) !?[]u32 {
        if (self.options.nonBasicASCII) return null;

        var set = std.AutoHashMapUnmanaged(u32, void){};
        defer set.deinit(self.allocator);

        if (self.options.invisibleCharacters) {
            for (unicodeCharacters.InvisibleCharacters.codePoints()) |code_point| {
                if (!isAllowedInvisibleCodePoint(code_point)) {
                    try set.put(self.allocator, code_point, {});
                }
            }
        }

        if (self.options.ambiguousCharacters) {
            const confusables = try self.ambiguous_characters.getConfusableCodePoints(self.allocator);
            defer self.allocator.free(confusables);
            for (confusables) |code_point| {
                try set.put(self.allocator, code_point, {});
            }
        }

        var it = self.allowed_code_points.keyIterator();
        while (it.next()) |key| {
            _ = set.remove(key.*);
        }

        var result = try allocator.alloc(u32, set.count());
        var i: usize = 0;
        var key_it = set.keyIterator();
        while (key_it.next()) |key| : (i += 1) {
            result[i] = key.*;
        }
        std.mem.sort(u32, result, {}, std.sort.asc(u32));
        return result;
    }

    fn shouldHighlightNonBasicASCII(self: *CodePointHighlighter, character: []const u8, word_context: ?[]const u8) SimpleHighlightReason {
        const code_point = decodeFirstCodePoint(character);

        if (self.allowed_code_points.contains(code_point)) return .None;
        if (self.options.nonBasicASCII) return .NonBasicASCII;

        var has_basic_ascii_characters = false;
        var has_non_confusable_non_basic_ascii_character = false;
        if (word_context) |context| {
            var view = std.unicode.Utf8View.initUnchecked(context);
            var it = view.iterator();
            while (it.nextCodepointSlice()) |char_slice| {
                const char_code_point = decodeFirstCodePoint(char_slice);
                const is_basic_ascii = strings.isBasicASCII(char_slice);
                has_basic_ascii_characters = has_basic_ascii_characters or is_basic_ascii;

                if (!is_basic_ascii and
                    !self.ambiguous_characters.isAmbiguous(char_code_point) and
                    !unicodeCharacters.InvisibleCharacters.isInvisibleCharacter(char_code_point))
                {
                    has_non_confusable_non_basic_ascii_character = true;
                }
            }
        }

        if (!has_basic_ascii_characters and has_non_confusable_non_basic_ascii_character) {
            // Don't allow mixing weird looking characters with ASCII.
            return .None;
        }

        if (self.options.invisibleCharacters) {
            if (!isAllowedInvisibleCharacter(character) and unicodeCharacters.InvisibleCharacters.isInvisibleCharacter(code_point)) {
                return .Invisible;
            }
        }

        if (self.options.ambiguousCharacters) {
            if (self.ambiguous_characters.isAmbiguous(code_point)) {
                return .Ambiguous;
            }
        }

        return .None;
    }
};

/// Builds a `[...]` character class matching every given code point.
pub fn buildRegExpCharClassExpr(allocator: Allocator, code_points: []const u32) ![]u8 {
    var utf8 = ArrayList(u8).init(allocator);
    defer utf8.deinit();
    var buffer: [4]u8 = undefined;
    for (code_points) |code_point| {
        const length = std.unicode.utf8Encode(@intCast(code_point), &buffer) catch continue;
        try utf8.appendSlice(buffer[0..length]);
    }
    var escaped = try strings.escapeRegExpCharacters(allocator, utf8.items);
    defer escaped.deinit();
    return std.fmt.allocPrint(allocator, "[{s}]", .{escaped.items});
}

pub const UnicodeTextModelHighlighter = struct {
    pub fn computeUnicodeHighlights(
        allocator: Allocator,
        io: std.Io,
        model: IUnicodeCharacterSearcherTarget,
        options: UnicodeHighlighterOptions,
        range: ?Range,
    ) !IUnicodeHighlightsResult {
        const start_line = if (range) |r| r.startLineNumber else 1;
        const end_line = if (range) |r| r.endLineNumber else model.lineCount();

        var highlighter = try CodePointHighlighter.init(allocator, options);
        defer highlighter.deinit();

        const candidates = try highlighter.getCandidateCodePoints(allocator);
        defer if (candidates) |slice| allocator.free(slice);

        const pattern = if (candidates == null)
            try allocator.dupe(u8, "[^\\t\\n\\r\\x20-\\x7E]")
        else
            try buildRegExpCharClassExpr(allocator, candidates.?);
        defer allocator.free(pattern);

        var regex = try RegExp.init(pattern, .{});
        defer regex.deinit();

        var ranges = ArrayList(Range).init(allocator);
        errdefer ranges.deinit();
        var has_more = false;

        var ambiguous_character_count: usize = 0;
        var invisible_character_count: usize = 0;
        var non_basic_ascii_character_count: usize = 0;

        const word_definition = wordHelper.defaultWordRegExp();

        var line_number = start_line;
        outer: while (line_number <= end_line) : (line_number += 1) {
            const line_content = model.lineContent(line_number);
            const line_length = line_content.len;

            var search_offset: usize = 0;
            while (regex.searchFrom(line_content, search_offset)) |match| {
                defer match.deinit();
                var start_index = match.index();
                var end_index = match.index() + match.length();

                // Extend the range to cover the entire code point.
                while (start_index > 0 and start_index < line_content.len and isUtf8ContinuationByte(line_content[start_index])) {
                    start_index -= 1;
                }
                while (end_index < line_length and isUtf8ContinuationByte(line_content[end_index])) {
                    end_index += 1;
                }

                const str = line_content[start_index..end_index];
                var word: ?wordHelper.IWordAtPosition = wordHelper.getWordAtText(io, start_index + 1, word_definition, line_content, 0);
                if (word != null and word.?.endColumn <= start_index + 1) {
                    // The word does not include the problematic character.
                    word = null;
                }
                const highlight_reason = highlighter.shouldHighlightNonBasicASCII(str, if (word) |w| w.word else null);

                if (highlight_reason != .None) {
                    switch (highlight_reason) {
                        .Ambiguous => ambiguous_character_count += 1,
                        .Invisible => invisible_character_count += 1,
                        .NonBasicASCII => non_basic_ascii_character_count += 1,
                        .None => unreachable,
                    }

                    if (ranges.items.len >= MAX_RESULT_LENGTH) {
                        has_more = true;
                        break :outer;
                    }

                    try ranges.append(Range.init(line_number, start_index + 1, line_number, end_index + 1));
                }

                // Always advance by at least one byte, even for an empty match.
                search_offset = if (match.length() == 0) match.index() + 1 else end_index;
                if (search_offset >= line_length) break;
            }
        }

        return .{
            .allocator = allocator,
            .ranges = try ranges.toOwnedSlice(),
            .hasMore = has_more,
            .ambiguousCharacterCount = ambiguous_character_count,
            .invisibleCharacterCount = invisible_character_count,
            .nonBasicAsciiCharacterCount = non_basic_ascii_character_count,
        };
    }

    pub fn computeUnicodeHighlightReason(
        allocator: Allocator,
        character: []const u8,
        options: UnicodeHighlighterOptions,
    ) !?UnicodeHighlighterReason {
        var highlighter = try CodePointHighlighter.init(allocator, options);
        defer highlighter.deinit();

        const reason = highlighter.shouldHighlightNonBasicASCII(character, null);
        switch (reason) {
            .None => return null,
            .Invisible => return UnicodeHighlighterReason{ .Invisible = {} },
            .NonBasicASCII => return UnicodeHighlighterReason{ .NonBasicAscii = {} },
            .Ambiguous => {
                const code_point = decodeFirstCodePoint(character);
                const primary_confusable = highlighter.ambiguous_characters.getPrimaryConfusable(code_point) orelse return null;

                var not_ambiguous_in_locales = ArrayList([]const u8).init(allocator);
                errdefer not_ambiguous_in_locales.deinit();

                var locales = ArrayList([]const u8).init(allocator);
                defer locales.deinit();
                try locales.appendSlice(options.allowedLocales);

                for (unicodeCharacters.AmbiguousCharacters.getLocales()) |locale| {
                    try locales.append(locale);
                    var set = try unicodeCharacters.AmbiguousCharacters.getInstance(allocator, locales.items);
                    defer set.deinit();
                    if (!set.isAmbiguous(code_point)) {
                        try not_ambiguous_in_locales.append(locale);
                    }
                    _ = locales.pop();
                }

                return UnicodeHighlighterReason{ .Ambiguous = .{
                    .confusableWith = primary_confusable,
                    .notAmbiguousInLocales = try not_ambiguous_in_locales.toOwnedSlice(),
                } };
            },
        }
    }
};

fn isUtf8ContinuationByte(byte: u8) bool {
    return (byte & 0b1100_0000) == 0b1000_0000;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestModel = struct {
    lines: []const []const u8,

    fn getLineCount(context: *anyopaque) usize {
        const self: *TestModel = @ptrCast(@alignCast(context));
        return self.lines.len;
    }

    fn getLineContent(context: *anyopaque, line_number: usize) []const u8 {
        const self: *TestModel = @ptrCast(@alignCast(context));
        return self.lines[line_number - 1];
    }

    fn target(self: *TestModel) IUnicodeCharacterSearcherTarget {
        return .{
            .context = @ptrCast(self),
            .getLineCount = getLineCount,
            .getLineContent = getLineContent,
        };
    }
};

fn ambiguousOptions() UnicodeHighlighterOptions {
    return .{
        .nonBasicASCII = false,
        .ambiguousCharacters = true,
        .invisibleCharacters = false,
        .includeComments = true,
        .includeStrings = true,
    };
}

test "computeUnicodeHighlights finds ambiguous characters" {
    const allocator = testing.allocator;
    // Cyrillic "а" (U+0430) looks like ASCII "a".
    var model = TestModel{ .lines = &.{"let \u{0430} = 1;"} };

    var result = try UnicodeTextModelHighlighter.computeUnicodeHighlights(allocator, std.testing.io, model.target(), ambiguousOptions(), null);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.ranges.len);
    try testing.expectEqual(@as(usize, 1), result.ambiguousCharacterCount);
    try testing.expectEqual(@as(usize, 0), result.invisibleCharacterCount);
    try testing.expectEqual(@as(usize, 0), result.nonBasicAsciiCharacterCount);
    try testing.expect(!result.hasMore);
    // The reported range covers the whole code point, in bytes.
    try testing.expectEqual(@as(usize, 5), result.ranges[0].startColumn);
    try testing.expectEqual(@as(usize, 7), result.ranges[0].endColumn);
}

test "computeUnicodeHighlights ignores plain ASCII" {
    const allocator = testing.allocator;
    var model = TestModel{ .lines = &.{ "let a = 1;", "const b = 2;" } };

    var result = try UnicodeTextModelHighlighter.computeUnicodeHighlights(allocator, std.testing.io, model.target(), ambiguousOptions(), null);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.ranges.len);
    try testing.expectEqual(@as(usize, 0), result.ambiguousCharacterCount);
}

test "computeUnicodeHighlights finds invisible characters" {
    const allocator = testing.allocator;
    var model = TestModel{ .lines = &.{"a\u{200B}b"} };

    var options = ambiguousOptions();
    options.ambiguousCharacters = false;
    options.invisibleCharacters = true;

    var result = try UnicodeTextModelHighlighter.computeUnicodeHighlights(allocator, std.testing.io, model.target(), options, null);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.ranges.len);
    try testing.expectEqual(@as(usize, 1), result.invisibleCharacterCount);
    try testing.expectEqual(@as(usize, 2), result.ranges[0].startColumn);
    try testing.expectEqual(@as(usize, 5), result.ranges[0].endColumn);
}

test "computeUnicodeHighlights honours allowed code points" {
    const allocator = testing.allocator;
    var model = TestModel{ .lines = &.{"let \u{0430} = 1;"} };

    var options = ambiguousOptions();
    const allowed = [_]u32{0x0430};
    options.allowedCodePoints = &allowed;

    var result = try UnicodeTextModelHighlighter.computeUnicodeHighlights(allocator, std.testing.io, model.target(), options, null);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.ranges.len);
}

test "computeUnicodeHighlights respects the range" {
    const allocator = testing.allocator;
    var model = TestModel{ .lines = &.{
        "let \u{0430} = 1;",
        "let \u{0430} = 2;",
    } };

    var result = try UnicodeTextModelHighlighter.computeUnicodeHighlights(allocator, std.testing.io, model.target(), ambiguousOptions(), Range.init(2, 1, 2, 13));
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.ranges.len);
    try testing.expectEqual(@as(usize, 2), result.ranges[0].startLineNumber);
}

test "computeUnicodeHighlights treats mixing with ASCII as suspicious" {
    const allocator = testing.allocator;
    var model = TestModel{ .lines = &.{ "caf\u{00E9}", "caf\u{00E9} \u{0430}" } };

    var options = ambiguousOptions();
    options.nonBasicASCII = true;

    var result = try UnicodeTextModelHighlighter.computeUnicodeHighlights(allocator, std.testing.io, model.target(), options, null);
    defer result.deinit();

    // Every non basic ASCII code point is a candidate.
    try testing.expectEqual(@as(usize, 3), result.ranges.len);
    try testing.expectEqual(@as(usize, 3), result.nonBasicAsciiCharacterCount);
}

test "computeUnicodeHighlightReason classifies characters" {
    const allocator = testing.allocator;

    try testing.expect((try UnicodeTextModelHighlighter.computeUnicodeHighlightReason(allocator, "a", ambiguousOptions())) == null);

    var invisible_options = ambiguousOptions();
    invisible_options.invisibleCharacters = true;
    const invisible = (try UnicodeTextModelHighlighter.computeUnicodeHighlightReason(allocator, "\u{200B}", invisible_options)) orelse unreachable;
    try testing.expect(invisible == .Invisible);

    const ambiguous = (try UnicodeTextModelHighlighter.computeUnicodeHighlightReason(allocator, "\u{0430}", ambiguousOptions())) orelse unreachable;
    try testing.expect(ambiguous == .Ambiguous);
    try testing.expectEqual(@as(u32, 'a'), ambiguous.Ambiguous.confusableWith);
    defer allocator.free(ambiguous.Ambiguous.notAmbiguousInLocales);
    // Cyrillic is expected in the Russian locale, so it is not ambiguous there.
    var found_ru = false;
    for (ambiguous.Ambiguous.notAmbiguousInLocales) |locale| {
        if (std.mem.eql(u8, locale, "ru")) found_ru = true;
    }
    try testing.expect(found_ru);
}
