// Port of `src/vs/editor/test/common/modes/languageConfiguration.test.ts`.
//
// Terminal adaptation: the upstream `TestLanguageConfigurationService` is the
// ported `LanguageConfigurationRegistry` directly; `dispose` is called on the
// registration value instead of an `IDisposable`.
const std = @import("std");
const language_configuration = @import("../../../common/languages/languageConfiguration.zig");
const registry_module = @import("../../../common/languages/languageConfigurationRegistry.zig");
const encoded_token_attributes = @import("../../../common/encodedTokenAttributes.zig");

const StandardAutoClosingPairConditional = language_configuration.StandardAutoClosingPairConditional;
const StandardTokenType = encoded_token_attributes.StandardTokenType;
const LanguageConfigurationRegistry = registry_module.LanguageConfigurationRegistry;

fn conditional(not_in: ?[]const []const u8) StandardAutoClosingPairConditional {
    return StandardAutoClosingPairConditional.init(.{
        .open = "{",
        .close = "}",
        .notIn = not_in,
    });
}

fn expectOK(
    value: *const StandardAutoClosingPairConditional,
    other: bool,
    comment: bool,
    string: bool,
    regex: bool,
) !void {
    try std.testing.expectEqual(other, value.isOK(.Other));
    try std.testing.expectEqual(comment, value.isOK(.Comment));
    try std.testing.expectEqual(string, value.isOK(.String));
    try std.testing.expectEqual(regex, value.isOK(.RegEx));
}

test "Missing notIn" {
    const value = conditional(null);
    try expectOK(&value, true, true, true, true);
}

test "Empty notIn" {
    const value = conditional(&.{});
    try expectOK(&value, true, true, true, true);
}

test "Invalid notIn" {
    const value = conditional(&.{"bla"});
    try expectOK(&value, true, true, true, true);
}

test "notIn in strings" {
    const value = conditional(&.{"string"});
    try expectOK(&value, true, true, false, true);
}

test "notIn in comments" {
    const value = conditional(&.{"comment"});
    try expectOK(&value, true, false, true, true);
}

test "notIn in regex" {
    const value = conditional(&.{"regex"});
    try expectOK(&value, true, true, true, false);
}

test "notIn in strings nor comments" {
    const value = conditional(&.{ "string", "comment" });
    try expectOK(&value, true, false, false, true);
}

test "notIn in strings nor regex" {
    const value = conditional(&.{ "string", "regex" });
    try expectOK(&value, true, true, false, false);
}

test "notIn in comments nor regex" {
    const value = conditional(&.{ "comment", "regex" });
    try expectOK(&value, true, false, true, false);
}

test "notIn in strings, comments nor regex" {
    const value = conditional(&.{ "string", "comment", "regex" });
    try expectOK(&value, true, false, false, false);
}

test "language configurations priorities" {
    const allocator = std.testing.allocator;
    var registry = try LanguageConfigurationRegistry.init(allocator);
    defer registry.deinit();

    const id = "testLang1";
    var first = try registry.register(id, .{
        .comments = .{ .lineComment = .{ .comment = "1", .noIndent = null }, .blockComment = null },
        .brackets = null,
        .wordPattern = null,
        .indentationRules = null,
        .onEnterRules = null,
        .autoClosingPairs = null,
        .surroundingPairs = null,
        .colorizedBracketPairs = null,
        .autoCloseBefore = null,
        .folding = null,
    }, 100);
    defer first.dispose();

    var second = try registry.register(id, .{
        .comments = .{ .lineComment = .{ .comment = "2", .noIndent = null }, .blockComment = null },
        .brackets = null,
        .wordPattern = null,
        .indentationRules = null,
        .onEnterRules = null,
        .autoClosingPairs = null,
        .surroundingPairs = null,
        .colorizedBracketPairs = null,
        .autoCloseBefore = null,
        .folding = null,
    }, 10);
    defer second.dispose();

    const config = registry.getLanguageConfiguration(id) orelse return error.MissingConfiguration;
    try std.testing.expectEqualStrings("1", config.comments.?.lineCommentToken.?);

    first.dispose();
    try std.testing.expectEqual(@as(usize, 1), registry.entryCount(id));
    const after = registry.getLanguageConfiguration(id) orelse return error.MissingConfiguration;
    try std.testing.expectEqualStrings("2", after.comments.?.lineCommentToken.?);
}
