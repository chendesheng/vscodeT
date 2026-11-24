//! Interactive native context-menu example.
//!
//! The menu is not a DOM node: it paints over the scene and the host routes
//! keys/mouse to it while it is open. The scene mirrors the VS Code Search
//! context menu from the reference screenshots.
//!
//! Run with `cd ui && zig build example-context-menu`.
//! `m`, the `...` button, or Enter/Space on it opens the menu. Arrow keys
//! navigate, Right/Enter opens a submenu, Escape closes one level and then the
//! menu. Ctrl-Q quits.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

const background = common.rgb(30, 30, 30);
const chrome = common.rgb(37, 37, 38);
const panel_background = common.rgb(37, 37, 38);
const foreground = common.rgb(204, 204, 204);
const dim = common.rgb(140, 140, 150);
const accent = common.rgb(230, 200, 120);
const button_background = common.rgb(61, 61, 66);
const button_foreground = common.rgb(255, 255, 255);

const Choice = struct {
    app: *App,
    label: []const u8,
};

const App = struct {
    allocator: Allocator,
    menu: ?*ui.ContextMenu = null,
    button: ?*ui.Node = null,
    status: ?*ui.Node = null,
    choices: [14]Choice = undefined,

    fn initChoices(self: *App) void {
        self.choices = .{
            .{ .app = self, .label = "View as Tree" },
            .{ .app = self, .label = "Pull" },
            .{ .app = self, .label = "Push" },
            .{ .app = self, .label = "Clone" },
            .{ .app = self, .label = "Fetch" },
            .{ .app = self, .label = "Commit" },
            .{ .app = self, .label = "Changes" },
            .{ .app = self, .label = "Branch" },
            .{ .app = self, .label = "Show Git Output" },
            .{ .app = self, .label = "View as List" },
            .{ .app = self, .label = "View as Tree" },
            .{ .app = self, .label = "Sort Changes by Name" },
            .{ .app = self, .label = "Sort Changes by Path" },
            .{ .app = self, .label = "Sort Changes by Status" },
        };
    }

    fn destroyMenu(self: *App) void {
        if (self.menu) |menu| menu.deinit();
        self.menu = null;
    }

    fn openMenu(self: *App) void {
        self.destroyMenu();
        const button = self.button orelse return;
        const rect = button.asElement().rect;
        var x = ui.cell.snap(rect.x);
        var y = ui.cell.snap(rect.y + rect.h);
        if (rect.w <= 0 or rect.h <= 0) {
            x = 2;
            y = 5;
        }

        const submenu = [_]ui.ContextMenuItem{
            .{
                .label = "View as List",
                .type = .checkbox,
                .checked = true,
                .click = .{ .context = &self.choices[9], .callback = onItemClick },
            },
            .{
                .label = "View as Tree",
                .click = .{ .context = &self.choices[10], .callback = onItemClick },
            },
            .{ .type = .separator },
            .{
                .label = "Sort Changes by Name",
                .click = .{ .context = &self.choices[11], .callback = onItemClick },
            },
            .{
                .label = "Sort Changes by Path",
                .type = .checkbox,
                .checked = true,
                .click = .{ .context = &self.choices[12], .callback = onItemClick },
            },
            .{
                .label = "Sort Changes by Status",
                .click = .{ .context = &self.choices[13], .callback = onItemClick },
            },
        };

        const items = [_]ui.ContextMenuItem{
            .{
                .label = "View as Tree",
                .click = .{ .context = &self.choices[0], .callback = onItemClick },
            },
            .{
                .label = "View & Sort",
                .type = .submenu,
                .submenu = &submenu,
            },
            .{ .type = .separator },
            .{
                .label = "Pull",
                .accelerator = "Ctrl+P",
                .click = .{ .context = &self.choices[1], .callback = onItemClick },
            },
            .{
                .label = "Push",
                .accelerator = "Ctrl+Shift+P",
                .click = .{ .context = &self.choices[2], .callback = onItemClick },
            },
            .{ .label = "Clone", .enabled = false },
            .{
                .label = "Fetch",
                .click = .{ .context = &self.choices[4], .callback = onItemClick },
            },
            .{ .type = .separator },
            .{
                .label = "Commit",
                .click = .{ .context = &self.choices[5], .callback = onItemClick },
            },
            .{
                .label = "Changes",
                .type = .checkbox,
                .checked = true,
                .click = .{ .context = &self.choices[6], .callback = onItemClick },
            },
            .{
                .label = "Branch",
                .click = .{ .context = &self.choices[7], .callback = onItemClick },
            },
            .{
                .label = "Show Git Output",
                .click = .{ .context = &self.choices[8], .callback = onItemClick },
            },
        };

        self.menu = ui.contextmenu.popup(
            self.allocator,
            &items,
            .{
                .x = x,
                .y = y,
                .min_width = 24,
                .max_width = 48,
            },
            .{ .context = self, .callback = onHide },
        ) catch null;
    }
};

fn onItemClick(context: ?*anyopaque, event: ui.ContextMenuEvent) void {
    const choice: *Choice = @ptrCast(@alignCast(context orelse return));
    if (choice.app.status) |status_node| {
        var buffer: [160]u8 = undefined;
        const suffix = if (event.ctrl_key)
            " (Ctrl)"
        else if (event.shift_key)
            " (Shift)"
        else
            "";
        const text = std.fmt.bufPrint(&buffer, "Selected: {s}{s}", .{ choice.label, suffix }) catch return;
        status_node.setTextContent(text) catch {};
    }
}

fn onHide(context: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    if (app.status) |status_node| {
        status_node.setTextContent("Menu closed") catch {};
    }
}

fn paintOverlay(context: ?*anyopaque, grid: *ui.CellGrid) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    const menu = app.menu orelse return;
    if (!menu.isOpen()) return;
    menu.renderWithBorderCapabilities(grid, .{});
}

fn keyOverlay(context: ?*anyopaque, event: *ui.KeyEvent) bool {
    const app: *App = @ptrCast(@alignCast(context orelse return false));
    const menu = app.menu orelse return false;
    if (!menu.isOpen()) {
        app.destroyMenu();
        return false;
    }
    _ = menu.handleKey(event);
    if (!menu.isOpen()) app.destroyMenu();
    return true;
}

fn mouseOverlay(context: ?*anyopaque, event: *ui.MouseEvent) bool {
    const app: *App = @ptrCast(@alignCast(context orelse return false));
    const menu = app.menu orelse return false;
    if (!menu.isOpen()) {
        app.destroyMenu();
        return false;
    }
    _ = menu.handleMouse(event);
    if (!menu.isOpen()) app.destroyMenu();
    return true;
}

fn onButtonClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
    if (event.button != .left) return;
    const app: *App = @ptrCast(@alignCast(context orelse return));
    if (app.menu == null) app.openMenu();
    event.stopPropagation();
    event.preventDefault();
}

fn onButtonKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    if (app.menu != null) return;
    if (!isActivationKey(event)) return;
    app.openMenu();
    event.stopPropagation();
    event.preventDefault();
}

fn onRootKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    if (app.menu != null) return;
    const is_menu_key = switch (event.key) {
        .char => |ch| ch == 'm',
        .text => |text| std.mem.eql(u8, text, "m"),
        else => false,
    };
    if (!is_menu_key or event.mods.ctrl or event.mods.alt) return;
    app.openMenu();
    event.stopPropagation();
    event.preventDefault();
}

fn isActivationKey(event: *const ui.KeyEvent) bool {
    return switch (event.key) {
        .enter => true,
        .char => |ch| ch == ' ',
        .text => |text| std.mem.eql(u8, text, " "),
        else => false,
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const example = try contextMenuExample(allocator);
    defer if (example.deinit) |deinit| deinit(example.context);
    try common.runInteractive(allocator, example);
}

pub fn contextMenuExample(allocator: Allocator) !common.Example {
    const app = try allocator.create(App);
    errdefer allocator.destroy(app);
    app.* = .{ .allocator = allocator };
    app.initChoices();

    return .{
        .title = "context menu",
        .context = app,
        .build = build,
        .deinit = galleryDeinit,
        .wants_keys = true,
        .overlay = .{
            .context = app,
            .paint = paintOverlay,
            .key_down = keyOverlay,
            .mouse = mouseOverlay,
        },
    };
}

fn galleryDeinit(context: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    const allocator = app.allocator;
    app.destroyMenu();
    allocator.destroy(app);
}

fn build(
    context: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    size: common.Size,
) !void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    app.destroyMenu();
    app.button = null;
    app.status = null;

    const root = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = background,
        .overflow = .hidden,
    });
    try root.addEventListener(.{ .context = app, .key_down = onRootKey });

    _ = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .background = chrome,
    });
    _ = try common.addLabel(doc, root, " Search: test   ×", .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = @floatFromInt(size.width -| 4) },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
    }, .{ .color = foreground });

    const button = try common.addBox(doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 2 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .background = button_background,
        .pointer = .pointer,
    });
    button.asElement().focusable = true;
    button.asElement().tab_index = 0;
    _ = try common.addText(doc, button, "...", .{
        .color = button_foreground,
        .bold = true,
    });
    try button.addEventListener(.{
        .context = app,
        .click = onButtonClick,
        .key_down = onButtonKey,
    });
    app.button = button;

    if (size.height >= 12 and size.width > 20) {
        const panel_width = @min(size.width -| 4, 62);
        const panel_height = @min(size.height -| 10, 12);
        const panel = try common.addBox(doc, root, .{
            .position = .absolute,
            .left = .{ .cells = 2 },
            .top = .{ .cells = 4 },
            .width = .{ .cells = @floatFromInt(panel_width) },
            .height = .{ .cells = @floatFromInt(panel_height) },
            .padding = ui.EdgeDecl.all(1),
            .border = ui.EdgeDecl.all(1),
            .border_style = .rounded,
            .border_color = common.rgb(69, 69, 69),
            .background = panel_background,
            .overflow = .hidden,
        });
        _ = try common.addLabel(doc, panel, "test — 7 files", .{
            .position = .absolute,
            .left = .{ .cells = 1 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(panel_width -| 4) },
            .height = .{ .cells = 1 },
            .overflow = .hidden,
        }, .{ .color = accent, .bold = true });
        const rows = [_][]const u8{
            "http-proxy.js:",
            "  84  let path",
            "index.ts:",
            "  12  export const",
            "contextmenu.zig:",
            "  1  const std = @import",
        };
        for (rows, 0..) |line, index| {
            _ = try common.addLabel(doc, panel, line, .{
                .position = .absolute,
                .left = .{ .cells = 1 },
                .top = .{ .cells = @floatFromInt(2 + index) },
                .width = .{ .cells = @floatFromInt(panel_width -| 4) },
                .height = .{ .cells = 1 },
                .overflow = .hidden,
            }, .{ .color = if (std.mem.endsWith(u8, line, ":")) foreground else dim });
        }
    }

    if (size.height >= 3) {
        const status = try common.addBox(doc, root, .{
            .position = .absolute,
            .left = .{ .cells = 2 },
            .top = .{ .cells = @floatFromInt(size.height - 2) },
            .width = .{ .cells = @floatFromInt(size.width -| 4) },
            .height = .{ .cells = 1 },
            .overflow = .hidden,
        });
        app.status = try common.addText(doc, status, "Selected: none", .{
            .color = accent,
            .bold = true,
        });

        _ = try common.addLabel(doc, root, "m / ... menu   ↑↓  →  ←  enter  esc   Ctrl-Q quit", .{
            .position = .absolute,
            .left = .{ .cells = 2 },
            .top = .{ .cells = @floatFromInt(size.height - 1) },
            .width = .{ .cells = @floatFromInt(size.width -| 4) },
            .height = .{ .cells = 1 },
            .overflow = .hidden,
        }, .{ .color = dim });
    }

    _ = button.focus();
}
