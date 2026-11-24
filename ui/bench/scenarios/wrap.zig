//! Wrapped text: many in-flow paragraphs with collapsing whitespace, tabs,
//! CJK and combining text. Measures one incremental paragraph edit and a full
//! solve/paint of the same document.

const std = @import("std");
const ui = @import("ui");
const harness = @import("../harness.zig");
const fixtures = @import("../fixtures.zig");

const paragraph_count = 80;
const State = struct {
    allocator: std.mem.Allocator,
    surface: *ui.Surface,
    paragraphs: [paragraph_count]*ui.Node = undefined,
    text_nodes: [paragraph_count]*ui.Node = undefined,
    buffers: [paragraph_count][512]u8 = undefined,
    versions: [paragraph_count]usize = @splat(0),

    fn init(allocator: std.mem.Allocator) !State {
        const surface = try allocator.create(ui.Surface);
        errdefer allocator.destroy(surface);
        surface.* = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
        errdefer surface.deinit();
        const doc = surface.document();
        const root = try fixtures.fullScreenRoot(doc);
        var state = State{ .allocator = allocator, .surface = surface };
        for (0..paragraph_count) |index| {
            const paragraph = try doc.createElement(.div);
            paragraph.setStyle(.{ .width = .{ .percent = 100 }, .white_space = .normal });
            _ = try root.appendChild(paragraph);
            const text = try doc.createText(fixtures.paragraphText(&state.buffers[index], index));
            _ = try paragraph.appendChild(text);
            state.paragraphs[index] = paragraph;
            state.text_nodes[index] = text;
        }
        return state;
    }

    fn deinit(self: *State) void {
        self.surface.deinit();
        self.allocator.destroy(self.surface);
    }
};

fn editStep(state: *State, index: usize) !void {
    const paragraph_index = index % paragraph_count;
    state.versions[paragraph_index] +%= 1;
    const text = fixtures.paragraphText(&state.buffers[paragraph_index], paragraph_index + state.versions[paragraph_index]);
    state.text_nodes[paragraph_index].setTextBorrowed(text);
    const box = (try state.surface.box_tree.rebuildSubtree(state.paragraphs[paragraph_index])) orelse
        return error.MissingBox;
    try ui.layout.layoutSubtree(state.surface.box_tree, state.surface.document(), box);
    try state.surface.paintFrame();
    if (state.surface.grid().cluster[0] == 0) return error.MissingContent;
}

fn fullStep(state: *State, _: usize) !void {
    state.surface.box_tree.markFullRebuild();
    try state.surface.paintFrame();
    if (state.surface.grid().cluster[0] == 0) return error.MissingContent;
}

pub const scenario = harness.Scenario{
    .name = "wrap",
    .description = "Wrapped paragraphs: one incremental edit and one full solve",
    .run = run,
};

fn run(ctx: *harness.Context) !void {
    var state = try State.init(ctx.allocator);
    defer state.deinit();
    try state.surface.paintFrame();
    state.surface.box_tree.setAutoInvalidate(false);
    try ctx.measure("wrap: edit one paragraph", &state, editStep);
    try ctx.measure("wrap: full solve and paint", &state, fullStep);
}
