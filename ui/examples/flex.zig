//! Flex layout: a column page, a toolbar row with a growing spacer, a
//! sidebar/content row, wrapped tags and a footer pushed down by an auto
//! margin.
//!
//! Run with `cd ui && zig build example-flex`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const example = try flexExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, init.io, example);
}

pub fn flexExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "flex", .build = build };
}

const background = common.rgb(18, 18, 24);
const panel = common.rgb(26, 28, 38);
const raised = common.rgb(34, 38, 52);
const accent = common.rgb(88, 132, 220);
const foreground = common.rgb(230, 230, 240);
const dim = common.rgb(150, 154, 176);

fn build(
    _: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    size: common.Size,
) !void {
    const root = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = @floatFromInt(size.width -| 2) },
        .height = .{ .cells = @floatFromInt(size.height -| 2) },
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .row = 1 },
        .background = background,
    });

    // Toolbar: fixed buttons, one growing spacer and a right-aligned label.
    const toolbar = try common.addBox(doc, root, .{
        .height = .{ .cells = 3 },
        .display = .flex,
        .align_items = .center,
        .gap = .{ .column = 2 },
        .padding = .{ .left = 1, .right = 1 },
        .overflow = .hidden,
        .background = panel,
    });

    for ([_][]const u8{ "open", "build", "run" }) |label| {
        _ = try common.addLabel(doc, toolbar, label, .{
            .width = .{ .cells = 7 },
            .height = .{ .cells = 1 },
            .background = raised,
            .text_align = .center,
        }, .{ .color = foreground, .bold = true });
    }

    _ = try common.addBox(doc, toolbar, .{
        .height = .{ .cells = 1 },
        .flex_grow = 1,
    });
    _ = try common.addLabel(doc, toolbar, "flex", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });

    // Body: a fixed sidebar and a growing content column. The sidebar keeps
    // its width and clips its labels so they cannot paint into the content.
    const narrow = size.width < 64;
    const body = try common.addBox(doc, root, .{
        .display = .flex,
        .flex_grow = 1,
        .gap = .{ .column = 1 },
        .overflow = .hidden,
    });

    const sidebar = try common.addBox(doc, body, .{
        .width = .{ .cells = 18 },
        .flex_shrink = 0,
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .row = 1 },
        .padding = ui.EdgeDecl.all(1),
        .overflow = .hidden,
        .background = panel,
    });
    _ = try common.addLabel(doc, sidebar, "explorer", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground, .bold = true });
    for ([_][]const u8{ "src/", "ui/", "docs/" }) |name| {
        _ = try common.addLabel(doc, sidebar, name, .{
            .height = .{ .cells = 1 },
        }, .{ .color = dim });
    }

    const content = try common.addBox(doc, body, .{
        .display = .flex,
        .flex_direction = .column,
        .flex_grow = 1,
        .gap = .{ .row = 1 },
        .padding = ui.EdgeDecl.all(1),
        .overflow = .hidden,
        .background = panel,
    });

    _ = try common.addLabel(doc, content, "flex layout", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground, .bold = true });

    const tags = try common.addBox(doc, content, .{
        .display = .flex,
        .flex_wrap = .wrap,
        .gap = ui.GapDecl.all(1),
        .align_items = .flex_start,
    });
    for ([_][]const u8{
        "direction", "wrap", "grow",  "shrink",       "basis", "justify",
        "align",     "gap",  "order", "auto margins",
    }) |tag| {
        _ = try common.addLabel(doc, tags, tag, .{
            .height = .{ .cells = 1 },
            .padding = .{ .left = 1, .right = 1 },
            .background = raised,
        }, .{ .color = foreground });
    }

    const card = try common.addBox(doc, content, .{
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .row = 1 },
        .padding = ui.EdgeDecl.all(1),
        .background = raised,
        .flex_grow = 1,
        .overflow = .hidden,
    });
    _ = try common.addLabel(doc, card, if (narrow) "auto margin footer" else "auto margins push this footer down", .{
        .height = .{ .cells = 1 },
        .overflow = .hidden,
    }, .{ .color = dim });
    _ = try common.addLabel(doc, card, "flex: 1 1 auto", .{
        .height = .{ .cells = 1 },
        .margin = .{ .top = .auto },
        .padding = .{ .left = 1, .right = 1 },
        .background = accent,
    }, .{ .color = foreground, .bold = true });
}
