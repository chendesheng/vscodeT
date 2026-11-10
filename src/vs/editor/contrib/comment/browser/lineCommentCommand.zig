// Port of `src/vs/editor/contrib/comment/browser/lineCommentCommand.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const strings = @import("../../../../base/common/strings.zig");
const CharCode = @import("../../../../base/common/charCode.zig").CharCode;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const selection_mod = @import("../../../common/core/selection.zig");
const Selection = selection_mod.Selection;
const edit_operation = @import("../../../common/core/editOperation.zig");
const ISingleEditOperation = edit_operation.ISingleEditOperation;

const editor_common = @import("../../../common/editorCommon.zig");
const ICommand = editor_common.ICommand;
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const commandOf = editor_common.commandOf;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const LanguageService = @import("../../../common/services/languageService.zig").LanguageService;

const comment = @import("./comment.zig");
const blockComment = @import("./blockCommentCommand.zig");
const BlockCommentCommand = blockComment.BlockCommentCommand;

pub const Type = enum {
    Toggle,
    ForceAdd,
    ForceRemove,
};

pub const IInsertionPoint = struct {
    ignore: bool,
    comment_str_offset: usize,
};

pub const ILinePreflightData = struct {
    ignore: bool,
    comment_str: []const u8,
    comment_str_offset: usize,
    comment_str_length: usize,
};

const PreflightData = struct {
    supported: bool,
    should_remove_comments: bool = false,
    lines: ArrayList(ILinePreflightData),
    line_contents: ArrayList([]const u8),

    fn deinit(self: *PreflightData) void {
        self.lines.deinit();
        self.line_contents.deinit();
    }
};

const MAX_SAFE_SMALL_INTEGER: usize = 1 << 30;

pub const LineCommentCommand = struct {
    allocator: Allocator,
    language_service: *LanguageService,
    selection: Selection,
    indent_size: usize,
    comment_type: Type,
    insert_space: bool,
    ignore_empty_lines: bool,
    ignore_first_line: bool,

    selection_id: ?u64 = null,
    delta_column: isize = 0,
    move_end_position_down: bool = false,

    pub fn init(
        allocator: Allocator,
        language_service: *LanguageService,
        selection: Selection,
        indent_size: usize,
        comment_type: Type,
        insert_space: bool,
        ignore_empty_lines: bool,
        ignore_first_line: bool,
    ) LineCommentCommand {
        return .{
            .allocator = allocator,
            .language_service = language_service,
            .selection = selection,
            .indent_size = indent_size,
            .comment_type = comment_type,
            .insert_space = insert_space,
            .ignore_empty_lines = ignore_empty_lines,
            .ignore_first_line = ignore_first_line,
        };
    }

    fn withEndPosition(selection: Selection, end_line_number: usize, end_column: usize) Selection {
        if (selection.getDirection() == .LTR) {
            return Selection.init(selection.startLineNumber, selection.startColumn, end_line_number, end_column);
        }
        return Selection.init(end_line_number, end_column, selection.startLineNumber, selection.startColumn);
    }

    fn gatherPreflightCommentStrings(
        arena: Allocator,
        self: *LineCommentCommand,
        model: *TextModel,
        start_line_number: usize,
        end_line_number: usize,
    ) !?PreflightData {
        model.tokenization().tokenizeIfCheap(start_line_number);
        const language_id = model.getLanguageIdAtPosition(start_line_number, 1);
        const config = comment.commentsFor(self.language_service, language_id) orelse return null;
        const comment_str = config.lineCommentToken orelse return null;
        if (comment_str.len == 0) return null;

        var data = PreflightData{
            .supported = true,
            .lines = ArrayList(ILinePreflightData).init(arena),
            .line_contents = ArrayList([]const u8).init(arena),
        };
        errdefer data.deinit();

        var line_number = start_line_number;
        while (line_number <= end_line_number) : (line_number += 1) {
            const line = try model.getLineContent(line_number);
            defer line.deinit();
            const content = try arena.dupe(u8, line.items);
            try data.line_contents.append(content);
            try data.lines.append(.{
                .ignore = false,
                .comment_str = comment_str,
                .comment_str_offset = 0,
                .comment_str_length = comment_str.len,
            });
        }
        return data;
    }

    fn analyzeLines(
        self: *LineCommentCommand,
        data: *PreflightData,
        model: *TextModel,
        start_line_number: usize,
    ) !void {
        const language_id = model.getLanguageIdAtPosition(start_line_number, 1);
        const config = comment.commentsFor(self.language_service, language_id);
        const line_comment_no_indent = if (config) |value| value.lineCommentNoIndent orelse false else false;

        var only_whitespace_lines = true;
        var should_remove_comments: bool = switch (self.comment_type) {
            .Toggle, .ForceRemove => true,
            .ForceAdd => false,
        };

        for (data.lines.items, 0..) |*line_data, i| {
            const line_number = start_line_number + i;
            if (line_number == start_line_number and self.ignore_first_line) {
                line_data.ignore = true;
                continue;
            }

            const line_content = data.line_contents.items[i];
            const line_content_start_offset = strings.firstNonWhitespaceIndex(line_content) orelse {
                line_data.ignore = self.ignore_empty_lines;
                line_data.comment_str_offset = if (line_comment_no_indent) 0 else line_content.len;
                continue;
            };

            only_whitespace_lines = false;
            const offset = if (line_comment_no_indent) 0 else line_content_start_offset;
            line_data.ignore = false;
            line_data.comment_str_offset = offset;

            if (should_remove_comments and !BlockCommentCommand.haystackHasNeedleAtOffset(line_content, line_data.comment_str, offset)) {
                if (self.comment_type == .Toggle) {
                    should_remove_comments = false;
                } else if (self.comment_type == .ForceAdd) {
                    // Will not happen.
                } else {
                    line_data.ignore = true;
                }
            }

            if (should_remove_comments and self.insert_space) {
                const comment_str_end_offset = line_content_start_offset + line_data.comment_str_length;
                if (comment_str_end_offset < line_content.len and line_content[comment_str_end_offset] == ' ') {
                    line_data.comment_str_length += 1;
                }
            }
        }

        if (self.comment_type == .Toggle and only_whitespace_lines) {
            should_remove_comments = false;
            for (data.lines.items) |*line_data| line_data.ignore = false;
        }

        data.should_remove_comments = should_remove_comments;
    }

    fn gatherPreflightData(
        arena: Allocator,
        self: *LineCommentCommand,
        model: *TextModel,
        start_line_number: usize,
        end_line_number: usize,
    ) !PreflightData {
        var data = (try gatherPreflightCommentStrings(arena, self, model, start_line_number, end_line_number)) orelse PreflightData{
            .supported = false,
            .lines = ArrayList(ILinePreflightData).init(arena),
            .line_contents = ArrayList([]const u8).init(arena),
        };
        if (!data.supported) return data;

        try analyzeLines(self, &data, model, start_line_number);
        return data;
    }

    fn nextVisibleColumn(current_visible_column: usize, indent_size: usize, is_tab: bool, column_size: usize) usize {
        if (is_tab) {
            return current_visible_column + (indent_size - (current_visible_column % indent_size));
        }
        return current_visible_column + column_size;
    }

    fn normalizeInsertionPoint(
        lines: []IInsertionPoint,
        line_contents: []const []const u8,
        start_line_number: usize,
        indent_size: usize,
    ) void {
        _ = start_line_number;
        var min_visible_column: usize = MAX_SAFE_SMALL_INTEGER;

        for (lines, 0..) |line, i| {
            if (line.ignore) continue;
            const line_content = line_contents[i];

            var current_visible_column: usize = 0;
            var j: usize = 0;
            while (current_visible_column < min_visible_column and j < line.comment_str_offset) : (j += 1) {
                current_visible_column = nextVisibleColumn(current_visible_column, indent_size, line_content[j] == '\t', 1);
            }

            if (current_visible_column < min_visible_column) {
                min_visible_column = current_visible_column;
            }
        }

        min_visible_column = (min_visible_column / indent_size) * indent_size;

        for (lines, 0..) |*line, i| {
            if (line.ignore) continue;
            const line_content = line_contents[i];

            var current_visible_column: usize = 0;
            var j: usize = 0;
            while (current_visible_column < min_visible_column and j < line.comment_str_offset) : (j += 1) {
                current_visible_column = nextVisibleColumn(current_visible_column, indent_size, line_content[j] == '\t', 1);
            }

            if (current_visible_column > min_visible_column) {
                line.comment_str_offset = j - 1;
            } else {
                line.comment_str_offset = j;
            }
        }
    }

    fn executeLineComments(
        self: *LineCommentCommand,
        arena: Allocator,
        builder: IEditOperationBuilder,
        data: *PreflightData,
        s: Selection,
    ) !void {
        const cursor_position = Position.init(s.positionLineNumber, s.positionColumn);

        if (data.should_remove_comments) {
            for (data.lines.items, 0..) |line_data, i| {
                if (line_data.ignore) continue;
                try builder.addEditOperation(Range.init(
                    s.startLineNumber + i,
                    line_data.comment_str_offset + 1,
                    s.startLineNumber + i,
                    line_data.comment_str_offset + line_data.comment_str_length + 1,
                ), null, false);
            }
        } else {
            var insertion_points = try arena.alloc(IInsertionPoint, data.lines.items.len);
            for (data.lines.items, 0..) |line_data, i| {
                insertion_points[i] = .{ .ignore = line_data.ignore, .comment_str_offset = line_data.comment_str_offset };
            }
            normalizeInsertionPoint(insertion_points, data.line_contents.items, s.startLineNumber, self.indent_size);

            for (data.lines.items, 0..) |*line_data, i| {
                if (line_data.ignore) continue;
                line_data.comment_str_offset = insertion_points[i].comment_str_offset;

                var text = ArrayList(u8).init(arena);
                try text.appendSlice(line_data.comment_str);
                if (self.insert_space) try text.append(' ');

                const range = Range.init(
                    s.startLineNumber + i,
                    line_data.comment_str_offset + 1,
                    s.startLineNumber + i,
                    line_data.comment_str_offset + 1,
                );
                try builder.addEditOperation(range, text.items, false);

                if (range.isEmpty() and range.getStartPosition().equals(cursor_position)) {
                    const line_content = data.line_contents.items[i];
                    if (line_content.len + 1 == cursor_position.column) {
                        self.delta_column = @intCast(text.items.len);
                    }
                }
            }
        }

        self.selection_id = builder.trackSelection(s);
    }

    fn attemptRemoveBlockComment(
        self: *LineCommentCommand,
        arena: Allocator,
        model: *TextModel,
        s: Selection,
        start_token: []const u8,
        end_token: []const u8,
    ) !?ArrayList(ISingleEditOperation) {
        _ = self;
        var start_line_number = s.startLineNumber;
        var end_line_number = s.endLineNumber;

        const start_token_allowed_before_column = end_token.len + @max(
            model.getLineFirstNonWhitespaceColumn(s.startLineNumber) catch 0,
            s.startColumn,
        );

        const start_line = try model.getLineContent(start_line_number);
        defer start_line.deinit();
        var end_line = try model.getLineContent(end_line_number);
        defer end_line.deinit();

        var start_token_index: ?usize = blockComment.lastIndexOf(
            start_line.items,
            start_token,
            start_token_allowed_before_column - 1,
        );
        var end_token_index: ?usize = blockComment.indexOfFrom(
            end_line.items,
            end_token,
            if (s.endColumn - 1 < start_token.len) 0 else s.endColumn - 1 - start_token.len,
        );

        if (start_token_index != null and end_token_index == null) {
            end_token_index = blockComment.indexOfFrom(start_line.items, end_token, start_token_index.? + start_token.len);
            end_line_number = start_line_number;
        }

        if (start_token_index == null and end_token_index != null) {
            start_token_index = blockComment.lastIndexOf(end_line.items, start_token, end_token_index.?);
            start_line_number = end_line_number;
        }

        if (s.isEmpty() and (start_token_index == null or end_token_index == null)) {
            start_token_index = blockComment.indexOfFrom(start_line.items, start_token, 0);
            if (start_token_index != null) {
                end_token_index = blockComment.indexOfFrom(start_line.items, end_token, start_token_index.? + start_token.len);
            }
        }

        var effective_start_token = start_token;
        var effective_end_token = end_token;
        var effective_end_index = end_token_index;

        if (start_token_index != null) {
            const source_line = if (start_line_number == s.startLineNumber) start_line.items else end_line.items;
            const offset = start_token_index.? + start_token.len;
            if (offset < source_line.len and source_line[offset] == ' ') {
                effective_start_token = try BlockCommentCommand.concat(arena, start_token, " ");
            }
        }

        if (end_token_index != null) {
            const source_line = if (end_line_number == s.startLineNumber) start_line.items else end_line.items;
            if (end_token_index.? > 0 and source_line[end_token_index.? - 1] == ' ') {
                effective_end_token = try BlockCommentCommand.concat(arena, " ", end_token);
                effective_end_index = end_token_index.? - 1;
            }
        }

        if (start_token_index != null and effective_end_index != null) {
            return try BlockCommentCommand.createRemoveBlockCommentOperations(
                arena,
                Range.init(
                    start_line_number,
                    start_token_index.? + effective_start_token.len + 1,
                    end_line_number,
                    effective_end_index.? + 1,
                ),
                effective_start_token,
                effective_end_token,
            );
        }
        return null;
    }

    fn executeBlockComment(
        self: *LineCommentCommand,
        arena: Allocator,
        model: *TextModel,
        builder: IEditOperationBuilder,
        s: Selection,
    ) !void {
        model.tokenization().tokenizeIfCheap(s.startLineNumber);
        const language_id = model.getLanguageIdAtPosition(s.startLineNumber, 1);
        const config = comment.commentsFor(self.language_service, language_id) orelse return;
        const start_token = config.blockCommentStartToken orelse return;
        const end_token = config.blockCommentEndToken orelse return;

        var operations: ?ArrayList(ISingleEditOperation) = null;
        if (try self.attemptRemoveBlockComment(arena, model, s, start_token, end_token)) |ops| {
            operations = ops;
        } else {
            var ops: ArrayList(ISingleEditOperation) = undefined;
            if (s.isEmpty()) {
                const line_content = try model.getLineContent(s.startLineNumber);
                defer line_content.deinit();
                var first_non_whitespace_index = strings.firstNonWhitespaceIndex(line_content.items) orelse line_content.items.len;
                if (first_non_whitespace_index == line_content.items.len) {
                    first_non_whitespace_index = line_content.items.len;
                }
                ops = try BlockCommentCommand.createAddBlockCommentOperations(
                    arena,
                    Range.init(s.startLineNumber, first_non_whitespace_index + 1, s.startLineNumber, line_content.items.len + 1),
                    start_token,
                    end_token,
                    self.insert_space,
                );
            } else {
                ops = try BlockCommentCommand.createAddBlockCommentOperations(
                    arena,
                    Range.init(
                        s.startLineNumber,
                        model.getLineFirstNonWhitespaceColumn(s.startLineNumber) catch 1,
                        s.endLineNumber,
                        model.getLineMaxColumn(s.endLineNumber),
                    ),
                    start_token,
                    end_token,
                    self.insert_space,
                );
            }

            if (ops.items.len == 1) {
                self.delta_column = @intCast(start_token.len + 1);
            }
            operations = ops;
        }

        if (operations) |*ops| {
            defer ops.deinit();
            self.selection_id = builder.trackSelection(s);
            for (ops.items) |op| {
                try builder.addEditOperation(op.range, op.text, false);
            }
        }
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *LineCommentCommand) ICommand {
        return commandOf(LineCommentCommand).of(self);
    }

    pub fn getEditOperations(self: *LineCommentCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var s = self.selection;
        self.move_end_position_down = false;
        self.delta_column = 0;

        if (s.startLineNumber == s.endLineNumber and self.ignore_first_line) {
            try builder.addEditOperation(
                Range.init(s.startLineNumber, model.getLineMaxColumn(s.startLineNumber), s.startLineNumber + 1, 1),
                if (s.startLineNumber == model.getLineCount()) "" else "\n",
                false,
            );
            self.selection_id = builder.trackSelection(s);
            return;
        }

        if (s.startLineNumber < s.endLineNumber and s.endColumn == 1) {
            self.move_end_position_down = true;
            s = withEndPosition(s, s.endLineNumber - 1, model.getLineMaxColumn(s.endLineNumber - 1));
        }

        var data = try gatherPreflightData(arena, self, model, s.startLineNumber, s.endLineNumber);
        defer data.deinit();

        if (data.supported) {
            return executeLineComments(self, arena, builder, &data, s);
        }

        return executeBlockComment(self, arena, model, builder, s);
    }

    pub fn computeCursorState(self: *LineCommentCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        var result = helper.getTrackedSelection(self.selection_id orelse return self.selection);

        if (self.move_end_position_down) {
            result = withEndPosition(result, result.endLineNumber + 1, 1);
        }

        return Selection.init(
            result.selectionStartLineNumber,
            @intCast(@as(isize, @intCast(result.selectionStartColumn)) + self.delta_column),
            result.positionLineNumber,
            @intCast(@as(isize, @intCast(result.positionColumn)) + self.delta_column),
        );
    }
};

comptime {
    _ = commandOf(LineCommentCommand).of;
}
