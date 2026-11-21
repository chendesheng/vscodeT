// Terminal Problems view. Ports the result-list rendering of
// `src/vs/workbench/contrib/markers/browser/markersView.ts` onto the terminal
// `CellGrid`. The portable row/selection state lives in
// `src/vs/workbench/contrib/markers/browser/markersView.zig`.
//
// Terminal adaptation: there is no filter widget, tree/table toggle, context
// menu, quick-fix light bulb, related-information children or file decoration
// service. The view is a flat list of file group rows and marker rows; moving
// the selection previews the marker in the editor, Enter focuses the editor.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const markers = @import("../vs/platform/markers/common/markers.zig");
const markers_view_mod = @import("../vs/workbench/contrib/markers/browser/markersView.zig");
const MarkersView = markers_view_mod.MarkersView;
const marker_service_mod = @import("../vs/platform/markers/common/markerService.zig");
const MarkerService = marker_service_mod.MarkerService;

pub const Host = struct {
    context: *anyopaque,
    preview_marker: *const fn (context: *anyopaque, marker: *const markers.Marker) anyerror!void,
    open_marker: *const fn (context: *anyopaque, marker: *const markers.Marker) anyerror!void,
    selection_changed: *const fn (context: *anyopaque) void,
    workspace_root: *const fn (context: *anyopaque) ?[]const u8,
    focus_editor: *const fn (context: *anyopaque) void,
};

pub const ProblemsView = struct {
    allocator: Allocator,
    view: *MarkersView,
    host: Host,
    listener: ?@import("../vs/base/common/event.zig").Emitter(void).ListenerId = null,

    pub fn init(allocator: Allocator, service: ?*MarkerService, host: Host) !*ProblemsView {
        const view = try allocator.create(MarkersView);
        errdefer allocator.destroy(view);
        view.* = MarkersView.init(allocator);
        errdefer view.deinit();

        const self = try allocator.create(ProblemsView);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .view = view,
            .host = host,
        };
        self.listener = try view.on_did_change.listen(self, onViewChanged);
        if (service) |value| view.setService(value);
        return self;
    }

    pub fn deinit(self: *ProblemsView) void {
        if (self.listener) |listener| self.view.on_did_change.unlisten(listener);
        self.listener = null;
        self.view.deinit();
        self.allocator.destroy(self.view);
        self.allocator.destroy(self);
    }

    pub fn setService(self: *ProblemsView, service: ?*MarkerService) void {
        self.view.setService(service);
    }

    fn onViewChanged(_: void, self: *ProblemsView) !void {
        self.host.selection_changed(self.host.context);
    }

    pub fn markerCount(self: *const ProblemsView) usize {
        return self.view.markerCount();
    }

    pub fn refresh(self: *ProblemsView) void {
        self.view.refresh() catch {};
    }

    pub fn selectedMarker(self: *const ProblemsView) ?*markers.Marker {
        return self.view.selectedMarker();
    }

    pub fn handleKey(self: *ProblemsView, event: *const ui.KeyEvent) !bool {
        switch (event.key) {
            .up => return self.move(-1),
            .down => return self.move(1),
            .page_up => return self.move(-8),
            .page_down => return self.move(8),
            .home => return self.selectEdge(0),
            .end => return self.selectEdge(self.view.markerCount() -| 1),
            .enter => {
                if (self.view.selectedMarker()) |marker| {
                    try self.host.open_marker(self.host.context, marker);
                    return true;
                }
                return false;
            },
            .escape => {
                self.host.focus_editor(self.host.context);
                return true;
            },
            else => return false,
        }
    }

    fn move(self: *ProblemsView, delta: isize) bool {
        const moved = self.view.moveSelection(delta);
        if (moved) self.previewSelection();
        return moved;
    }

    fn selectEdge(self: *ProblemsView, index: usize) bool {
        const moved = self.view.selectMarkerRow(index);
        if (moved) self.previewSelection();
        return moved;
    }

    fn previewSelection(self: *ProblemsView) void {
        if (self.view.selectedMarker()) |marker| {
            self.host.preview_marker(self.host.context, marker) catch {};
        }
    }

    /// Clicking a marker row selects and previews it. Clicking a file group row
    /// selects its first marker, matching the tree's resource-row behavior.
    pub fn handleMouse(self: *ProblemsView, event: *const ui.MouseEvent, rect: ui.Rect) !bool {
        if (event.kind == .wheel) {
            const height = ui.cell.snap(rect.h) -| 2;
            const delta: isize = if (event.delta_y > 0) 3 else if (event.delta_y < 0) -3 else 0;
            self.view.scrollBy(delta, height);
            return true;
        }
        if (event.kind != .down and event.kind != .click) return false;
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (event.x < x or event.x >= x + width) return false;
        if (event.y < y or event.y >= y + height) return false;
        const list_top = y + 2;
        const list_height = height -| 2;
        if (event.y < list_top) return false;
        const visible_index = event.y - list_top;
        if (visible_index >= list_height) return false;
        self.view.updateScroll(list_height);
        const row_index = self.view.scroll + visible_index;
        if (row_index >= self.view.rowCount()) return false;
        const row = self.view.rowsSlice()[row_index];
        const marker_index = switch (row.kind) {
            .marker => self.markerIndexForRow(row_index) orelse return false,
            .resource => self.firstMarkerForResource(row.resource.key) orelse return false,
        };
        if (!self.view.selectMarkerRow(marker_index)) return false;
        self.previewSelection();
        return true;
    }

    fn markerIndexForRow(self: *const ProblemsView, row_index: usize) ?usize {
        for (self.view.markerRows(), 0..) |row, index| {
            if (row.row_index == row_index) return index;
        }
        return null;
    }

    fn firstMarkerForResource(self: *const ProblemsView, key: []const u8) ?usize {
        for (self.view.markerRows(), 0..) |row, index| {
            if (std.mem.eql(u8, row.resource.key, key)) return index;
        }
        return null;
    }

    pub fn render(self: *ProblemsView, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) !void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;

        const background = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(.{ .r = 190, .g = 190, .b = 190 }),
            .bg = ui.cell.packColor(.{ .r = 30, .g = 30, .b = 33 }),
        };
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), background);

        const header_style = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(.{ .r = 220, .g = 220, .b = 220 }),
            .attrs = if (focused) ui.cell.Attr.bold else 0,
        };
        drawText(grid, x + 1, y, width -| 2, "PROBLEMS", header_style);

        var count_buf: [64]u8 = undefined;
        var count_len: usize = 0;
        const base_counts = std.fmt.bufPrint(&count_buf, "\u{2716} {d}  \u{26A0} {d}", .{
            self.view.counts.errors,
            self.view.counts.warnings,
        }) catch "";
        count_len = base_counts.len;
        if (self.view.counts.infos > 0) {
            const info = std.fmt.bufPrint(count_buf[count_len..], "  \u{2139} {d}", .{self.view.counts.infos}) catch "";
            count_len += info.len;
        }
        const counts = count_buf[0..count_len];
        if (counts.len > 0 and width > counts.len + 1) {
            const count_style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(.{ .r = 170, .g = 170, .b = 170 }),
                .bg = background.bg,
            };
            drawText(grid, x + width -| counts.len -| 1, y, counts.len, counts, count_style);
        }

        if (height > 1) {
            const divider_style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(.{ .r = 70, .g = 70, .b = 70 }),
            };
            var divider: usize = 0;
            while (divider < width) : (divider += 1) {
                grid.putCodepoint(x + divider, y + 1, '\u{2500}', 1, divider_style);
            }
        }

        const list_top = y + 2;
        const list_height = height -| 2;
        if (self.view.markerCount() == 0) {
            const empty_style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(.{ .r = 150, .g = 150, .b = 150 }),
                .bg = background.bg,
            };
            drawText(grid, x + 1, list_top, width -| 2, "No problems detected", empty_style);
            return;
        }
        self.view.updateScroll(list_height);
        const root = self.host.workspace_root(self.host.context);
        var row: usize = 0;
        while (row < list_height) : (row += 1) {
            const source = self.view.scroll + row;
            if (source >= self.view.rowCount()) break;
            const entry = self.view.rowsSlice()[source];
            var style = background;
            if (entry.kind == .marker and entry.marker == self.view.selectedMarker()) {
                style.bg = ui.cell.packColor(.{ .r = if (focused) 38 else 32, .g = if (focused) 79 else 34, .b = if (focused) 120 else 40 });
                style.fg = ui.cell.packColor(.{ .r = 240, .g = 240, .b = 240 });
            }
            switch (entry.kind) {
                .resource => {
                    var label_buf: [1024]u8 = undefined;
                    const label = std.fmt.bufPrint(&label_buf, "{s} ({d})", .{
                        relativeLabel(entry.resource.path, root),
                        entry.resource.total(),
                    }) catch entry.resource.path;
                    var resource_style = style;
                    resource_style.fg = ui.cell.packColor(.{ .r = 200, .g = 200, .b = 200 });
                    resource_style.attrs |= ui.cell.Attr.bold;
                    drawText(grid, x + 1, list_top + row, width -| 2, label, resource_style);
                },
                .marker => {
                    const marker = entry.marker.?;
                    const indent = 3;
                    var glyph_buf = [4]u8{ 0, 0, 0, 0 };
                    const glyph = severityGlyph(marker.severity);
                    @memcpy(glyph_buf[0..glyph.len], glyph);
                    const glyph_style = ui.cell.PaintStyle{
                        .fg = ui.cell.packColor(severityColor(marker.severity)),
                        .bg = style.bg,
                    };
                    drawText(grid, x + indent -| 1, list_top + row, 2, glyph_buf[0..glyph.len], glyph_style);

                    var line_buf: [32]u8 = undefined;
                    const position = std.fmt.bufPrint(&line_buf, "{d}:{d}", .{
                        marker.start_line_number,
                        marker.start_column,
                    }) catch "";
                    var message_buf: [1024]u8 = undefined;
                    const message = if (marker.source) |source_name|
                        std.fmt.bufPrint(&message_buf, "{s}  {s}  ({s})", .{ position, marker.message, source_name }) catch marker.message
                    else
                        std.fmt.bufPrint(&message_buf, "{s}  {s}", .{ position, marker.message }) catch marker.message;
                    drawText(grid, x + indent + 1, list_top + row, width -| indent -| 1, message, style);
                },
            }
        }

        if (self.view.rowCount() > list_height and list_height > 0) {
            const thumb = self.view.scrollbarThumb(list_height);
            const column = x + width -| 1;
            var index: usize = 0;
            while (index < list_height) : (index += 1) {
                const style = ui.cell.PaintStyle{
                    .fg = ui.cell.packColor(.{ .r = 108, .g = 108, .b = 108 }),
                };
                const glyph: u21 = if (index >= thumb.start and index < thumb.start + thumb.length) '\u{2588}' else '\u{2502}';
                grid.putCodepoint(column, list_top + index, glyph, 1, style);
            }
        }
    }
};

fn severityGlyph(severity: u32) []const u8 {
    return switch (severity) {
        markers.MarkerSeverity.Error => "\u{2716}",
        markers.MarkerSeverity.Warning => "\u{26A0}",
        markers.MarkerSeverity.Info => "\u{2139}",
        else => "\u{00B7}",
    };
}

fn severityColor(severity: u32) ui.Color {
    return switch (severity) {
        markers.MarkerSeverity.Error => .{ .r = 241, .g = 76, .b = 76 },
        markers.MarkerSeverity.Warning => .{ .r = 204, .g = 167, .b = 0 },
        markers.MarkerSeverity.Info => .{ .r = 55, .g = 148, .b = 255 },
        else => .{ .r = 138, .g = 138, .b = 138 },
    };
}

fn relativeLabel(path: []const u8, root: ?[]const u8) []const u8 {
    const base = root orelse return path;
    const trimmed = std.mem.trimEnd(u8, base, "/\\");
    if (trimmed.len == 0) return path;
    if (path.len <= trimmed.len + 1) return path;
    if (!std.mem.startsWith(u8, path, trimmed)) return path;
    if (path[trimmed.len] != '/' and path[trimmed.len] != '\\') return path;
    return path[trimmed.len + 1 ..];
}

fn drawText(grid: *ui.CellGrid, x: usize, y: usize, width: usize, text: []const u8, style: ui.cell.PaintStyle) void {
    if (width == 0) return;
    var column: usize = 0;
    var index: usize = 0;
    while (index < text.len and column < width) {
        const decoded = ui.dom.decodeAt(text, index);
        if (decoded.len == 0) break;
        const cell_width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (cell_width == 0) {
            index += decoded.len;
            continue;
        }
        if (column + cell_width > width) break;
        grid.putCodepoint(x + column, y, decoded.cp, cell_width, style);
        column += cell_width;
        index += decoded.len;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestHost = struct {
    previews: usize = 0,
    opens: usize = 0,
    changes: usize = 0,
    focused: usize = 0,

    fn preview(context: *anyopaque, _: *const markers.Marker) anyerror!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.previews += 1;
    }
    fn open(context: *anyopaque, _: *const markers.Marker) anyerror!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.opens += 1;
    }
    fn changed(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.changes += 1;
    }
    fn root(_: *anyopaque) ?[]const u8 {
        return "/repo";
    }
    fn focus(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.focused += 1;
    }
};

test "problemsView: empty state and list rendering" {
    const allocator = testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    var host = TestHost{};
    const view = try ProblemsView.init(allocator, &service, .{
        .context = &host,
        .preview_marker = TestHost.preview,
        .open_marker = TestHost.open,
        .selection_changed = TestHost.changed,
        .workspace_root = TestHost.root,
        .focus_editor = TestHost.focus,
    });
    defer view.deinit();

    var grid = try ui.CellGrid.init(allocator, 40, 10);
    defer grid.deinit();
    try view.render(&grid, .{ .x = 0, .y = 0, .w = 40, .h = 10 }, true);
    const empty = try grid.rowText(allocator, 2);
    defer allocator.free(empty);
    try testing.expect(std.mem.indexOf(u8, empty, "No problems") != null);

    const resource = markers.Resource{ .scheme = "file", .path = "/repo/a.zig" };
    try service.changeOne("owner", resource, &.{
        .{ .severity = markers.MarkerSeverity.Error, .message = "broken", .start_line_number = 3, .start_column = 1 },
    }, null);
    try view.render(&grid, .{ .x = 0, .y = 0, .w = 40, .h = 10 }, true);
    const header = try grid.rowText(allocator, 0);
    defer allocator.free(header);
    try testing.expect(std.mem.indexOf(u8, header, "PROBLEMS") != null);
    const file_row = try grid.rowText(allocator, 2);
    defer allocator.free(file_row);
    try testing.expect(std.mem.indexOf(u8, file_row, "a.zig") != null);
    const marker_row = try grid.rowText(allocator, 3);
    defer allocator.free(marker_row);
    try testing.expect(std.mem.indexOf(u8, marker_row, "3:1") != null);
    try testing.expect(std.mem.indexOf(u8, marker_row, "broken") != null);
}

test "problemsView: selection previews, enter opens and escape focuses editor" {
    const allocator = testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = markers.Resource{ .scheme = "file", .path = "/repo/a.zig" };
    try service.changeOne("owner", resource, &.{
        .{ .severity = markers.MarkerSeverity.Error, .message = "one", .start_line_number = 1 },
        .{ .severity = markers.MarkerSeverity.Warning, .message = "two", .start_line_number = 2 },
    }, null);

    var host = TestHost{};
    const view = try ProblemsView.init(allocator, &service, .{
        .context = &host,
        .preview_marker = TestHost.preview,
        .open_marker = TestHost.open,
        .selection_changed = TestHost.changed,
        .workspace_root = TestHost.root,
        .focus_editor = TestHost.focus,
    });
    defer view.deinit();

    const down = ui.KeyEvent{ .key = .down };
    try testing.expect(try view.handleKey(&down));
    try testing.expectEqual(@as(usize, 1), host.previews);
    try testing.expectEqualStrings("two", view.selectedMarker().?.message);

    const enter = ui.KeyEvent{ .key = .enter };
    try testing.expect(try view.handleKey(&enter));
    try testing.expectEqual(@as(usize, 1), host.opens);

    const escape = ui.KeyEvent{ .key = .escape };
    try testing.expect(try view.handleKey(&escape));
    try testing.expectEqual(@as(usize, 1), host.focused);

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 40, .h = 10 };
    const click = ui.MouseEvent{ .kind = .down, .x = 4, .y = 3, .button = .left };
    try testing.expect(try view.handleMouse(&click, rect));
    try testing.expectEqual(@as(usize, 2), host.previews);
}
