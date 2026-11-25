// Port of the notification list/viewer in
// `src/vs/workbench/browser/parts/notifications/notificationsList.ts` and
// `notificationsViewer.ts`. Terminal adaptation: rows occupy cells and
// actions/explicit links have hit regions rather than browser DOM targets.
// ARIA labels and browser pixel measurements are not used by the terminal.
const std = @import("std");
const ui = @import("ui");
const Item = @import("../../../common/notifications.zig").NotificationViewItem;
const Model = @import("../../../common/notifications.zig").NotificationsModel;
const ThemeColors = @import("../../themeColors.zig").ThemeColors;
const Paint = ui.cell.PaintStyle;

pub const NotificationsList = struct {
    allocator: std.mem.Allocator,
    hits: std.ArrayList(Hit) = .empty,
    keyboard_hit: ?usize = null,

    pub const Action = union(enum) { row, close, toggle, primary: usize, secondary: usize, link: usize, clear_all, hide, filter };
    pub const Hit = struct { rect: ui.Rect, item: ?*Item = null, action: Action };

    pub fn init(allocator: std.mem.Allocator) NotificationsList {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *NotificationsList) void {
        self.hits.deinit(self.allocator);
    }
    pub fn clear(self: *NotificationsList) void {
        self.hits.clearRetainingCapacity();
    }
    pub fn invalidate(self: *NotificationsList) void {
        self.clear();
        self.keyboard_hit = null;
    }
    fn add(self: *NotificationsList, item: ?*Item, action: Action, bounds: ui.Rect) !void {
        if (bounds.w > 0 and bounds.h > 0) try self.hits.append(self.allocator, .{ .rect = bounds, .item = item, .action = action });
    }
    pub fn hitAt(self: *const NotificationsList, x: usize, y: usize) ?Hit {
        var i = self.hits.items.len;
        while (i != 0) {
            i -= 1;
            const hit = self.hits.items[i];
            const xx: f64 = @floatFromInt(x);
            const yy: f64 = @floatFromInt(y);
            if (xx >= hit.rect.x and xx < hit.rect.right() and yy >= hit.rect.y and yy < hit.rect.bottom()) return hit;
        }
        return null;
    }
    pub fn focusAction(self: *NotificationsList, item: *Item, reverse: bool) bool {
        if (self.hits.items.len == 0) return false;
        var index = self.keyboard_hit orelse if (reverse) 0 else self.hits.items.len - 1;
        for (0..self.hits.items.len) |_| {
            index = if (reverse) (index + self.hits.items.len - 1) % self.hits.items.len else (index + 1) % self.hits.items.len;
            const hit = self.hits.items[index];
            if (hit.item == item and hit.action != .row) {
                self.keyboard_hit = index;
                return true;
            }
        }
        return false;
    }
    pub fn focusedAction(self: *NotificationsList, item: *Item) ?Hit {
        const index = self.keyboard_hit orelse return null;
        if (index >= self.hits.items.len or self.hits.items[index].item != item) return null;
        return self.hits.items[index];
    }
    fn color(theme: ?*const ThemeColors, id: []const u8, fallback: [3]u8) u32 {
        return ui.cell.packColor(if (theme) |palette| palette.color(id, fallback) else .{ .r = fallback[0], .g = fallback[1], .b = fallback[2] });
    }
    fn draw(doc: *const ui.Document, grid: *ui.CellGrid, text: []const u8, x: usize, y: usize, paint: Paint, clip: ui.Rect) void {
        ui.paint.drawText(doc, grid, text, @floatFromInt(x), @floatFromInt(y), paint, false, clip);
    }
    fn rect(x: usize, y: usize, width: usize, height: usize) ui.Rect {
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(width), .h = @floatFromInt(height) };
    }
    pub fn textRows(item: *const Item, width: usize) usize {
        if (!item.expanded) return 1;
        var chars: usize = 0;
        for (item.message.linked_text.nodes) |node| {
            const text = if (node == .text) node.text else node.link.label;
            chars += std.unicode.utf8CountCodepoints(text) catch text.len;
        }
        const available = @max(width -| 6, 1);
        return @max(1, (chars + available - 1) / available);
    }
    pub fn rowHeight(item: *const Item, width: usize, base: usize) usize {
        return base + textRows(item, width) - 1 + @intFromBool(item.expanded and item.source != null) + @intFromBool(item.actions.primary.len != 0 or item.actions.secondary.len != 0) + @intFromBool(item.hasActiveProgress());
    }
    pub fn renderHeader(self: *NotificationsList, model: *const Model, doc: *const ui.Document, grid: *ui.CellGrid, bounds: ui.Rect, theme: ?*const ThemeColors) !void {
        const x = ui.cell.snap(bounds.x);
        const y = ui.cell.snap(bounds.y);
        const width = ui.cell.snap(bounds.w);
        if (width == 0) return;
        const paint: Paint = .{ .fg = color(theme, "notificationCenterHeader.foreground", .{ 204, 204, 204 }), .bg = color(theme, "notificationCenterHeader.background", .{ 48, 48, 48 }), .attrs = ui.cell.Attr.bold };
        grid.fillRect(bounds.x, bounds.y, bounds.w, 1, paint);
        draw(doc, grid, if (model.notifications.items.len == 0) "No new notifications" else "Notifications", x + 1, y, paint, bounds);
        if (width < 12) return;
        draw(doc, grid, "[Clear] [D] [v]", x + width -| 15, y, paint, bounds);
        try self.add(null, .clear_all, rect(x + width -| 15, y, 7, 1));
        try self.add(null, .filter, rect(x + width -| 7, y, 3, 1));
        try self.add(null, .hide, rect(x + width -| 3, y, 3, 1));
    }
    pub fn renderItem(self: *NotificationsList, item: *Item, doc: *const ui.Document, grid: *ui.CellGrid, bounds: ui.Rect, theme: ?*const ThemeColors, focused: bool) !void {
        const x = ui.cell.snap(bounds.x);
        const y = ui.cell.snap(bounds.y);
        const width = ui.cell.snap(bounds.w);
        const height = ui.cell.snap(bounds.h);
        if (width < 6 or height == 0) return;
        const fg = color(theme, "notifications.foreground", .{ 204, 204, 204 });
        const bg = if (focused) color(theme, "list.focusBackground", .{ 41, 55, 69 }) else color(theme, "notifications.background", .{ 37, 37, 38 });
        const paint: Paint = .{ .fg = fg, .bg = bg };
        grid.fillRect(bounds.x, bounds.y, bounds.w, bounds.h, paint);
        try self.add(item, .row, bounds);
        const severity_color = switch (item.severity) {
            .Error => color(theme, "notificationsErrorIcon.foreground", .{ 244, 88, 88 }),
            .Warning => color(theme, "notificationsWarningIcon.foreground", .{ 204, 167, 0 }),
            else => color(theme, "notificationsInfoIcon.foreground", .{ 55, 148, 223 }),
        };
        draw(doc, grid, switch (item.severity) {
            .Error => "!",
            .Warning => "!",
            else => "i",
        }, x + 1, y, .{ .fg = severity_color, .bg = bg, .attrs = ui.cell.Attr.bold }, bounds);
        const message_x = x + 3;
        const available = width - 6;
        const message_rows = @min(textRows(item, width), height);
        var row: usize = 0;
        var col: usize = 0;
        for (item.message.linked_text.nodes, 0..) |node, node_index| {
            const text = if (node == .text) node.text else node.link.label;
            var start: usize = 0;
            while (start < text.len and row < message_rows) {
                var end = start;
                var cells: usize = 0;
                while (end < text.len) {
                    const bytes = @min(std.unicode.utf8ByteSequenceLength(text[end]) catch 1, text.len - end);
                    const count = doc.measureText(text[end .. end + bytes]);
                    if (col + cells + count > available) break;
                    cells += count;
                    end += bytes;
                }
                if (end == start) {
                    row += 1;
                    col = 0;
                    if (row < message_rows and available == 1) start += @min(std.unicode.utf8ByteSequenceLength(text[start]) catch 1, text.len - start);
                    continue;
                }
                const is_link = node == .link;
                const link_paint: Paint = if (is_link) .{ .bg = bg, .fg = color(theme, "notificationLink.foreground", .{ 55, 148, 223 }), .attrs = ui.cell.Attr.underline } else paint;
                draw(doc, grid, text[start..end], message_x + col, y + row, link_paint, rect(message_x, y + row, available, 1));
                if (is_link) try self.add(item, .{ .link = node_index }, rect(message_x + col, y + row, cells, 1));
                start = end;
                col += cells;
                if (start < text.len) {
                    row += 1;
                    col = 0;
                }
            }
            if (row >= message_rows) break;
        }
        if (item.canCollapse()) {
            draw(doc, grid, if (item.expanded) "v" else "^", x + width - 3, y, paint, bounds);
            try self.add(item, .toggle, rect(x + width - 3, y, 1, 1));
        }
        if (!item.hasActiveProgress()) {
            draw(doc, grid, "x", x + width - 1, y, paint, bounds);
            try self.add(item, .close, rect(x + width - 1, y, 1, 1));
        }
        var next_row = y + message_rows;
        if (item.expanded) if (item.source) |source| {
            if (next_row < y + height) {
                draw(doc, grid, "Source: ", message_x, next_row, paint, bounds);
                draw(doc, grid, source, message_x + 8, next_row, paint, bounds);
                next_row += 1;
            }
        };
        if (item.hasActiveProgress() and next_row < y + height) {
            const state = item.progress_value.?.state;
            var buffer: [48]u8 = undefined;
            const text = if (state.total) |total| std.fmt.bufPrint(&buffer, "{d}/{d}", .{ state.worked orelse 0, total }) catch "Working..." else "Working...";
            draw(doc, grid, text, message_x, next_row, paint, bounds);
            next_row += 1;
        }
        if (next_row < y + height) {
            var action_x = message_x;
            for ([_][]const @import("../../../../base/common/actions.zig").IAction{ item.actions.primary, item.actions.secondary }, 0..) |actions, group| {
                for (actions, 0..) |action, index| {
                    const label = action.label();
                    const cells = doc.measureText(label) + 2;
                    if (action_x + cells > x + width) break;
                    const selected = self.keyboard_hit == self.hits.items.len;
                    const button: Paint = .{ .fg = color(theme, if (group == 0) "button.foreground" else "button.secondaryForeground", .{ 255, 255, 255 }), .bg = color(theme, if (group == 0) "button.background" else "button.secondaryBackground", .{ 14, 99, 156 }), .attrs = if (!action.enabled()) ui.cell.Attr.dim else if (selected) ui.cell.Attr.underline else 0 };
                    grid.fillRect(@floatFromInt(action_x), @floatFromInt(next_row), @floatFromInt(cells), 1, button);
                    draw(doc, grid, label, action_x + 1, next_row, button, bounds);
                    if (action.enabled()) try self.add(item, if (group == 0) .{ .primary = index } else .{ .secondary = index }, rect(action_x, next_row, cells, 1));
                    action_x += cells + 1;
                }
            }
        }
    }
};
