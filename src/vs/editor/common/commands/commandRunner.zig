// Port of the command execution loop from
// `src/vs/editor/common/cursor/cursor.ts` (`_getEditOperations` /
// `_executeCommands`).
//
// The browser cursor controller cannot be ported directly. This module keeps
// the portable part: it runs a batch of `ICommand`s, maps tracked selections
// through the edits the commands produced, and asks each command for its
// resulting cursor state.
//
// Tracked selections are mapped through a `TextEdit` built from the command's
// forward edits. The model's decoration-backed tracked ranges are not used
// because its decoration id migration (string vs. u64) is still incomplete.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const String = @import("../../../base/common/strings.zig").String;
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const selection_mod = @import("../core/selection.zig");
const Selection = selection_mod.Selection;
const SelectionDirection = selection_mod.SelectionDirection;
const TextLength = @import("../core/text/textLength.zig").TextLength;
const TextEdit = @import("../core/edits/textEdit.zig").TextEdit;
const TextReplacement = @import("../core/edits/textEdit.zig").TextReplacement;

const model_mod = @import("../model.zig");
const IdentifiedSingleEditOperation = model_mod.IdentifiedSingleEditOperation;
const SingleEditOperationIdentifier = model_mod.SingleEditOperationIdentifier;
const ValidEditOperation = model_mod.ValidEditOperation;

const editor_common = @import("../editorCommon.zig");
const ICommand = editor_common.ICommand;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const ICursorStateComputerData = editor_common.ICursorStateComputerData;

const text_model = @import("../model/textModel.zig");
const TextModel = text_model.TextModel;
const CursorStateComputer = @import("../model/editStack.zig").CursorStateComputer;

const TrackedSelection = struct {
    original: Selection,
    direction: SelectionDirection,
    start_stick_before: bool,
    start_inside_end: bool,
    end_stick_before: bool,
    end_inside_end: bool,
};

const CommandRun = struct {
    command: ICommand,
    tracked: ArrayList(TrackedSelection),
    had_tracked_edit_operation: bool = false,
};

const BuilderState = struct {
    allocator: Allocator,
    model: *TextModel,
    major: i64,
    minor: i64 = 0,
    operations: *ArrayList(IdentifiedSingleEditOperation),
    tracked: *ArrayList(TrackedSelection),
    inserts_auto_whitespace: ?bool,
    had_tracked_edit_operation: bool = false,
    error_flag: ?anyerror = null,
};

fn addEditOperation(
    context: *anyopaque,
    range: Range,
    text: ?[]const u8,
    force_move_markers: bool,
) anyerror!void {
    const self: *BuilderState = @ptrCast(@alignCast(context));

    if (range.isEmpty() and (text == null or text.?.len == 0)) {
        // Commands sometimes want to add a no-op to force execution. The
        // model does not need one.
        return;
    }

    var owned_text: ?String = null;
    if (text) |value| {
        var buffer = ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();
        try buffer.appendSlice(value);
        owned_text = String.initOwned(buffer);
    }
    errdefer {
        if (owned_text) |*value| value.deinit();
    }

    try self.operations.append(.{
        .range = range,
        .text = owned_text,
        .forceMoveMarkers = force_move_markers,
        .identifier = SingleEditOperationIdentifier{
            .major = self.major,
            .minor = self.minor,
        },
        .isAutoWhitespaceEdit = self.inserts_auto_whitespace,
        ._isTracked = false,
    });
    self.minor += 1;
}

fn addTrackedEditOperation(
    context: *anyopaque,
    range: Range,
    text: ?[]const u8,
    force_move_markers: bool,
) anyerror!void {
    const self: *BuilderState = @ptrCast(@alignCast(context));
    self.had_tracked_edit_operation = true;
    return addEditOperation(context, range, text, force_move_markers);
}

fn trackSelection(context: *anyopaque, selection: Selection) u64 {
    const self: *BuilderState = @ptrCast(@alignCast(context));

    const empty = selection.isEmpty();
    const at_line_end = empty and
        selection.startColumn == self.model.getLineMaxColumn(selection.startLineNumber);

    var start_stick_before = false;
    var start_inside_end = true;
    var end_stick_before = false;
    var end_inside_end = true;

    if (empty) {
        if (at_line_end) {
            start_stick_before = true;
            start_inside_end = false;
            end_stick_before = true;
            end_inside_end = false;
        }
    } else {
        start_inside_end = false;
        end_stick_before = true;
    }

    const index = self.tracked.items.len;
    self.tracked.append(.{
        .original = selection,
        .direction = selection.getDirection(),
        .start_stick_before = start_stick_before,
        .start_inside_end = start_inside_end,
        .end_stick_before = end_stick_before,
        .end_inside_end = end_inside_end,
    }) catch |err| {
        self.error_flag = err;
        return 0;
    };
    return @intCast(index);
}

fn mapPosition(edit: *const TextEdit, position: Position, stick_before: bool, inside_end: bool) Position {
    if (!stick_before) {
        // A tracked marker that does not stick to the previous character moves
        // after text inserted exactly at its position.
        for (edit.replacements) |replacement| {
            const start_position = replacement.range.getStartPosition();
            if (replacement.range.isEmpty() and start_position.equals(position)) {
                return TextLength.ofText(replacement.text).addToPosition(position);
            }
        }
    }

    return switch (edit.mapPosition(position)) {
        .position => |mapped| mapped,
        .range => |mapped| if (inside_end) blk: {
            const end = mapped.getEndPosition();
            // A marker that sticks to the previous character stays on the
            // character before a replaced range's end.
            if (end.column > 1) break :blk Position.init(end.lineNumber, end.column - 1);
            break :blk end;
        } else mapped.getStartPosition(),
    };
}

const Helper = struct {
    edit: ?*const TextEdit,
    tracked: []const TrackedSelection,
    inverse: []const ValidEditOperation,

    fn getInverseEditOperations(context: *anyopaque) []const ValidEditOperation {
        const self: *Helper = @ptrCast(@alignCast(context));
        return self.inverse;
    }

    fn getTrackedSelection(context: *anyopaque, id: u64) Selection {
        const self: *Helper = @ptrCast(@alignCast(context));
        const index: usize = @intCast(id);
        if (index >= self.tracked.len) {
            return Selection.init(1, 1, 1, 1);
        }

        const tracked = self.tracked[index];
        const edit = self.edit orelse return tracked.original;
        const start = mapPosition(
            edit,
            tracked.original.getStartPosition(),
            tracked.start_stick_before,
            tracked.start_inside_end,
        );
        const end = mapPosition(
            edit,
            tracked.original.getEndPosition(),
            tracked.end_stick_before,
            tracked.end_inside_end,
        );
        return selection_mod.createWithDirection(
            start.lineNumber,
            start.column,
            end.lineNumber,
            end.column,
            tracked.direction,
        );
    }

    fn interface(self: *Helper) ICursorStateComputerData {
        return .{
            .context = self,
            .get_inverse_edit_operations = getInverseEditOperations,
            .get_tracked_selection = getTrackedSelection,
        };
    }
};

const CursorComputer = struct {
    allocator: Allocator,
    model: *TextModel,
    runs: []const CommandRun,
    before: []const Selection,
    edit: ?*const TextEdit,

    fn compute(context: *anyopaque, inverse_operations: []ValidEditOperation) ?[]Selection {
        const self: *CursorComputer = @ptrCast(@alignCast(context));

        var groups = self.allocator.alloc(ArrayList(ValidEditOperation), self.runs.len) catch return null;
        defer {
            for (groups) |*group| group.deinit();
            self.allocator.free(groups);
        }
        for (groups) |*group| group.* = ArrayList(ValidEditOperation).init(self.allocator);

        for (inverse_operations) |op| {
            const identifier = op.identifier orelse continue;
            if (identifier.major < 0) continue;
            const major: usize = @intCast(identifier.major);
            if (major >= groups.len) continue;
            groups[major].append(op) catch return null;
        }

        for (groups) |*group| {
            std.mem.sort(ValidEditOperation, group.items, {}, struct {
                fn lessThan(_: void, a: ValidEditOperation, b: ValidEditOperation) bool {
                    const a_minor = if (a.identifier) |id| id.minor else 0;
                    const b_minor = if (b.identifier) |id| id.minor else 0;
                    return a_minor < b_minor;
                }
            }.lessThan);
        }

        const result = self.allocator.alloc(Selection, self.before.len) catch return null;
        for (self.runs, 0..) |run, i| {
            if (i >= groups.len or groups[i].items.len == 0) {
                result[i] = self.before[i];
                continue;
            }

            var helper = Helper{
                .edit = self.edit,
                .tracked = run.tracked.items,
                .inverse = groups[i].items,
            };
            result[i] = run.command.computeCursorState(self.model, helper.interface()) catch self.before[i];
        }
        return result;
    }

    fn interface(self: *CursorComputer) CursorStateComputer {
        return .{ .context = self, .compute = compute };
    }
};

/// Runs a batch of commands against `model`.
///
/// `commands[i]` corresponds to `before_selections[i]` and produces one
/// resulting selection. The returned slice is allocated with `allocator` and
/// owned by the caller; `null` means the commands produced no edits at all.
pub fn executeCommands(
    allocator: Allocator,
    model: *TextModel,
    commands: []const ?ICommand,
    before_selections: []const Selection,
) !?[]Selection {
    if (commands.len != before_selections.len) {
        return error.InvalidArgument;
    }

    var runs = ArrayList(CommandRun).init(allocator);
    defer {
        for (runs.items) |*run| run.tracked.deinit();
        runs.deinit();
    }

    var operations = ArrayList(IdentifiedSingleEditOperation).init(allocator);
    defer {
        for (operations.items) |*op| {
            if (op.text) |*text| text.deinit();
        }
        operations.deinit();
    }

    for (commands, 0..) |maybe_command, index| {
        const command = maybe_command orelse continue;

        try runs.append(.{
            .command = command,
            .tracked = ArrayList(TrackedSelection).init(allocator),
        });
        const run = &runs.items[runs.items.len - 1];

        var state = BuilderState{
            .allocator = allocator,
            .model = model,
            .major = @intCast(index),
            .operations = &operations,
            .tracked = &run.tracked,
            .inserts_auto_whitespace = command.inserts_auto_whitespace,
        };
        const builder = IEditOperationBuilder{
            .context = &state,
            .add_edit_operation = addEditOperation,
            .add_tracked_edit_operation = addTrackedEditOperation,
            .track_selection = trackSelection,
        };

        try command.getEditOperations(model, builder);
        if (state.error_flag) |err| return err;
        run.had_tracked_edit_operation = state.had_tracked_edit_operation;
    }

    if (operations.items.len == 0) {
        return null;
    }

    for (runs.items) |run| {
        if (run.had_tracked_edit_operation) {
            operations.items[0]._isTracked = true;
            break;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var has_tracked = false;
    for (runs.items) |run| {
        if (run.tracked.items.len > 0) {
            has_tracked = true;
            break;
        }
    }

    var text_edit: ?TextEdit = null;
    if (has_tracked) {
        var replacements = ArrayList(TextReplacement).init(arena);
        for (operations.items) |op| {
            const text = if (op.text) |*value| value.items() else "";
            try replacements.append(TextReplacement.init(op.range, text));
        }
        text_edit = try TextEdit.fromParallelReplacementsUnsorted(arena, replacements.items);
    }

    const before = try allocator.dupe(Selection, before_selections);
    defer allocator.free(before);

    var computer = CursorComputer{
        .allocator = allocator,
        .model = model,
        .runs = runs.items,
        .before = before,
        .edit = if (text_edit) |*edit| edit else null,
    };
    return try model.pushEditOperations(before, operations.items, computer.interface(), null);
}
