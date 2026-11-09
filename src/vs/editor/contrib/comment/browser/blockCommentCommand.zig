// Port of `src/vs/editor/contrib/comment/browser/blockCommentCommand.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const CharCode = @import("../../../../base/common/charCode.zig").CharCode;
const Range = @import("../../../common/core/range.zig").Range;
const Position = @import("../../../common/core/position.zig").Position;
const selection_mod = @import("../../../common/core/selection.zig");
const Selection = selection_mod.Selection;
const edit_operation = @import("../../../common/core/editOperation.zig");
const ISingleEditOperation = edit_operation.ISingleEditOperation;

const editor_common = @import("../../../common/editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const commandOf = editor_common.commandOf;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const LanguageService = @import("../../../common/services/languageService.zig").LanguageService;
const comment = @import("./comment.zig");

pub const BlockCommentCommand = struct {
    allocator: Allocator,
    selection: Selection,
    insert_space: bool,
    language_service: *LanguageService,
    used_end_token: ?[]const u8 = null,
    selection_id: ?u64 = null,

    pub fn init(
        allocator: Allocator,
        selection: Selection,
        insert_space: bool,
        language_service: *LanguageService,
    ) BlockCommentCommand {
        return .{
            .allocator = allocator,
            .selection = selection,
            .insert_space = insert_space,
            .language_service = language_service,
        };
    }

    pub fn haystackHasNeedleAtOffset(haystack: []const u8, needle: []const u8, offset: usize) bool {
        if (offset > haystack.len) return false;
        if (offset + needle.len > haystack.len) return false;

        for (needle, 0..) |needle_char, i| {
            const haystack_char = haystack[offset + i];
            if (haystack_char == needle_char) continue;
            if (haystack_char >= 'A' and haystack_char <= 'Z' and haystack_char + 32 == needle_char) continue;
            if (needle_char >= 'A' and needle_char <= 'Z' and needle_char + 32 == haystack_char) continue;
            return false;
        }
        return true;
    }

    pub fn concat(allocator: Allocator, a: []const u8, b: []const u8) ![]u8 {
        const result = try allocator.alloc(u8, a.len + b.len);
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return result;
    }

    /// Deletes the start/end tokens around `r`.
    pub fn createRemoveBlockCommentOperations(
        allocator: Allocator,
        r: Range,
        start_token: []const u8,
        end_token: []const u8,
    ) !ArrayList(ISingleEditOperation) {
        var result = ArrayList(ISingleEditOperation).init(allocator);
        errdefer result.deinit();

        if (!r.isEmpty()) {
            try result.append(edit_operation.EditOperation.delete(Range.init(
                r.startLineNumber,
                r.startColumn -| start_token.len,
                r.startLineNumber,
                r.startColumn,
            )));
            try result.append(edit_operation.EditOperation.delete(Range.init(
                r.endLineNumber,
                r.endColumn,
                r.endLineNumber,
                r.endColumn + end_token.len,
            )));
        } else {
            try result.append(edit_operation.EditOperation.delete(Range.init(
                r.startLineNumber,
                r.startColumn -| start_token.len,
                r.endLineNumber,
                r.endColumn + end_token.len,
            )));
        }
        return result;
    }

    /// Inserts start/end tokens around `r`.
    pub fn createAddBlockCommentOperations(
        allocator: Allocator,
        r: Range,
        start_token: []const u8,
        end_token: []const u8,
        insert_space: bool,
    ) !ArrayList(ISingleEditOperation) {
        var result = ArrayList(ISingleEditOperation).init(allocator);
        errdefer result.deinit();

        if (!r.isEmpty()) {
            try result.append(edit_operation.EditOperation.insert(
                Position.init(r.startLineNumber, r.startColumn),
                try concat(allocator, start_token, if (insert_space) " " else ""),
            ));
            try result.append(edit_operation.EditOperation.insert(
                Position.init(r.endLineNumber, r.endColumn),
                try concat(allocator, if (insert_space) " " else "", end_token),
            ));
        } else {
            try result.append(edit_operation.EditOperation.replace(
                r,
                try concat(allocator, start_token, try concat(allocator, "  ", end_token)),
            ));
        }
        return result;
    }

    fn createOperationsForBlockComment(
        self: *BlockCommentCommand,
        arena: Allocator,
        selection: Range,
        start_token: []const u8,
        end_token: []const u8,
        model: *TextModel,
        builder: IEditOperationBuilder,
    ) !void {
        const start_line_number = selection.startLineNumber;
        const start_column = selection.startColumn;
        const end_line_number = selection.endLineNumber;
        const end_column = selection.endColumn;

        const start_line = try model.getLineContent(start_line_number);
        defer start_line.deinit();
        const end_line = try model.getLineContent(end_line_number);
        defer end_line.deinit();

        const start_line_text = start_line.items;
        const end_line_text = end_line.items;

        var start_token_index: ?usize = lastIndexOf(
            start_line_text,
            start_token,
            start_column - 1 + start_token.len,
        );
        var end_token_index: ?usize = indexOfFrom(
            end_line_text,
            end_token,
            if (end_column - 1 < start_token.len) 0 else end_column - 1 - start_token.len,
        );

        if (start_token_index != null and end_token_index != null) {
            if (start_line_number == end_line_number) {
                const line_between_tokens = start_line_text[start_token_index.? + start_token.len .. end_token_index.?];
                if (std.mem.indexOf(u8, line_between_tokens, end_token) != null) {
                    start_token_index = null;
                    end_token_index = null;
                }
            } else {
                const start_line_after_start_token = start_line_text[start_token_index.? + start_token.len ..];
                const end_line_before_end_token = end_line_text[0..end_token_index.?];
                if (std.mem.indexOf(u8, start_line_after_start_token, end_token) != null or
                    std.mem.indexOf(u8, end_line_before_end_token, end_token) != null)
                {
                    start_token_index = null;
                    end_token_index = null;
                }
            }
        }

        var effective_start_token = start_token;
        var effective_end_token = end_token;

        if (start_token_index != null and end_token_index != null) {
            var end_index = end_token_index.?;
            if (self.insert_space and start_token_index.? + start_token.len < start_line_text.len and
                start_line_text[start_token_index.? + start_token.len] == ' ')
            {
                effective_start_token = try concat(arena, start_token, " ");
            }
            if (self.insert_space and end_index > 0 and end_line_text[end_index - 1] == ' ') {
                effective_end_token = try concat(arena, " ", end_token);
                end_index -= 1;
            }

            var operations = try createRemoveBlockCommentOperations(
                arena,
                Range.init(
                    start_line_number,
                    start_token_index.? + effective_start_token.len + 1,
                    end_line_number,
                    end_index + 1,
                ),
                effective_start_token,
                effective_end_token,
            );
            defer operations.deinit();
            for (operations.items) |op| {
                try builder.addTrackedEditOperation(op.range, op.text, false);
            }
        } else {
            var operations = try createAddBlockCommentOperations(
                arena,
                selection,
                start_token,
                end_token,
                self.insert_space,
            );
            defer operations.deinit();
            for (operations.items) |op| {
                try builder.addTrackedEditOperation(op.range, op.text, false);
            }
            if (operations.items.len == 1) {
                self.used_end_token = end_token;
            }
        }
    }

    pub fn getEditOperations(self: *BlockCommentCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const start_line_number = self.selection.startLineNumber;
        const start_column = self.selection.startColumn;

        model.tokenization().tokenizeIfCheap(start_line_number);
        const language_id = model.getLanguageIdAtPosition(start_line_number, start_column);
        const config = comment.commentsFor(self.language_service, language_id) orelse return;
        const start_token = config.blockCommentStartToken orelse return;
        const end_token = config.blockCommentEndToken orelse return;
        if (start_token.len == 0 or end_token.len == 0) return;

        self.used_end_token = null;
        try self.createOperationsForBlockComment(
            arena,
            Range.init(self.selection.startLineNumber, self.selection.startColumn, self.selection.endLineNumber, self.selection.endColumn),
            start_token,
            end_token,
            model,
            builder,
        );
        self.selection_id = builder.trackSelection(self.selection);
    }

    pub fn computeCursorState(self: *BlockCommentCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        const inverse_operations = helper.getInverseEditOperations();
        if (inverse_operations.len == 2) {
            const start_operation = inverse_operations[0];
            const end_operation = inverse_operations[1];
            return Selection.init(
                start_operation.range.endLineNumber,
                start_operation.range.endColumn,
                end_operation.range.startLineNumber,
                end_operation.range.startColumn,
            );
        }

        const source_range = inverse_operations[0].range;
        const delta_column: isize = if (self.used_end_token) |token| -@as(isize, @intCast(token.len)) - 1 else 0;
        const column: usize = @intCast(@as(isize, @intCast(source_range.endColumn)) + delta_column);
        return Selection.init(source_range.endLineNumber, column, source_range.endLineNumber, column);
    }
};

pub fn lastIndexOf(haystack: []const u8, needle: []const u8, from_index: usize) ?usize {
    if (needle.len == 0) return @min(from_index, haystack.len);
    if (haystack.len < needle.len) return null;
    var index = @min(from_index, haystack.len - needle.len);
    while (true) {
        if (std.mem.eql(u8, haystack[index .. index + needle.len], needle)) return index;
        if (index == 0) break;
        index -= 1;
    }
    return null;
}

pub fn indexOfFrom(haystack: []const u8, needle: []const u8, from_index: usize) ?usize {
    if (from_index >= haystack.len) return null;
    return std.mem.indexOfPos(u8, haystack, from_index, needle) orelse null;
}

comptime {
    _ = commandOf(BlockCommentCommand).of;
}
