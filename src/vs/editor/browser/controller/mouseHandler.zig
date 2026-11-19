// Port of the portable click/drag/selection state machine from
// `src/vs/editor/browser/controller/mouseHandler.ts`.
//
// The browser handler owns pointer capture, DOM listeners and browser hit
// testing. The terminal host feeds decoded pointer events and supplies the
// target node, line mapping and editor selection operations through
// `TerminalMouseHost`; the press/drag/click order and selection behavior stay
// upstream-shaped.

const std = @import("std");
const ui = @import("ui");

const Position = @import("../../common/core/position.zig").Position;

pub const MousePress = struct {
    x: usize,
    y: usize,
};

/// The terminal surface/view operations the handler needs.
pub const TerminalMouseHost = struct {
    context: *anyopaque,

    element_from_point: *const fn (context: *anyopaque, x: usize, y: usize) ?*ui.Node,
    root_node: *const fn (context: *anyopaque) ?*ui.Node,
    is_scrollbar_hit: *const fn (context: *anyopaque, x: usize, y: usize) bool,
    begin_scrollbar_drag: *const fn (context: *anyopaque, x: usize, y: usize) void,
    end_scrollbar_drag: *const fn (context: *anyopaque) void,
    scrollbar_dragging: *const fn (context: *anyopaque) bool,
    drag_scrollbar: *const fn (context: *anyopaque, y: usize) void,
    toggle_fold: *const fn (context: *anyopaque, x: usize, y: usize) anyerror!bool,
    line_for_node: *const fn (context: *anyopaque, node: *ui.Node) ?usize,
    position_at_cell: *const fn (context: *anyopaque, view_line: usize, x: usize) anyerror!Position,
    set_cursor: *const fn (context: *anyopaque, position: Position) anyerror!void,
    selection_start: *const fn (context: *anyopaque) Position,
    select_from: *const fn (context: *anyopaque, anchor: Position, position: Position) anyerror!void,
    update_drag_selection: *const fn (context: *anyopaque, anchor: Position, position: Position) anyerror!void,
    dispatch_click: *const fn (
        context: *anyopaque,
        press_x: usize,
        press_y: usize,
        x: usize,
        y: usize,
        mods: ui.Modifiers,
    ) void,
    scroll_lines: *const fn (context: *anyopaque, y: usize, delta: f64) bool,
};

/// Port of the mouse-state subset of `MouseHandler`.
pub const TerminalMouseHandler = struct {
    press: ?MousePress = null,
    drag_anchor: ?Position = null,
    drag_moved: bool = false,

    pub fn reset(self: *TerminalMouseHandler) void {
        self.press = null;
        self.drag_anchor = null;
        self.drag_moved = false;
    }

    pub fn dispatch(
        self: *TerminalMouseHandler,
        host: TerminalMouseHost,
        event: *ui.MouseEvent,
        target: *ui.Node,
    ) !bool {
        var caret_changed = false;
        switch (event.kind) {
            .down => {
                if (event.button == .left and host.is_scrollbar_hit(host.context, event.x, event.y)) {
                    self.reset();
                    if (!event.default_prevented) {
                        host.begin_scrollbar_drag(host.context, event.x, event.y);
                    }
                    return false;
                }
                host.end_scrollbar_drag(host.context);
                if (event.button == .left and
                    !event.default_prevented and
                    try host.toggle_fold(host.context, event.x, event.y))
                {
                    self.reset();
                    return true;
                }
                if (event.button == .left) {
                    self.press = .{ .x = event.x, .y = event.y };
                    self.drag_anchor = null;
                    self.drag_moved = false;
                    if (!event.default_prevented) {
                        if (host.line_for_node(host.context, target)) |view_line| {
                            const position = try host.position_at_cell(host.context, view_line, event.x);
                            if (event.mods.shift) {
                                const anchor = host.selection_start(host.context);
                                self.drag_anchor = anchor;
                                try host.select_from(host.context, anchor, position);
                            } else {
                                try host.set_cursor(host.context, position);
                                self.drag_anchor = position;
                            }
                            caret_changed = true;
                        }
                    }
                }
            },
            .move => {
                if (host.scrollbar_dragging(host.context)) {
                    host.drag_scrollbar(host.context, event.y);
                    return false;
                }
                if (event.button == .left) {
                    if (self.drag_anchor) |anchor| {
                        if (host.line_for_node(host.context, target)) |view_line| {
                            const position = try host.position_at_cell(host.context, view_line, event.x);
                            if (position.lineNumber != anchor.lineNumber or
                                position.column != anchor.column)
                            {
                                try host.update_drag_selection(host.context, anchor, position);
                                self.drag_moved = true;
                                caret_changed = true;
                            }
                        }
                    }
                }
            },
            .up => {
                if (host.scrollbar_dragging(host.context)) {
                    host.end_scrollbar_drag(host.context);
                    return false;
                }
                if (event.button == .left) {
                    if (self.press) |press| {
                        self.press = null;
                        const drag_moved = self.drag_moved;
                        self.drag_anchor = null;
                        self.drag_moved = false;
                        if (!drag_moved) {
                            host.dispatch_click(
                                host.context,
                                press.x,
                                press.y,
                                event.x,
                                event.y,
                                event.mods,
                            );
                        }
                    }
                }
            },
            .wheel => {
                if (!event.default_prevented and event.delta_y != 0) {
                    _ = host.scroll_lines(host.context, event.y, event.delta_y);
                }
            },
            .click => {},
        }
        return caret_changed;
    }
};

test "terminal mouse handler tracks a press, drag and release" {
    const testing = std.testing;
    const State = struct {
        cursor: Position = Position.init(1, 1),
        selections: usize = 0,
        clicks: usize = 0,
        scrolls: usize = 0,

        fn element(_: *anyopaque, _: usize, _: usize) ?*ui.Node {
            return null;
        }
        fn root(_: *anyopaque) ?*ui.Node {
            return null;
        }
        fn noScrollbar(_: *anyopaque, _: usize, _: usize) bool {
            return false;
        }
        fn noDrag(_: *anyopaque, _: usize, _: usize) void {}
        fn noEnd(_: *anyopaque) void {}
        fn notDragging(_: *anyopaque) bool {
            return false;
        }
        fn noWheel(_: *anyopaque, _: usize) void {}
        fn noFold(_: *anyopaque, _: usize, _: usize) anyerror!bool {
            return false;
        }
        fn line(_: *anyopaque, _: *ui.Node) ?usize {
            return 1;
        }
        fn atCell(context: *anyopaque, _: usize, x: usize) anyerror!Position {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self;
            return Position.init(1, x + 1);
        }
        fn setCursor(context: *anyopaque, position: Position) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cursor = position;
        }
        fn start(context: *anyopaque) Position {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.cursor;
        }
        fn selectFrom(context: *anyopaque, _: Position, position: Position) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.selections += 1;
            self.cursor = position;
        }
        fn updateDrag(context: *anyopaque, _: Position, position: Position) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.selections += 1;
            self.cursor = position;
        }
        fn click(context: *anyopaque, _: usize, _: usize, _: usize, _: usize, _: ui.Modifiers) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.clicks += 1;
        }
        fn scroll(context: *anyopaque, _: usize, _: f64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.scrolls += 1;
            return true;
        }
    };

    var state = State{};
    const host = TerminalMouseHost{
        .context = &state,
        .element_from_point = State.element,
        .root_node = State.root,
        .is_scrollbar_hit = State.noScrollbar,
        .begin_scrollbar_drag = State.noDrag,
        .end_scrollbar_drag = State.noEnd,
        .scrollbar_dragging = State.notDragging,
        .drag_scrollbar = State.noWheel,
        .toggle_fold = State.noFold,
        .line_for_node = State.line,
        .position_at_cell = State.atCell,
        .set_cursor = State.setCursor,
        .selection_start = State.start,
        .select_from = State.selectFrom,
        .update_drag_selection = State.updateDrag,
        .dispatch_click = State.click,
        .scroll_lines = State.scroll,
    };
    var handler = TerminalMouseHandler{};

    var down = ui.MouseEvent{ .kind = .down, .x = 2, .y = 0, .button = .left };
    try testing.expect(try handler.dispatch(host, &down, undefined));
    try testing.expectEqual(@as(usize, 3), state.cursor.column);

    var move = ui.MouseEvent{ .kind = .move, .x = 5, .y = 0, .button = .left };
    try testing.expect(try handler.dispatch(host, &move, undefined));
    try testing.expectEqual(@as(usize, 1), state.selections);
    try testing.expect(handler.drag_moved);

    var up = ui.MouseEvent{ .kind = .up, .x = 5, .y = 0, .button = .left };
    try testing.expect(!try handler.dispatch(host, &up, undefined));
    try testing.expectEqual(@as(usize, 0), state.clicks);
    try testing.expect(handler.press == null);
}
