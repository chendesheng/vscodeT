const std = @import("std");
const Allocator = std.mem.Allocator;
const Selection = @import("../core/selection.zig").Selection;
const cursorCommon = @import("../cursorCommon.zig");
const CursorConfiguration = cursorCommon.CursorConfiguration;
const EditOperationResult = cursorCommon.EditOperationResult;
const EditOperationType = cursorCommon.EditOperationType;
const ReplaceCommand = cursorCommon.ReplaceCommand;

pub fn getTypingOperation(typedText: []const u8, previousTypingOperation: EditOperationType) EditOperationType {
    if (std.mem.eql(u8, typedText, " ")) {
        return if (previousTypingOperation == .TypingFirstSpace or previousTypingOperation == .TypingConsecutiveSpace)
            .TypingConsecutiveSpace
        else
            .TypingFirstSpace;
    }
    return .TypingOther;
}

pub fn shouldPushStackElementBetween(previousTypingOperation: EditOperationType, typingOperation: EditOperationType) bool {
    if (isTypingOperation(previousTypingOperation) and !isTypingOperation(typingOperation)) return true;
    if (previousTypingOperation == .TypingFirstSpace) return false;
    return normalizeOperationType(previousTypingOperation) != normalizeOperationType(typingOperation);
}

fn normalizeOperationType(operation: EditOperationType) EditOperationType {
    return if (operation == .TypingConsecutiveSpace or operation == .TypingFirstSpace) .TypingOther else operation;
}

fn isTypingOperation(operation: EditOperationType) bool {
    return operation == .TypingOther or operation == .TypingFirstSpace or operation == .TypingConsecutiveSpace;
}

pub const TypeWithoutInterceptorsOperation = struct {
    pub fn getEdits(allocator: Allocator, prevEditOperationType: EditOperationType, selections: []const Selection, str: []const u8) !EditOperationResult {
        const commands = try allocator.alloc(?ReplaceCommand, selections.len);
        errdefer allocator.free(commands);
        for (selections, 0..) |selection, i| {
            commands[i] = ReplaceCommand.init(rangeFromSelection(selection), str);
        }
        const op_type = getTypingOperation(str, prevEditOperationType);
        return .{
            .type = op_type,
            .commands = commands,
            .shouldPushStackElementBefore = shouldPushStackElementBetween(prevEditOperationType, op_type),
            .shouldPushStackElementAfter = false,
        };
    }
};

pub const SimpleCharacterTypeOperation = struct {
    pub fn getEdits(
        allocator: Allocator,
        config: *const CursorConfiguration,
        prevEditOperationType: EditOperationType,
        selections: []const Selection,
        ch: []const u8,
        isDoingComposition: bool,
    ) !EditOperationResult {
        _ = config;
        _ = isDoingComposition;
        // Overtype replacement is not wired yet; both paths use ReplaceCommand here.
        const commands = try allocator.alloc(?ReplaceCommand, selections.len);
        errdefer allocator.free(commands);
        for (selections, 0..) |selection, i| {
            commands[i] = ReplaceCommand.init(rangeFromSelection(selection), ch);
        }
        const op_type = getTypingOperation(ch, prevEditOperationType);
        return .{
            .type = op_type,
            .commands = commands,
            .shouldPushStackElementBefore = shouldPushStackElementBetween(prevEditOperationType, op_type),
            .shouldPushStackElementAfter = false,
        };
    }
};

fn rangeFromSelection(selection: Selection) @import("../core/range.zig").Range {
    return @import("../core/range.zig").Range.init(
        selection.startLineNumber,
        selection.startColumn,
        selection.endLineNumber,
        selection.endColumn,
    );
}

test "cursor type edit: typing operation grouping" {
    try std.testing.expectEqual(EditOperationType.TypingFirstSpace, getTypingOperation(" ", .Other));
    try std.testing.expectEqual(EditOperationType.TypingConsecutiveSpace, getTypingOperation(" ", .TypingFirstSpace));
    try std.testing.expectEqual(EditOperationType.TypingOther, getTypingOperation("a", .Other));
    try std.testing.expect(!shouldPushStackElementBetween(.TypingFirstSpace, .TypingConsecutiveSpace));
    try std.testing.expect(shouldPushStackElementBetween(.TypingConsecutiveSpace, .DeletingLeft));
}

test "cursor type edit: type without interceptors" {
    const allocator = std.testing.allocator;
    const selections = [_]Selection{Selection.init(1, 1, 1, 1)};
    var result = try TypeWithoutInterceptorsOperation.getEdits(allocator, .TypingOther, &selections, "x");
    defer result.deinit(allocator);
    try std.testing.expectEqual(EditOperationType.TypingOther, result.type);
    try std.testing.expectEqual(@as(usize, 1), result.commands.len);
    try std.testing.expectEqualStrings("x", result.commands[0].?.text);
}
