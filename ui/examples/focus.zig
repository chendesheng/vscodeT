//! Keyboard focus: focusable items, Tab traversal, Enter/Space activation and
//! the active element. Press `q` to quit. Input is read from stdin, so a pipe
//! can drive it too; EOF exits.
//!
//! Run with `cd ui && zig build example-focus`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

const labels = [_][]const u8{ "Open file", "Search", "Settings" };

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const example = try focusExample(allocator);
    defer if (example.deinit) |destroy| destroy(example.context);
    try common.runInteractive(allocator, example);
}

pub fn focusExample(allocator: std.mem.Allocator) !common.Example {
    const app = try allocator.create(App);
    app.* = .{
        .allocator = allocator,
        .doc = undefined,
        .status = undefined,
    };
    return .{
        .title = "focus",
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
    app.doc = doc;
    app.quit = false;

    const root = try common.addBox(doc, parent, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .display = .flex,
        .flex_direction = .column,
        .background = common.rgb(16, 16, 22),
    });

    _ = try common.addLabel(doc, root, "keyboard focus", .{
        .height = .{ .cells = 1 },
        .margin = .{ .left = .{ .cells = 3 } },
        .flex_shrink = 0,
    }, .{
        .color = common.rgb(255, 255, 255),
        .bold = true,
    });

    const list = try common.addBox(doc, root, .{
        .display = .flex,
        .flex_direction = .column,
        .flex_grow = 1,
        .margin = .{ .left = .{ .cells = 3 }, .right = .{ .cells = 3 }, .top = .{ .cells = 1 } },
        .overflow = .hidden,
    });

    inline for (labels, 0..) |label, i| {
        const node = try common.addBox(doc, list, .{
            .height = .{ .cells = 1 },
            .flex_shrink = 0,
            .border = ui.Edges.all(1),
            .border_color = common.rgb(70, 70, 90),
            .background = common.rgb(28, 28, 38),
            .padding = .{ .left = 2 },
        });
        _ = try common.addText(doc, node, label, .{
            .color = common.rgb(190, 190, 210),
        });

        app.items[i] = .{
            .app = app,
            .node = node,
            .label = label,
        };
        node.asElement().focusable = true;
        try node.addEventListener(app.items[i].listener());
        try node.addEventListener(app.items[i].focusListener());
    }

    const status_bar = try common.addBox(doc, root, .{
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .flex_shrink = 0,
        .background = common.rgb(40, 40, 52),
    });
    app.status = try common.addText(doc, status_bar, "", .{
        .color = common.rgb(220, 220, 235),
    });

    try root.addEventListener(.{ .context = app, .key_down = App.onRootKey });
    _ = doc.focus(app.items[0].node);
    app.updateStatus();
}

const App = struct {
    allocator: Allocator,
    doc: *ui.Document,
    status: *ui.Node,
    items: [labels.len]Item = undefined,
    quit: bool = false,

    fn updateStatus(self: *App) void {
        const active = self.doc.activeElement();
        var name: []const u8 = "root";
        for (&self.items) |*item| {
            if (active == item.node) {
                name = item.label;
                break;
            }
        }
        var buffer: [160]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            " focus: {s}   Tab move   Enter activate   q quit",
            .{name},
        ) catch "";
        self.status.setTextContent(text) catch {};
    }

    fn activate(self: *App, label: []const u8) void {
        var buffer: [160]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            " activated: {s}   Tab move   Enter activate   q quit",
            .{label},
        ) catch "";
        self.status.setTextContent(text) catch {};
    }

    fn onRootKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));

        const ctrl_q = event.mods.ctrl and switch (event.key) {
            .char => |ch| ch == 'q',
            else => false,
        };
        if (ctrl_q) {
            self.quit = true;
            event.preventDefault();
            return;
        }

        switch (event.key) {
            .text => |text| {
                if (std.mem.eql(u8, text, "q")) {
                    self.quit = true;
                    event.preventDefault();
                }
            },
            .escape => {
                self.doc.blur();
                self.updateStatus();
            },
            else => {},
        }
    }
};

const Item = struct {
    app: *App,
    node: *ui.Node,
    label: []const u8,
    focused: bool = false,

    fn listener(self: *Item) ui.Listener {
        return .{ .context = self, .key_down = onKeyDown };
    }

    fn focusListener(self: *Item) ui.Listener {
        return .{
            .context = self,
            .focus = onFocus,
            .blur = onBlur,
        };
    }

    fn onFocus(context: ?*anyopaque, _: *ui.FocusEvent) void {
        const self: *Item = @ptrCast(@alignCast(context orelse return));
        self.focused = true;
        self.applyStyle();
        self.app.updateStatus();
    }

    fn onBlur(context: ?*anyopaque, _: *ui.FocusEvent) void {
        const self: *Item = @ptrCast(@alignCast(context orelse return));
        self.focused = false;
        self.applyStyle();
        self.app.updateStatus();
    }

    fn onKeyDown(context: ?*anyopaque, event: *ui.KeyEvent) void {
        const self: *Item = @ptrCast(@alignCast(context orelse return));
        switch (event.key) {
            .enter => self.app.activate(self.label),
            // A terminal sends Space as printable text, not a control key.
            .text => |text| {
                if (std.mem.eql(u8, text, " ")) self.app.activate(self.label);
            },
            .char => |ch| {
                if (ch == ' ') self.app.activate(self.label);
            },
            else => {},
        }
    }

    fn applyStyle(self: *Item) void {
        var style = self.node.style().*;
        style.background = if (self.focused)
            common.rgb(55, 70, 110)
        else
            common.rgb(28, 28, 38);
        style.border_color = if (self.focused)
            common.rgb(120, 180, 255)
        else
            common.rgb(70, 70, 90);
        style.color = if (self.focused)
            common.rgb(255, 255, 255)
        else
            common.rgb(190, 190, 210);
        self.node.setStyle(style);
    }
};
