//! Cell-border heavy scene: 24 bordered boxes plus a rounded popup. Measures a
//! full paint, a changed render and an unchanged render.

const std = @import("std");
const ui = @import("ui");
const harness = @import("../harness.zig");
const fixtures = @import("../fixtures.zig");

const box_count = 24;
const State = struct {
    allocator: std.mem.Allocator,
    surface: *ui.Surface,
    boxes: [box_count]*ui.Node = undefined,
    writer: std.Io.Writer.Allocating,
    changed: usize = 0,
    light: [box_count]bool = @splat(false),

    fn init(allocator: std.mem.Allocator) !State {
        const surface = try allocator.create(ui.Surface);
        errdefer allocator.destroy(surface);
        surface.* = try ui.Surface.init(allocator, .{
            .cols = 100,
            .rows = 40,
            .cell_borders = true,
        });
        errdefer surface.deinit();
        const doc = surface.document();
        const root = try fixtures.fullScreenRoot(doc);
        var state = State{
            .allocator = allocator,
            .surface = surface,
            .writer = std.Io.Writer.Allocating.init(allocator),
        };
        for (0..box_count) |index| {
            const column = index % 6;
            const row = index / 6;
            const rect = fixtures.Rect{
                .x = 1 + column * 16,
                .y = 1 + row * 8,
                .w = 14,
                .h = 6,
            };
            const box = try fixtures.borderedBox(doc, root, rect, "bordered cell", fixtures.accent(index), fixtures.rowBackground(index));
            // Add some interior rows so painting each box is not just its border.
            _ = try fixtures.row(doc, box, 1, .{ .x = 1, .y = 1, .w = 12, .h = 1 }, "interior row one", null, .pre);
            _ = try fixtures.row(doc, box, 2, .{ .x = 1, .y = 2, .w = 12, .h = 1 }, "interior row two", null, .pre);
            state.boxes[index] = box;
        }

        const popup = try fixtures.borderedBox(doc, root, .{ .x = 30, .y = 12, .w = 36, .h = 8 }, "rounded popup", .{ .r = 140, .g = 160, .b = 220 }, .{ .r = 30, .g = 32, .b = 40 });
        popup.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 30 },
            .top = .{ .cells = 12 },
            .width = .{ .cells = 36 },
            .height = .{ .cells = 8 },
            .border = ui.EdgeDecl.all(1),
            .border_style = .rounded,
            .border_color = .{ .r = 140, .g = 160, .b = 220 },
            .background = .{ .r = 30, .g = 32, .b = 40 },
        });
        return state;
    }

    fn deinit(self: *State) void {
        self.writer.deinit();
        self.surface.deinit();
        self.allocator.destroy(self.surface);
    }
};

fn fullStep(state: *State, _: usize) !void {
    state.surface.box_tree.markFullRebuild();
    try state.surface.paintFrame();
    if (state.surface.grid().borderIdAt(1, 1) == 0) return error.MissingBorder;
}

fn renderStep(state: *State, _: usize) !void {
    state.changed = (state.changed + 1) % box_count;
    state.light[state.changed] = !state.light[state.changed];
    const background = if (state.light[state.changed])
        ui.Color{ .r = 40, .g = 44, .b = 54 }
    else
        ui.Color{ .r = 90, .g = 40, .b = 44 };
    const box = state.boxes[state.changed];
    box.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = @floatFromInt(1 + (state.changed % 6) * 16) },
        .top = .{ .cells = @floatFromInt(1 + (state.changed / 6) * 8) },
        .width = .{ .cells = 14 },
        .height = .{ .cells = 6 },
        .border = ui.EdgeDecl.all(1),
        .border_color = fixtures.accent(state.changed),
        .background = background,
        .overflow = .hidden,
    });
    const rebuilt = (try state.surface.box_tree.rebuildSubtree(box)) orelse return error.MissingBox;
    try ui.layout.layoutSubtree(state.surface.box_tree, state.surface.document(), rebuilt);
    state.writer.clearRetainingCapacity();
    try state.surface.render(&state.writer.writer, .{});
    if (state.writer.written().len == 0) return error.MissingDelta;
}

fn unchangedStep(state: *State, _: usize) !void {
    state.writer.clearRetainingCapacity();
    try state.surface.render(&state.writer.writer, .{});
    if (state.writer.written().len != 0) return error.UnexpectedDelta;
}

pub const scenario = harness.Scenario{
    .name = "borders",
    .description = "Bordered boxes: full paint, changed render, unchanged render",
    .run = run,
};

fn run(ctx: *harness.Context) !void {
    var state = try State.init(ctx.allocator);
    defer state.deinit();
    try state.surface.paintFrame();
    state.surface.box_tree.setAutoInvalidate(false);
    try ctx.measure("borders: full solve and paint", &state, fullStep);
    try ctx.measure("borders: changed render", &state, renderStep);
    try ctx.measure("borders: unchanged render", &state, unchangedStep);
}
