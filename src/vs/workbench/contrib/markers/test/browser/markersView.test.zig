// Tests for the portable Problems list state. The upstream
// `markersView.test.ts` exercises the Workbench widget; this port covers the
// row/selection behavior the terminal view consumes.

const std = @import("std");
const markers = @import("../../../../../platform/markers/common/markers.zig");
const MarkerService = @import("../../../../../platform/markers/common/markerService.zig").MarkerService;
const view_mod = @import("../../browser/markersView.zig");

test "markersView: live refresh preserves selection by marker identity" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = markers.Resource{ .scheme = "file", .path = "/a.zig" };
    try service.changeOne("owner", resource, &.{
        .{ .message = "one", .severity = markers.MarkerSeverity.Error, .start_line_number = 1 },
        .{ .message = "two", .severity = markers.MarkerSeverity.Warning, .start_line_number = 2 },
    }, null);

    var view = view_mod.MarkersView.init(allocator);
    defer view.deinit();
    view.setService(&service);
    try std.testing.expect(view.moveSelection(1));
    try std.testing.expectEqualStrings("two", view.selectedMarker().?.message);

    try service.changeOne("owner", resource, &.{
        .{ .message = "one", .severity = markers.MarkerSeverity.Error, .start_line_number = 1 },
        .{ .message = "two", .severity = markers.MarkerSeverity.Warning, .start_line_number = 2 },
        .{ .message = "three", .severity = markers.MarkerSeverity.Info, .start_line_number = 3 },
    }, null);
    try std.testing.expectEqualStrings("two", view.selectedMarker().?.message);
}
