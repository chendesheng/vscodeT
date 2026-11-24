//! Retained scroll window: translate the visible rows, recycle the leaving row
//! and add the entering one, then repaint. Mirrors the editor scroll frame
//! minus the model/tokenization work.

const std = @import("std");
const ui = @import("ui");
const harness = @import("../harness.zig");
const fixtures = @import("../fixtures.zig");

const visible_rows = 40;

const State = struct {
    allocator: std.mem.Allocator,
    surface: *ui.Surface,
    root: *ui.Node,
    lines: [visible_rows]*ui.Node = undefined,
    buffers: [visible_rows][128]u8 = undefined,
    head: usize = 0,
    next_line: usize = visible_rows,

    fn init(allocator: std.mem.Allocator) !State {
        const surface = try allocator.create(ui.Surface);
        errdefer allocator.destroy(surface);
        surface.* = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
        errdefer surface.deinit();
        const doc = surface.document();
        const root = try fixtures.fullScreenRoot(doc);
        var state = State{ .allocator = allocator, .surface = surface, .root = root };
        for (0..visible_rows) |index| {
            state.lines[index] = try makeLine(&state, index, index, index);
        }
        return state;
    }

    fn deinit(self: *State) void {
        self.surface.deinit();
        self.allocator.destroy(self.surface);
    }

    fn makeLine(self: *State, slot: usize, model_line: usize, top: usize) !*ui.Node {
        const text = fixtures.lineText(&self.buffers[slot], model_line);
        return fixtures.row(self.surface.document(), self.root, top, .{ .x = 0, .y = top, .w = 100, .h = 1 }, text, fixtures.rowBackground(model_line), .pre);
    }
};

fn step(state: *State, _: usize) !void {
    // Scroll every remaining row up one cell.
    for (state.lines, 0..) |line, index| {
        if (index == state.head) continue;
        if (!state.surface.box_tree.translateSubtree(line, 0, -1)) return error.MissingBox;
    }

    // Recycle the row that left the viewport and append the entering row.
    const leaving = state.lines[state.head];
    state.surface.box_tree.removeSubtree(leaving);
    state.surface.document().destroy(leaving);

    const slot = state.head;
    state.lines[slot] = try state.makeLine(slot, state.next_line, visible_rows - 1);
    state.next_line += 1;
    state.head = (state.head + 1) % visible_rows;

    const added = (try state.surface.box_tree.addSubtree(state.lines[slot])) orelse
        return error.MissingBox;
    try ui.layout.layoutSubtree(state.surface.box_tree, state.surface.document(), added);
    try state.surface.paintFrame();
    if (state.surface.grid().cluster[0] == 0) return error.MissingContent;
}

pub const scenario = harness.Scenario{
    .name = "scroll",
    .description = "Scroll a retained 40-row window one row and repaint",
    .run = run,
};

fn run(ctx: *harness.Context) !void {
    var state = try State.init(ctx.allocator);
    defer state.deinit();
    try state.surface.paintFrame();
    state.surface.box_tree.setAutoInvalidate(false);
    try ctx.measure("scroll: one retained row", &state, step);
}
