// Terminal subset of `src/vs/editor/common/cursor/cursor.ts`.
//
// The browser `CursorsController` orchestrates edits, typing, commands,
// reveal and view-model events around a `CursorCollection`. The terminal
// controller subset owns the collection and the selection/state surface the
// TUI and code editor widget can share; typing/command orchestration stays in
// the TUI editor (the terminal replacement for the browser controller).
const std = @import("std");
const Allocator = std.mem.Allocator;

const text_model = @import("../model/textModel.zig");
const cursor_context = @import("cursorContext.zig");
const cursor_collection = @import("cursorCollection.zig");
const cursor_common = @import("../cursorCommon.zig");
const Selection = @import("../core/selection.zig").Selection;
const Position = @import("../core/position.zig").Position;
const CursorState = cursor_common.CursorState;
const PartialCursorState = cursor_common.PartialCursorState;
const CursorCollection = cursor_collection.CursorCollection;
const CursorContext = cursor_context.CursorContext;

pub const CursorsController = struct {
    allocator: Allocator,
    model: *text_model.TextModel,
    context: *CursorContext,
    cursors: CursorCollection,

    pub fn init(allocator: Allocator, context: *CursorContext) !CursorsController {
        return .{
            .allocator = allocator,
            .model = context.model,
            .context = context,
            .cursors = try CursorCollection.init(allocator, context),
        };
    }

    pub fn deinit(self: *CursorsController) void {
        self.cursors.deinit();
    }

    pub fn getSelections(self: *CursorsController, allocator: Allocator) ![]Selection {
        return self.cursors.getSelections(allocator);
    }

    pub fn getSelection(self: *CursorsController) Selection {
        return self.cursors.getPrimaryCursor().modelState.selection;
    }

    pub fn getPosition(self: *CursorsController) Position {
        return self.getSelection().getPosition();
    }

    pub fn getCursorStates(self: *CursorsController, allocator: Allocator) ![]CursorState {
        return self.cursors.getAll(allocator);
    }

    pub fn setSelections(self: *CursorsController, allocator: Allocator, selections: []const Selection) !void {
        try self.cursors.setSelections(allocator, selections);
        try self.cursors.ensureValidState();
    }

    pub fn setStates(self: *CursorsController, states: []const PartialCursorState) !void {
        try self.cursors.setStates(states);
        try self.cursors.ensureValidState();
    }

    pub fn killSecondaryCursors(self: *CursorsController) !void {
        try self.cursors.killSecondaryCursors();
    }

    pub fn saveState(self: *CursorsController, allocator: Allocator) ![]CursorState {
        return self.cursors.getAll(allocator);
    }

    pub fn restoreState(self: *CursorsController, allocator: Allocator, states: []const CursorState) !void {
        const selections = try allocator.alloc(Selection, states.len);
        defer allocator.free(selections);
        for (states, 0..) |state, index| selections[index] = state.modelState.selection;
        try self.setSelections(allocator, selections);
    }

    /// Keeps the cursor collection valid after model edits.
    pub fn onModelContentChanged(self: *CursorsController) !void {
        try self.cursors.ensureValidState();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_support = @import("../../test/common/port/testSupport.zig");
const lines_mod = @import("../viewModel/viewModelLines.zig");
const CoreRange = @import("../core/range.zig").Range;

const Fixture = struct {
    allocator: Allocator,
    model: test_support.TestModel,
    lines: lines_mod.ProjectedViewModelLines,
    converter: lines_mod.CoordinatesConverter,
    config: cursor_common.CursorConfiguration,
    context: CursorContext,

    fn init(self: *Fixture, allocator: Allocator, text: []const u8) !void {
        self.allocator = allocator;
        self.model = try test_support.TestModel.init(allocator, text, "plaintext");
        self.lines = try lines_mod.ProjectedViewModelLines.init(allocator, self.model.model, 80, 4, .Same, .normal);
        self.converter = lines_mod.CoordinatesConverter.init(&self.lines);
        self.config = .{
            .tabSize = 4,
            .indentSize = 4,
            .insertSpaces = true,
            .pageSize = 10,
        };
        self.context = CursorContext.init(self.model.model, self.lines.interface(), self.converter.interface(), &self.config);
    }

    fn deinit(self: *Fixture) void {
        self.lines.deinit();
        self.model.deinit();
    }
};

test "cursors controller: selections, position and state save/restore" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "hello\nworld");
    defer fixture.deinit();

    var controller = try CursorsController.init(allocator, &fixture.context);
    defer controller.deinit();

    const selections = [_]Selection{
        Selection.init(1, 2, 1, 4),
        Selection.init(2, 1, 2, 3),
    };
    try controller.setSelections(allocator, &selections);
    const all = try controller.getSelections(allocator);
    defer allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqual(Position.init(1, 4), controller.getPosition());

    const saved = try controller.saveState(allocator);
    defer allocator.free(saved);

    try controller.setSelections(allocator, &[_]Selection{Selection.init(2, 5, 2, 5)});
    try controller.restoreState(allocator, saved);
    try testing.expectEqual(Position.init(1, 4), controller.getPosition());

    try fixture.model.applyEdit(CoreRange.init(2, 1, 2, 6), "");
    try controller.onModelContentChanged();
    const after_edit = try controller.getSelections(allocator);
    defer allocator.free(after_edit);
    try testing.expectEqual(@as(usize, 2), after_edit.len);
}
