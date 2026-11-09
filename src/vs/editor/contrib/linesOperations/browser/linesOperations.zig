// Port of the portable command-producing actions from
// `src/vs/editor/contrib/linesOperations/browser/linesOperations.ts`.
//
// The editor action/keybinding wrappers are intentionally not ported. These
// helpers execute the same commands through the shared command runner.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const range_mod = @import("../../../common/core/range.zig");
const Range = range_mod.Range;
const Position = @import("../../../common/core/position.zig").Position;
const Selection = @import("../../../common/core/selection.zig").Selection;

const editor_common = @import("../../../common/editorCommon.zig");
const ICommand = editor_common.ICommand;
const commandOf = editor_common.commandOf;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const command_runner = @import("../../../common/commands/commandRunner.zig");

const CopyLinesCommand = @import("./copyLinesCommand.zig").CopyLinesCommand;
const MoveLinesCommand = @import("./moveLinesCommand.zig").MoveLinesCommand;
const SortLinesCommand = @import("./sortLinesCommand.zig").SortLinesCommand;
const ReplaceCommandThatSelectsText = @import("../../../common/commands/replaceCommand.zig").ReplaceCommandThatSelectsText;
const TrimTrailingWhitespaceCommand = @import("../../../common/commands/trimTrailingWhitespaceCommand.zig").TrimTrailingWhitespaceCommand;

fn runConcrete(
    comptime T: type,
    allocator: Allocator,
    model: *TextModel,
    selections: []const Selection,
    commands: []T,
) !?[]Selection {
    const interfaces = try allocator.alloc(?ICommand, commands.len);
    defer allocator.free(interfaces);
    for (commands, 0..) |*command, i| {
        interfaces[i] = commandOf(T).of(command);
    }
    return command_runner.executeCommands(allocator, model, interfaces, selections);
}

const CopyCandidate = struct {
    selection: Selection,
    index: usize,
    ignore: bool = false,
};

fn copyCandidateLessThan(_: void, a: CopyCandidate, b: CopyCandidate) bool {
    const a_range = Range.init(
        a.selection.startLineNumber,
        a.selection.startColumn,
        a.selection.endLineNumber,
        a.selection.endColumn,
    );
    const b_range = Range.init(
        b.selection.startLineNumber,
        b.selection.startColumn,
        b.selection.endLineNumber,
        b.selection.endColumn,
    );
    return range_mod.compareRangesUsingStarts(&a_range, &b_range) < 0;
}

/// Copy Line Up/Down. `down` selects the direction.
pub fn copyLines(
    allocator: Allocator,
    model: *TextModel,
    selections: []const Selection,
    down: bool,
) !?[]Selection {
    if (selections.len == 0) return null;

    const candidates = try allocator.alloc(CopyCandidate, selections.len);
    defer allocator.free(candidates);
    for (selections, 0..) |selection, index| {
        candidates[index] = .{ .selection = selection, .index = index };
    }
    std.mem.sort(CopyCandidate, candidates, {}, copyCandidateLessThan);

    var previous_index: usize = 0;
    var i: usize = 1;
    while (i < candidates.len) : (i += 1) {
        const previous = &candidates[previous_index];
        const current = &candidates[i];
        if (previous.selection.endLineNumber == current.selection.startLineNumber) {
            if (previous.index < current.index) {
                current.ignore = true;
            } else {
                previous.ignore = true;
                previous_index = i;
            }
        } else {
            previous_index = i;
        }
    }

    var commands = try allocator.alloc(CopyLinesCommand, selections.len);
    defer allocator.free(commands);
    for (selections, 0..) |selection, index| {
        var ignore = false;
        for (candidates) |candidate| {
            if (candidate.index == index) {
                ignore = candidate.ignore;
                break;
            }
        }
        commands[index] = CopyLinesCommand.init(allocator, selection, down, ignore);
    }

    return runConcrete(CopyLinesCommand, allocator, model, selections, commands);
}

/// Move Line Up/Down.
pub fn moveLines(
    allocator: Allocator,
    model: *TextModel,
    selections: []const Selection,
    down: bool,
) !?[]Selection {
    if (selections.len == 0) return null;

    const commands = try allocator.alloc(MoveLinesCommand, selections.len);
    defer allocator.free(commands);
    for (selections, 0..) |selection, index| {
        commands[index] = MoveLinesCommand.init(allocator, selection, down, .Advanced);
    }

    return runConcrete(MoveLinesCommand, allocator, model, selections, commands);
}

/// Sort Lines Ascending/Descending. A single-line selection applies to the
/// whole document, matching the upstream action.
pub fn sortLines(
    allocator: Allocator,
    model: *TextModel,
    selections: []const Selection,
    descending: bool,
) !?[]Selection {
    if (selections.len == 0) return null;

    var effective = try allocator.alloc(Selection, selections.len);
    defer allocator.free(effective);
    for (selections, 0..) |selection, index| {
        effective[index] = selection;
    }

    if (selections.len == 1 and selections[0].startLineNumber == selections[0].endLineNumber) {
        effective[0] = Selection.init(1, 1, model.getLineCount(), model.getLineMaxColumn(model.getLineCount()));
    }

    for (effective) |selection| {
        var probe = SortLinesCommand.init(allocator, selection, descending);
        if (!try probe.canRun(model)) return null;
    }

    const commands = try allocator.alloc(SortLinesCommand, effective.len);
    defer allocator.free(commands);
    for (effective, 0..) |selection, index| {
        commands[index] = SortLinesCommand.init(allocator, selection, descending);
    }

    return runConcrete(SortLinesCommand, allocator, model, effective, commands);
}

/// Duplicate the current selection. Empty selections duplicate the line; a
/// non-empty selection is inserted again at its end and selected.
pub fn duplicateSelection(
    allocator: Allocator,
    model: *TextModel,
    selections: []const Selection,
) !?[]Selection {
    if (selections.len == 0) return null;

    var copies = ArrayList(CopyLinesCommand).init(allocator);
    defer copies.deinit();
    try copies.ensureTotalCapacity(selections.len);
    var replacements = ArrayList(ReplaceCommandThatSelectsText).init(allocator);
    defer replacements.deinit();
    try replacements.ensureTotalCapacity(selections.len);
    var texts = ArrayList([]u8).init(allocator);
    defer {
        for (texts.items) |text| allocator.free(text);
        texts.deinit();
    }

    const interfaces = try allocator.alloc(?ICommand, selections.len);
    defer allocator.free(interfaces);

    for (selections, 0..) |selection, index| {
        if (selection.isEmpty()) {
            try copies.append(CopyLinesCommand.init(allocator, selection, true, false));
            interfaces[index] = commandOf(CopyLinesCommand).of(&copies.items[copies.items.len - 1]);
        } else {
            var value = try model.getValueInRange(Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn), null);
            const text = try value.toOwnedSlice();
            try texts.append(text);
            try replacements.append(ReplaceCommandThatSelectsText.init(
                Range.init(selection.endLineNumber, selection.endColumn, selection.endLineNumber, selection.endColumn),
                text,
            ));
            interfaces[index] = commandOf(ReplaceCommandThatSelectsText).of(&replacements.items[replacements.items.len - 1]);
        }
    }

    return command_runner.executeCommands(allocator, model, interfaces, selections);
}

/// Trim trailing whitespace on all lines except the lines the cursors sit on.
pub fn trimTrailingWhitespace(
    allocator: Allocator,
    model: *TextModel,
    selections: []const Selection,
) !?[]Selection {
    if (selections.len == 0) return null;

    const commands = try allocator.alloc(TrimTrailingWhitespaceCommand, selections.len);
    defer allocator.free(commands);

    const positions = try allocator.alloc(Position, selections.len);
    defer allocator.free(positions);
    for (selections, 0..) |selection, index| {
        positions[index] = selection.getPosition();
    }

    for (selections, 0..) |selection, index| {
        commands[index] = TrimTrailingWhitespaceCommand.init(allocator, selection, positions, false);
    }

    return runConcrete(TrimTrailingWhitespaceCommand, allocator, model, selections, commands);
}
