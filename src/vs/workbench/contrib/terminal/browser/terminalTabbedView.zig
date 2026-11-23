// Port of terminalTabbedView.ts. Its horizontal SplitView is measured in
// cells. The enclosing PanelPart supplies the view title and terminal toolbar.

const std = @import("std");
const ui = @import("ui");
const ThemeColors = @import("../../../browser/themeColors.zig").ThemeColors;
const panel_part = @import("../../../browser/parts/panel/panelPart.zig");
const TerminalService = @import("./terminalService.zig").TerminalService;
const Config = @import("../common/terminalConfiguration.zig").Config;
const tabs = @import("./terminalTabsList.zig");
const terminal_view = @import("./terminalRenderer.zig");

pub const TerminalTabbedView = struct {
    tab_list: tabs.TerminalTabList = .{},
    width_storage_path: ?[]u8 = null,

    pub fn setProfileStorage(self: *TerminalTabbedView, allocator: std.mem.Allocator, io: std.Io, user_data_dir: []const u8) !void {
        const path = try std.fs.path.join(allocator, &.{ user_data_dir, "User", "globalStorage", "tabs-list-width-horizontal" });
        if (self.width_storage_path) |old| allocator.free(old);
        self.width_storage_path = path;
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
        defer file.close(io);
        var buffer: [32]u8 = undefined;
        const len = file.readPositionalAll(io, &buffer, 0) catch return;
        const width = std.fmt.parseUnsigned(usize, std.mem.trim(u8, buffer[0..len], " \r\n"), 10) catch return;
        if (width > 0) self.tab_list.resize(width);
    }

    pub fn storeListWidth(self: *const TerminalTabbedView, io: std.Io) !void {
        const path = self.width_storage_path orelse return;
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |directory| try cwd.createDirPath(io, directory);
        var buffer: [32]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buffer, "{d}\n", .{self.tab_list.width});
        var atomic = try cwd.createFileAtomic(io, path, .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, bytes);
        try atomic.replace(io);
    }

    pub fn deinit(self: *TerminalTabbedView, allocator: std.mem.Allocator) void {
        if (self.width_storage_path) |path| allocator.free(path);
    }

    pub fn shouldShowTabs(config: Config, instances: usize, groups: usize) bool {
        if (!config.tabs_enabled) return false;
        return switch (config.tabs_hide_condition) {
            .never => true,
            .singleTerminal => instances > 1,
            .singleGroup => groups > 1,
        };
    }

    pub fn layout(self: *const TerminalTabbedView, rect: ui.Rect, config: Config, instances: usize, groups: usize) Layout {
        var result: Layout = .{ .terminal = panel_part.contentRect(rect) };
        const width = ui.cell.snap(result.terminal.w);
        if (width < tabs.narrow_view_width + 2 or !shouldShowTabs(config, instances, groups)) return result;
        const list_width = @min(self.tab_list.width, width - tabs.narrow_view_width - 1);
        const cells: f64 = @floatFromInt(list_width);
        result.tabs = result.terminal;
        result.tabs.w = cells;
        result.terminal.w -= cells + 1;
        if (config.tabs_location == .left) {
            result.terminal.x += cells + 1;
        } else {
            result.tabs.x += result.terminal.w + 1;
        }
        result.sash_x = if (config.tabs_location == .left)
            ui.cell.snap(result.tabs.x + result.tabs.w)
        else
            ui.cell.snap(result.tabs.x) - 1;
        return result;
    }

    pub fn layoutForService(self: *const TerminalTabbedView, rect: ui.Rect, service: *const TerminalService) Layout {
        const config = Config.load(service.options.configuration);
        return self.layout(rect, config, service.count(), service.group.groupCount());
    }

    pub fn render(self: *const TerminalTabbedView, grid: *ui.CellGrid, service: *TerminalService, rect: ui.Rect, title_end: usize, palette: ?*const ThemeColors) !void {
        const l = self.layoutForService(rect, service);
        const panel_bg = tabs.color(palette, "panel.background", .{ 30, 30, 33 });
        const terminal_bg = if (palette) |colors| colors.colorOr("terminal.background", panel_bg) else panel_bg;
        grid.fillRect(l.terminal.x, l.terminal.y, l.terminal.w, l.terminal.h, .{ .bg = ui.cell.packColor(terminal_bg) });
        if (service.active() != null) {
            const group = service.group.groupRange(service.group.active);
            for (group.first..group.end) |index| {
                const pane = service.group.paneRect(l.terminal, index);
                if (pane.w > 0 and pane.h > 0) {
                    try terminal_view.paint(&service.at(index).?.emulator, grid, pane);
                }
                if (index > group.first) {
                    const previous = service.group.paneRect(l.terminal, index - 1);
                    if (pane.x > previous.x + previous.w) {
                        renderDivider(grid, ui.cell.snap(pane.x) - 1, pane, terminal_bg, palette);
                    }
                }
            }
        }
        if (l.sash_x) |sash| {
            grid.fillRect(l.tabs.x, l.tabs.y, l.tabs.w, l.tabs.h, .{ .bg = ui.cell.packColor(panel_bg) });
            self.tab_list.render(grid, service, l.tabs, palette);
            renderDivider(grid, sash, l.tabs, panel_bg, palette);
        }
        self.renderToolbar(grid, service, rect, l, title_end, palette);
    }

    fn renderToolbar(self: *const TerminalTabbedView, grid: *ui.CellGrid, service: *const TerminalService, rect: ui.Rect, l: Layout, title_end: usize, palette: ?*const ThemeColors) void {
        const config = Config.load(service.options.configuration);
        const t = self.toolbar(rect, l, title_end, config, service.count()) orelse return;
        const foreground = tabs.color(palette, "foreground", .{ 204, 204, 204 });
        const background = tabs.color(palette, "panel.background", .{ 30, 30, 33 });
        const style: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(foreground), .bg = ui.cell.packColor(background) };
        const y = ui.cell.snap(rect.y);
        if (t.terminal_picker) |x| {
            if (service.active()) |instance| {
                _ = tabs.drawText(grid, x, y, 1, tabs.terminal_icon, style);
                _ = tabs.drawText(grid, x + 2, y, t.new_terminal - x - 4, instance.displayTitle(), style);
                _ = tabs.drawText(grid, t.new_terminal - 2, y, 1, "⌄", style);
            }
        }
        _ = tabs.drawText(grid, t.new_terminal, y, 1, "+", style);
        _ = tabs.drawText(grid, t.new_terminal + 1, y, 1, "⌄", style);
        if (t.split) |x| {
            _ = tabs.drawText(grid, x, y, 1, tabs.split_icon, style);
            _ = tabs.drawText(grid, x + 2, y, 1, tabs.kill_icon, style);
        }
    }

    pub fn hitTest(self: *const TerminalTabbedView, service: *const TerminalService, rect: ui.Rect, title_end: usize, x: usize, y: usize) Hit {
        const l = self.layoutForService(rect, service);
        if (y == ui.cell.snap(rect.y)) {
            if (self.toolbar(rect, l, title_end, Config.load(service.options.configuration), service.count())) |t| {
                if (x == t.new_terminal) return .new_terminal;
                if (x == t.new_terminal + 1) return .profiles;
                if (t.split) |split| {
                    if (x == split) return .{ .split = service.group.active };
                    if (x == split + 2) return .{ .kill = service.group.active };
                }
                if (t.terminal_picker) |start| {
                    if (x >= start and x < t.new_terminal) return .terminal_picker;
                }
            }
            return .none;
        }
        if (l.sash_x == x and y >= ui.cell.snap(l.tabs.y) and y < ui.cell.snap(l.tabs.y + l.tabs.h)) return .sash;
        if (contains(l.tabs, x, y)) {
            const first = @min(self.tab_list.first_visible, service.count() -| ui.cell.snap(l.tabs.h));
            const index = first + y - ui.cell.snap(l.tabs.y);
            if (index >= service.count()) return .empty_tabs;
            const width = ui.cell.snap(l.tabs.w);
            if (tabs.TerminalTabList.hasActionBar(width)) {
                const end = ui.cell.snap(l.tabs.x) + width;
                if (x == end - 4) return .{ .split = index };
                if (x == end - 2) return .{ .kill = index };
            }
            return .{ .tab = index };
        }
        if (contains(l.terminal, x, y) and service.active() != null) {
            const group = service.group.groupRange(service.group.active);
            for (group.first..group.end) |index| {
                const pane = service.group.paneRect(l.terminal, index);
                if (index > group.first and x + 1 == ui.cell.snap(pane.x)) return .{ .pane_sash = index };
                if (contains(pane, x, y)) return .{ .content = .{ .index = index, .rect = pane } };
            }
        }
        return .none;
    }

    fn toolbar(_: *const TerminalTabbedView, rect: ui.Rect, l: Layout, title_end: usize, config: Config, count: usize) ?Toolbar {
        // Reserve a gutter between panel titles and the terminal actions.
        const end = ui.cell.snap(rect.right()) -| 1;
        const start = title_end + 1;
        if (end -| start < 3 or ui.cell.snap(rect.h) == 0) return null;
        const narrow = l.sash_x != null and ui.cell.snap(l.tabs.w) < tabs.midpoint_view_width;
        const show_actions = end - start >= 7 and count > 0 and show(config.tabs_show_actions, count, narrow);
        const new_terminal = end - if (show_actions) @as(usize, 7) else 3;
        const show_active = count > 0 and (show(config.tabs_show_active_terminal, count, narrow) or !config.tabs_enabled);
        const picker_width = @min(16, new_terminal - start);
        return .{
            .new_terminal = new_terminal,
            .split = if (show_actions) end - 3 else null,
            .terminal_picker = if (show_active and picker_width >= 5) new_terminal - picker_width else null,
        };
    }
};

pub const Layout = struct { terminal: ui.Rect, tabs: ui.Rect = .{}, sash_x: ?usize = null };
const Toolbar = struct { new_terminal: usize, split: ?usize, terminal_picker: ?usize };
pub const Hit = union(enum) {
    none,
    tab: usize,
    new_terminal,
    profiles,
    terminal_picker,
    split: usize,
    kill: usize,
    sash,
    pane_sash: usize,
    empty_tabs,
    content: struct { index: usize, rect: ui.Rect },
};

fn show(setting: Config.Show, count: usize, narrow: bool) bool {
    return switch (setting) {
        .always => true,
        .singleTerminal => count == 1,
        .singleTerminalOrNarrow => count == 1 or narrow,
        .never => false,
    };
}

pub fn contains(rect: ui.Rect, x: usize, y: usize) bool {
    const left = ui.cell.snap(rect.x);
    const top = ui.cell.snap(rect.y);
    return x >= left and x - left < ui.cell.snap(rect.w) and y >= top and y - top < ui.cell.snap(rect.h);
}

fn renderDivider(grid: *ui.CellGrid, x: usize, rect: ui.Rect, background: ui.Color, palette: ?*const ThemeColors) void {
    const foreground = tabs.color(palette, "terminal.border", .{ 69, 69, 69 });
    const style: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(foreground), .bg = ui.cell.packColor(background) };
    const y = ui.cell.snap(rect.y);
    for (y..y + ui.cell.snap(rect.h)) |row| grid.putCodepoint(x, row, '│', 1, style);
}
