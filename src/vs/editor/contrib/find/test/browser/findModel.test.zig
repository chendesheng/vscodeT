// Port of `src/vs/editor/contrib/find/test/browser/findModel.test.ts`.
//
// Adapted to the terminal editor: the browser test inspects model decorations;
// this port inspects `FindDecorations` ranges and the editor selection, which
// are the values the view paints. The search progression and state assertions
// are kept.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const FindReplaceState = @import("../../browser/findState.zig").FindReplaceState;
const FindModel = @import("../../browser/findModel.zig").FindModel;

const source =
    \\// my cool header
    \\#include "cool.h"
    \\#include <iostream>
    \\
    \\int main() {
    \\    cout << "hello world, Hello!" << endl;
    \\    cout << "hello world again" << endl;
    \\    cout << "Hello world again" << endl;
    \\    cout << "helloworld again" << endl;
    \\}
    \\// blablablaciao
    \\
;

fn createEditor(allocator: Allocator) !*Editor {
    const io = std.testing.io;
    return Editor.createFromText(allocator, io, source, "test.txt", 80, 24);
}

fn expectState(
    editor: *Editor,
    model: *FindModel,
    cursor: [4]usize,
    highlighted: ?Range,
    matches: []const Range,
) !void {
    const selection = editor.modelSelection();
    try std.testing.expectEqual(cursor[0], selection.startLineNumber);
    try std.testing.expectEqual(cursor[1], selection.startColumn);
    try std.testing.expectEqual(cursor[2], selection.endLineNumber);
    try std.testing.expectEqual(cursor[3], selection.endColumn);

    const decorations = model.getDecorations();
    if (highlighted) |range| {
        try std.testing.expect(decorations.current != null);
        try std.testing.expect(Range.equalsRange(decorations.current.?, range));
    } else {
        try std.testing.expect(decorations.current == null);
    }

    try std.testing.expectEqual(matches.len, decorations.matches.len);
    for (matches, decorations.matches) |expected, actual| {
        try std.testing.expect(Range.equalsRange(expected, actual));
    }
}

test "FindModel: incremental find from beginning of file" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    var state = FindReplaceState.init(allocator);
    defer state.deinit();
    defer @import("../../../../common/core/wordCharacterClassifier.zig").freeWordClassifierCache();
    const model = try FindModel.init(allocator, editor, &state, null, null);
    defer model.deinit();

    state.change(.{ .search_string = "H" }, true, true);
    try expectState(editor, model, .{ 1, 12, 1, 13 }, Range.init(1, 12, 1, 13), &.{
        Range.init(1, 12, 1, 13),
        Range.init(2, 16, 2, 17),
        Range.init(6, 14, 6, 15),
        Range.init(6, 27, 6, 28),
        Range.init(7, 14, 7, 15),
        Range.init(8, 14, 8, 15),
        Range.init(9, 14, 9, 15),
    });

    state.change(.{ .search_string = "He" }, true, true);
    try expectState(editor, model, .{ 1, 12, 1, 14 }, Range.init(1, 12, 1, 14), &.{
        Range.init(1, 12, 1, 14),
        Range.init(6, 14, 6, 16),
        Range.init(6, 27, 6, 29),
        Range.init(7, 14, 7, 16),
        Range.init(8, 14, 8, 16),
        Range.init(9, 14, 9, 16),
    });

    state.change(.{ .search_string = "Hello" }, true, true);
    try expectState(editor, model, .{ 6, 14, 6, 19 }, Range.init(6, 14, 6, 19), &.{
        Range.init(6, 14, 6, 19),
        Range.init(6, 27, 6, 32),
        Range.init(7, 14, 7, 19),
        Range.init(8, 14, 8, 19),
        Range.init(9, 14, 9, 19),
    });

    state.change(.{ .match_case = true }, true, true);
    try expectState(editor, model, .{ 6, 27, 6, 32 }, Range.init(6, 27, 6, 32), &.{
        Range.init(6, 27, 6, 32),
        Range.init(8, 14, 8, 19),
    });

    state.change(.{ .search_string = "hello" }, true, true);
    try expectState(editor, model, .{ 6, 14, 6, 19 }, Range.init(6, 14, 6, 19), &.{
        Range.init(6, 14, 6, 19),
        Range.init(7, 14, 7, 19),
        Range.init(9, 14, 9, 19),
    });

    state.change(.{ .whole_word = true }, true, true);
    try expectState(editor, model, .{ 6, 14, 6, 19 }, Range.init(6, 14, 6, 19), &.{
        Range.init(6, 14, 6, 19),
        Range.init(7, 14, 7, 19),
    });

    state.change(.{ .match_case = false }, true, true);
    try expectState(editor, model, .{ 6, 14, 6, 19 }, Range.init(6, 14, 6, 19), &.{
        Range.init(6, 14, 6, 19),
        Range.init(6, 27, 6, 32),
        Range.init(7, 14, 7, 19),
        Range.init(8, 14, 8, 19),
    });

    state.change(.{ .whole_word = false }, true, true);
    try expectState(editor, model, .{ 6, 14, 6, 19 }, Range.init(6, 14, 6, 19), &.{
        Range.init(6, 14, 6, 19),
        Range.init(6, 27, 6, 32),
        Range.init(7, 14, 7, 19),
        Range.init(8, 14, 8, 19),
        Range.init(9, 14, 9, 19),
    });

    state.change(.{ .search_scope = .{ .ranges = &.{Range.init(8, 1, 10, 1)} } }, true, true);
    try expectState(editor, model, .{ 8, 14, 8, 19 }, Range.init(8, 14, 8, 19), &.{
        Range.init(8, 14, 8, 19),
        Range.init(9, 14, 9, 19),
    });

    state.change(.{ .search_scope = .none }, true, true);
    try expectState(editor, model, .{ 6, 14, 6, 19 }, Range.init(6, 14, 6, 19), &.{
        Range.init(6, 14, 6, 19),
        Range.init(6, 27, 6, 32),
        Range.init(7, 14, 7, 19),
        Range.init(8, 14, 8, 19),
        Range.init(9, 14, 9, 19),
    });
}

test "FindModel: updates matchesCount and clears matches" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var state = FindReplaceState.init(allocator);
    defer state.deinit();

    state.change(.{ .search_string = "hello" }, false, true);
    const model = try FindModel.init(allocator, editor, &state, null, null);
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 5), state.matches_count);
    try std.testing.expectEqual(@as(usize, 5), model.getDecorations().getCount());

    state.change(.{ .search_string = "helloo" }, false, true);
    try std.testing.expectEqual(@as(usize, 0), state.matches_count);
    try std.testing.expectEqual(@as(usize, 0), model.getDecorations().getCount());
}

test "FindModel: next, previous and loop" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    var state = FindReplaceState.init(allocator);
    defer state.deinit();
    const model = try FindModel.init(allocator, editor, &state, null, null);
    defer model.deinit();

    state.change(.{ .search_string = "hello" }, false, true);
    try std.testing.expectEqual(@as(usize, 5), state.matches_count);

    try model.moveToNextMatch();
    var selection = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 6), selection.startLineNumber);
    try std.testing.expectEqual(@as(usize, 14), selection.startColumn);
    try std.testing.expectEqual(@as(usize, 1), state.matches_position);

    try model.moveToNextMatch();
    selection = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 27), selection.startColumn);
    try std.testing.expectEqual(@as(usize, 2), state.matches_position);

    try model.moveToPrevMatch();
    selection = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 14), selection.startColumn);
    try std.testing.expectEqual(@as(usize, 1), state.matches_position);

    // Wrapping backwards moves to the last match.
    try model.moveToPrevMatch();
    selection = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 9), selection.startLineNumber);
    try std.testing.expectEqual(@as(usize, 5), state.matches_position);
}

test "FindModel: replace and replace all" {
    const allocator = std.testing.allocator;
    const editor = try createEditor(allocator);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(1, 1));

    var state = FindReplaceState.init(allocator);
    defer state.deinit();
    const model = try FindModel.init(allocator, editor, &state, null, null);
    defer model.deinit();

    state.change(.{ .search_string = "hello" }, false, true);
    state.change(.{ .replace_string = "goodbye" }, false, true);

    try model.moveToNextMatch();
    try model.replace();
    const replaced = try editor.model.getLineContent(6);
    defer replaced.deinit();
    try std.testing.expect(std.mem.indexOf(u8, replaced.items, "\"goodbye world, Hello!\"") != null);

    try model.replaceAll();
    const line7 = try editor.model.getLineContent(7);
    defer line7.deinit();
    try std.testing.expect(std.mem.indexOf(u8, line7.items, "\"goodbye world again\"") != null);

    state.change(.{ .search_string = "goodbye" }, false, true);
    try std.testing.expectEqual(@as(usize, 5), state.matches_count);
}

test "FindModel: content changes schedule search and explicit cursor changes set start position" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const editor = try Editor.createFromText(allocator, io, "one one", "test.txt", 80, 24);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    var queue = @import("../../../../../base/common/windowDispatch.zig").Queue{ .io = io };
    var state = FindReplaceState.init(allocator);
    defer state.deinit();
    const model = try FindModel.init(allocator, editor, &state, null, null);
    defer model.deinit();
    model.attachWindow(&queue);
    state.change(.{ .search_string = "one", .is_revealed = true }, false, true);
    try std.testing.expectEqual(@as(usize, 2), model.getDecorations().getCount());

    try editor.replaceRange(Range.init(1, 1, 1, 4), "two");
    const deadline = model.update_decorations_scheduler.deadline_ms.?;
    try std.testing.expect(!queue.dispatch(deadline - 1));
    try std.testing.expect(queue.dispatch(deadline));
    try std.testing.expectEqual(@as(usize, 1), model.getDecorations().getCount());

    try editor.setMouseSelection(Position.init(1, 2), Position.init(1, 2));
    try std.testing.expectEqual(Position.init(1, 2), model.getDecorations().getStartPosition());
    state.change(.{ .is_revealed = false }, false, true);
    try editor.replaceRange(Range.init(1, 1, 1, 4), "one");
    try std.testing.expect(!model.update_decorations_scheduler.isScheduled());
}
