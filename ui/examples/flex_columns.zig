//! Nested column and row flex: a page header, a sidebar/content split, three
//! growing panels, and a footer pushed down by an auto margin.
//!
//! Run with `cd ui && zig build example-flex-columns`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const example = try flexColumnsExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runStatic(allocator, init.io, example);
}

pub fn flexColumnsExample(allocator: std.mem.Allocator) !common.Example {
    _ = allocator;
    return .{ .title = "flex columns", .build = build };
}

const background = common.rgb(17, 18, 24);
const panel = common.rgb(28, 31, 42);
const raised = common.rgb(38, 42, 56);
const accent = common.rgb(88, 132, 220);
const green = common.rgb(110, 200, 150);
const foreground = common.rgb(232, 234, 244);
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

    const compact = size.width < 48;
    const header = try common.addBox(doc, root, .{
        .height = .{ .cells = 1 },
        .display = .flex,
        .align_items = .center,
        .justify_content = .space_between,
        .gap = .{ .column = 1 },
        .overflow = .hidden,
    });
    _ = try common.addLabel(doc, header, "flex columns", .{
        .height = .{ .cells = 1 },
        .flex_shrink = 0,
    }, .{ .color = foreground, .bold = true });
    if (!compact) {
        _ = try common.addLabel(doc, header, "nested column + row flex", .{
            .height = .{ .cells = 1 },
            .overflow = .hidden,
        }, .{ .color = dim });
    }

    const body = try common.addBox(doc, root, .{
        .display = .flex,
        .gap = .{ .column = 1 },
    });

    const sidebar = try common.addBox(doc, body, .{
        .width = .{ .cells = if (compact) 16 else 20 },
        .flex_shrink = 0,
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .row = 1 },
        .padding = ui.EdgeDecl.all(1),
        .background = panel,
    });
    _ = try common.addLabel(doc, sidebar, "sidebar", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground, .bold = true });
    for ([_][]const u8{ "overview", "layout", "styles", "events" }) |item| {
        _ = try common.addLabel(doc, sidebar, item, .{
            .height = .{ .cells = 1 },
        }, .{ .color = dim });
    }
    _ = try common.addLabel(doc, sidebar, "auto margin", .{
        .height = .{ .cells = 1 },
        .margin = .{ .top = .auto },
        .background = raised,
        .overflow = .hidden,
    }, .{ .color = green });

    const main_panel = try common.addBox(doc, body, .{
        .display = .flex,
        .flex_direction = .column,
        .flex_grow = 1,
        .gap = .{ .row = 1 },
        .padding = ui.EdgeDecl.all(1),
        .background = panel,
    });
    _ = try common.addLabel(doc, main_panel, "main content", .{
        .height = .{ .cells = 1 },
    }, .{ .color = foreground, .bold = true });

    const panels = try common.addBox(doc, main_panel, .{
        .height = .{ .cells = 6 },
        .display = .flex,
        .gap = .{ .column = 1 },
    });
    const panel_label = if (compact) "grow" else "flex-grow: 1";
    for (0..3) |_| {
        const panel_box = try common.addBox(doc, panels, .{
            .display = .flex,
            .flex_direction = .column,
            .justify_content = .center,
            .align_items = .center,
            .flex_grow = 1,
            .overflow = .hidden,
            .background = raised,
        });
        _ = try common.addLabel(doc, panel_box, panel_label, .{
            .height = .{ .cells = 1 },
            .overflow = .hidden,
        }, .{ .color = foreground });
    }

    _ = try common.addLabel(doc, main_panel, "panels share the row with flex-grow", .{
        .height = .{ .cells = 1 },
    }, .{ .color = dim });

    _ = try common.addLabel(doc, root, if (compact) "footer · auto" else "footer · margin-top: auto", .{
        .height = .{ .cells = 1 },
        .overflow = .hidden,
        .margin = .{ .top = .auto },
        .background = accent,
    }, .{ .color = foreground, .bold = true });
}
