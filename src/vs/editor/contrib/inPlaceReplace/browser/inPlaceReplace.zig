// Port of `src/vs/editor/contrib/inPlaceReplace/browser/inPlaceReplace.ts`.
//
// Adaptations for this port:
//  * the editor worker service is replaced by a direct call to the already
//    ported `BasicInplaceReplace`; the lookup is synchronous, so upstream's
//    `EditorState` validation after an async request is unnecessary;
//  * the decoration is created and expired by the TUI host because this
//    contribution has no editor object of its own;
//  * the TUI dispatches Alt+. / Alt+, because terminals cannot encode the
//    upstream Ctrl+Shift+Period / Ctrl+Shift+Comma chords. The action metadata
//    still carries the upstream keybindings.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const BasicInplaceReplace = @import("../../../common/languages/supports/inplaceReplaceSupport.zig").BasicInplaceReplace;
const editor_extensions = @import("../../../browser/editorExtensions.zig");
const EditorAction = editor_extensions.EditorAction;

pub const InPlaceReplaceResult = struct {
    range: Range,
    /// Owned by the caller.
    value: []const u8,
    selection: Selection,
    highlight_range: Range,

    pub fn deinit(self: *InPlaceReplaceResult, allocator: Allocator) void {
        allocator.free(@constCast(self.value));
    }
};

/// The controller's portable core: rejects multi-line selections, expands an
/// empty selection by one column, looks up the value set and returns the edit
/// plus the upstream selection/highlight ranges.
pub fn compute(
    allocator: Allocator,
    model: *TextModel,
    selection: Selection,
    up: bool,
) !?InPlaceReplaceResult {
    if (selection.startLineNumber != selection.endLineNumber) {
        // Can't accept a multiline selection.
        return null;
    }

    var range = Range.init(
        selection.startLineNumber,
        selection.startColumn,
        selection.endLineNumber,
        selection.endColumn,
    );
    if (range.startColumn == range.endColumn) {
        range.endColumn += 1;
    }

    var selection_text = try model.getValueInRange(range, null);
    defer selection_text.deinit();

    const maybe_word = model.getWordAtPosition(Position.init(range.startLineNumber, range.startColumn));
    if (maybe_word == null) return null;
    var word = maybe_word.?;
    defer word.deinit();

    const word_range = Range.init(
        range.startLineNumber,
        word.startColumn,
        range.startLineNumber,
        word.endColumn,
    );
    const maybe_result = try BasicInplaceReplace.INSTANCE.navigateValueSet(
        allocator,
        range,
        selection_text.items,
        word_range,
        word.word.items,
        up,
    );
    if (maybe_result == null) return null;
    const result = maybe_result.?;

    if (result.value.len == 0) {
        allocator.free(result.value);
        return null;
    }

    const highlight_range = Range.init(
        result.range.startLineNumber,
        result.range.startColumn,
        result.range.startLineNumber,
        result.range.startColumn + result.value.len,
    );

    var new_selection = selection;
    const diff = @as(isize, @intCast(result.value.len)) -
        @as(isize, @intCast(selection.endColumn - selection.startColumn));
    if (diff > 1) {
        new_selection = Selection.init(
            selection.startLineNumber,
            selection.startColumn,
            selection.endLineNumber,
            selection.endColumn + @as(usize, @intCast(diff - 1)),
        );
    }

    return .{
        .range = result.range,
        .value = result.value,
        .selection = new_selection,
        .highlight_range = highlight_range,
    };
}

pub const InPlaceReplaceUpAction = struct {
    pub const id = "editor.action.inPlaceReplace.up";
    pub const label = "Replace with Previous Value";
    pub const description = "Replace with Previous Value";
    pub const keybinding = editor_extensions.Keybinding{
        .key = ",",
        .ctrl = true,
        .shift = true,
        .weight = .editor_contrib,
        .when = "editorTextFocus",
    };

    context: *anyopaque,
    run_editor: *const fn (context: *anyopaque) anyerror!void,

    pub fn init(context: *anyopaque, run_editor: *const fn (context: *anyopaque) anyerror!void) InPlaceReplaceUpAction {
        return .{ .context = context, .run_editor = run_editor };
    }

    pub fn run(self: *InPlaceReplaceUpAction) !void {
        return self.run_editor(self.context);
    }

    pub fn editorAction(self: *InPlaceReplaceUpAction) EditorAction {
        return EditorAction.init(.{
            .id = id,
            .label = label,
            .description = description,
            .precondition = "writable",
            .keybinding = keybinding,
            .context = self,
            .run = runEditorAction,
        });
    }

    fn runEditorAction(context: *anyopaque) anyerror!void {
        const self: *InPlaceReplaceUpAction = @ptrCast(@alignCast(context));
        return self.run();
    }
};

pub const InPlaceReplaceDownAction = struct {
    pub const id = "editor.action.inPlaceReplace.down";
    pub const label = "Replace with Next Value";
    pub const description = "Replace with Next Value";
    pub const keybinding = editor_extensions.Keybinding{
        .key = ".",
        .ctrl = true,
        .shift = true,
        .weight = .editor_contrib,
        .when = "editorTextFocus",
    };

    context: *anyopaque,
    run_editor: *const fn (context: *anyopaque) anyerror!void,

    pub fn init(context: *anyopaque, run_editor: *const fn (context: *anyopaque) anyerror!void) InPlaceReplaceDownAction {
        return .{ .context = context, .run_editor = run_editor };
    }

    pub fn run(self: *InPlaceReplaceDownAction) !void {
        return self.run_editor(self.context);
    }

    pub fn editorAction(self: *InPlaceReplaceDownAction) EditorAction {
        return EditorAction.init(.{
            .id = id,
            .label = label,
            .description = description,
            .precondition = "writable",
            .keybinding = keybinding,
            .context = self,
            .run = runEditorAction,
        });
    }

    fn runEditorAction(context: *anyopaque) anyerror!void {
        const self: *InPlaceReplaceDownAction = @ptrCast(@alignCast(context));
        return self.run();
    }
};
