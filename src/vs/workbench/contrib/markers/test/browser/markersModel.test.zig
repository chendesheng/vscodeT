// Port of the behavior cases in
// `src/vs/workbench/contrib/markers/test/browser/markersModel.test.ts`.
//
// Related-information and `toString` cases are omitted because the terminal
// platform marker has no related information and the model borrows service
// records instead of owning copies.

const std = @import("std");
const markers = @import("../../../../../platform/markers/common/markers.zig");
const MarkerService = @import("../../../../../platform/markers/common/markerService.zig").MarkerService;
const model_mod = @import("../../browser/markersModel.zig");
const MarkersModel = model_mod.MarkersModel;

test "markersModel: reset clears resources and total" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    try service.changeOne("owner", .{ .scheme = "file", .path = "/a.zig" }, &.{
        .{ .message = "one", .severity = markers.MarkerSeverity.Error },
    }, null);
    try service.changeOne("owner", .{ .scheme = "file", .path = "/b.zig" }, &.{
        .{ .message = "two", .severity = markers.MarkerSeverity.Warning },
    }, null);

    var model = MarkersModel.init(allocator);
    defer model.deinit();
    try model.refresh(&service);
    try std.testing.expectEqual(@as(usize, 2), model.total());
    try std.testing.expectEqual(@as(usize, 2), model.resourceMarkers().len);

    model.reset();
    try std.testing.expectEqual(@as(usize, 0), model.total());
    try std.testing.expectEqual(@as(usize, 0), model.resourceMarkers().len);
}

test "markersModel: resources sort by severity then path" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    try service.changeOne("owner", .{ .scheme = "file", .path = "/warn.zig" }, &.{
        .{ .message = "w", .severity = markers.MarkerSeverity.Warning },
    }, null);
    try service.changeOne("owner", .{ .scheme = "file", .path = "/error.zig" }, &.{
        .{ .message = "e", .severity = markers.MarkerSeverity.Error },
    }, null);
    try service.changeOne("owner", .{ .scheme = "file", .path = "/a-warn.zig" }, &.{
        .{ .message = "w2", .severity = markers.MarkerSeverity.Warning },
    }, null);

    var model = MarkersModel.init(allocator);
    defer model.deinit();
    try model.refresh(&service);
    const resources = model.resourceMarkers();
    try std.testing.expectEqualStrings("/error.zig", resources[0].path);
    try std.testing.expectEqualStrings("/a-warn.zig", resources[1].path);
    try std.testing.expectEqualStrings("/warn.zig", resources[2].path);
}

test "markersModel: unsupported schemes are skipped" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    try service.changeOne("owner", .{ .scheme = "inmemory", .path = "/x.zig" }, &.{
        .{ .message = "hidden", .severity = markers.MarkerSeverity.Error },
    }, null);

    var model = MarkersModel.init(allocator);
    defer model.deinit();
    try model.refresh(&service);
    try std.testing.expectEqual(@as(usize, 0), model.total());
}
