//! DOM/box derivation stress: build thousands of inline spans, solve and
//! paint, then remove them and repaint. Mirrors TermDOM's `dom-ops` scenario.

const std = @import("std");
const ui = @import("ui");
const harness = @import("../harness.zig");
const fixtures = @import("../fixtures.zig");

const span_count = 5000;

const State = struct {
    allocator: std.mem.Allocator,
};

fn step(state: *State, index: usize) !void {
    var surface = try ui.Surface.init(state.allocator, .{ .cols = 100, .rows = 40 });
    defer surface.deinit();
    const doc = surface.document();
    const root = try fixtures.fullScreenRoot(doc);

    const list = try doc.createElement(.div);
    list.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .white_space = .normal,
        .overflow = .hidden,
    });
    _ = try root.appendChild(list);

    for (0..span_count) |span_index| {
        const span = try doc.createElement(.span);
        span.setStyle(.{
            .color = fixtures.accent(span_index + index),
            .bold = span_index % 7 == 0,
        });
        _ = try span.appendChild(try doc.createText(if (span_index % 5 == 0) "word " else "x"));
        _ = try list.appendChild(span);
    }

    try surface.paintFrame();
    if (surface.grid().cluster[0] == 0) return error.MissingContent;

    // Remove the whole list and repaint a cleared document.
    list.clearChildren();
    _ = try list.appendChild(try doc.createText("done"));
    try surface.paintFrame();
}

pub const scenario = harness.Scenario{
    .name = "dom_ops",
    .description = "Build, solve, paint and remove 5000 inline spans",
    .run = run,
};

fn run(ctx: *harness.Context) !void {
    var state = State{ .allocator = ctx.allocator };
    try ctx.measure("dom: 5000 spans build, solve and remove", &state, step);
}
