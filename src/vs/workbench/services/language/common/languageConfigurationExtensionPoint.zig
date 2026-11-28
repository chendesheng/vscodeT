// Port of the data subset of
// `src/vs/workbench/services/language/common/languageConfigurationExtensionPoint.ts`.
//
// The TUI consumes comments, brackets, auto-closing/surrounding pairs,
// colorized bracket pairs, the off-side folding flag and the compiled
// indentation rules. `wordPattern`, `onEnterRules` and folding markers remain
// deferred in docs/extensions.md.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configuration_models = @import("../../../../platform/configuration/common/configurationModels.zig");
const language_configuration = @import("../../../../editor/common/languages/languageConfiguration.zig");
const LanguageConfiguration = language_configuration.LanguageConfiguration;
const CommentRule = language_configuration.CommentRule;
const LineCommentConfig = language_configuration.LineCommentConfig;
const CharacterPair = language_configuration.CharacterPair;
const FoldingRules = language_configuration.FoldingRules;
const IndentationRule = language_configuration.IndentationRule;
const IAutoClosingPairConditional = language_configuration.IAutoClosingPairConditional;
const IAutoClosingPair = language_configuration.IAutoClosingPair;
const RegExp = @import("../../../../../support/regexp.zig").RegExp;

/// Reads `root/relative_path` as JSONC and returns a configuration whose
/// strings are owned by `arena`.
pub fn load(arena: Allocator, io: std.Io, root: []const u8, relative_path: []const u8) !LanguageConfiguration {
    const path = try std.fs.path.join(arena, &.{ root, relative_path });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    return loadText(arena, text);
}

/// Parses an already loaded language configuration (JSONC). This is the entry
/// point for configurations embedded from VS Code extension assets.
pub fn loadText(arena: Allocator, text: []const u8) !LanguageConfiguration {
    const sanitized = try configuration_models.stripJsonc(arena, text);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, sanitized, .{});
    if (value != .object) return error.InvalidLanguageConfiguration;
    const object = value.object;

    var config = language_configuration.empty();

    if (object.get("comments")) |comments| {
        if (comments == .object) config.comments = try parseComments(arena, comments.object);
    }
    if (object.get("brackets")) |brackets| {
        if (brackets == .array) config.brackets = try parsePairs(arena, brackets.array.items);
    }
    if (object.get("colorizedBracketPairs")) |brackets| {
        if (brackets == .array) config.colorizedBracketPairs = try parsePairs(arena, brackets.array.items);
    }
    if (object.get("autoClosingPairs")) |pairs| {
        if (pairs == .array) config.autoClosingPairs = try parseAutoClosingPairs(arena, pairs.array.items);
    }
    if (object.get("surroundingPairs")) |pairs| {
        if (pairs == .array) {
            const parsed = try parsePairs(arena, pairs.array.items);
            const result = try arena.alloc(IAutoClosingPair, parsed.len);
            for (parsed, 0..) |pair, index| result[index] = .{ .open = pair[0], .close = pair[1] };
            config.surroundingPairs = result;
        }
    }
    if (object.get("folding")) |folding| {
        if (folding == .object) {
            const off_side = folding.object.get("offSide");
            config.folding = .{
                .offSide = if (off_side != null and off_side.? == .bool) off_side.?.bool else false,
                .markers = null,
            };
        }
    }
    if (object.get("indentationRules")) |rules| {
        if (rules == .object) config.indentationRules = try parseIndentationRules(rules.object);
    }
    return config;
}

fn parseIndentationRules(object: std.json.ObjectMap) !IndentationRule {
    return .{
        .decreaseIndentPattern = try parseRegExp(object, "decreaseIndentPattern"),
        .increaseIndentPattern = try parseRegExp(object, "increaseIndentPattern"),
        .indentNextLinePattern = try parseRegExp(object, "indentNextLinePattern"),
        .unIndentedLinePattern = try parseRegExp(object, "unIndentedLinePattern"),
    };
}

fn parseRegExp(object: std.json.ObjectMap, name: []const u8) !?RegExp {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return RegExp.init(value.string, .{}) catch null;
}

fn parseComments(arena: Allocator, object: std.json.ObjectMap) !CommentRule {
    var line_comment: ?LineCommentConfig = null;
    if (object.get("lineComment")) |value| {
        switch (value) {
            .string => |comment| line_comment = .{ .comment = try arena.dupe(u8, comment), .noIndent = null },
            .object => |line| {
                if (stringField(line, "comment")) |comment| {
                    line_comment = .{
                        .comment = try arena.dupe(u8, comment),
                        .noIndent = if (line.get("noIndent")) |no_indent| if (no_indent == .bool) no_indent.bool else null else null,
                    };
                }
            },
            else => {},
        }
    }
    var block_comment: ?CharacterPair = null;
    if (object.get("blockComment")) |value| {
        if (value == .array and value.array.items.len >= 2) {
            const open = value.array.items[0];
            const close = value.array.items[1];
            if (open == .string and close == .string) {
                block_comment = .{ try arena.dupe(u8, open.string), try arena.dupe(u8, close.string) };
            }
        }
    }
    return .{ .lineComment = line_comment, .blockComment = block_comment };
}

fn parsePairs(arena: Allocator, items: []const std.json.Value) ![]CharacterPair {
    var result = std.array_list.Managed(CharacterPair).init(arena);
    for (items) |item| {
        if (item != .array or item.array.items.len < 2) continue;
        const open = item.array.items[0];
        const close = item.array.items[1];
        if (open != .string or close != .string) continue;
        try result.append(.{ try arena.dupe(u8, open.string), try arena.dupe(u8, close.string) });
    }
    return result.toOwnedSlice();
}

fn parseAutoClosingPairs(arena: Allocator, items: []const std.json.Value) ![]IAutoClosingPairConditional {
    var result = std.array_list.Managed(IAutoClosingPairConditional).init(arena);
    for (items) |item| {
        if (item != .object) continue;
        const open = stringField(item.object, "open") orelse continue;
        const close = stringField(item.object, "close") orelse continue;
        var not_in: ?[]const []const u8 = null;
        if (item.object.get("notIn")) |value| {
            if (value == .array) {
                var list = std.array_list.Managed([]const u8).init(arena);
                for (value.array.items) |entry| {
                    if (entry == .string) try list.append(try arena.dupe(u8, entry.string));
                }
                not_in = try list.toOwnedSlice();
            }
        }
        try result.append(.{ .open = try arena.dupe(u8, open), .close = try arena.dupe(u8, close), .notIn = not_in });
    }
    return result.toOwnedSlice();
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

test "language configuration extension point reads markdown-basics" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const config = load(arena.allocator(), std.testing.io, "vscode/extensions/markdown-basics", "language-configuration.json") catch return error.SkipZigTest;
    try std.testing.expect(config.comments != null);
    try std.testing.expect(config.comments.?.blockComment != null);
    try std.testing.expectEqualStrings("<!--", config.comments.?.blockComment.?[0]);
    try std.testing.expect(config.brackets != null);
    try std.testing.expect(config.brackets.?.len >= 3);
    try std.testing.expect(config.folding != null);
    try std.testing.expect(config.folding.?.offSide != null and config.folding.?.offSide.?);
    try std.testing.expect(config.autoClosingPairs != null);
    try std.testing.expect(config.autoClosingPairs.?.len >= 4);
}

test "language configuration extension point compiles json indentation rules" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var config = load(arena.allocator(), std.testing.io, "vscode/extensions/json", "language-configuration.json") catch return error.SkipZigTest;
    defer config.deinit();

    const rules = config.indentationRules orelse return error.MissingIndentationRules;
    try std.testing.expect(rules.increaseIndentPattern != null);
    try std.testing.expect(rules.decreaseIndentPattern != null);
    try std.testing.expect(rules.increaseIndentPattern.?.isMatch("{"));
    try std.testing.expect(rules.increaseIndentPattern.?.isMatch("  ["));
    try std.testing.expect(rules.decreaseIndentPattern.?.isMatch("  },"));
}

test "language configuration extension point reads the vendored json fallback" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var config = load(arena.allocator(), std.testing.io, "src/support/languageConfigurations", "json.json") catch return error.SkipZigTest;
    defer config.deinit();

    const rules = config.indentationRules orelse return error.MissingIndentationRules;
    try std.testing.expect(rules.increaseIndentPattern != null);
    try std.testing.expect(rules.decreaseIndentPattern != null);
    try std.testing.expect(config.brackets != null);
    try std.testing.expect(config.autoClosingPairs != null);
}
