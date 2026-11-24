//! Retained editor-like viewport: 40 visible rows, gutter plus content text.
//! Each step edits one row and re-solves only that row's retained box subtree,
//! then paints. This is the dirty-line path the 2026-11-21 report identified.

const std = @import("std");
const ui = @import("ui");
const harness = @import("../harness.zig");
const fixtures = @import("../fixtures.zig");

const rows = 40;
const gutter = 4;

const State = struct {
    allocator: std.mem.Allocator,
    surface: *ui.Surface,
    root: *ui.Node,
    line_nodes: [rows]*ui.Node = undefined,
    text_nodes: [rows]*ui.Node = undefined,
    buffers: [rows][128]u8 = undefined,
    versions: [rows]usize = @splat(0),

    fn init(allocator: std.mem.Allocator) !State {
        const surface = try allocator.create(ui.Surface);
        errdefer allocator.destroy(surface);
        surface.* = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
        errdefer surface.deinit();
        const doc = surface.document();
        const root = try fixtures.fullScreenRoot(doc);
        var state = State{
            .allocator = allocator,
            .surface = surface,
            .root = root,
        };
        for (0..rows) |index| {
            const line = try doc.createElement(.div);
            line.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = @floatFromInt(index) },
                .width = .{ .percent = 100 },
                .height = .{ .cells = 1 },
                .background = fixtures.rowBackground(index),
                .white_space = .pre,
                .overflow = .hidden,
            });
            _ = try root.appendChild(line);

            const gutter_text = try doc.createText("  1 ");
            _ = try line.appendChild(gutter_text);
            const content_text = try doc.createText(fixtures.lineText(&state.buffers[index], index));
            _ = try line.appendChild(content_text);
            state.line_nodes[index] = line;
            state.text_nodes[index] = content_text;
        }
        return state;
    }

    fn deinit(self: *State) void {
        self.surface.deinit();
        self.allocator.destroy(self.surface);
    }
};

fn step(state: *State, index: usize) !void {
    const row = index % rows;
    state.versions[row] +%= 1;
    const text = fixtures.lineText(&state.buffers[row], row + state.versions[row]);
    state.text_nodes[row].setTextBorrowed(text);

    const box = (try state.surface.box_tree.rebuildSubtree(state.line_nodes[row])) orelse
        return error.MissingBox;
    try ui.layout.layoutSubtree(state.surface.box_tree, state.surface.document(), box);
    try state.surface.paintFrame();
    if (state.surface.grid().cluster[gutter] == 0) return error.MissingContent;
}

pub const scenario = harness.Scenario{
    .name = "editor",
    .description = "Edit one retained view line subtree and repaint",
    .run = run,
};

fn run(ctx: *harness.Context) !void {
    var state = try State.init(ctx.allocator);
    defer state.deinit();
    try state.surface.paintFrame();
    state.surface.box_tree.setAutoInvalidate(false);
    try ctx.measure("editor: edit one retained line", &state, step);
}
