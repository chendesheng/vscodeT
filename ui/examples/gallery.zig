//! Fullscreen gallery for the UI examples: a side navigation list on the left
//! and the selected example in the content area. Up/Down (and PageUp/PageDown,
//! Home/End) change the selection; hover/click a sidebar item; wheel moves the
//! selection. Mouse events over the content go to the example.
//!
//! Run with `cd ui && zig build examples`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const hello = @import("hello.zig");
const list = @import("list.zig");
const layout = @import("layout.zig");
const flex = @import("flex.zig");
const overflow = @import("overflow.zig");
const borders = @import("borders.zig");
const table = @import("table.zig");
const tree = @import("tree.zig");
const styling = @import("styling.zig");
const focus = @import("focus.zig");
const mouse = @import("mouse.zig");
const mouse_events = @import("mouse_events.zig");

const sidebar_width = 16;
const items_top = 2;
const Allocator = std.mem.Allocator;

const Entry = struct {
    title: []const u8,
    open: *const fn (Allocator) anyerror!common.Example,
};

const entries = [_]Entry{
    .{ .title = "hello", .open = hello.helloExample },
    .{ .title = "list", .open = list.listExample },
    .{ .title = "layout", .open = layout.layoutExample },
    .{ .title = "flex", .open = flex.flexExample },
    .{ .title = "overflow", .open = overflow.overflowExample },
    .{ .title = "borders", .open = borders.bordersExample },
    .{ .title = "table", .open = table.tableExample },
    .{ .title = "tree", .open = tree.treeExample },
    .{ .title = "styling", .open = styling.stylingExample },
    .{ .title = "focus", .open = focus.focusExample },
    .{ .title = "mouse", .open = mouse.mouseExample },
    .{ .title = "mouse events", .open = mouse_events.mouseEventsExample },
};

const sidebar_background = common.rgb(22, 22, 30);
const content_background = common.rgb(16, 16, 22);
const foreground = common.rgb(220, 220, 235);
const dim = common.rgb(140, 140, 160);
const selected_background = common.rgb(62, 82, 132);
const hover_background = common.rgb(38, 38, 50);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var surface = try common.fullscreenSurface(allocator);
    defer surface.deinit();

    var app = Gallery{
        .allocator = allocator,
        .surface = &surface,
    };
    defer app.deinit();

    try app.openSelected();
    try app.present();
}

const Gallery = struct {
    allocator: Allocator,
    surface: *ui.Surface,
    selected: usize = 0,
    scroll: usize = 0,
    hovered: ?usize = null,
    scene: ?common.Example = null,
    item_nodes: [entries.len]?*ui.Node = @splat(null),
    item_indices: [entries.len]?usize = @splat(null),
    router: common.MouseRouter = .{},
    quit: bool = false,

    fn deinit(self: *Gallery) void {
        if (self.scene) |scene| {
            if (scene.deinit) |destroy| destroy(scene.context);
        }
    }

    fn openSelected(self: *Gallery) !void {
        if (self.scene) |scene| {
            if (scene.deinit) |destroy| destroy(scene.context);
        }
        self.scene = null;
        self.scene = try entries[self.selected].open(self.allocator);
        self.ensureVisible();
        try self.rebuild();
    }

    fn visibleRows(self: *const Gallery) usize {
        const rows = self.surface.document().rows;
        return (rows -| items_top) -| 1;
    }

    fn ensureVisible(self: *Gallery) void {
        const visible = self.visibleRows();
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (visible > 0 and self.selected >= self.scroll + visible) {
            self.scroll = self.selected - visible + 1;
        }
    }

    fn sidebarCells(self: *const Gallery) usize {
        return @min(sidebar_width, self.surface.document().cols);
    }

    fn itemStyle(self: *const Gallery, index: usize) ui.Style {
        return .{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(self.sidebarCells() -| 1) },
            .height = .{ .cells = 1 },
            .padding = .{ .left = 1 },
            .overflow = .hidden,
            .background = if (index == self.selected)
                selected_background
            else if (index == self.hovered)
                hover_background
            else
                null,
            .color = if (index == self.selected or index == self.hovered) foreground else dim,
        };
    }

    fn applyItemStyles(self: *Gallery) void {
        for (self.item_nodes, 0..) |maybe_node, slot| {
            const node = maybe_node orelse continue;
            const index = self.item_indices[slot] orelse continue;
            var style = node.style().*;
            style.background = if (index == self.selected)
                selected_background
            else if (index == self.hovered)
                hover_background
            else
                null;
            style.color = if (index == self.selected or index == self.hovered) foreground else dim;
            node.setStyle(style);
        }
    }

    fn rebuild(self: *Gallery) !void {
        const doc = self.surface.document();
        doc.clear();
        self.item_nodes = @splat(null);
        self.item_indices = @splat(null);

        const cols = doc.cols;
        const rows = doc.rows;
        const sidebar = self.sidebarCells();
        const content_width = cols -| sidebar;

        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .background = content_background,
        });
        doc.setRoot(root);

        const nav = try common.addBox(doc, root, .{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(sidebar) },
            .height = .{ .percent = 100 },
            .overflow = .hidden,
            .background = sidebar_background,
        });
        _ = try common.addLabel(doc, nav, "examples", .{
            .position = .absolute,
            .left = .{ .cells = 1 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(sidebar -| 2) },
            .height = .{ .cells = 1 },
            .overflow = .hidden,
        }, .{
            .color = foreground,
            .bold = true,
        });

        const visible = self.visibleRows();
        var slot: usize = 0;
        while (slot < visible and self.scroll + slot < entries.len) : (slot += 1) {
            const index = self.scroll + slot;
            var style = self.itemStyle(index);
            style.top = .{ .cells = @floatFromInt(items_top + slot) };
            const item = try common.addBox(doc, nav, style);
            _ = try common.addText(doc, item, entries[index].title, .{});
            self.item_nodes[slot] = item;
            self.item_indices[slot] = index;
        }

        if (rows > 1) {
            _ = try common.addLabel(doc, nav, "up/down q quit", .{
                .position = .absolute,
                .left = .{ .cells = 1 },
                .top = .{ .cells = @floatFromInt(rows - 1) },
                .width = .{ .cells = @floatFromInt(sidebar -| 2) },
                .height = .{ .cells = 1 },
                .overflow = .hidden,
            }, .{ .color = dim });
        }

        if (content_width > 0) {
            const content = try common.addBox(doc, root, .{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(sidebar) },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(content_width) },
                .height = .{ .percent = 100 },
                .overflow = .hidden,
                .background = content_background,
            });
            if (self.scene) |scene| {
                try scene.build(scene.context, doc, content, .{
                    .width = content_width,
                    .height = rows,
                });
            }
        }

        self.applyItemStyles();
    }

    fn itemAt(self: *const Gallery, x: usize, y: usize) ?usize {
        if (x >= self.sidebarCells()) return null;
        const rows = self.surface.document().rows;
        if (y < items_top or y >= rows -| 1) return null;
        const slot = y - items_top;
        if (slot >= self.visibleRows()) return null;
        const index = self.scroll + slot;
        if (index >= entries.len) return null;
        return index;
    }

    fn select(self: *Gallery, index: usize) !void {
        const next = @min(index, entries.len - 1);
        if (next == self.selected) return;
        self.selected = next;
        self.hovered = null;
        try self.openSelected();
    }

    fn handleKey(self: *Gallery, event: *ui.KeyEvent) !bool {
        const ctrl_q = event.mods.ctrl and switch (event.key) {
            .char => |ch| ch == 'q',
            else => false,
        };
        if (ctrl_q) {
            self.quit = true;
            return false;
        }

        switch (event.key) {
            .text => |text| {
                if (std.mem.eql(u8, text, "q")) {
                    self.quit = true;
                    return false;
                }
            },
            .char => |ch| {
                if (ch == 'q') {
                    self.quit = true;
                    return false;
                }
            },
            else => {},
        }

        const page = self.visibleRows();
        const last = entries.len - 1;
        const next = switch (event.key) {
            .up => self.selected -| 1,
            .down => @min(self.selected + 1, last),
            .page_up => self.selected -| page,
            .page_down => @min(self.selected + page, last),
            .home => 0,
            .end => last,
            else => self.selected,
        };
        if (next == self.selected) return false;
        try self.select(next);
        return true;
    }

    fn handleMouse(self: *Gallery, event: *ui.MouseEvent) !bool {
        if (event.x < self.sidebarCells()) {
            switch (event.kind) {
                .move => {
                    const hovered = self.itemAt(event.x, event.y);
                    if (hovered == self.hovered) return false;
                    self.hovered = hovered;
                    self.applyItemStyles();
                    return true;
                },
                .down => {
                    if (event.button != .left) return false;
                    if (self.itemAt(event.x, event.y)) |index| try self.select(index);
                    return true;
                },
                .wheel => {
                    if (event.delta_y == 0) return false;
                    const next = if (event.delta_y > 0)
                        @min(self.selected + 1, entries.len - 1)
                    else
                        self.selected -| 1;
                    if (next == self.selected) return false;
                    try self.select(next);
                    return true;
                },
                else => return false,
            }
        }

        try self.router.dispatch(self.surface, event);
        return true;
    }

    fn present(self: *Gallery) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var buffer: [16384]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);
        const out = &stdout.interface;

        try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h");
        defer {
            out.writeAll("\x1b[?1006l\x1b[?1003l\x1b[?25h\x1b[?1049l") catch {};
            out.flush() catch {};
        }

        const orig_termios = common.enableRawMode(io);
        defer {
            if (orig_termios) |orig| common.disableRawMode(orig) catch {};
        }

        try self.surface.render(out, .{});
        try out.flush();

        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        while (!self.quit) {
            const ready = (std.posix.poll(&fds, -1) catch 0) > 0;
            if (!ready) continue;

            var bytes: [1024]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &bytes) catch 0;
            if (n == 0) return;

            var items = try ui.input.decode(self.allocator, bytes[0..n]);
            defer items.deinit(self.allocator);

            for (items.items) |*item| {
                switch (item.*) {
                    .key => |*key| _ = try self.handleKey(key),
                    .mouse => |*event| _ = try self.handleMouse(event),
                }
                if (self.quit) return;
            }

            try self.surface.render(out, .{});
            try out.flush();
        }
    }
};
