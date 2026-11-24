//! Focus, hover and hit testing across 500 focusable rows.

const std = @import("std");
const ui = @import("ui");
const harness = @import("../harness.zig");
const fixtures = @import("../fixtures.zig");

const row_count = 500;
const State = struct {
    allocator: std.mem.Allocator,
    surface: *ui.Surface,
    rows: [row_count]*ui.Node = undefined,

    fn init(allocator: std.mem.Allocator) !State {
        const surface = try allocator.create(ui.Surface);
        errdefer allocator.destroy(surface);
        surface.* = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
        errdefer surface.deinit();
        const doc = surface.document();
        const root = try fixtures.fullScreenRoot(doc);
        var state = State{ .allocator = allocator, .surface = surface };
        for (0..row_count) |index| {
            const line = try doc.createElement(.div);
            line.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = @floatFromInt(index) },
                .width = .{ .percent = 100 },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .overflow = .hidden,
            });
            line.asElement().focusable = true;
            line.asElement().tab_index = 0;
            var buffer: [96]u8 = undefined;
            _ = try line.appendChild(try doc.createText(fixtures.lineText(&buffer, index)));
            _ = try root.appendChild(line);
            state.rows[index] = line;
        }
        return state;
    }

    fn deinit(self: *State) void {
        self.surface.deinit();
        self.allocator.destroy(self.surface);
    }
};

fn tabStep(state: *State, _: usize) !void {
    const doc = state.surface.document();
    if (!doc.moveFocus(.forward)) return error.FocusFailed;
    if (doc.activeElement() == null) return error.NoActiveElement;
}

fn hoverStep(state: *State, index: usize) !void {
    const row = index % 40;
    const changed = try state.surface.updateHoverAt((index * 13) % 100, row);
    _ = changed;
    const hit = (try state.surface.elementFromPoint((index * 13) % 100, row)) orelse
        return error.MissingHit;
    if (!hit.isElement()) return error.HitNotElement;
}

fn clickStep(state: *State, index: usize) !void {
    const row = index % 40;
    const target = (try state.surface.elementFromPoint(4, row)) orelse return error.MissingHit;
    var event = ui.MouseEvent{
        .kind = .click,
        .x = 4,
        .y = row,
        .button = .left,
    };
    state.surface.document().dispatchMouse(target, &event);
    try state.surface.paintFrame();
    if (state.surface.grid().cluster[0] == 0) return error.MissingContent;
}

pub const scenario = harness.Scenario{
    .name = "interaction",
    .description = "Focus traversal, hover/hit testing and click dispatch over 500 rows",
    .run = run,
};

fn run(ctx: *harness.Context) !void {
    var state = try State.init(ctx.allocator);
    defer state.deinit();
    try state.surface.paintFrame();
    try ctx.measure("interaction: tab traversal", &state, tabStep);
    try ctx.measure("interaction: hover and hit test", &state, hoverStep);
    try ctx.measure("interaction: click and paint", &state, clickStep);
}
