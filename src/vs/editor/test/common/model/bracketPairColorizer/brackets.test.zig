// Port of the `Basic` case from
// `src/vs/editor/test/common/model/bracketPairColorizer/brackets.test.ts`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const LanguageConfiguration = @import("../../../../common/languages/languageConfiguration.zig");
const CharacterPair = LanguageConfiguration.CharacterPair;
const brackets_mod = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/brackets.zig");
const buildLanguageBrackets = brackets_mod.buildLanguageBrackets;
const tokenizer_mod = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/tokenizer.zig");
const tokenForText = tokenizer_mod.tokenForText;
const StringIdProvider = tokenizer_mod.StringIdProvider;
const TokenKind = tokenizer_mod.TokenKind;

fn keyForId(ids: *StringIdProvider, id: usize) ?[]const u8 {
    var it = ids.ids.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == id) return entry.key_ptr.*;
    }
    return null;
}

test "brackets: Basic" {
    const allocator = std.testing.allocator;
    const language = "testMode1";

    var pairs = [_]CharacterPair{
        .{ "{", "}" },
        .{ "[", "]" },
        .{ "(", ")" },
        .{ "begin", "end" },
        .{ "case", "endcase" },
        .{ "casez", "endcase" },
        .{ "\\left(", "\\right)" },
        .{ "\\left(", "\\right." },
        .{ "\\left.", "\\right)" },
        .{ "\\left[", "\\right]" },
        .{ "\\left[", "\\right." },
        .{ "\\left.", "\\right]" },
    };
    var config = LanguageConfiguration.empty();
    config.brackets = &pairs;

    var brackets = try buildLanguageBrackets(allocator, config);
    defer {
        brackets.defs.deinit();
        brackets.all.deinit();
    }

    var ids = StringIdProvider.init(allocator);
    defer ids.deinit();

    const Expected = struct {
        text: []const u8,
        length: usize,
        kind: TokenKind,
        bracket_key: []const u8,
        bracket_keys: []const []const u8,
    };
    const expected = [_]Expected{
        .{ .text = "{", .length = 1, .kind = .opening_bracket, .bracket_key = "{", .bracket_keys = &.{"{"} },
        .{ .text = "[", .length = 1, .kind = .opening_bracket, .bracket_key = "[", .bracket_keys = &.{"["} },
        .{ .text = "(", .length = 1, .kind = .opening_bracket, .bracket_key = "(", .bracket_keys = &.{"("} },
        .{ .text = "begin", .length = 5, .kind = .opening_bracket, .bracket_key = "begin", .bracket_keys = &.{"begin"} },
        .{ .text = "case", .length = 4, .kind = .opening_bracket, .bracket_key = "case", .bracket_keys = &.{"case"} },
        .{ .text = "casez", .length = 5, .kind = .opening_bracket, .bracket_key = "casez", .bracket_keys = &.{"casez"} },
        .{ .text = "\\left(", .length = 6, .kind = .opening_bracket, .bracket_key = "\\left(", .bracket_keys = &.{"\\left("} },
        .{ .text = "\\left.", .length = 6, .kind = .opening_bracket, .bracket_key = "\\left.", .bracket_keys = &.{"\\left."} },
        .{ .text = "\\left[", .length = 6, .kind = .opening_bracket, .bracket_key = "\\left[", .bracket_keys = &.{"\\left["} },

        .{ .text = "}", .length = 1, .kind = .closing_bracket, .bracket_key = "{", .bracket_keys = &.{"{"} },
        .{ .text = "]", .length = 1, .kind = .closing_bracket, .bracket_key = "[", .bracket_keys = &.{"["} },
        .{ .text = ")", .length = 1, .kind = .closing_bracket, .bracket_key = "(", .bracket_keys = &.{"("} },
        .{ .text = "end", .length = 3, .kind = .closing_bracket, .bracket_key = "begin", .bracket_keys = &.{"begin"} },
        .{ .text = "endcase", .length = 7, .kind = .closing_bracket, .bracket_key = "case", .bracket_keys = &.{ "case", "casez" } },
        .{ .text = "\\right)", .length = 7, .kind = .closing_bracket, .bracket_key = "\\left(", .bracket_keys = &.{ "\\left(", "\\left." } },
        .{ .text = "\\right.", .length = 7, .kind = .closing_bracket, .bracket_key = "\\left(", .bracket_keys = &.{ "\\left(", "\\left[" } },
        .{ .text = "\\right]", .length = 7, .kind = .closing_bracket, .bracket_key = "\\left[", .bracket_keys = &.{ "\\left[", "\\left." } },
    };

    for (expected) |want| {
        const token = (try tokenForText(allocator, &ids, language, &brackets, want.text, null)) orelse {
            std.debug.print("missing token for {s}\n", .{want.text});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(want.length, token.length);
        try std.testing.expectEqual(want.kind, token.kind);

        const bracket_key = keyForId(&ids, token.bracket_id).?;
        try std.testing.expectEqualStrings(want.bracket_key, bracket_key[language.len + 3 ..]);

        var actual_keys = ArrayList([]const u8).init(allocator);
        defer actual_keys.deinit();
        var it = ids.ids.iterator();
        while (it.next()) |entry| {
            if (token.bracket_ids.has(entry.value_ptr.*)) try actual_keys.append(entry.key_ptr.*[language.len + 3 ..]);
        }
        try std.testing.expectEqual(want.bracket_keys.len, actual_keys.items.len);
        for (want.bracket_keys) |key| {
            var found = false;
            for (actual_keys.items) |actual| {
                if (std.mem.eql(u8, key, actual)) found = true;
            }
            try std.testing.expect(found);
        }
    }
}
