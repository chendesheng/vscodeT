const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Position = @import("../core/position.zig").Position;
const range_mod = @import("../core/range.zig");
const Range = range_mod.Range;
const Selection = @import("../core/selection.zig").Selection;
const CursorContext = @import("./cursorContext.zig").CursorContext;
const Cursor = @import("./oneCursor.zig").Cursor;
const cursorCommon = @import("../cursorCommon.zig");
const CursorState = cursorCommon.CursorState;
const PartialCursorState = cursorCommon.PartialCursorState;

const SortedCursor = struct {
    index: usize,
    selection: Selection,
};

fn compareSortedCursors(_: void, a: SortedCursor, b: SortedCursor) bool {
    const a_range = Range.init(a.selection.startLineNumber, a.selection.startColumn, a.selection.endLineNumber, a.selection.endColumn);
    const b_range = Range.init(b.selection.startLineNumber, b.selection.startColumn, b.selection.endLineNumber, b.selection.endColumn);
    return range_mod.compareRangesUsingStarts(&a_range, &b_range) < 0;
}

pub const CursorCollection = struct {
    allocator: Allocator,
    context: *CursorContext,
    cursors: ArrayList(Cursor),
    lastAddedCursorIndex: usize,

    pub fn init(allocator: Allocator, context: *CursorContext) !CursorCollection {
        var cursors = ArrayList(Cursor).init(allocator);
        errdefer cursors.deinit();
        try cursors.append(try Cursor.init(context));
        return .{
            .allocator = allocator,
            .context = context,
            .cursors = cursors,
            .lastAddedCursorIndex = 0,
        };
    }

    pub fn deinit(self: *CursorCollection) void {
        for (self.cursors.items) |*cursor| cursor.dispose(self.context);
        self.cursors.deinit();
    }

    pub fn updateContext(self: *CursorCollection, context: *CursorContext) void {
        self.context = context;
    }

    pub fn ensureValidState(self: *CursorCollection) !void {
        for (self.cursors.items) |*cursor| try cursor.ensureValidState(self.context);
    }

    pub fn getAll(self: *CursorCollection, allocator: Allocator) ![]CursorState {
        const result = try allocator.alloc(CursorState, self.cursors.items.len);
        for (self.cursors.items, 0..) |*cursor, i| result[i] = cursor.asCursorState();
        return result;
    }

    pub fn getSelections(self: *CursorCollection, allocator: Allocator) ![]Selection {
        const result = try allocator.alloc(Selection, self.cursors.items.len);
        for (self.cursors.items, 0..) |*cursor, i| result[i] = cursor.modelState.selection;
        return result;
    }

    pub fn getViewSelections(self: *CursorCollection, allocator: Allocator) ![]Selection {
        const result = try allocator.alloc(Selection, self.cursors.items.len);
        for (self.cursors.items, 0..) |*cursor, i| result[i] = cursor.viewState.selection;
        return result;
    }

    pub fn getViewPositions(self: *CursorCollection, allocator: Allocator) ![]Position {
        const result = try allocator.alloc(Position, self.cursors.items.len);
        for (self.cursors.items, 0..) |*cursor, i| result[i] = cursor.viewState.position;
        return result;
    }

    pub fn getPrimaryCursor(self: *CursorCollection) CursorState {
        return self.cursors.items[0].asCursorState();
    }

    pub fn setSelections(self: *CursorCollection, allocator: Allocator, selections: []const Selection) !void {
        const states = try CursorState.fromModelSelections(allocator, selections);
        defer allocator.free(states);
        try self.setStates(states);
    }

    pub fn setStates(self: *CursorCollection, states: []const PartialCursorState) !void {
        if (states.len == 0) return;
        try self.cursors.items[0].setState(self.context, states[0].modelState, states[0].viewState);
        try self.setSecondaryStates(states[1..]);
    }

    fn setSecondaryStates(self: *CursorCollection, secondaryStates: []const PartialCursorState) !void {
        const secondaryCursorsLength = self.cursors.items.len - 1;
        const secondaryStatesLength = secondaryStates.len;

        if (secondaryCursorsLength < secondaryStatesLength) {
            for (0..secondaryStatesLength - secondaryCursorsLength) |_| try self.addSecondaryCursor();
        } else if (secondaryCursorsLength > secondaryStatesLength) {
            for (0..secondaryCursorsLength - secondaryStatesLength) |_| self.removeSecondaryCursor(self.cursors.items.len - 2);
        }

        for (secondaryStates, 0..) |state, i| {
            try self.cursors.items[i + 1].setState(self.context, state.modelState, state.viewState);
        }
    }

    pub fn killSecondaryCursors(self: *CursorCollection) !void {
        try self.setSecondaryStates(&[_]PartialCursorState{});
    }

    fn addSecondaryCursor(self: *CursorCollection) !void {
        try self.cursors.append(try Cursor.init(self.context));
        self.lastAddedCursorIndex = self.cursors.items.len - 1;
    }

    pub fn getLastAddedCursorIndex(self: *const CursorCollection) usize {
        if (self.cursors.items.len == 1 or self.lastAddedCursorIndex == 0) return 0;
        return self.lastAddedCursorIndex;
    }

    fn removeSecondaryCursor(self: *CursorCollection, removeIndex: usize) void {
        if (self.lastAddedCursorIndex >= removeIndex + 1) self.lastAddedCursorIndex -= 1;
        var removed = self.cursors.orderedRemove(removeIndex + 1);
        removed.dispose(self.context);
    }

    pub fn normalize(self: *CursorCollection) !void {
        if (self.cursors.items.len == 1) return;
        if (!self.context.cursorConfig.multiCursorMergeOverlapping) return;

        var sorted = ArrayList(SortedCursor).init(self.allocator);
        defer sorted.deinit();
        for (self.cursors.items, 0..) |*cursor, i| {
            try sorted.append(.{ .index = i, .selection = cursor.modelState.selection });
        }
        std.sort.heap(SortedCursor, sorted.items, {}, compareSortedCursors);

        var sorted_index: usize = 0;
        while (sorted_index + 1 < sorted.items.len) {
            const current = sorted.items[sorted_index];
            const next = sorted.items[sorted_index + 1];
            const currentSelection = current.selection;
            const nextSelection = next.selection;

            const shouldMerge = if (nextSelection.isEmpty() or currentSelection.isEmpty())
                nextSelection.getStartPosition().isBeforeOrEqual(currentSelection.getEndPosition())
            else
                nextSelection.getStartPosition().isBefore(currentSelection.getEndPosition());

            if (!shouldMerge) {
                sorted_index += 1;
                continue;
            }

            const winner_sorted_index = if (current.index < next.index) sorted_index else sorted_index + 1;
            const looser_sorted_index = if (current.index < next.index) sorted_index + 1 else sorted_index;
            const looser_index = sorted.items[looser_sorted_index].index;
            const winner_index = sorted.items[winner_sorted_index].index;
            const looser_selection = sorted.items[looser_sorted_index].selection;
            const winner_selection = sorted.items[winner_sorted_index].selection;

            if (!looser_selection.equalsSelection(&winner_selection)) {
                const resulting_range = looser_selection.plusRange(&winner_selection);
                const looser_is_ltr = looser_selection.selectionStartLineNumber == looser_selection.startLineNumber and looser_selection.selectionStartColumn == looser_selection.startColumn;
                const winner_is_ltr = winner_selection.selectionStartLineNumber == winner_selection.startLineNumber and winner_selection.selectionStartColumn == winner_selection.startColumn;

                var resulting_is_ltr = winner_is_ltr;
                if (looser_index == self.lastAddedCursorIndex) {
                    resulting_is_ltr = looser_is_ltr;
                    self.lastAddedCursorIndex = winner_index;
                }

                const resulting_selection = if (resulting_is_ltr)
                    Selection.init(resulting_range.startLineNumber, resulting_range.startColumn, resulting_range.endLineNumber, resulting_range.endColumn)
                else
                    Selection.init(resulting_range.endLineNumber, resulting_range.endColumn, resulting_range.startLineNumber, resulting_range.startColumn);

                sorted.items[winner_sorted_index].selection = resulting_selection;
                const resulting_state = CursorState.fromModelSelection(resulting_selection);
                try self.cursors.items[winner_index].setState(self.context, resulting_state.modelState, resulting_state.viewState);
            }

            for (sorted.items) |*entry| {
                if (entry.index > looser_index) entry.index -= 1;
            }

            _ = sorted.orderedRemove(looser_sorted_index);
            self.removeSecondaryCursor(looser_index - 1);
            if (sorted_index > 0) sorted_index -= 1;
        }
    }
};
