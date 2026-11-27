// Tests for the marker navigation contracts in
// `src/vs/editor/contrib/gotoError/browser/markerNavigationService.ts`.
const std = @import("std");
const marker_types = @import("../../../../../platform/markers/common/markers.zig");
const MarkerService = @import("../../../../../platform/markers/common/markerService.zig").MarkerService;
const navigation = @import("../../browser/markerNavigationService.zig");
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const Position = @import("../../../../common/core/position.zig").Position;

test "markerNavigation: scoped severity and position order, wrap and live marker replacement" {
    const a = std.testing.allocator;
    var model = try TestModel.init(a, "first word\nsecond word\nthird word", "plaintext");
    defer model.deinit();
    var service = MarkerService.init(a);
    defer service.deinit();
    var resource = try marker_types.Resource.fromUri(a, model.model.uri());
    defer resource.deinit(a);
    const key = try resource.key(a);
    defer a.free(key);
    const initial: []const marker_types.MarkerData = &.{
        .{ .message = "warning", .severity = marker_types.MarkerSeverity.Warning, .start_line_number = 1, .start_column = 2, .end_line_number = 1, .end_column = 4 },
        .{ .message = "error", .severity = marker_types.MarkerSeverity.Error, .start_line_number = 2, .start_column = 2, .end_line_number = 2, .end_column = 4 },
        .{ .message = "hint", .severity = marker_types.MarkerSeverity.Hint, .start_line_number = 3, .start_column = 1, .end_line_number = 3, .end_column = 3 },
    };
    try service.changeOne("test", resource, initial, null);
    const other: marker_types.Resource = .{ .scheme = "file", .path = "/other" };
    try service.changeOne("test", other, &.{.{ .message = "other" }}, null);
    const severity = try navigation.MarkerList.create(a, &service, resource, .severity);
    defer severity.deinit();
    const position = try navigation.MarkerList.create(a, &service, resource, .position);
    defer position.deinit();
    const global = try navigation.MarkerList.create(a, &service, null, .position);
    defer global.deinit();
    try std.testing.expect(severity.matches(key) and !severity.matches(null));
    try std.testing.expect(global.matches(null));
    try std.testing.expectEqual(@as(usize, 3), global.markers.len);
    try std.testing.expect(try severity.move(true, model.model, Position.init(1, 1)));
    try std.testing.expectEqualStrings("error", severity.selected().?.marker.message);
    try std.testing.expectEqual(@as(usize, 1), severity.selected().?.index);
    try std.testing.expectEqual(@as(usize, 2), severity.selected().?.total);
    try std.testing.expect(try severity.move(true, model.model, Position.init(1, 1)));
    try std.testing.expectEqualStrings("warning", severity.selected().?.marker.message);
    try std.testing.expect(try severity.move(true, model.model, Position.init(1, 1)));
    try std.testing.expectEqualStrings("error", severity.selected().?.marker.message);
    try std.testing.expect(try severity.move(false, model.model, Position.init(1, 1)));
    try std.testing.expectEqualStrings("warning", severity.selected().?.marker.message);
    try std.testing.expect(try position.move(true, model.model, Position.init(1, 1)));
    try std.testing.expectEqualStrings("warning", position.selected().?.marker.message);
    position.resetIndex();
    try std.testing.expect(try position.move(false, model.model, Position.init(2, 1)));
    try std.testing.expectEqualStrings("warning", position.selected().?.marker.message);
    try std.testing.expectEqualStrings("error", position.find(key, Position.init(2, 3)).?.marker.message);
    const Probe = struct {
        count: usize = 0,
        fn changed(_: void, self: *@This()) !void {
            self.count += 1;
        }
    };
    var probe: Probe = .{};
    const listener = try position.on_did_change.listen(&probe, Probe.changed);
    defer position.on_did_change.unlisten(listener);
    // Same diagnostic payload from a replacement service allocation must not
    // reset navigation or leave the list borrowing retired marker memory.
    try service.changeOne("test", resource, initial, null);
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try std.testing.expectEqualStrings("warning", position.selected().?.marker.message);
    try service.changeOne("test", other, &.{.{ .message = "unrelated changed" }}, null);
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try service.changeOne("test", resource, &.{.{ .message = "new diagnostic" }}, null);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expect(position.selected() == null);
    try std.testing.expect(try position.move(true, model.model, Position.init(1, 1)));
    try std.testing.expectEqualStrings("new diagnostic", position.selected().?.marker.message);
}
