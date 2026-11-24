//! ANSI frame encoder: full frame, one-row delta and unchanged frame at each
//! supported colour depth. The grids are built outside the timed steps.

const std = @import("std");
const ui = @import("ui");
const harness = @import("../harness.zig");

const State = struct {
    allocator: std.mem.Allocator,
    base: ui.CellGrid,
    same: ui.CellGrid,
    delta: ui.CellGrid,
    changed_cell: usize = 0,

    fn init(allocator: std.mem.Allocator) !State {
        var base = try ui.CellGrid.init(allocator, 140, 44);
        errdefer base.deinit();
        var same = try ui.CellGrid.init(allocator, 140, 44);
        errdefer same.deinit();
        var delta = try ui.CellGrid.init(allocator, 140, 44);
        errdefer delta.deinit();

        for (0..44) |row| {
            for (0..140) |col| {
                const paint = ui.cell.PaintStyle{
                    .fg = ui.cell.packColor(.{
                        .r = @intCast((col * 3 + row) % 256),
                        .g = @intCast((col + row * 5) % 256),
                        .b = @intCast((col * 7 + row * 2) % 256),
                    }),
                    .bg = if ((row + col) % 9 == 0)
                        ui.cell.packColor(.{ .r = 30, .g = 32, .b = 40 })
                    else
                        0,
                    .attrs = if (row % 7 == 0) ui.cell.Attr.bold else 0,
                };
                const glyph: u21 = if (col % 17 == 0) '中' else @intCast('a' + ((col + row) % 26));
                base.putCodepoint(col, row, glyph, if (glyph == '中') 2 else 1, paint);
            }
        }
        // A few border sets so the encoder has to emit pen transitions.
        const stroke = ui.cell_border.Stroke{
            .color = .{ .rgb = .{ .r = 0x7a, .g = 0xa2, .b = 0xf7 } },
            .width = 64,
        };
        for (0..140) |col| {
            base.addBorder(col, 0, ui.cell_border.Segment.top, stroke);
            base.addBorder(col, 43, ui.cell_border.Segment.bottom, stroke);
        }
        for (0..44) |row| {
            base.addBorder(0, row, ui.cell_border.Segment.left, stroke);
            base.addBorder(139, row, ui.cell_border.Segment.right, stroke);
        }

        try same.blit(&base, 0, 0, 140, 44);
        try delta.blit(&base, 0, 0, 140, 44);
        return .{ .allocator = allocator, .base = base, .same = same, .delta = delta };
    }

    fn deinit(self: *State) void {
        self.base.deinit();
        self.same.deinit();
        self.delta.deinit();
    }
};

fn fullStep(state: *State, index: usize) !void {
    const depth: ui.ColorDepth = switch (index % 3) {
        0 => .rgb,
        1 => .ansi256,
        else => .ansi,
    };
    const encoded = try ui.ansi.encode(state.allocator, null, &state.base, .{ .color_depth = depth });
    defer state.allocator.free(encoded);
    if (encoded.len == 0) return error.EmptyFrame;
}

fn unchangedStep(state: *State, _: usize) !void {
    const encoded = try ui.ansi.encode(state.allocator, &state.base, &state.same, .{});
    defer state.allocator.free(encoded);
    if (encoded.len != 0) return error.UnexpectedFrame;
}

fn deltaStep(state: *State, index: usize) !void {
    const row = index % 44;
    const col = (index * 7) % 140;
    state.changed_cell = row * 140 + col;
    state.delta.cluster[state.changed_cell] = 'Z';
    const encoded = try ui.ansi.encode(state.allocator, &state.base, &state.delta, .{});
    defer state.allocator.free(encoded);
    if (encoded.len == 0) return error.EmptyDelta;
    state.delta.cluster[state.changed_cell] = state.base.cluster[state.changed_cell];
    state.delta.attrs[state.changed_cell] = state.base.attrs[state.changed_cell];
    state.delta.fg[state.changed_cell] = state.base.fg[state.changed_cell];
    state.delta.bg[state.changed_cell] = state.base.bg[state.changed_cell];
}

pub const scenario = harness.Scenario{
    .name = "ansi",
    .description = "Encode a full 140x44 frame, a one-row delta and an unchanged frame",
    .run = run,
};

fn run(ctx: *harness.Context) !void {
    var state = try State.init(ctx.allocator);
    defer state.deinit();
    try ctx.measure("ansi: full frame (all depths)", &state, fullStep);
    try ctx.measure("ansi: one-row delta", &state, deltaStep);
    try ctx.measure("ansi: unchanged frame", &state, unchangedStep);
}
