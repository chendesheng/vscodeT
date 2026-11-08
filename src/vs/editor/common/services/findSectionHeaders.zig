// Port of `src/vs/editor/common/services/findSectionHeaders.ts`.
//
// The upstream code works on UTF-16 strings and JavaScript regular expressions
// with the `gdm` flags. Here lines are UTF-8 byte slices, Oniguruma's default
// anchors are JavaScript's `m` flag and `Options.multiline` is JavaScript's `s`
// flag. Match offsets are bytes, not code units.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const strings = @import("../../../base/common/strings.zig");
const re = @import("../../../../support/regexp.zig");
const RegExp = re.RegExp;

const Range = @import("../core/range.zig").Range;
const languageConfiguration = @import("../languages/languageConfiguration.zig");
const FoldingRules = languageConfiguration.FoldingRules;
const isMultilineRegexSource = @import("../model/textModelSearch.zig").isMultilineRegexSource;

/// The part of a text model that section header search needs.
pub const ISectionHeaderFinderTarget = struct {
    context: *anyopaque,
    getLineCount: *const fn (context: *anyopaque) usize,
    /// The content of `line_number` (1 based), without its line terminator.
    /// Borrowed for the duration of the call.
    getLineContent: *const fn (context: *anyopaque, line_number: usize) []const u8,

    pub fn lineCount(self: ISectionHeaderFinderTarget) usize {
        return self.getLineCount(self.context);
    }

    pub fn lineContent(self: ISectionHeaderFinderTarget, line_number: usize) []const u8 {
        return self.getLineContent(self.context, line_number);
    }
};

pub const FindSectionHeaderOptions = struct {
    foldingRules: ?FoldingRules = null,
    findRegionSectionHeaders: bool,
    findMarkSectionHeaders: bool,
    markSectionHeaderRegex: []const u8,
    /// The tokens that open and close a block comment in the model's language
    /// (e.g. `<!--` and `-->`). When a mark section header is inside a block
    /// comment that closes at the end of the header, the closing token is
    /// comment syntax and not part of the label.
    blockCommentStartToken: ?[]const u8 = null,
    blockCommentEndToken: ?[]const u8 = null,
};

pub const SectionHeader = struct {
    /// The location of the header text in the text model.
    range: Range,
    /// The section header text. Owned by the returned list.
    text: []const u8,
    /// Whether the section header includes a separator line.
    hasSeparatorLine: bool,
    /// This section should be omitted before rendering if it's not in a comment.
    shouldBeInComments: bool,
};

/// Frees the header texts and the array itself.
pub fn freeSectionHeaders(allocator: Allocator, headers: []SectionHeader) void {
    for (headers) |header| allocator.free(header.text);
    if (headers.len > 0) allocator.free(headers);
}

const CHUNK_SIZE: usize = 100;
const MAX_SECTION_LINES: usize = 5;
const whitespace = " \t\n\r\x0b\x0c";

/// Finds the section headers of the model, both the region headers (`// #region`)
/// and the mark headers (`// MARK: label`).
pub fn findSectionHeaders(
    allocator: Allocator,
    model: ISectionHeaderFinderTarget,
    options: *const FindSectionHeaderOptions,
) ![]SectionHeader {
    var headers = ArrayList(SectionHeader).init(allocator);
    errdefer {
        for (headers.items) |header| allocator.free(header.text);
        headers.deinit();
    }
    if (options.findRegionSectionHeaders and options.foldingRules != null and options.foldingRules.?.markers != null) {
        try collectRegionHeaders(allocator, &headers, model, options);
    }
    if (options.findMarkSectionHeaders) {
        try collectMarkHeaders(allocator, &headers, model, options);
    }
    return headers.toOwnedSlice();
}

/// Port of `getHeaderText`: trims the text, remembers whether it started with a
/// separator line and strips the dashes of that separator.
fn getHeaderText(allocator: Allocator, text: []const u8) !struct { text: []u8, hasSeparatorLine: bool } {
    const trimmed = std.mem.trim(u8, text, whitespace);
    const has_separator_line = trimmed.len > 0 and trimmed[0] == '-';
    var start: usize = 0;
    while (start < trimmed.len and trimmed[start] == '-') start += 1;
    var end = trimmed.len;
    while (end > start and trimmed[end - 1] == '-') end -= 1;
    return .{ .text = try allocator.dupe(u8, trimmed[start..end]), .hasSeparatorLine = has_separator_line };
}

fn collectRegionHeaders(
    allocator: Allocator,
    headers: *ArrayList(SectionHeader),
    model: ISectionHeaderFinderTarget,
    options: *const FindSectionHeaderOptions,
) !void {
    const markers = options.foldingRules.?.markers.?;
    const end_line_number = model.lineCount();
    var line_number: usize = 1;
    while (line_number <= end_line_number) : (line_number += 1) {
        const line_content = model.lineContent(line_number);
        const result = markers.start.search(line_content) orelse continue;
        defer result.deinit();

        const matched_length = result.length();
        const range = Range.init(line_number, matched_length + 1, line_number, line_content.len + 1);
        if (range.endColumn <= range.startColumn) continue;

        const header_text = try getHeaderText(allocator, line_content[matched_length..]);
        if (header_text.text.len == 0 and !header_text.hasSeparatorLine) {
            allocator.free(header_text.text);
            continue;
        }
        try headers.append(.{
            .range = range,
            .text = header_text.text,
            .hasSeparatorLine = header_text.hasSeparatorLine,
            .shouldBeInComments = false,
        });
    }
}

fn collectMarkHeaders(
    allocator: Allocator,
    headers: *ArrayList(SectionHeader),
    model: ISectionHeaderFinderTarget,
    options: *const FindSectionHeaderOptions,
) !void {
    const end_line_number = model.lineCount();

    // Validate regex to prevent infinite loops
    if (std.mem.trim(u8, options.markSectionHeaderRegex, whitespace).len == 0) {
        return;
    }

    // JavaScript's `s` flag makes the dot match newlines; `m` is Oniguruma's
    // default anchor behaviour, and `g`/`d` are implied by the iteration API.
    const dot_all = isMultilineRegexSource(options.markSectionHeaderRegex);
    var regex = try RegExp.init(options.markSectionHeaderRegex, .{ .multiline = dot_all });
    defer regex.deinit();

    // Check if the regex would lead to an endless loop
    if (strings.regExpLeadsToEndlessLoop(&regex, options.markSectionHeaderRegex)) {
        return;
    }

    // Process text in overlapping chunks for better performance
    var start_line: usize = 1;
    while (start_line <= end_line_number) : (start_line += CHUNK_SIZE - MAX_SECTION_LINES) {
        const end_line = @min(start_line + CHUNK_SIZE - 1, end_line_number);
        var text = ArrayList(u8).init(allocator);
        defer text.deinit();
        var line = start_line;
        while (line <= end_line) : (line += 1) {
            if (line > start_line) try text.append('\n');
            try text.appendSlice(model.lineContent(line));
        }

        var offset: usize = 0;
        while (offset < text.items.len) {
            const result = regex.searchFrom(text.items, offset) orelse break;
            defer result.deinit();
            try processMarkMatch(allocator, headers, options, start_line, text.items, &result);
            // JavaScript's `exec` with the `g` flag never advances on an empty
            // match, which is why upstream guards against such regexes. Advance
            // by at least one byte so an empty match cannot spin here.
            offset = result.index() + @max(result.length(), 1);
        }
    }
}

fn processMarkMatch(
    allocator: Allocator,
    headers: *ArrayList(SectionHeader),
    options: *const FindSectionHeaderOptions,
    chunk_start_line: usize,
    text: []const u8,
    result: *const re.SearchResult,
) !void {
    const match_index = result.index();
    const match_length = result.length();

    // Calculate which line this match starts on by counting newlines before it
    const preceding_text = text[0..match_index];
    var line_offset: usize = 0;
    for (preceding_text) |byte| {
        if (byte == '\n') line_offset += 1;
    }
    const line_number = chunk_start_line + line_offset;

    // Calculate match height to check overlap properly
    const match_text = text[match_index .. match_index + match_length];
    var match_height: usize = 1;
    for (match_text) |byte| {
        if (byte == '\n') match_height += 1;
    }
    const match_end_line = line_number + match_height - 1;

    // Calculate start column - need to find the start of the line containing the match
    const line_start_index: usize = if (std.mem.lastIndexOfScalar(u8, preceding_text, '\n')) |newline| newline + 1 else 0;
    const start_column = match_index - line_start_index + 1;

    // Calculate end column - need to handle multi-line matches
    const last_match_line = if (std.mem.lastIndexOfScalar(u8, match_text, '\n')) |newline|
        match_text[newline + 1 ..]
    else
        match_text;
    const end_column = if (match_height == 1) start_column + match_length else last_match_line.len + 1;

    const range = Range.init(line_number, start_column, match_end_line, end_column);

    const label_indices = result.groupRangeNamed("label");
    const separator_indices = result.groupRangeNamed("separator");
    var label: []const u8 = if (label_indices) |indices| text[indices[0]..indices[1]] else "";
    var separator: []const u8 = if (separator_indices) |indices| text[indices[0]..indices[1]] else "";

    if (options.blockCommentStartToken) |block_comment_start_token| {
        if (options.blockCommentEndToken) |block_comment_end_token| {
            // The comment context is determined right before the captured text, because a
            // custom regex may consume the comment start token itself, e.g.
            // `^<!--\s*MARK:\s*(?<label>.*)$`
            const captures_start = @min(
                @min(
                    if (separator_indices) |indices| indices[0] else std.math.maxInt(usize),
                    if (label_indices) |indices| indices[0] else std.math.maxInt(usize),
                ),
                match_index + match_length,
            );
            const captures_line_start: usize = if (captures_start == 0)
                0
            else if (std.mem.lastIndexOfScalar(u8, text[0..captures_start], '\n')) |newline|
                newline + 1
            else
                0;
            if (captures_line_start <= captures_start and isInsideBlockComment(
                text[captures_line_start..captures_start],
                block_comment_start_token,
                block_comment_end_token,
            )) {
                const captures_are_contiguous = separator_indices != null and
                    label_indices != null and
                    separator_indices.?[1] == label_indices.?[0];
                const stripped = try stripBlockCommentEnd(
                    allocator,
                    label,
                    separator,
                    block_comment_end_token,
                    captures_are_contiguous,
                );
                defer {
                    if (stripped.owned_separator) |owned| allocator.free(owned);
                }
                label = stripped.label;
                separator = stripped.separator;
            }
        }
    }

    const has_separator_line = separator.len != 0;
    if (label.len == 0 and !has_separator_line) return;

    // only push if the previous one doesn't have this same line
    if (headers.items.len > 0 and headers.items[headers.items.len - 1].range.endLineNumber >= line_number) {
        return;
    }

    try headers.append(.{
        .range = range,
        .text = try allocator.dupe(u8, label),
        .hasSeparatorLine = has_separator_line,
        .shouldBeInComments = true,
    });
}

/// Whether the text that precedes the captured header on its line leaves a
/// block comment open, e.g. `<!-- ` in `<!-- MARK: Section -->`, but not
/// `// ` in `// MARK: Regex /foo.*\/`.
/// The tokens are matched in order, so identical start and end tokens (e.g.
/// `"""`) are supported.
fn isInsideBlockComment(line_prefix: []const u8, block_comment_start_token: []const u8, block_comment_end_token: []const u8) bool {
    if (block_comment_start_token.len == 0 or block_comment_end_token.len == 0) {
        return false;
    }
    var is_open = false;
    var offset: usize = 0;
    while (offset < line_prefix.len) {
        const token = if (is_open) block_comment_end_token else block_comment_start_token;
        const index = std.mem.indexOfPos(u8, line_prefix, offset, token) orelse break;
        is_open = !is_open;
        offset = index + token.len;
    }
    return is_open;
}

/// Removes the token that closes the enclosing block comment (e.g. `-->` in
/// `<!-- MARK: Section -->`) from the end of a mark section header.
fn stripBlockCommentEnd(
    allocator: Allocator,
    label: []const u8,
    separator: []const u8,
    block_comment_end_token: []const u8,
    captures_are_contiguous: bool,
) !StrippedHeader {
    const trimmed_label = std.mem.trimEnd(u8, label, whitespace);
    if (std.mem.endsWith(u8, trimmed_label, block_comment_end_token)) {
        return .{
            .label = std.mem.trimEnd(u8, trimmed_label[0 .. trimmed_label.len - block_comment_end_token.len], whitespace),
            .separator = separator,
        };
    }
    if (captures_are_contiguous and trimmed_label.len < block_comment_end_token.len) {
        // The token was split across the separator and the label, e.g. `<!-- MARK: -->`
        const combined = try std.mem.concat(allocator, u8, &.{ separator, trimmed_label });
        defer allocator.free(combined);
        if (std.mem.endsWith(u8, combined, block_comment_end_token)) {
            const remaining_separator = combined[0 .. combined.len - block_comment_end_token.len];
            const trimmed_separator = std.mem.trim(u8, remaining_separator, whitespace);
            if (trimmed_separator.len == 0) {
                return .{ .label = &.{}, .separator = &.{} };
            }
            const owned = try allocator.dupe(u8, remaining_separator);
            return .{ .label = &.{}, .separator = owned, .owned_separator = owned };
        }
    }
    return .{ .label = label, .separator = separator };
}

const StrippedHeader = struct {
    label: []const u8,
    separator: []const u8,
    /// Set when `separator` was allocated by `stripBlockCommentEnd`.
    owned_separator: ?[]u8 = null,
};

const TestTarget = struct {
    lines: []const []const u8,

    fn target(self: *TestTarget) ISectionHeaderFinderTarget {
        return .{ .context = self, .getLineCount = getLineCount, .getLineContent = getLineContent };
    }

    fn getLineCount(context: *anyopaque) usize {
        const self: *TestTarget = @ptrCast(@alignCast(context));
        return self.lines.len;
    }

    fn getLineContent(context: *anyopaque, line_number: usize) []const u8 {
        const self: *TestTarget = @ptrCast(@alignCast(context));
        return self.lines[line_number - 1];
    }
};

fn expectHeader(header: SectionHeader, text: []const u8, start_line: usize, has_separator_line: bool, in_comments: bool) !void {
    try std.testing.expectEqualStrings(text, header.text);
    try std.testing.expectEqual(start_line, header.range.startLineNumber);
    try std.testing.expectEqual(has_separator_line, header.hasSeparatorLine);
    try std.testing.expectEqual(in_comments, header.shouldBeInComments);
}

test "findSectionHeaders: region headers" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{
        "// #region Section A",
        "let a = 1;",
        "// #endregion",
        "// #region ----",
        "// #endregion",
    };
    var target = TestTarget{ .lines = &lines };

    var start_re = try RegExp.init("^\\s*//\\s*#region\\b", .{});
    defer start_re.deinit();
    var end_re = try RegExp.init("^\\s*//\\s*#endregion\\b", .{});
    defer end_re.deinit();

    const options = FindSectionHeaderOptions{
        .foldingRules = .{ .offSide = null, .markers = .{ .start = start_re, .end = end_re } },
        .findRegionSectionHeaders = true,
        .findMarkSectionHeaders = false,
        .markSectionHeaderRegex = "",
    };
    const headers = try findSectionHeaders(allocator, target.target(), &options);
    defer freeSectionHeaders(allocator, headers);

    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try expectHeader(headers[0], "Section A", 1, false, false);
    // The text starts right after the matched region marker.
    try std.testing.expectEqual(@as(usize, 11), headers[0].range.startColumn);
    try std.testing.expectEqual(@as(usize, 21), headers[0].range.endColumn);
    // A header with only a separator line has no text but is still a header.
    try expectHeader(headers[1], "", 4, true, false);
}

test "findSectionHeaders: region headers need folding rules" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{"// #region Section A"};
    var target = TestTarget{ .lines = &lines };
    const options = FindSectionHeaderOptions{
        .findRegionSectionHeaders = true,
        .findMarkSectionHeaders = false,
        .markSectionHeaderRegex = "",
    };
    const headers = try findSectionHeaders(allocator, target.target(), &options);
    defer freeSectionHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 0), headers.len);
}

test "findSectionHeaders: mark headers" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{
        "let a = 1;",
        "// MARK: First",
        "// MARK: Second",
        "let b = 2;",
        "// MARK: Third",
    };
    var target = TestTarget{ .lines = &lines };
    const options = FindSectionHeaderOptions{
        .findRegionSectionHeaders = false,
        .findMarkSectionHeaders = true,
        .markSectionHeaderRegex = "//\\s*MARK:\\s*(?<label>.*)",
    };
    const headers = try findSectionHeaders(allocator, target.target(), &options);
    defer freeSectionHeaders(allocator, headers);

    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try expectHeader(headers[0], "First", 2, false, true);
    try std.testing.expectEqual(@as(usize, 1), headers[0].range.startColumn);
    try std.testing.expectEqual(@as(usize, 15), headers[0].range.endColumn);
    try expectHeader(headers[1], "Second", 3, false, true);
    try expectHeader(headers[2], "Third", 5, false, true);
}

test "findSectionHeaders: mark headers are de-duplicated per line" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{
        "// MARK: First",
        "// MARK: Second",
    };
    var target = TestTarget{ .lines = &lines };
    const options = FindSectionHeaderOptions{
        .findRegionSectionHeaders = false,
        .findMarkSectionHeaders = true,
        .markSectionHeaderRegex = "(?<label>MARK: \\w+)",
    };
    const headers = try findSectionHeaders(allocator, target.target(), &options);
    defer freeSectionHeaders(allocator, headers);
    // Both matches are on distinct lines, so both survive.
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try expectHeader(headers[0], "MARK: First", 1, false, true);
}

test "findSectionHeaders: mark header with a separator capture" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{"// MARK: -----"};
    var target = TestTarget{ .lines = &lines };
    const options = FindSectionHeaderOptions{
        .findRegionSectionHeaders = false,
        .findMarkSectionHeaders = true,
        .markSectionHeaderRegex = "MARK:\\s*(?<label>[^-]*)(?<separator>-*)",
    };
    const headers = try findSectionHeaders(allocator, target.target(), &options);
    defer freeSectionHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try expectHeader(headers[0], "", 1, true, true);
}

test "findSectionHeaders: strips the closing block comment token" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{
        "<!-- MARK: Section -->",
        "<!-- MARK: ---- -->",
    };
    var target = TestTarget{ .lines = &lines };
    const options = FindSectionHeaderOptions{
        .findRegionSectionHeaders = false,
        .findMarkSectionHeaders = true,
        .markSectionHeaderRegex = "^<!--\\s*MARK:\\s*(?<label>.*)$",
        .blockCommentStartToken = "<!--",
        .blockCommentEndToken = "-->",
    };
    const headers = try findSectionHeaders(allocator, target.target(), &options);
    defer freeSectionHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try expectHeader(headers[0], "Section", 1, false, true);
    try expectHeader(headers[1], "----", 2, false, true);
}

test "findSectionHeaders: keeps block comment tokens of other languages" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{"// MARK: Regex /foo.*\\/"};
    var target = TestTarget{ .lines = &lines };
    const options = FindSectionHeaderOptions{
        .findRegionSectionHeaders = false,
        .findMarkSectionHeaders = true,
        .markSectionHeaderRegex = "MARK:\\s*(?<label>.*)",
        .blockCommentStartToken = "<!--",
        .blockCommentEndToken = "-->",
    };
    const headers = try findSectionHeaders(allocator, target.target(), &options);
    defer freeSectionHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try expectHeader(headers[0], "Regex /foo.*\\/", 1, false, true);
}

test "findSectionHeaders: multi line mark headers" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{
        "MARK: one",
        "two END",
    };
    var target = TestTarget{ .lines = &lines };
    const dot_all_options = FindSectionHeaderOptions{
        .findRegionSectionHeaders = false,
        .findMarkSectionHeaders = true,
        .markSectionHeaderRegex = "MARK:(?<label>.*\\n.*)",
    };
    const headers = try findSectionHeaders(allocator, target.target(), &dot_all_options);
    defer freeSectionHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try expectHeader(headers[0], " one\ntwo END", 1, false, true);
    try std.testing.expectEqual(@as(usize, 2), headers[0].range.endLineNumber);
    try std.testing.expectEqual(@as(usize, 8), headers[0].range.endColumn);
}

test "findSectionHeaders: rejects a regex that would loop forever" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{"MARK: one"};
    var target = TestTarget{ .lines = &lines };
    const options = FindSectionHeaderOptions{
        .findRegionSectionHeaders = false,
        .findMarkSectionHeaders = true,
        .markSectionHeaderRegex = "a*",
    };
    const headers = try findSectionHeaders(allocator, target.target(), &options);
    defer freeSectionHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 0), headers.len);
}

test "findSectionHeaders: empty mark regex finds nothing" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{"MARK: one"};
    var target = TestTarget{ .lines = &lines };
    const options = FindSectionHeaderOptions{
        .findRegionSectionHeaders = false,
        .findMarkSectionHeaders = true,
        .markSectionHeaderRegex = "   ",
    };
    const headers = try findSectionHeaders(allocator, target.target(), &options);
    defer freeSectionHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 0), headers.len);
}
