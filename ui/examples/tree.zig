//! A file tree drawn with box-drawing prefixes inside a bordered panel.
//!
//! Run with `cd ui && zig build example-tree`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const lines = [_]struct { text: []const u8, dir: bool }{
    .{ .text = "src/", .dir = true },
    .{ .text = "├─ main.zig", .dir = false },
    .{ .text = "├─ tui/", .dir = true },
    .{ .text = "│  ├─ app.zig", .dir = false },
    .{ .text = "│  ├─ preview.zig", .dir = false },
    .{ .text = "│  └─ editor.zig", .dir = false },
    .{ .text = "└─ vs/", .dir = true },
    .{ .text = "   └─ editor/", .dir = true },
    .{ .text = "      └─ common/", .dir = true },
    .{ .text = "         └─ model.zig", .dir = false },
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const example = try treeExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, init.io, example);
}

pub fn treeExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "tree", .build = build };
}

fn build(
    _: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    _: common.Size,
) !void {
    const root = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = common.rgb(18, 18, 24),
    });

    _ = try common.addLabel(doc, root, "file tree", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 56 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(255, 255, 255), .bold = true });

    const panel = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 34 },
        .height = .{ .cells = 10 },
        .padding = ui.EdgeDecl.all(1),
        .border = ui.EdgeDecl.all(1),
        .border_color = common.rgb(70, 70, 100),
        .background = common.rgb(26, 28, 38),
    });

    for (lines, 0..) |line, index| {
        const top: f64 = @floatFromInt(index);
        _ = try common.addLabel(doc, panel, line.text, .{
            .position = .absolute,
            .left = .{ .cells = 1 },
            .top = .{ .cells = top },
            .width = .{ .cells = 32 },
            .height = .{ .cells = 1 },
        }, .{
            .color = if (line.dir) common.rgb(120, 200, 255) else common.rgb(200, 200, 210),
            .bold = line.dir,
        });
    }

    const side = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 40 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 16 },
        .height = .{ .cells = 10 },
        .padding = ui.EdgeDecl.all(1),
        .border = ui.EdgeDecl.all(1),
        .border_color = common.rgb(70, 70, 100),
        .background = common.rgb(26, 28, 38),
    });
    _ = try common.addLabel(doc, side, "utf-8 box drawing", .{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 14 },
        .height = .{ .cells = 1 },
    }, .{
        .color = common.rgb(230, 200, 120),
        .bold = true,
    });
    _ = try common.addLabel(doc, side, "├─ └─ │ ─ ┌ ┐", .{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 14 },
        .height = .{ .cells = 1 },
    }, .{ .color = common.rgb(180, 180, 200) });
}
