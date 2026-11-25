// Port of `src/vs/editor/test/common/services/markerDecorationsService.test.ts`.
//
// Adapted to the terminal marker-decoration service: models register
// explicitly and the resource comes from `TextModel.uri()`.

const std = @import("std");
const TestModel = @import("../port/testSupport.zig").TestModel;
const markers = @import("../../../../platform/markers/common/markers.zig");
const MarkerService = @import("../../../../platform/markers/common/markerService.zig").MarkerService;
const decorations_mod = @import("../../../common/services/markerDecorationsService.zig");
const MarkerDecorationsService = decorations_mod.MarkerDecorationsService;
const Range = @import("../../../common/core/range.zig").Range;

fn markerData(line: u32, severity: u32) markers.MarkerData {
    return .{
        .message = "problem",
        .severity = severity,
        .start_line_number = line,
        .start_column = 1,
        .end_line_number = line,
        .end_column = 2,
    };
}

test "markerDecorationsService: applies and removes decorations" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "one\ntwo\nthree", "plaintext");
    defer model.deinit();
    var marker_service = MarkerService.init(allocator);
    defer marker_service.deinit();
    var service = try MarkerDecorationsService.init(allocator, &marker_service);
    defer service.deinit();

    try service.registerModel(model.model);
    const resource = try markers.Resource.fromUri(allocator, model.model.uri());
    defer {
        var owned = resource;
        owned.deinit(allocator);
    }

    try marker_service.changeOne("test", resource, &.{
        markerData(1, markers.MarkerSeverity.Error),
        markerData(2, markers.MarkerSeverity.Warning),
    }, null);

    const live = try service.getLiveMarkers(allocator, model.model);
    defer allocator.free(live);
    try std.testing.expectEqual(@as(usize, 2), live.len);

    try marker_service.changeOne("test", resource, &.{}, null);
    const empty = try service.getLiveMarkers(allocator, model.model);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    service.unregisterModel(model.model);
}

test "markerDecorationsService: limit and suppression" {
    const allocator = std.testing.allocator;
    var text = std.array_list.Managed(u8).init(allocator);
    defer text.deinit();
    for (0..5100) |_| try text.appendSlice("value\n");
    var model = try TestModel.init(allocator, text.items, "plaintext");
    defer model.deinit();
    var marker_service = MarkerService.init(allocator);
    defer marker_service.deinit();
    var service = try MarkerDecorationsService.init(allocator, &marker_service);
    defer service.deinit();
    try service.registerModel(model.model);

    const resource = try markers.Resource.fromUri(allocator, model.model.uri());
    defer {
        var owned = resource;
        owned.deinit(allocator);
    }
    const data = try allocator.alloc(markers.MarkerData, 5001);
    defer allocator.free(data);
    for (data, 0..) |*item, index| {
        item.* = markerData(@intCast(index + 1), markers.MarkerSeverity.Error);
    }
    try marker_service.changeOne("test", resource, data, null);
    const live = try service.getLiveMarkers(allocator, model.model);
    defer allocator.free(live);
    try std.testing.expectEqual(@as(usize, 5000), live.len);

    const suppression = try service.addMarkerSuppression(model.model, Range.init(1, 1, 100, 2));
    const suppressed = try service.getLiveMarkers(allocator, model.model);
    defer allocator.free(suppressed);
    try std.testing.expectEqual(@as(usize, 4900), suppressed.len);
    suppression.dispose();

    const restored = try service.getLiveMarkers(allocator, model.model);
    defer allocator.free(restored);
    try std.testing.expectEqual(@as(usize, 5000), restored.len);
}
