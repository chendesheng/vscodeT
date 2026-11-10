// Port of the auto-closing-pair typing logic from
// `src/vs/editor/common/cursor/cursorTypeEditOperations.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const Selection = @import("../core/selection.zig").Selection;
const cursor_common = @import("../cursorCommon.zig");
const CursorConfiguration = cursor_common.CursorConfiguration;
const isQuote = cursor_common.isQuote;

const editor_common = @import("../editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const ICommand = editor_common.ICommand;
const commandOf = editor_common.commandOf;

const TextModel = @import("../model/textModel.zig").TextModel;

pub const AutoClosingPair = struct {
    open: []const u8,
    close: []const u8,
};

fn lineBefore(line: []const u8, column: usize) []const u8 {
    return line[0..@min(column -| 1, line.len)];
}

fn lineAfter(line: []const u8, column: usize) []const u8 {
    return line[@min(column -| 1, line.len)..];
}

fn isBeforeClosingBrace(config: *const CursorConfiguration, line_after: []const u8) bool {
    if (line_after.len == 0) return false;
    var is_before_starting = false;
    var is_before_closing = false;
    for (config.auto_closing_pairs) |pair| {
        if (std.mem.startsWith(u8, line_after, pair.open)) is_before_starting = true;
        if (std.mem.startsWith(u8, line_after, pair.close)) is_before_closing = true;
    }
    return !is_before_starting and is_before_closing;
}

fn shouldAutoCloseBefore(config: *const CursorConfiguration, ch: u8, quote: bool) bool {
    const set = if (quote) config.auto_close_before_quotes else config.auto_close_before_brackets;
    return std.mem.indexOfScalar(u8, set, ch) != null;
}

fn isWordCharacter(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn pairIsOK(config: *const CursorConfiguration, pair: AutoClosingPair, token_type: @import("../encodedTokenAttributes.zig").StandardTokenType) bool {
    for (config.auto_closing_pairs) |candidate| {
        if (std.mem.eql(u8, candidate.open, pair.open) and std.mem.eql(u8, candidate.close, pair.close)) {
            return candidate.isOK(token_type);
        }
    }
    return true;
}

/// Finds the pair to auto-close for a typed character. Returns null when any
/// selection is non-empty or when language/editor conditions reject it.
pub fn findAutoClosingPair(
    config: *const CursorConfiguration,
    model: *TextModel,
    selections: []const Selection,
    ch: []const u8,
    ch_is_already_typed: bool,
) !?AutoClosingPair {
    if (selections.len == 0 or ch.len == 0) return null;
    for (selections) |selection| {
        if (!selection.isEmpty()) return null;
    }

    var best: ?AutoClosingPair = null;
    for (config.auto_closing_pairs) |pair| {
        if (pair.open.len < ch.len) continue;
        if (!std.mem.endsWith(u8, pair.open, ch)) continue;
        if (best == null or pair.open.len > best.?.open.len) {
            best = .{ .open = pair.open, .close = pair.close };
        }
    }
    const pair = best orelse return null;

    const quote = isQuote(ch[0]);
    const strategy = if (quote) config.autoClosingQuotes else config.autoClosingBrackets;
    if (strategy == .never) return null;
    // This port currently handles single-character pairs (the TUI's default
    // bracket set). Multi-character opening pairs need the typed-prefix
    // follow-up path from upstream.
    if (pair.open.len != 1 or pair.close.len != 1) return null;

    for (selections) |selection| {
        const position = selection.getPosition();
        const before_column = if (ch_is_already_typed) position.column - ch.len else position.column;
        const line = try model.getLineContent(position.lineNumber);
        defer line.deinit();
        const before = lineBefore(line.items, before_column);
        const after = lineAfter(line.items, before_column + (if (ch_is_already_typed) ch.len else 0));

        if (after.len > 0 and strategy != .always) {
            const next = after[0];
            if (strategy == .beforeWhitespace) {
                if (next != ' ' and next != '\t' and next != '\n') return null;
            } else if (!isBeforeClosingBrace(config, after) and !shouldAutoCloseBefore(config, next, quote)) {
                return null;
            }
        }

        if (!quote and strategy != .always and !ch_is_already_typed) {
            if (model.hasUnmatchedClosingBracketAfter(Position.init(position.lineNumber, before_column), pair.open)) {
                return null;
            }
        }

        if (quote and pair.open.len == 1 and strategy != .always and before.len > 0) {
            if (isWordCharacter(before[before.len - 1])) return null;
        }

        model.forceTokenization(position.lineNumber);
        const token_type = try model.getTokenTypeIfInsertingCharacter(position.lineNumber, before_column, ch);
        if (!pairIsOK(config, pair, token_type)) return null;
    }

    return pair;
}

/// Replaces the selection with `open + close` and places the cursor between
/// the pair. This is upstream's `TypeWithAutoClosingCommand`.
pub const TypeWithAutoClosingCommand = struct {
    allocator: Allocator,
    selection: Selection,
    open: []const u8,
    close: []const u8,
    insert_open: bool,

    pub fn init(allocator: Allocator, selection: Selection, open: []const u8, close: []const u8, insert_open: bool) TypeWithAutoClosingCommand {
        return .{ .allocator = allocator, .selection = selection, .open = open, .close = close, .insert_open = insert_open };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *TypeWithAutoClosingCommand) ICommand {
        return commandOf(TypeWithAutoClosingCommand).of(self);
    }

    pub fn getEditOperations(self: *TypeWithAutoClosingCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        _ = model;
        var text = ArrayList(u8).init(self.allocator);
        defer text.deinit();
        if (self.insert_open) try text.appendSlice(self.open);
        try text.appendSlice(self.close);
        try builder.addTrackedEditOperation(
            Range.init(self.selection.startLineNumber, self.selection.startColumn, self.selection.endLineNumber, self.selection.endColumn),
            text.items,
            false,
        );
    }

    pub fn computeCursorState(self: *TypeWithAutoClosingCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        const inverse = helper.getInverseEditOperations();
        const range = inverse[0].range;
        const column = range.endColumn -| self.close.len;
        return Selection.init(range.endLineNumber, column, range.endLineNumber, column);
    }
};

/// Returns true when typing `ch` should overtype an existing closing
/// character instead of inserting a duplicate.
pub fn shouldOvertypeClose(
    config: *const CursorConfiguration,
    model: *TextModel,
    selections: []const Selection,
    ch: []const u8,
) !bool {
    if (config.autoClosingOvertype == .never or ch.len != 1) return false;
    for (selections) |selection| {
        if (!selection.isEmpty()) return false;
        const position = selection.getPosition();
        const line = try model.getLineContent(position.lineNumber);
        defer line.deinit();
        if (position.column > line.items.len) return false;
        if (line.items[position.column - 1] != ch[0]) return false;
    }
    for (config.auto_closing_pairs) |pair| {
        if (pair.close.len == 1 and pair.close[0] == ch[0]) return true;
    }
    return false;
}

/// Returns the range that removes an automatically inserted pair around a
/// collapsed cursor, or null.
pub fn autoClosingDeleteRange(
    config: *const CursorConfiguration,
    model: *TextModel,
    selection: Selection,
) !?Range {
    if (config.autoClosingDelete == .never or !selection.isEmpty()) return null;
    const position = selection.getPosition();
    if (position.column <= 1) return null;
    const line = try model.getLineContent(position.lineNumber);
    defer line.deinit();
    if (position.column > line.items.len) return null;

    const before = line.items[position.column - 2];
    const after = line.items[position.column - 1];
    for (config.auto_closing_pairs) |pair| {
        if (pair.open.len == 1 and pair.close.len == 1 and pair.open[0] == before and pair.close[0] == after) {
            return Range.init(position.lineNumber, position.column - 1, position.lineNumber, position.column + 1);
        }
    }
    return null;
}

comptime {
    _ = commandOf(TypeWithAutoClosingCommand).of;
}
