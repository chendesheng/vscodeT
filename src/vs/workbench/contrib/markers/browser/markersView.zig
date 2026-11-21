// Port of the portable list state in
// `src/vs/workbench/contrib/markers/browser/markersView.ts`.
//
// The browser `MarkersView` owns a filter pane and a Workbench tree/table
// widget. The terminal port keeps the parts the side-panel list needs: resource
// and marker row flattening, marker-row selection, counts, scroll helpers and
// the marker-changes subscription. Filters, table/tree switching, related
// information, quick fixes, range decorations and view-state persistence live
// in the unported UI layer.

const std = @import("std");
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

pub const MarkersView = struct {
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
};

test "markersView: rows, counts and selection" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();

    const resource = markers.Resource{ .scheme = "file", .path = "/b.zig" };
    const resource2 = markers.Resource{ .scheme = "file", .path = "/a.zig" };
    try service.changeOne("owner", resource, &.{
        .{ .severity = markers.MarkerSeverity.Warning, .message = "warn", .start_line_number = 3 },
    }, null);
    try service.changeOne("owner", resource2, &.{
        .{ .severity = markers.MarkerSeverity.Error, .message = "error", .start_line_number = 8 },
    }, null);

    var view = MarkersView.init(allocator);
    defer view.deinit();
    view.setService(&service);

    try std.testing.expectEqual(@as(usize, 2), view.markerCount());
    try std.testing.expectEqual(@as(usize, 2), view.resourceCount());
    try std.testing.expectEqual(@as(usize, 4), view.rowCount());
    try std.testing.expectEqual(@as(usize, 1), view.counts.errors);
    try std.testing.expectEqual(@as(usize, 1), view.counts.warnings);
    // Error resource sorts before the warning resource.
    try std.testing.expectEqualStrings("/a.zig", view.rows.items[0].resource.path);

    try std.testing.expect(view.moveSelection(1));
    try std.testing.expectEqualStrings("warn", view.selectedMarker().?.message);
    try std.testing.expect(!view.moveSelection(1));
}
