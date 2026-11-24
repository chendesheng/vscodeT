//! Class-toggle stress: change one of 500 classed rows and rebuild/repaint the
//! whole document through the automatic mutation path.

const std = @import("std");
const ui = @import("ui");
const harness = @import("../harness.zig");
const fixtures = @import("../fixtures.zig");

const row_count = 500;
const Class = enum(u16) { row_a = 0, row_b = 1, active = 2 };

const State = struct {
    allocator: std.mem.Allocator,
    surface: *ui.Surface,
    rows: [row_count]*ui.Node = undefined,
    active_row: ?usize = null,

    fn init(allocator: std.mem.Allocator) !State {
        const surface = try allocator.create(ui.Surface);
        errdefer allocator.destroy(surface);
        surface.* = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
        errdefer surface.deinit();
        const doc = surface.document();
        _ = try doc.registerSheet(.{ .styles = &.{
            .{ .background = .{ .r = 20, .g = 22, .b = 28 } },
            .{ .background = .{ .r = 28, .g = 30, .b = 38 } },
            .{ .background = .{ .r = 60, .g = 80, .b = 140 }, .bold = true },
        } });
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
            try line.setClasses(&.{if (index % 2 == 0) Class.row_a else Class.row_b});
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

fn step(state: *State, _: usize) !void {
    if (state.active_row) |previous| {
        const base: Class = if (previous % 2 == 0) .row_a else .row_b;
        try state.rows[previous].setClasses(&.{base});
    }
    const row_index = ((state.active_row orelse row_count - 1) + 1) % row_count;
    state.active_row = row_index;
    const base: Class = if (row_index % 2 == 0) .row_a else .row_b;
    try state.rows[row_index].setClasses(&.{ base, Class.active });
    try state.surface.paintFrame();
    if (state.surface.grid().cluster[0] == 0) return error.MissingContent;
}

pub const scenario = harness.Scenario{
    .name = "toggle",
    .description = "Toggle a class on a 500-row document and repaint",
    .run = run,
};

fn run(ctx: *harness.Context) !void {
    var state = try State.init(ctx.allocator);
    defer state.deinit();
    try state.surface.paintFrame();
    try ctx.measure("toggle: class change plus full repaint", &state, step);
}
