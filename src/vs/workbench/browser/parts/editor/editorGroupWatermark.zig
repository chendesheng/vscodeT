// Port of `src/vs/workbench/browser/parts/editor/editorGroupWatermark.ts`.
// The terminal uses the supplied cell artwork and three shortcuts in a fixed
// order. The browser toolbar, randomized tips, hover tooltips and persisted
// context conditions are outside this terminal view's three commands.

const std = @import("std");
const ui = @import("ui");
const Class = @import("media/editorgroupview_css.zig").Class;

pub const settings_key = "workbench.tips.enabled";

pub const entries = [_]Entry{
    .{ .id = "workbench.action.showCommands", .label = "Show All Commands", .icon = "≡" },
    // An ASCII prompt keeps the layout width and the terminal's advance equal.
    .{ .id = "workbench.action.terminal.toggleTerminal", .label = "Toggle Terminal", .icon = ">" },
    .{ .id = "workbench.action.findInFiles", .label = "Find in Files", .icon = "⌕" },
};

const Entry = struct { id: []const u8, label: []const u8, icon: []const u8 };

const letterpress =
    \\                  ▗▄██▙▄▖
    \\                ▗▟█████████▄
    \\              ▄▟████████████
    \\ ▗▄▄        ▄███████████████
    \\▟████▙▄  ▗▄████████▀▘▐██████
    \\▝▀██████████████▛▘   ▐██████
    \\   ▀█████████▛▀      ▐██████
    \\   ▄█████████▙▄      ▐██████
    \\▗▄██████████████▙▖   ▐██████
    \\▜████▛▀  ▝▀████████▄▖▐██████
    \\ ▝▀▀        ▀███████████████
    \\              ▀▜████████████
    \\                ▝▜█████████▀
    \\                  ▝▀██▛▀▘
;
const letterpress_height = std.mem.count(u8, letterpress, "\n") + 1;

pub fn letterpressColor(background: ui.Color, foreground: ui.Color) ui.Color {
    // The letterpress is recessed on a dark theme and raised on a light
    // theme. On pure black/white, use the foreground to retain contrast.
    const brightness = @as(u16, background.r) + background.g + background.b;
    const edge: u16 = if (brightness >= 384) 255 else 0;
    if (brightness < 30 or brightness > 735) return .{
        .r = @intCast((@as(u16, background.r) * 9 + foreground.r) / 10),
        .g = @intCast((@as(u16, background.g) * 9 + foreground.g) / 10),
        .b = @intCast((@as(u16, background.b) * 9 + foreground.b) / 10),
    };
    return .{
        .r = @intCast((@as(u16, background.r) * 2 + edge) / 3),
        .g = @intCast((@as(u16, background.g) * 2 + edge) / 3),
        .b = @intCast((@as(u16, background.b) * 2 + edge) / 3),
    };
}

pub const Colors = struct {
    background: ui.Color,
    foreground: ui.Color,
    description: ui.Color,
    letterpress: ui.Color,
    hover: ui.Color,
    key_foreground: ui.Color,
    key_background: ui.Color,
};

pub const EditorGroupWatermark = struct {
    root: *ui.Node,
    content: *ui.Node,
    mark: *ui.Node,
    shortcuts: ?*ui.Node = null,
    letterpress_width: usize,
    shortcuts_width: usize = 0,
    shortcuts_height: usize = 0,

    pub fn init(group: *ui.Node) !EditorGroupWatermark {
        const doc = group.document;
        const root = try appendElement(group, .editor_group_watermark_wrapper);
        errdefer doc.destroy(root);
        const content = try appendElement(root, .editor_group_watermark);
        const mark = try appendElement(content, .letterpress);
        try mark.setAttribute("aria-hidden", "true");
        _ = try mark.appendChild(try doc.createTextBorrowed(letterpress));
        var width: usize = 0;
        var lines = std.mem.splitScalar(u8, letterpress, '\n');
        while (lines.next()) |line| width = @max(width, doc.measureText(line));
        return .{ .root = root, .content = content, .mark = mark, .letterpress_width = width };
    }

    pub fn renderShortcuts(
        self: *EditorGroupWatermark,
        labels: [entries.len]?[]const u8,
        context: *anyopaque,
        comptime execute: fn (*anyopaque, []const u8) void,
    ) !void {
        const doc = self.root.document;
        const shortcuts = try appendElement(self.content, .shortcuts);
        errdefer doc.destroy(shortcuts);
        try shortcuts.setAttribute("role", "toolbar");
        try shortcuts.setAttribute("aria-label", "Editor Shortcuts");
        var width: usize = 0;
        var count: usize = 0;
        for (entries, labels) |entry, label| {
            const keybinding = label orelse continue;
            const row = try appendElement(shortcuts, .watermark_entry);
            row.asElement().focusable = true;
            try row.setAttribute("role", "button");
            try row.setAttribute("data-command", entry.id);
            try row.addEventListener(.{
                .context = context,
                .key_down = Handlers(execute).onKey,
                .mouse_down = Handlers(execute).onMouseDown,
                .focus = onFocus,
                .blur = onBlur,
            });
            const icon = try appendText(row, .watermark_icon, entry.icon);
            try icon.setAttribute("aria-hidden", "true");
            _ = try appendText(row, .watermark_label, entry.label);
            _ = try appendText(row, .watermark_keybinding, keybinding);
            // One cell on each side of the row and the keycap, plus two gaps.
            const row_width = doc.measureText(entry.icon) + doc.measureText(entry.label) + doc.measureText(keybinding) + 6;
            width = @max(width, row_width);
            count += 1;
        }
        if (self.shortcuts) |old| doc.destroy(old);
        self.shortcuts = shortcuts;
        self.shortcuts_width = std.mem.alignForward(usize, @max(width, 36), 2);
        self.shortcuts_height = (count * 2) -| 1;
    }

    pub fn invalidateShortcuts(self: *EditorGroupWatermark) void {
        const shortcuts = self.shortcuts orelse return;
        self.blur();
        shortcuts.document.destroy(shortcuts);
        self.shortcuts = null;
        self.shortcuts_height = 0;
    }

    pub fn layout(self: *EditorGroupWatermark, width: usize, height: usize, visible: bool, tips: bool, colors: Colors) void {
        const show_shortcuts = visible and tips and self.shortcuts_height > 0 and
            width >= self.shortcuts_width + 2 and height >= self.shortcuts_height;
        const min_mark_height = letterpress_height + if (show_shortcuts) self.shortcuts_height + 1 else @as(usize, 0);
        const show_mark = visible and width >= self.letterpress_width and height >= min_mark_height;
        const shortcuts_width = if (show_shortcuts) self.shortcuts_width else 0;
        const shortcuts_height = if (show_shortcuts) self.shortcuts_height else 0;
        const content_width = @max(shortcuts_width, if (show_mark) self.letterpress_width else 0);
        const content_height = if (show_mark) min_mark_height else shortcuts_height;
        setStyle(self.root, .{
            .display = if (visible) .block else .none,
            .background = colors.background,
            .color = colors.foreground,
        });
        // Keep one-cell action rows on integral coordinates. A half-cell
        // origin can snap paint to a cell whose center misses the hit box.
        setStyle(self.content, .{
            .left = .{ .cells = @floatFromInt((width -| content_width) / 2) },
            .top = .{ .cells = @floatFromInt((height -| content_height) / 2) },
            .width = .{ .cells = @floatFromInt(content_width) },
            .height = .{ .cells = @floatFromInt(content_height) },
        });
        setStyle(self.mark, .{
            .display = if (show_mark) .block else .none,
            .width = .{ .cells = @floatFromInt(self.letterpress_width) },
            .height = .{ .cells = letterpress_height },
            .color = colors.letterpress,
        });
        const shortcuts = self.shortcuts orelse return;
        if (!show_shortcuts) self.blur();
        setStyle(shortcuts, .{
            .display = if (show_shortcuts) .flex else .none,
            .width = .{ .cells = @floatFromInt(self.shortcuts_width) },
            .height = .{ .cells = @floatFromInt(self.shortcuts_height) },
        });
        if (!show_shortcuts) return;
        var rows = ui.dom.children(shortcuts);
        while (rows.next()) |row| {
            row.setHoverStyle(.{ .background = colors.hover });
            setStyle(row.first_child.?, .{ .color = colors.description });
            setStyle(row.first_child.?.prev.?, .{ .color = colors.key_foreground, .background = colors.key_background });
        }
    }

    pub fn blur(self: *const EditorGroupWatermark) void {
        const doc = self.root.document;
        if (self.rowAt(doc.focusedElement()) != null) doc.blur();
    }

    pub fn rowAt(self: *const EditorGroupWatermark, target: ?*ui.Node) ?*ui.Node {
        const shortcuts = self.shortcuts orelse return null;
        var current = target;
        while (current) |node| : (current = node.parent) {
            if (node.parent == shortcuts) return node;
        }
        return null;
    }

    pub fn handleKey(self: *const EditorGroupWatermark, event: *const ui.KeyEvent) bool {
        const shortcuts = self.shortcuts orelse return false;
        if (self.root.declaredDisplay() == .none or shortcuts.declaredDisplay() == .none) return false;
        const doc = self.root.document;
        if (self.rowAt(doc.focusedElement()) == null) {
            if (event.mods.ctrl or event.mods.alt) return false;
            return switch (event.key) {
                .tab => doc.moveFocus(if (event.mods.shift) .backward else .forward),
                .backtab => doc.moveFocus(.backward),
                else => false,
            };
        }
        var key = event.*;
        doc.dispatchEvent(&key);
        return key.default_prevented or (!key.mods.ctrl and !key.mods.alt and (key.key == .tab or key.key == .backtab));
    }
};

fn Handlers(comptime execute: fn (*anyopaque, []const u8) void) type {
    return struct {
        fn onMouseDown(context: ?*anyopaque, event: *ui.MouseEvent) void {
            if (event.button != .left) return;
            const row = event.current_target.?;
            event.stopPropagation();
            event.preventDefault();
            _ = row.focus();
            execute(context.?, row.getAttribute("data-command").?);
        }

        fn onKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
            if (event.mods.ctrl or event.mods.alt) return;
            const row = event.current_target.?;
            switch (event.key) {
                .up => _ = row.prev.?.focus(),
                .down => _ = (row.next orelse row.parent.?.first_child.?).focus(),
                .escape => row.blur(),
                .enter => execute(context.?, row.getAttribute("data-command").?),
                .char => |ch| {
                    if (ch != ' ') return;
                    execute(context.?, row.getAttribute("data-command").?);
                },
                else => return,
            }
            event.preventDefault();
        }
    };
}

fn onFocus(_: ?*anyopaque, event: *ui.event.FocusEvent) void {
    setStyle(event.current_target.?, .{ .reverse = true });
}

fn onBlur(_: ?*anyopaque, event: *ui.event.FocusEvent) void {
    setStyle(event.current_target.?, .{});
}

fn appendElement(parent: *ui.Node, class: Class) !*ui.Node {
    const node = try parent.document.createElement(.div);
    errdefer parent.document.destroy(node);
    try node.addClass(class);
    return parent.appendChild(node);
}

fn appendText(parent: *ui.Node, class: Class, label: []const u8) !*ui.Node {
    const node = try appendElement(parent, class);
    _ = try node.appendChild(try parent.document.createText(label));
    return node;
}

fn setStyle(node: *ui.Node, style: ui.Style) void {
    if (!std.meta.eql(node.asElement().style, style)) node.setStyle(style);
}
