// Port of the cursor undo/redo state machine from
// `src/vs/editor/contrib/cursorUndo/browser/cursorUndo.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Selection = @import("../../../common/core/selection.zig").Selection;
const editor_extensions = @import("../../../browser/editorExtensions.zig");
const EditorAction = editor_extensions.EditorAction;

const CursorState = struct {
    selections: []Selection,

    fn equals(self: CursorState, other: CursorState) bool {
        if (self.selections.len != other.selections.len) return false;
        for (self.selections, other.selections) |a, b| {
            if (!a.equalsSelection(&b)) return false;
        }
        return true;
    }
};

const StackElement = struct {
    cursor_state: CursorState,
    scroll_top: f64 = 0,
    scroll_left: f64 = 0,
};

pub const CursorUndoRedoController = struct {
    allocator: Allocator,
    undo_stack: ArrayList(StackElement),
    redo_stack: ArrayList(StackElement),
    is_cursor_undo_redo: bool = false,

    pub fn init(allocator: Allocator) CursorUndoRedoController {
        return .{
            .allocator = allocator,
            .undo_stack = ArrayList(StackElement).init(allocator),
            .redo_stack = ArrayList(StackElement).init(allocator),
        };
    }

    pub fn deinit(self: *CursorUndoRedoController) void {
        freeStack(&self.undo_stack, self.allocator);
        freeStack(&self.redo_stack, self.allocator);
        self.undo_stack.deinit();
        self.redo_stack.deinit();
    }

    fn freeStack(stack: *ArrayList(StackElement), allocator: Allocator) void {
        for (stack.items) |element| allocator.free(element.cursor_state.selections);
        stack.clearRetainingCapacity();
    }

    fn cloneSelections(allocator: Allocator, selections: []const Selection) ![]Selection {
        const copy = try allocator.alloc(Selection, selections.len);
        @memcpy(copy, selections);
        return copy;
    }

    fn pushState(self: *CursorUndoRedoController, stack: *ArrayList(StackElement), selections: []const Selection, scroll_top: f64, scroll_left: f64) !void {
        const copy = try cloneSelections(self.allocator, selections);
        try stack.append(.{
            .cursor_state = .{ .selections = copy },
            .scroll_top = scroll_top,
            .scroll_left = scroll_left,
        });
    }

    /// Records the previous selection set. The caller supplies the old
    /// selections, matching upstream's selection-change listener.
    pub fn recordSelectionChange(self: *CursorUndoRedoController, old_selections: []const Selection, old_model_version: i64, model_version: i64) !void {
        if (self.is_cursor_undo_redo or old_model_version != model_version) return;
        const state = CursorState{ .selections = try cloneSelections(self.allocator, old_selections) };
        defer self.allocator.free(state.selections);
        if (self.undo_stack.items.len > 0 and self.undo_stack.items[self.undo_stack.items.len - 1].cursor_state.equals(state)) return;
        try self.pushState(&self.undo_stack, old_selections, 0, 0);
        freeStack(&self.redo_stack, self.allocator);
        if (self.undo_stack.items.len > 50) {
            const first = self.undo_stack.orderedRemove(0);
            self.allocator.free(first.cursor_state.selections);
        }
    }

    pub fn cursorUndo(self: *CursorUndoRedoController, current_selections: []const Selection) []const Selection {
        if (self.undo_stack.items.len == 0) return current_selections;
        self.pushState(&self.redo_stack, current_selections, 0, 0) catch return current_selections;
        const element = self.undo_stack.pop().?;
        self.is_cursor_undo_redo = true;
        const result = element.cursor_state.selections;
        self.is_cursor_undo_redo = false;
        return result;
    }

    pub fn cursorRedo(self: *CursorUndoRedoController, current_selections: []const Selection) []const Selection {
        if (self.redo_stack.items.len == 0) return current_selections;
        self.pushState(&self.undo_stack, current_selections, 0, 0) catch return current_selections;
        const element = self.redo_stack.pop().?;
        self.is_cursor_undo_redo = true;
        const result = element.cursor_state.selections;
        self.is_cursor_undo_redo = false;
        return result;
    }
};

pub const CursorUndoAction = struct {
    pub const id = "cursorUndo";
    pub const label = "Cursor Undo";
    pub const description = "Cursor Undo";

    pub fn action(controller: *CursorUndoRedoController, context: *anyopaque, get_current: *const fn (*anyopaque) []const Selection, apply: *const fn (*anyopaque, []const Selection) anyerror!void) EditorAction {
        _ = controller;
        return EditorAction.init(.{
            .id = id,
            .label = label,
            .description = description,
            .context = context,
            .run = struct {
                fn run(_: *anyopaque) anyerror!void {
                    _ = get_current;
                    _ = apply;
                }
            }.run,
        });
    }
};

pub const CursorRedoAction = struct {
    pub const id = "cursorRedo";
    pub const label = "Cursor Redo";
    pub const description = "Cursor Redo";
};
