//! Mouse operations: hover a row to highlight it, click to select it, drag
//! across rows to extend the selection, and wheel over the list to scroll. The
//! status row reports the last event and the selection.
//!
//! Press `q` to quit. Input is read from stdin with SGR mouse reports, so the
//! example can also be driven by a pipe.
//!
//! Run with `cd ui && zig build example-mouse`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

const cols = 64;
const rows = 16;
const list_left = 2;
const list_top = 3;
const list_width = 60;
const list_height = 9;

const items = [_][]const u8{
    "app.zig",      "dom.zig",        "event.zig",     "input.zig",
    "surface.zig",  "box.zig",        "layout.zig",    "paint.zig",
    "style.zig",    "cell.zig",       "frame.zig",     "ansi.zig",
    "inputbox.zig", "examples/hello", "examples/list", "examples/focus",
    "tests.zig",    "README.md",      "docs/guide",    "release notes",
    "changelog",    "TODO",           "LICENSE",       "build.zig.zon",
};

const background = common.rgb(16, 16, 22);
const panel_background = common.rgb(24, 24, 32);
const foreground = common.rgb(220, 220, 235);
const dim = common.rgb(140, 140, 160);
const accent = common.rgb(48, 66, 112);
const hover_background = common.rgb(36, 36, 48);
const selected_text = common.rgb(255, 255, 255);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const example = try mouseExample(allocator);
    defer if (example.deinit) |destroy| destroy(example.context);
    try common.runInteractive(allocator, example);
}

pub fn mouseExample(allocator: std.mem.Allocator) !common.Example {
    const app = try allocator.create(App);
    app.* = .{
        .allocator = allocator,
        .status = undefined,
        .panel = undefined,
    };
    return .{
        .title = "mouse",
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
    size: common.Size,
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

    _ = try common.addLabel(doc, root, "mouse ops", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 40 },
        .height = .{ .cells = 1 },
    }, .{
        .color = foreground,
        .bold = true,
    });
    _ = try common.addLabel(doc, root, "hover/click a row | drag to select | wheel over the list | q quit", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = list_width },
        .height = .{ .cells = 1 },
    }, .{
        .color = dim,
    });

    const panel = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = list_left },
        .top = .{ .cells = list_top },
        .width = .{ .cells = list_width },
        .height = .{ .cells = list_height },
        .overflow = .hidden,
        .background = panel_background,
    });

    const status_bar = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = @floatFromInt(size.height -| 1) },
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .background = common.rgb(40, 40, 52),
    });
    app.status = try common.addText(doc, status_bar, "", .{
        .color = foreground,
    });
    app.panel = panel;

    for (0..list_height) |index| {
        const row = try common.addBox(doc, panel, .{
            .position = .absolute,
            .left = .{ .cells = 1 },
            .top = .{ .cells = @floatFromInt(index) },
            .width = .{ .cells = list_width - 2 },
            .height = .{ .cells = 1 },
        });
        const text = try common.addText(doc, row, "", .{
            .color = foreground,
        });
        app.rows[index] = .{
            .app = app,
            .row = index,
            .box = row,
            .text = text,
        };
        try row.addEventListener(app.rows[index].listener());
    }

    // Wheel and release bubble from a row to the panel, so the list keeps
    // scrolling even when the pointer is over a selected row.
    try panel.addEventListener(.{
        .context = app,
        .mouse_move = App.onPanelMove,
        .mouse_up = App.onPanelUp,
        .wheel = App.onPanelWheel,
    });
    if (doc.root) |doc_root| {
        try doc_root.addEventListener(.{
            .context = app,
            .capture = true,
            .mouse_move = App.onDocumentMove,
        });
    }

    app.apply();
}

const App = struct {
    allocator: Allocator,
    status: *ui.Node,
    panel: *ui.Node,
    rows: [list_height]Row = undefined,
    scroll: usize = 0,
    anchor: ?usize = null,
    active: ?usize = null,
    hovered: ?usize = null,
    dragging: bool = false,
    last: [96]u8 = undefined,
    last_len: usize = 0,

    fn maxScroll(self: *const App) usize {
        _ = self;
        return items.len -| list_height;
    }

    fn selection(self: *const App) ?struct { start: usize, end: usize } {
        const anchor = self.anchor orelse return null;
        const active = self.active orelse return null;
        return .{
            .start = @min(anchor, active),
            .end = @max(anchor, active),
        };
    }

    fn isSelected(self: *const App, index: usize) bool {
        const range = self.selection() orelse return false;
        return index >= range.start and index <= range.end;
    }

    fn setLast(self: *App, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.last, fmt, args) catch "";
        self.last_len = text.len;
    }

    fn updateStatus(self: *App) void {
        var selection_buffer: [32]u8 = undefined;
        const selection_text = if (self.selection()) |range|
            std.fmt.bufPrint(&selection_buffer, "{d}-{d}", .{ range.start + 1, range.end + 1 }) catch "?"
        else
            "none";
        var buffer: [192]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            " sel {s}   scroll {d}/{d}   last: {s}",
            .{ selection_text, self.scroll, self.maxScroll(), self.last[0..self.last_len] },
        ) catch "";
        self.status.setTextContent(text) catch {};
    }

    fn apply(self: *App) void {
        for (&self.rows, 0..) |*row, index| {
            const item_index = self.scroll + index;
            const selected = item_index < items.len and self.isSelected(item_index);

            const hovered = item_index < items.len and self.hovered == item_index;
            var row_style = row.box.style().*;
            row_style.background = if (selected) accent else if (hovered) hover_background else null;
            row.box.setStyle(row_style);

            var text_style = row.text.style().*;
            text_style.color = if (selected or hovered) selected_text else foreground;
            row.text.setStyle(text_style);

            if (item_index < items.len) {
                var label: [64]u8 = undefined;
                const value = std.fmt.bufPrint(
                    &label,
                    " {d:>2}  {s}",
                    .{ item_index + 1, items[item_index] },
                ) catch "";
                row.text.setTextContent(value) catch {};
            } else {
                row.text.setTextContent("") catch {};
            }
        }
        self.updateStatus();
    }

    fn select(self: *App, index: usize) void {
        self.anchor = index;
        self.active = index;
    }

    fn scrollBy(self: *App, delta: i32) bool {
        const current: isize = @intCast(self.scroll);
        const maximum: isize = @intCast(self.maxScroll());
        const next = std.math.clamp(current + delta, 0, maximum);
        if (next == current) return false;
        self.scroll = @intCast(next);
        return true;
    }

    fn onPanelMove(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        if (event.button != .none or event.target != self.panel) return;
        if (self.hovered == null) return;
        self.hovered = null;
        self.apply();
    }

    fn onDocumentMove(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        if (event.button != .none) return;
        if (isWithin(event.target, self.panel) or self.hovered == null) return;
        self.hovered = null;
        self.apply();
    }

    fn onPanelUp(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        if (event.button != .left) return;
        self.dragging = false;
        self.setLast("release at {d},{d}", .{ event.x, event.y });
        self.apply();
    }

    fn onPanelWheel(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        if (event.delta_y != 0 and self.scrollBy(event.delta_y)) {
            self.hovered = null;
            self.setLast("wheel dy={d} -> row {d}", .{ event.delta_y, self.scroll });
        }
        self.apply();
        // The list consumed the notch; do not let a parent scroll.
        event.preventDefault();
    }
};

const Row = struct {
    app: *App,
    row: usize,
    box: *ui.Node,
    text: *ui.Node,

    fn itemIndex(self: *const Row) ?usize {
        const index = self.app.scroll + self.row;
        if (index >= items.len) return null;
        return index;
    }

    fn listener(self: *Row) ui.Listener {
        return .{
            .context = self,
            .mouse_down = onDown,
            .mouse_move = onMove,
            .click = onClick,
        };
    }

    fn onDown(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *Row = @ptrCast(@alignCast(context orelse return));
        if (event.button != .left) return;
        const index = self.itemIndex() orelse return;
        self.app.select(index);
        self.app.dragging = true;
        self.app.setLast("press row {d} at {d},{d}", .{ index + 1, event.x, event.y });
        self.app.apply();
    }

    fn onMove(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *Row = @ptrCast(@alignCast(context orelse return));
        const index = self.itemIndex() orelse return;

        if (event.button == .none) {
            if (self.app.hovered == index) return;
            self.app.hovered = index;
            self.app.apply();
            return;
        }
        if (event.button != .left or !self.app.dragging) return;
        if (self.app.active == index) return;
        self.app.active = index;
        self.app.setLast("drag row {d} at {d},{d}", .{ index + 1, event.x, event.y });
        self.app.apply();
    }

    fn onClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *Row = @ptrCast(@alignCast(context orelse return));
        const index = self.itemIndex() orelse return;
        self.app.setLast("click row {d} at {d},{d}", .{ index + 1, event.x, event.y });
        self.app.apply();
    }
};

fn isWithin(target: ?*ui.Node, ancestor: *ui.Node) bool {
    var current = target;
    while (current) |node| : (current = node.parent) {
        if (node == ancestor) return true;
    }
    return false;
}
