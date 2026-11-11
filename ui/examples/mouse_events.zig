//! Every mouse event kind in one place: idle hover, press, move, release, click
//! and wheel are logged with their cell, button, modifiers, wheel delta and
//! hit-tested target. Idle motion highlights the zone under the pointer; the
//! log is the demo.
//!
//! Press `q` to quit. Input is read from stdin with SGR mouse reports, so the
//! example can also be driven by a pipe.
//!
//! Run with `cd ui && zig build example-mouse-events`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

const cols = 64;
const rows = 18;
const log_lines = 9;
const log_top = 8;

const background = common.rgb(16, 16, 22);
const foreground = common.rgb(220, 220, 235);
const dim = common.rgb(140, 140, 160);
const log_color = common.rgb(180, 220, 180);

const zone_names = [_][]const u8{ "left", "middle", "right" };
const zone_colors = [_]ui.Color{
    common.rgb(52, 36, 60),
    common.rgb(32, 52, 44),
    common.rgb(36, 44, 64),
};
const zone_hover_colors = [_]ui.Color{
    common.rgb(82, 56, 96),
    common.rgb(48, 82, 68),
    common.rgb(56, 68, 100),
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const example = try mouseEventsExample(allocator);
    defer if (example.deinit) |destroy| destroy(example.context);
    try common.runInteractive(allocator, example);
}

pub fn mouseEventsExample(allocator: std.mem.Allocator) !common.Example {
    const app = try allocator.create(App);
    app.* = .{
        .allocator = allocator,
        .doc = undefined,
    };
    return .{
        .title = "mouse events",
        .context = app,
        .build = build,
        .deinit = deinit,
    };
}

fn deinit(context: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    app.allocator.destroy(app);
}

fn build(
    context: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    _: common.Size,
) !void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    const root = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = background,
    });

    _ = try common.addLabel(doc, root, "mouse events", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 40 },
        .height = .{ .cells = 1 },
    }, .{
        .color = foreground,
        .bold = true,
    });
    _ = try common.addLabel(doc, root, "hover a zone; press, drag, release, click and wheel | q quit", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 60 },
        .height = .{ .cells = 1 },
    }, .{
        .color = dim,
    });

    app.doc = doc;
    for (zone_names, 0..) |name, index| {
        const left: f64 = @floatFromInt(2 + index * 20);
        const zone = try common.addBox(doc, root, .{
            .position = .absolute,
            .left = .{ .cells = left },
            .top = .{ .cells = 3 },
            .width = .{ .cells = 18 },
            .height = .{ .cells = 3 },
            .background = zone_colors[index],
            .text_align = .center,
        });
        _ = try common.addText(doc, zone, name, .{
            .color = foreground,
        });
        app.zone_nodes[index] = zone;
    }

    _ = try common.addLabel(doc, root, "event log (newest at the bottom)", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 6 },
        .width = .{ .cells = 60 },
        .height = .{ .cells = 1 },
    }, .{
        .color = dim,
        .bold = true,
    });

    for (0..log_lines) |index| {
        const top: f64 = @floatFromInt(log_top + index);
        // Text nodes are inline content; a positioned box owns the row.
        const row = try common.addBox(doc, root, .{
            .position = .absolute,
            .left = .{ .cells = 2 },
            .top = .{ .cells = top },
            .width = .{ .cells = cols - 4 },
            .height = .{ .cells = 1 },
        });
        const text = try common.addText(doc, row, "", .{
            .color = log_color,
        });
        app.log_rows[index] = text;
    }

    try root.addEventListener(.{
        .context = app,
        .mouse_down = App.onDown,
        .mouse_move = App.onMove,
        .mouse_up = App.onUp,
        .click = App.onClick,
        .wheel = App.onWheel,
    });
    // Capture motion before the logger so the hover style follows the pointer.
    try root.addEventListener(.{
        .context = app,
        .capture = true,
        .mouse_move = App.onHover,
    });

    app.push("ready: hover, click a zone, drag, and wheel");
}

const App = struct {
    allocator: Allocator,
    doc: *ui.Document,
    zone_nodes: [3]*ui.Node = undefined,
    log_rows: [log_lines]*ui.Node = undefined,
    log_text: [log_lines][120]u8 = undefined,
    log_lens: [log_lines]usize = @splat(0),
    hovered_zone: ?usize = null,

    fn zoneIndex(self: *const App, target: ?*ui.Node) ?usize {
        var current = target;
        while (current) |node| : (current = node.parent) {
            for (self.zone_nodes, 0..) |zone, index| {
                if (zone == node) return index;
            }
            if (node == self.doc.root) break;
        }
        return null;
    }

    fn zoneName(self: *const App, target: ?*ui.Node) []const u8 {
        const index = self.zoneIndex(target) orelse return "root";
        return zone_names[index];
    }

    fn onHover(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        const hovered = self.zoneIndex(event.target);
        if (hovered == self.hovered_zone) return;
        self.hovered_zone = hovered;
        for (self.zone_nodes, 0..) |zone, index| {
            var style = zone.style().*;
            style.background = if (hovered == index) zone_hover_colors[index] else zone_colors[index];
            zone.setStyle(style);
        }
    }

    fn push(self: *App, text: []const u8) void {
        const length = @min(text.len, self.log_text[0].len);
        var index: usize = 1;
        while (index < log_lines) : (index += 1) {
            const previous = self.log_lens[index];
            @memcpy(self.log_text[index - 1][0..previous], self.log_text[index][0..previous]);
            self.log_lens[index - 1] = previous;
        }
        @memcpy(self.log_text[log_lines - 1][0..length], text[0..length]);
        self.log_lens[log_lines - 1] = length;

        for (self.log_rows, 0..) |row, i| {
            row.setTextContent(self.log_text[i][0..self.log_lens[i]]) catch {};
        }
    }

    fn record(self: *App, event: *ui.MouseEvent) void {
        var buffer: [120]u8 = undefined;
        const zone = self.zoneName(event.target);
        const text = switch (event.kind) {
            .wheel => std.fmt.bufPrint(
                &buffer,
                "{s:<5} x={d:>2} y={d:>2}  dy={d:>3} dx={d:>3}  -> {s}",
                .{ kindName(event.kind), event.x, event.y, event.delta_y, event.delta_x, zone },
            ) catch "",
            else => std.fmt.bufPrint(
                &buffer,
                "{s:<5} x={d:>2} y={d:>2}  {s:<6} {s:<3} -> {s}",
                .{
                    kindName(event.kind),
                    event.x,
                    event.y,
                    buttonName(event.button),
                    modsName(event.mods),
                    zone,
                },
            ) catch "",
        };
        self.push(text);
    }

    fn onDown(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        self.record(event);
    }

    fn onMove(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        self.record(event);
    }

    fn onUp(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        self.record(event);
    }

    fn onClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        self.record(event);
    }

    fn onWheel(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        self.record(event);
    }
};

fn kindName(kind: ui.MouseKind) []const u8 {
    return switch (kind) {
        .down => "down",
        .move => "move",
        .up => "up",
        .click => "click",
        .wheel => "wheel",
    };
}

fn buttonName(button: ui.MouseButton) []const u8 {
    return switch (button) {
        .none => "-",
        .left => "left",
        .middle => "middle",
        .right => "right",
    };
}

fn modsName(mods: ui.Modifiers) []const u8 {
    if (mods.shift and mods.alt and mods.ctrl) return "sac";
    if (mods.shift and mods.alt) return "sa";
    if (mods.shift and mods.ctrl) return "sc";
    if (mods.alt and mods.ctrl) return "ac";
    if (mods.shift) return "s";
    if (mods.alt) return "a";
    if (mods.ctrl) return "c";
    return "-";
}
