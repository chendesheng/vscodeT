//! Nested flex layout: a toolbar, a wrapping card grid and a footer, solved
//! and painted from a retained document.

const std = @import("std");
const ui = @import("ui");
const harness = @import("../harness.zig");
const fixtures = @import("../fixtures.zig");

const card_count = 80;
const State = struct {
    allocator: std.mem.Allocator,
    surface: *ui.Surface,
    root: *ui.Node,

    fn init(allocator: std.mem.Allocator) !State {
        const surface = try allocator.create(ui.Surface);
        errdefer allocator.destroy(surface);
        surface.* = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
        errdefer surface.deinit();
        const doc = surface.document();
        const root = try fixtures.fullScreenRoot(doc);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .display = .flex,
            .flex_direction = .column,
            .overflow = .hidden,
        });

        const toolbar = try doc.createElement(.div);
        toolbar.setStyle(.{
            .height = .{ .cells = 2 },
            .display = .flex,
            .align_items = .center,
            .gap = .{ .column = 1 },
            .background = .{ .r = 24, .g = 26, .b = 34 },
        });
        _ = try root.appendChild(toolbar);
        for (0..6) |index| {
            const label = try doc.createElement(.div);
            label.setStyle(.{ .white_space = .pre, .bold = index == 0, .color = fixtures.accent(index) });
            var buffer: [32]u8 = undefined;
            _ = try label.appendChild(try doc.createText(std.fmt.bufPrint(&buffer, "tool {d}", .{index}) catch "tool"));
            _ = try toolbar.appendChild(label);
        }

        const body = try doc.createElement(.div);
        body.setStyle(.{
            .flex_grow = 1,
            .display = .flex,
            .flex_wrap = .wrap,
            .align_content = .flex_start,
            .gap = .{ .row = 0, .column = 1 },
            .padding = ui.EdgeDecl.all(1),
            .overflow = .hidden,
        });
        _ = try root.appendChild(body);

        for (0..card_count) |index| {
            const card = try doc.createElement(.div);
            card.setStyle(.{
                .width = .{ .cells = 22 },
                .height = .{ .cells = 4 },
                .display = .flex,
                .flex_direction = .column,
                .padding = ui.EdgeDecl.all(1),
                .border = ui.EdgeDecl.all(1),
                .border_color = fixtures.accent(index),
                .background = fixtures.rowBackground(index),
                .overflow = .hidden,
            });
            var title_buffer: [32]u8 = undefined;
            const title = try doc.createText(std.fmt.bufPrint(&title_buffer, "card {d}", .{index}) catch "card");
            _ = try card.appendChild(title);
            const detail = try doc.createElement(.div);
            detail.setStyle(.{ .white_space = .pre, .color = .{ .r = 170, .g = 176, .b = 190 } });
            _ = try detail.appendChild(try doc.createText("flex item detail"));
            _ = try card.appendChild(detail);
            _ = try body.appendChild(card);
        }

        const footer = try doc.createElement(.div);
        footer.setStyle(.{ .height = .{ .cells = 1 }, .white_space = .pre, .background = .{ .r = 20, .g = 22, .b = 28 } });
        _ = try footer.appendChild(try doc.createText("status: 80 cards"));
        _ = try root.appendChild(footer);

        return .{ .allocator = allocator, .surface = surface, .root = root };
    }

    fn deinit(self: *State) void {
        self.surface.deinit();
        self.allocator.destroy(self.surface);
    }
};

fn step(state: *State, _: usize) !void {
    state.surface.box_tree.markFullRebuild();
    try state.surface.paintFrame();
    if (state.surface.grid().cluster[0] == 0) return error.MissingContent;
}

pub const scenario = harness.Scenario{
    .name = "flex",
    .description = "Full solve and paint of a nested flex card grid",
    .run = run,
};

fn run(ctx: *harness.Context) !void {
    var state = try State.init(ctx.allocator);
    defer state.deinit();
    try state.surface.paintFrame();
    try ctx.measure("flex: full solve and paint", &state, step);
}
