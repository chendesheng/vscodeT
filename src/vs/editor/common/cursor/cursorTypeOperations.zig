const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const CursorColumns = @import("../core/cursorColumns.zig").CursorColumns;
const EditorAutoSurroundStrategy = @import("../config/editorOptions.zig").EditorAutoSurroundStrategy;
const CursorConfiguration = @import("../cursorCommon.zig").CursorConfiguration;
const EditOperationResult = @import("../cursorCommon.zig").EditOperationResult;
const EditOperationType = @import("../cursorCommon.zig").EditOperationType;
const Selection = @import("../core/selection.zig").Selection;
const TypeWithoutInterceptorsOperation = @import("./cursorTypeEditOperations.zig").TypeWithoutInterceptorsOperation;
const isQuote = @import("../cursorCommon.zig").isQuote;

pub const TypeOperations = struct {
    pub fn shiftIndent(allocator: Allocator, config: *const CursorConfiguration, indentation: []const u8, count: usize) ![]const u8 {
        const effective_count = if (count == 0) 1 else count;
        return shiftUnshift(allocator, config, indentation, indentation.len + effective_count, false);
    }

    pub fn unshiftIndent(allocator: Allocator, config: *const CursorConfiguration, indentation: []const u8, count: usize) ![]const u8 {
        const effective_count = if (count == 0) 1 else count;
        return shiftUnshift(allocator, config, indentation, indentation.len + effective_count, true);
    }

    pub fn typeWithoutInterceptors(
        allocator: Allocator,
        prevEditOperationType: EditOperationType,
        selections: []const Selection,
        text: []const u8,
    ) !EditOperationResult {
        return TypeWithoutInterceptorsOperation.getEdits(allocator, prevEditOperationType, selections, text);
    }

    pub fn shouldSurroundChar(config: *const CursorConfiguration, ch: u8) bool {
        if (isQuote(ch)) {
            return config.autoSurround == .quotes or config.autoSurround == .languageDefined;
        }
        return config.autoSurround == .brackets or config.autoSurround == .languageDefined;
    }
};

fn shiftUnshift(allocator: Allocator, config: *const CursorConfiguration, indentation: []const u8, column: usize, unshift: bool) ![]const u8 {
    const visible = CursorColumns.visibleColumnFromColumn(indentation, column, config.tabSize);
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();

    if (config.insertSpaces) {
        const desired = if (unshift)
            CursorColumns.prevIndentTabStop(visible, config.indentSize)
        else
            CursorColumns.nextIndentTabStop(visible, config.indentSize);
        const count = desired / config.indentSize;
        for (0..count) |_| try result.appendNTimes(' ', config.indentSize);
    } else {
        const desired = if (unshift)
            CursorColumns.prevRenderTabStop(visible, config.tabSize)
        else
            CursorColumns.nextRenderTabStop(visible, config.tabSize);
        const count = desired / config.tabSize;
        for (0..count) |_| try result.append('\t');
    }
    return try result.toOwnedSlice();
}

/// Normalize the leading whitespace of `str` to the configured indentation.
pub fn normalizeIndentation(allocator: Allocator, str: []const u8, indentSize: usize, insertSpaces: bool) ![]const u8 {
    var first_non_whitespace: usize = str.len;
    for (str, 0..) |ch, i| {
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') {
            first_non_whitespace = i;
            break;
        }
    }

    var spaces_count: usize = 0;
    for (str[0..first_non_whitespace]) |ch| {
        if (ch == '\t') {
            spaces_count = CursorColumns.nextIndentTabStop(spaces_count, indentSize);
        } else {
            spaces_count += 1;
        }
    }

    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    if (!insertSpaces) {
        const tabs_count = spaces_count / indentSize;
        spaces_count = spaces_count % indentSize;
        for (0..tabs_count) |_| try result.append('\t');
    }
    try result.appendNTimes(' ', spaces_count);
    try result.appendSlice(str[first_non_whitespace..]);
    return try result.toOwnedSlice();
}

test "cursor type operations: shift and unshift indentation" {
    const allocator = std.testing.allocator;
    const config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };

    const shifted = try TypeOperations.shiftIndent(allocator, &config, "  ", 1);
    defer allocator.free(shifted);
    try std.testing.expectEqualStrings("    ", shifted);

    const unshifted = try TypeOperations.unshiftIndent(allocator, &config, "      ", 1);
    defer allocator.free(unshifted);
    try std.testing.expectEqualStrings("    ", unshifted);
}

test "cursor type operations: normalize indentation and surround" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeIndentation(allocator, "\tfoo", 4, true);
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("    foo", normalized);

    const tabs = try normalizeIndentation(allocator, "      foo", 4, false);
    defer allocator.free(tabs);
    try std.testing.expectEqualStrings("\t  foo", tabs);

    var config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };
    try std.testing.expect(!TypeOperations.shouldSurroundChar(&config, '"'));
    config.autoSurround = .quotes;
    try std.testing.expect(TypeOperations.shouldSurroundChar(&config, '"'));
    try std.testing.expect(!TypeOperations.shouldSurroundChar(&config, '('));
}

pub const CompositionOutcome = struct {
    deletedText: []const u8,
    deletedSelectionStart: usize,
    deletedSelectionEnd: usize,
    insertedText: []const u8,
    insertedSelectionStart: usize,
    insertedSelectionEnd: usize,
    insertedTextRange: @import("../core/range.zig").Range,
};

test "cursor type operations: composition outcome and type wrapper" {
    const allocator = std.testing.allocator;
    const selections = [_]Selection{Selection.init(1, 1, 1, 1)};
    var result = try TypeOperations.typeWithoutInterceptors(allocator, .TypingOther, &selections, "a");
    defer result.deinit(allocator);
    try std.testing.expectEqual(EditOperationType.TypingOther, result.type);

    const outcome = CompositionOutcome{
        .deletedText = "d",
        .deletedSelectionStart = 0,
        .deletedSelectionEnd = 1,
        .insertedText = "i",
        .insertedSelectionStart = 0,
        .insertedSelectionEnd = 1,
        .insertedTextRange = @import("../core/range.zig").Range.init(1, 1, 1, 2),
    };
    try std.testing.expectEqualStrings("i", outcome.insertedText);
}
