// Port of `MarkersStatusBarContributions` from
// `src/vs/workbench/contrib/markers/browser/markers.contribution.ts`.
//
// Terminal adaptation: the codicon labels (`$(error)`, `$(warning)`,
// `$(info)`) become `✖`, `⚠` and `ℹ` text. Counts are the workbench-wide
// `MarkerService` statistics, matching upstream; `problems.showCurrentInStatus`
// and `problems.visibility` are not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const statusbar_mod = @import("../../../browser/parts/statusbar/statusbarPart.zig");
const StatusbarService = statusbar_mod.StatusbarService;
const EntryAccessor = statusbar_mod.EntryAccessor;
const statusbar = @import("../../../services/statusbar/browser/statusbar.zig");
const StatusbarEntry = statusbar.StatusbarEntry;
const MarkerService = @import("../../../../platform/markers/common/markerService.zig").MarkerService;
const MarkerChangeEvent = @import("../../../../platform/markers/common/markerService.zig").MarkerChangeEvent;
const MarkerStatistics = @import("../../../../platform/markers/common/markers.zig").MarkerStatistics;
const common = @import("../common/markers.zig");

pub const STATUS_ENTRY_ID = "status.problems";

pub const MarkersStatusBar = struct {
    allocator: Allocator,
    statusbar: *StatusbarService,
    service: ?*MarkerService = null,
    accessor: ?EntryAccessor = null,
    listener: ?@import("../../../../base/common/event.zig").Emitter(MarkerChangeEvent).ListenerId = null,
    text_buf: [128]u8 = undefined,
    tooltip_buf: [160]u8 = undefined,

    pub fn init(allocator: Allocator, statusbar_service: *StatusbarService) !*MarkersStatusBar {
        const self = try allocator.create(MarkersStatusBar);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .statusbar = statusbar_service,
        };
        self.accessor = try statusbar_service.addEntry(.{
            .name = common.PROBLEMS_TITLE,
            .text = "",
            .command = .{ .id = common.Markers.TOGGLE_MARKERS_VIEW_ACTION_ID },
        }, STATUS_ENTRY_ID, .left, .{ .number = 50 });
        return self;
    }

    pub fn deinit(self: *MarkersStatusBar) void {
        if (self.listener) |listener| {
            if (self.service) |service| service.on_marker_changed.unlisten(listener);
            self.listener = null;
        }
        if (self.accessor) |accessor| accessor.dispose();
        self.accessor = null;
        self.allocator.destroy(self);
    }

    pub fn attach(self: *MarkersStatusBar, service: *MarkerService) void {
        if (self.service == service) {
            self.update();
            return;
        }
        if (self.listener) |listener| {
            if (self.service) |old| old.on_marker_changed.unlisten(listener);
            self.listener = null;
        }
        self.service = service;
        self.listener = service.on_marker_changed.listen(self, onMarkerChanged) catch null;
        self.update();
    }

    fn onMarkerChanged(_: MarkerChangeEvent, self: *MarkersStatusBar) !void {
        self.update();
    }

    pub fn update(self: *MarkersStatusBar) void {
        const accessor = self.accessor orelse return;
        if (self.service == null) {
            accessor.update(.{
                .name = common.PROBLEMS_TITLE,
                .text = "",
                .command = .{ .id = common.Markers.TOGGLE_MARKERS_VIEW_ACTION_ID },
            });
            return;
        }
        const stats = self.service.?.getStatistics();
        const text = self.formatText(stats);
        const tooltip = self.formatTooltip(stats);
        accessor.update(.{
            .name = common.PROBLEMS_TITLE,
            .text = text,
            .aria_label = tooltip,
            .tooltip = tooltip,
            .command = .{ .id = common.Markers.TOGGLE_MARKERS_VIEW_ACTION_ID },
        });
    }

    fn formatText(self: *MarkersStatusBar, stats: MarkerStatistics) []const u8 {
        var scratch: [3][12]u8 = undefined;
        const errors = packNumber(&scratch[0], stats.errors);
        const warnings = packNumber(&scratch[1], stats.warnings);
        var length: usize = 0;
        const base = std.fmt.bufPrint(self.text_buf[0..], "\u{2716} {s}  \u{26A0} {s}", .{ errors, warnings }) catch return "Problems";
        length = base.len;
        if (stats.infos > 0) {
            const infos = packNumber(&scratch[2], stats.infos);
            const more = std.fmt.bufPrint(self.text_buf[length..], "  \u{2139} {s}", .{infos}) catch "";
            length += more.len;
        }
        return self.text_buf[0..length];
    }

    fn formatTooltip(self: *MarkersStatusBar, stats: MarkerStatistics) []const u8 {
        if (stats.errors == 0 and stats.warnings == 0 and stats.infos == 0) {
            return "No Problems";
        }
        var length: usize = 0;
        if (stats.errors > 0) {
            const part = std.fmt.bufPrint(self.tooltip_buf[0..], "Errors: {d}", .{stats.errors}) catch return "Problems";
            length = part.len;
        }
        if (stats.warnings > 0) {
            if (length > 0) {
                const comma = std.fmt.bufPrint(self.tooltip_buf[length..], ", Warnings: {d}", .{stats.warnings}) catch "";
                length += comma.len;
            } else {
                const part = std.fmt.bufPrint(self.tooltip_buf[0..], "Warnings: {d}", .{stats.warnings}) catch return "Problems";
                length = part.len;
            }
        }
        if (stats.infos > 0) {
            if (length > 0) {
                const comma = std.fmt.bufPrint(self.tooltip_buf[length..], ", Infos: {d}", .{stats.infos}) catch "";
                length += comma.len;
            } else {
                const part = std.fmt.bufPrint(self.tooltip_buf[0..], "Infos: {d}", .{stats.infos}) catch return "Problems";
                length = part.len;
            }
        }
        return self.tooltip_buf[0..length];
    }
};

/// Upstream `packNumber`: `1K`, `10K+`, otherwise the decimal count.
pub fn packNumber(buffer: *[12]u8, n: usize) []const u8 {
    if (n > 9999) return "10K+";
    if (n > 999) {
        return std.fmt.bufPrint(buffer, "{d}K", .{n / 1000}) catch "?";
    }
    return std.fmt.bufPrint(buffer, "{d}", .{n}) catch "?";
}

test "markersStatusBar: counts, packing and tooltip" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    var statusbar_service = try StatusbarService.init(allocator);
    defer statusbar_service.deinit();
    var status = try MarkersStatusBar.init(allocator, &statusbar_service);
    defer status.deinit();
    status.attach(&service);

    const entry = statusbar_service.main_part.model.findEntry(STATUS_ENTRY_ID).?;
    try std.testing.expect(std.mem.indexOf(u8, entry.item.text(), "0") != null);
    try std.testing.expectEqualStrings("No Problems", entry.item.tooltip().?);

    const resource = @import("../../../../platform/markers/common/markers.zig").Resource{ .scheme = "file", .path = "/a.zig" };
    try service.changeOne("owner", resource, &.{
        .{ .severity = @import("../../../../platform/markers/common/markers.zig").MarkerSeverity.Error, .message = "e", .start_line_number = 1 },
        .{ .severity = @import("../../../../platform/markers/common/markers.zig").MarkerSeverity.Warning, .message = "w", .start_line_number = 2 },
    }, null);
    const updated = statusbar_service.main_part.model.findEntry(STATUS_ENTRY_ID).?;
    try std.testing.expect(std.mem.indexOf(u8, updated.item.text(), "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated.item.tooltip().?, "Errors: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated.item.tooltip().?, "Warnings: 1") != null);

    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("1K", packNumber(&buf, 1000));
    try std.testing.expectEqualStrings("10K+", packNumber(&buf, 10000));
}
