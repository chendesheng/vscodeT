// Terminal adaptation of `src/vs/workbench/contrib/output/browser/outputView.ts`.
// Retains a single read-only, file-backed model and paints its visible lines.
// The native panel substitutes cell rendering for a browser editor; filters,
// full editor-backed selection/link behavior and the channel dropdown remain
// portable gaps. Left/right select adjacent channels, vertical keys scroll.
const std = @import("std");
const ui = @import("ui");
const output = @import("../../../services/output/common/output.zig");
const OutputService = @import("outputServices.zig").OutputService;
const views_mod = @import("../../../services/views/common/viewsService.zig");
const Layout = @import("../../../services/layout/browser/layoutService.zig");
const PaneCompositePart = @import("../../../browser/parts/paneCompositePart.zig");
const ThemeColors = @import("../../../browser/themeColors.zig").ThemeColors;

pub const OutputViewPane = struct {
    pub const ID = output.OUTPUT_VIEW_ID;
    service: *OutputService,
    views: views_mod.IViewsService,
    pane: *PaneCompositePart.PaneCompositePart,
    layout: Layout.IWorkbenchLayoutService,
    host: struct { context: *anyopaque, changed: *const fn (*anyopaque) void },
    scroll: usize = 0,
    page_rows: usize = 1,
    model_listener: ?usize = null,
    active_listener: ?usize = null,
    open_listener: ?usize = null,
    close_listener: ?usize = null,
    visibility_listener: ?usize = null,

    pub fn attach(self: *OutputViewPane) !void {
        self.model_listener = try self.service.on_did_change.listen(self, onChanged);
        self.active_listener = try self.service.on_active_output_channel.listen(self, onActiveChanged);
        self.open_listener = try self.pane.on_did_pane_composite_open.listen(self, onPanelOpened);
        self.close_listener = try self.pane.on_did_pane_composite_close.listen(self, onPanelClosed);
        self.visibility_listener = try self.layout.on_did_change_part_visibility.listen(self, onPartVisibilityChanged);
        self.updateVisibility();
    }

    pub fn deinit(self: *OutputViewPane) void {
        if (self.model_listener) |id| self.service.on_did_change.unlisten(id);
        if (self.active_listener) |id| self.service.on_active_output_channel.unlisten(id);
        if (self.open_listener) |id| self.pane.on_did_pane_composite_open.unlisten(id);
        if (self.close_listener) |id| self.pane.on_did_pane_composite_close.unlisten(id);
        if (self.visibility_listener) |id| self.layout.on_did_change_part_visibility.unlisten(id);
        self.service.setVisible(false);
    }

    fn onChanged(_: void, self: *OutputViewPane) !void {
        self.host.changed(self.host.context);
    }
    fn onActiveChanged(_: void, self: *OutputViewPane) !void {
        self.scroll = 0;
        self.host.changed(self.host.context);
    }
    fn onPanelOpened(_: PaneCompositePart.OpenEvent, self: *OutputViewPane) !void {
        self.updateVisibility();
    }
    fn onPanelClosed(_: []const u8, self: *OutputViewPane) !void {
        self.updateVisibility();
    }
    fn onPartVisibilityChanged(event: Layout.IPartVisibilityChangeEvent, self: *OutputViewPane) !void {
        if (event.part_id == .panel) self.updateVisibility();
    }
    fn updateVisibility(self: *OutputViewPane) void {
        self.service.setVisible(self.views.isViewVisible(ID));
    }

    pub fn handleKey(self: *OutputViewPane, event: *const ui.KeyEvent) !bool {
        switch (event.key) {
            .up => self.scroll +|= 1,
            .down => self.scroll -|= 1,
            .page_up => self.scroll +|= self.page_rows,
            .page_down => self.scroll -|= self.page_rows,
            .home => self.scroll = std.math.maxInt(usize),
            .end => self.scroll = 0,
            .left => try self.service.cycleChannels(true),
            .right => try self.service.cycleChannels(false),
            else => return false,
        }
        self.host.changed(self.host.context);
        return true;
    }

    pub fn scrollBy(self: *OutputViewPane, lines: isize) void {
        if (lines > 0) self.scroll +|= @intCast(lines) else self.scroll -|= @intCast(-lines);
        self.host.changed(self.host.context);
    }

    pub fn render(self: *OutputViewPane, grid: *ui.CellGrid, rect: ui.Rect, focused: bool, theme: ?*const ThemeColors) void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;
        const fg = if (theme) |p| p.colorOr("editor.foreground", .{ .r = 210, .g = 210, .b = 210 }) else ui.Color{ .r = 210, .g = 210, .b = 210 };
        const bg = if (theme) |p| p.colorOr("panel.background", .{ .r = 30, .g = 30, .b = 33 }) else ui.Color{ .r = 30, .g = 30, .b = 33 };
        const style = ui.cell.PaintStyle{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), style);
        const active = self.service.active orelse {
            drawText(grid, x, y, width, "No output channels", style);
            return;
        };
        var title_style = style;
        if (focused) title_style.attrs |= ui.cell.Attr.bold;
        drawText(grid, x, y, width, active.descriptor.label, title_style);
        if (height <= 1) return;
        self.page_rows = height - 1;
        const text = active.model.content;
        const count = std.mem.count(u8, text, "\n") + 1;
        const max_scroll = count -| self.page_rows;
        self.scroll = @min(self.scroll, max_scroll);
        const first = max_scroll - self.scroll;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var index: usize = 0;
        while (lines.next()) |line| : (index += 1) {
            if (index < first) continue;
            const row = index - first;
            if (row >= self.page_rows) break;
            drawText(grid, x, y + 1 + row, width, std.mem.trimEnd(u8, line, "\r"), style);
        }
    }
};

fn drawText(grid: *ui.CellGrid, x: usize, y: usize, width: usize, text: []const u8, style: ui.cell.PaintStyle) void {
    var column: usize = 0;
    var index: usize = 0;
    while (index < text.len and column < width) {
        const decoded = ui.dom.decodeAt(text, index);
        if (decoded.len == 0) break;
        index += decoded.len;
        if (decoded.cp < 32 or decoded.cp == 127) continue;
        const cell_width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (cell_width == 0 or column + cell_width > width) continue;
        grid.putCodepoint(x + column, y, decoded.cp, cell_width, style);
        column += cell_width;
    }
}
