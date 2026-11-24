//! Cold startup: build a workbench-like scene and paint the first frame.
//! There is no warmup; every iteration builds fresh state.

const std = @import("std");
const ui = @import("ui");
const harness = @import("../harness.zig");
const fixtures = @import("../fixtures.zig");

const State = struct {
    allocator: std.mem.Allocator,
};

fn step(state: *State, _: usize) !void {
    var surface = try ui.Surface.init(state.allocator, .{ .cols = 100, .rows = 40 });
    defer surface.deinit();
    const doc = surface.document();
    const root = try fixtures.fullScreenRoot(doc);

    // Sidebar, editor and panel regions, each with enough rows to force real
    // flex/block work rather than a single background fill.
    const sidebar = try doc.createElement(.div);
    sidebar.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 22 },
        .height = .{ .percent = 100 },
        .background = .{ .r = 20, .g = 22, .b = 28 },
        .overflow = .hidden,
    });
    _ = try root.appendChild(sidebar);

    const editor = try doc.createElement(.div);
    editor.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 23 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 76 },
        .height = .{ .cells = 32 },
        .background = .{ .r = 12, .g = 13, .b = 16 },
        .overflow = .hidden,
    });
    _ = try root.appendChild(editor);

    const panel = try doc.createElement(.div);
    panel.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 23 },
        .top = .{ .cells = 33 },
        .width = .{ .cells = 76 },
        .height = .{ .cells = 6 },
        .background = .{ .r = 18, .g = 20, .b = 26 },
        .overflow = .hidden,
    });
    _ = try root.appendChild(panel);

    var buffer: [128]u8 = undefined;
    for (0..40) |index| {
        const text = fixtures.lineText(&buffer, index);
        _ = try fixtures.row(doc, sidebar, index, .{ .x = 1, .y = index, .w = 20, .h = 1 }, text, null, .pre);
        if (index < 32) {
            _ = try fixtures.row(doc, editor, index, .{ .x = 1, .y = index, .w = 73, .h = 1 }, text, fixtures.rowBackground(index), .pre);
        }
    }
    for (0..5) |index| {
        _ = try fixtures.row(doc, panel, 1 + index, .{ .x = 1, .y = 1 + index, .w = 73, .h = 1 }, "panel output row", null, .pre);
    }

    try surface.paintFrame();
    if (surface.grid().cluster[0] == 0) return error.MissingFirstCell;
}

pub const scenario = harness.Scenario{
    .name = "startup",
    .description = "Build a workbench-like scene and paint the first frame",
    .run = run,
};

fn run(ctx: *harness.Context) !void {
    var instance = State{ .allocator = ctx.allocator };
    try ctx.measure("startup: scene to first frame", &instance, step);
}
