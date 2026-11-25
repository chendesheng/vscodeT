// Port of the main-window Problems list in
// `src/vs/workbench/contrib/markers/browser/markersView.ts`.
// The terminal paints resource and marker rows into the panel's cell grid.
// Keyboard and mouse selection, preview, opening, and scrolling use that list.
// The filter widget, table/tree switcher, quick fixes, related-information
// children and persisted widget state are still unported.

const std = @import("std");
const ui = @import("ui");
const Allocator = std.mem.Allocator;
const markers = @import("../../../../platform/markers/common/markers.zig");
const marker_service_mod = @import("../../../../platform/markers/common/markerService.zig");
const MarkerService = marker_service_mod.MarkerService;
const MarkerChangeEvent = marker_service_mod.MarkerChangeEvent;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const model_mod = @import("./markersModel.zig");
const MarkersModel = model_mod.MarkersModel;
const ResourceMarkers = model_mod.ResourceMarkers;

pub const RowKind = enum { resource, marker };

pub const Row = struct {
    kind: RowKind,
    resource: *ResourceMarkers,
    marker: ?*markers.Marker = null,
    depth: usize = 0,
};

pub const MarkerRow = struct {
    resource: *ResourceMarkers,
    marker: *markers.Marker,
    row_index: usize,
};

pub const Counts = struct {
    errors: usize = 0,
    warnings: usize = 0,
    infos: usize = 0,
};

const Fingerprint = struct {
    key: []u8,
    line: u32,
    column: u32,
    message: []u8,

    fn deinit(self: *Fingerprint, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.message);
    }
};

pub const Host = struct {
    context: *anyopaque,
    open_editor: *const fn (context: *anyopaque, marker: *const markers.Marker, preserve_focus: bool, pinned: bool) anyerror!void,
    selection_changed: *const fn (context: *anyopaque) void,
    workspace_root: *const fn (context: *anyopaque) ?[]const u8,
    focus_editor: *const fn (context: *anyopaque) void,
};

pub const MarkersView = struct {
    host: ?Host = null,
    allocator: Allocator,
    service: ?*MarkerService = null,
    model: MarkersModel,
    rows: std.array_list.Managed(Row),
    marker_rows: std.array_list.Managed(MarkerRow),
    selection: usize = 0,
    scroll: usize = 0,
    counts: Counts = .{},
    on_did_change: Emitter(void),
    listener: ?Emitter(MarkerChangeEvent).ListenerId = null,

    pub fn init(allocator: Allocator) MarkersView {
        return .{
            .allocator = allocator,
            .model = MarkersModel.init(allocator),
            .rows = std.array_list.Managed(Row).init(allocator),
            .marker_rows = std.array_list.Managed(MarkerRow).init(allocator),
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    /// Connect a mounted view after its owner has given it a stable address.
    pub fn attach(self: *MarkersView, service: ?*MarkerService, host: Host) !void {
        if (self.host == null) {
            _ = try self.on_did_change.listen(self, struct {
                fn changed(_: void, view: *MarkersView) !void {
                    const bindings = view.host orelse return;
                    bindings.selection_changed(bindings.context);
                }
            }.changed);
        }
        self.host = host;
        self.setService(service);
    }

    pub fn deinit(self: *MarkersView) void {
        self.unlisten();
        self.on_did_change.deinit();
        self.rows.deinit();
        self.marker_rows.deinit();
        self.model.deinit();
        self.* = undefined;
    }

    fn unlisten(self: *MarkersView) void {
        if (self.listener) |listener| {
            if (self.service) |service| service.on_marker_changed.unlisten(listener);
            self.listener = null;
        }
    }

    pub fn setService(self: *MarkersView, service: ?*MarkerService) void {
        if (self.service == service) {
            self.refresh() catch {};
            return;
        }
        self.unlisten();
        self.service = service;
        if (service) |value| {
            self.listener = value.on_marker_changed.listen(self, onMarkerChanged) catch null;
        }
        self.refresh() catch {};
    }

    fn onMarkerChanged(_: MarkerChangeEvent, self: *MarkersView) !void {
        self.refresh() catch {};
    }

    pub fn refresh(self: *MarkersView) !void {
        var fingerprint = self.captureSelection();
        defer if (fingerprint) |*value| value.deinit(self.allocator);

        // Rows borrow marker records from the service. Clear them before the
        // model rebuild: on an allocation failure the rows would otherwise
        // keep pointers to markers the service retires when this event ends.
        self.rows.clearRetainingCapacity();
        self.marker_rows.clearRetainingCapacity();

        if (self.service) |service| {
            try self.model.refresh(service);
        } else {
            self.model.reset();
        }
        try self.rebuildRows();
        self.restoreSelection(fingerprint);
        self.clampSelection();
        try self.on_did_change.fire({});
    }

    fn rebuildRows(self: *MarkersView) !void {
        self.rows.clearRetainingCapacity();
        self.marker_rows.clearRetainingCapacity();
        self.counts = .{};

        for (self.model.resourceMarkers()) |group| {
            try self.rows.append(.{
                .kind = .resource,
                .resource = group,
                .depth = 0,
            });
            for (group.markers.items) |marker| {
                switch (marker.severity) {
                    markers.MarkerSeverity.Error => self.counts.errors += 1,
                    markers.MarkerSeverity.Warning => self.counts.warnings += 1,
                    markers.MarkerSeverity.Info => self.counts.infos += 1,
                    else => {},
                }
                const row_index = self.rows.items.len;
                try self.marker_rows.append(.{
                    .resource = group,
                    .marker = marker,
                    .row_index = row_index,
                });
                try self.rows.append(.{
                    .kind = .marker,
                    .resource = group,
                    .marker = marker,
                    .depth = 1,
                });
            }
        }
    }

    fn captureSelection(self: *MarkersView) ?Fingerprint {
        const selected = self.selectedMarker() orelse return null;
        const key = self.selectedResourceKey() orelse return null;
        const key_copy = self.allocator.dupe(u8, key) catch return null;
        const message_copy = self.allocator.dupe(u8, selected.message) catch {
            self.allocator.free(key_copy);
            return null;
        };
        return .{
            .key = key_copy,
            .line = selected.start_line_number,
            .column = selected.start_column,
            .message = message_copy,
        };
    }

    fn restoreSelection(self: *MarkersView, fingerprint: ?Fingerprint) void {
        if (fingerprint) |wanted| {
            for (self.marker_rows.items, 0..) |row, index| {
                if (!std.mem.eql(u8, row.resource.key, wanted.key)) continue;
                if (row.marker.start_line_number != wanted.line) continue;
                if (row.marker.start_column != wanted.column) continue;
                if (!std.mem.eql(u8, row.marker.message, wanted.message)) continue;
                self.selection = index;
                return;
            }
        }
        if (self.marker_rows.items.len == 0) {
            self.selection = 0;
        } else if (self.selection >= self.marker_rows.items.len) {
            self.selection = self.marker_rows.items.len - 1;
        }
    }

    fn clampSelection(self: *MarkersView) void {
        if (self.marker_rows.items.len == 0) {
            self.selection = 0;
            self.scroll = 0;
            return;
        }
        if (self.selection >= self.marker_rows.items.len) {
            self.selection = self.marker_rows.items.len - 1;
        }
    }

    pub fn markerCount(self: *const MarkersView) usize {
        return self.marker_rows.items.len;
    }

    pub fn rowCount(self: *const MarkersView) usize {
        return self.rows.items.len;
    }

    pub fn resourceCount(self: *const MarkersView) usize {
        return self.model.resourceMarkers().len;
    }

    pub fn rowsSlice(self: *const MarkersView) []const Row {
        return self.rows.items;
    }

    pub fn markerRows(self: *const MarkersView) []const MarkerRow {
        return self.marker_rows.items;
    }

    pub fn selectedMarker(self: *const MarkersView) ?*markers.Marker {
        if (self.marker_rows.items.len == 0) return null;
        if (self.selection >= self.marker_rows.items.len) return null;
        return self.marker_rows.items[self.selection].marker;
    }

    pub fn selectedResource(self: *const MarkersView) ?*ResourceMarkers {
        if (self.marker_rows.items.len == 0) return null;
        if (self.selection >= self.marker_rows.items.len) return null;
        return self.marker_rows.items[self.selection].resource;
    }

    fn selectedResourceKey(self: *const MarkersView) ?[]const u8 {
        const group = self.selectedResource() orelse return null;
        return group.key;
    }

    pub fn moveSelection(self: *MarkersView, delta: isize) bool {
        if (self.marker_rows.items.len == 0) return false;
        const count: isize = @intCast(self.marker_rows.items.len);
        var next: isize = @as(isize, @intCast(self.selection)) + delta;
        if (next < 0) next = 0;
        if (next >= count) next = count - 1;
        if (next == self.selection) return false;
        self.selection = @intCast(next);
        self.on_did_change.fire({}) catch {};
        return true;
    }

    pub fn selectMarkerRow(self: *MarkersView, index: usize) bool {
        if (index >= self.marker_rows.items.len) return false;
        if (index == self.selection) return false;
        self.selection = index;
        self.on_did_change.fire({}) catch {};
        return true;
    }

    /// Row index of the selected marker in the flattened list, or null.
    pub fn selectedRowIndex(self: *const MarkersView) ?usize {
        if (self.marker_rows.items.len == 0) return null;
        if (self.selection >= self.marker_rows.items.len) return null;
        return self.marker_rows.items[self.selection].row_index;
    }

    pub const Thumb = struct { start: usize, length: usize };

    pub fn updateScroll(self: *MarkersView, height: usize) void {
        if (height == 0 or self.rows.items.len == 0) {
            self.scroll = 0;
            return;
        }
        const selected_row = self.selectedRowIndex() orelse {
            self.scroll = 0;
            return;
        };
        if (selected_row < self.scroll) self.scroll = selected_row;
        if (height > 0 and selected_row >= self.scroll + height) {
            self.scroll = selected_row - height + 1;
        }
        const max_scroll = self.rows.items.len -| height;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
    }

    pub fn scrollBy(self: *MarkersView, delta: isize, height: usize) void {
        const max_scroll = self.rows.items.len -| height;
        const current: isize = @intCast(self.scroll);
        var next = current + delta;
        if (next < 0) next = 0;
        if (next > @as(isize, @intCast(max_scroll))) next = @intCast(max_scroll);
        self.scroll = @intCast(next);
    }

    pub fn scrollbarThumb(self: *const MarkersView, height: usize) Thumb {
        const total = self.rows.items.len;
        if (total <= height or height == 0) return .{ .start = 0, .length = height };
        const length = @max(@as(usize, 1), height * height / total);
        const max_start = height - length;
        const start = if (total - height == 0) 0 else self.scroll * max_start / (total - height);
        return .{ .start = start, .length = length };
    }

    pub fn handleKey(self: *MarkersView, event: *const ui.KeyEvent) !bool {
        const host = self.host orelse return false;
        switch (event.key) {
            .up => return self.move(-1),
            .down => return self.move(1),
            .page_up => return self.move(-8),
            .page_down => return self.move(8),
            .home => return self.selectEdge(0),
            .end => return self.selectEdge(self.markerCount() -| 1),
            .enter => {
                if (self.selectedMarker()) |marker| {
                    try self.openFileAtElement(marker, false, true);
                    return true;
                }
                return false;
            },
            .escape => {
                host.focus_editor(host.context);
                return true;
            },
            else => return false,
        }
    }

    fn move(self: *MarkersView, delta: isize) bool {
        const moved = self.moveSelection(delta);
        if (moved) self.previewSelection();
        return moved;
    }

    fn selectEdge(self: *MarkersView, index: usize) bool {
        const moved = self.selectMarkerRow(index);
        if (moved) self.previewSelection();
        return moved;
    }

    fn previewSelection(self: *MarkersView) void {
        const marker = self.selectedMarker() orelse return;
        self.openFileAtElement(marker, true, false) catch {};
    }

    /// Marker.range in markersModel.ts exposes the coordinates of the raw marker.
    pub fn markerRange(marker: *const markers.Marker) @import("../../../../editor/common/core/range.zig").Range {
        return .init(marker.start_line_number, marker.start_column, marker.end_line_number, marker.end_column);
    }

    /// The terminal editor service opens local file resources in the active group.
    pub fn openFileAtElement(self: *MarkersView, marker: *const markers.Marker, preserve_focus: bool, pinned: bool) !void {
        const host = self.host orelse return;
        if (!std.mem.eql(u8, marker.resource.scheme, "file")) return;
        try host.open_editor(host.context, marker, preserve_focus, pinned);
    }

    /// Clicking a marker row selects and previews it. Clicking a file group row
    /// selects its first marker, matching the tree's resource-row behavior.
    pub fn handleMouse(self: *MarkersView, event: *const ui.MouseEvent, rect: ui.Rect, options: RenderOptions) !bool {
        if (event.kind == .wheel) {
            const height = ui.cell.snap(rect.h) -| options.headerRows();
            const delta: isize = if (event.delta_y > 0) 3 else if (event.delta_y < 0) -3 else 0;
            self.scrollBy(delta, height);
            return true;
        }
        if (event.kind != .down and event.kind != .click) return false;
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (event.x < x or event.x >= x + width) return false;
        if (event.y < y or event.y >= y + height) return false;
        const list_top = y + options.headerRows();
        const list_height = height -| options.headerRows();
        if (event.y < list_top) return false;
        const visible_index = event.y - list_top;
        if (visible_index >= list_height) return false;
        self.updateScroll(list_height);
        const row_index = self.scroll + visible_index;
        if (row_index >= self.rowCount()) return false;
        const row = self.rowsSlice()[row_index];
        const marker_index = switch (row.kind) {
            .marker => self.markerIndexForRow(row_index) orelse return false,
            .resource => self.firstMarkerForResource(row.resource.key) orelse return false,
        };
        if (!self.selectMarkerRow(marker_index)) return false;
        self.previewSelection();
        return true;
    }

    fn markerIndexForRow(self: *const MarkersView, row_index: usize) ?usize {
        for (self.markerRows(), 0..) |row, index| {
            if (row.row_index == row_index) return index;
        }
        return null;
    }

    fn firstMarkerForResource(self: *const MarkersView, key: []const u8) ?usize {
        for (self.markerRows(), 0..) |row, index| {
            if (std.mem.eql(u8, row.resource.key, key)) return index;
        }
        return null;
    }

    pub const RenderOptions = struct {
        /// The panel title carries the view name and counts, so the embedded
        /// view starts directly with the list. Standalone callers keep the
        /// upstream-shaped "PROBLEMS" header row and divider.
        show_header: bool = true,

        fn headerRows(self: RenderOptions) usize {
            return if (self.show_header) 2 else 0;
        }
    };

    pub fn render(self: *MarkersView, grid: *ui.CellGrid, rect: ui.Rect, focused: bool, options: RenderOptions) !void {
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

        const header_rows = options.headerRows();
        if (options.show_header) {
            const header_style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(.{ .r = 220, .g = 220, .b = 220 }),
                .attrs = if (focused) ui.cell.Attr.bold else 0,
            };
            drawText(grid, x + 1, y, width -| 2, "PROBLEMS", header_style);

            var count_buf: [64]u8 = undefined;
            var count_len: usize = 0;
            const base_counts = std.fmt.bufPrint(&count_buf, "\u{2716} {d}  \u{26A0} {d}", .{
                self.counts.errors,
                self.counts.warnings,
            }) catch "";
            count_len = base_counts.len;
            if (self.counts.infos > 0) {
                const info = std.fmt.bufPrint(count_buf[count_len..], "  \u{2139} {d}", .{self.counts.infos}) catch "";
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
        }

        const list_top = y + header_rows;
        const list_height = height -| header_rows;
        if (self.markerCount() == 0) {
            const empty_style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(.{ .r = 150, .g = 150, .b = 150 }),
                .bg = background.bg,
            };
            drawText(grid, x + 1, list_top, width -| 2, "No problems detected", empty_style);
            return;
        }
        self.updateScroll(list_height);
        const root = if (self.host) |host| host.workspace_root(host.context) else null;
        var row: usize = 0;
        while (row < list_height) : (row += 1) {
            const source = self.scroll + row;
            if (source >= self.rowCount()) break;
            const entry = self.rowsSlice()[source];
            var style = background;
            if (entry.kind == .marker and entry.marker == self.selectedMarker()) {
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

        if (self.rowCount() > list_height and list_height > 0) {
            const thumb = self.scrollbarThumb(list_height);
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
