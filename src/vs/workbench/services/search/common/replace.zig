// Port of the replacement pattern in
// `src/vs/workbench/services/search/common/replace.ts`.
//
// The parser and case-preserving helpers already exist in the editor find
// port. This wrapper keeps the search query regex so capture groups can be
// resolved against a matched preview line, then delegates the replacement
// pieces to `replacePattern.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const search_types = @import("search.zig");
const PatternInfo = search_types.PatternInfo;
const strings = @import("../../../../base/common/strings.zig");
const RegExp = @import("../../../../../support/regexp.zig").RegExp;
const find_replace = @import("../../../../editor/contrib/find/browser/replacePattern.zig");

pub const ReplacePattern = struct {
    allocator: Allocator,
    raw: []u8,
    regex: RegExp,
    pieces: find_replace.ReplacePattern,

    pub fn init(allocator: Allocator, replace_string: []const u8, info: PatternInfo) !ReplacePattern {
        const raw = try allocator.dupe(u8, replace_string);
        errdefer allocator.free(raw);

        const pieces = try find_replace.parseReplaceString(allocator, replace_string);
        errdefer {
            var value = pieces;
            value.deinit();
        }

        const source_pattern = if (info.pattern.len == 0) "a^" else info.pattern;
        const multiline = if (info.is_regex)
            @import("../../../../editor/common/model/textModelSearch.zig").isMultilineRegexSource(source_pattern)
        else
            strings.containsLF(source_pattern);
        const regex = try strings.createRegExp(allocator, source_pattern, info.is_regex, info.is_word_match, .{
            .ignore_case = !info.is_case_sensitive,
            .singleline = !multiline,
        });

        return .{
            .allocator = allocator,
            .raw = raw,
            .regex = regex,
            .pieces = pieces,
        };
    }

    pub fn deinit(self: *ReplacePattern) void {
        self.allocator.free(self.raw);
        self.regex.deinit();
        self.pieces.deinit();
    }

    pub fn hasParameters(self: *const ReplacePattern) bool {
        return self.pieces.hasReplacementPatterns();
    }

    pub fn pattern(self: *const ReplacePattern) []const u8 {
        return self.raw;
    }

    /// Returns the replacement for the first match in `text`, or null when the
    /// pattern does not match. The returned string is owned by the caller.
    pub fn getReplaceString(
        self: *const ReplacePattern,
        allocator: Allocator,
        text: []const u8,
        preserve_case: bool,
    ) !?[]u8 {
        const found = self.regex.search(text) orelse return null;
        defer found.deinit();

        const count = found.numberOfGroups();
        const matches = try allocator.alloc([]const u8, count);
        defer allocator.free(matches);
        for (0..count) |index| {
            matches[index] = found.groupNOrNull(index) orelse "";
        }

        if (self.hasParameters()) {
            return try self.pieces.buildReplaceString(allocator, matches, preserve_case);
        }
        return try self.pieces.buildReplaceString(allocator, matches, preserve_case);
    }
};

test "ReplacePattern: groups and case operations" {
    const allocator = std.testing.allocator;
    var pattern = try ReplacePattern.init(allocator, "import * as $1 from '$2';", .{
        .pattern = "let\\s+(\\w+)\\s*=\\s*require\\s*\\(\\s*['\"]([\\w.\\-/]+)\\s*['\"]\\s*\\)\\s*",
        .is_regex = true,
    });
    defer pattern.deinit();

    const replaced = (try pattern.getReplaceString(allocator, "let fs = require('fs')", false)).?;
    defer allocator.free(replaced);
    try std.testing.expectEqualStrings("import * as fs from 'fs';", replaced);
}

test "ReplacePattern: static, group and case operations" {
    const allocator = std.testing.allocator;
    var static_pattern = try ReplacePattern.init(allocator, "omega", .{ .pattern = "alpha" });
    defer static_pattern.deinit();
    const static_result = (try static_pattern.getReplaceString(allocator, "alpha", false)).?;
    defer allocator.free(static_result);
    try std.testing.expectEqualStrings("omega", static_result);

    var group_pattern = try ReplacePattern.init(allocator, "$2-$1", .{ .pattern = "(foo)\\s+(bar)", .is_regex = true });
    defer group_pattern.deinit();
    const group_result = (try group_pattern.getReplaceString(allocator, "foo bar", false)).?;
    defer allocator.free(group_result);
    try std.testing.expectEqualStrings("bar-foo", group_result);
}
