// Port of the runtime cases of
// `src/vs/platform/notification/test/common/notificationMessage.test.ts`. The
// two upstream type-level cases (nominal content, frozen nodes) have no Zig
// runtime equivalent.
const std = @import("std");
const NotificationText = @import("../../common/notificationMessage.zig").NotificationText;
const icon_labels = @import("../../../../base/common/iconLabels.zig");

const link_title = "Show Logs";

test "formats literal arguments and explicit links without interpreting markup" {
    const allocator = std.testing.allocator;
    const filename = "README.md [Open](command:unexpected \"Open README\")";
    var link = try NotificationText.link(allocator, "[Show logs](command:unexpected)", "command:showLogs?%5B%22file%22%5D", null);
    defer link.deinit();

    var formatted = try NotificationText.format(allocator, "Failed to open {0}. {1}", &.{
        .{ .text = filename },
        .{ .content = &link },
    });
    defer formatted.deinit();

    const nodes = formatted.getNodes();
    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    try std.testing.expectEqualStrings("Failed to open ", nodes[0].text);
    try std.testing.expectEqualStrings(filename, nodes[1].text);
    try std.testing.expectEqualStrings(". ", nodes[2].text);
    try std.testing.expectEqualStrings("[Show logs](command:unexpected)", nodes[3].link.label);
    try std.testing.expectEqualStrings("command:showLogs?%5B%22file%22%5D", nodes[3].link.href);
}

test "formats reordered, repeated and missing placeholders without expanding arguments recursively" {
    const allocator = std.testing.allocator;
    var link = try NotificationText.link(allocator, "Details", "https://example.com", null);
    defer link.deinit();

    var formatted = try NotificationText.format(allocator, "{1}: {0}, {1}, {2}", &.{
        .{ .text = "{1}" },
        .{ .content = &link },
    });
    defer formatted.deinit();

    const text = try formatted.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Details: {1}, Details, {2}", text);
}

test "formats empty and literal templates" {
    const allocator = std.testing.allocator;

    var empty = try NotificationText.format(allocator, "", &.{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.getNodes().len);

    var literal = try NotificationText.format(allocator, "[Open](command:unexpected)", &.{});
    defer literal.deinit();
    try std.testing.expectEqual(@as(usize, 1), literal.getNodes().len);
    try std.testing.expectEqualStrings("[Open](command:unexpected)", literal.getNodes()[0].text);
}

const StripMapper = struct {
    fn map(_: *anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror![]const u8 {
        return icon_labels.stripIcons(allocator, text);
    }
};

test "composes rich fragments and preserves link targets when transforming display text" {
    const allocator = std.testing.allocator;
    var link = try NotificationText.link(allocator, "$(info) [Logs](command:unexpected)", "command:showLogs?%5B%22file%22%5D", link_title);
    defer link.deinit();

    var message = try NotificationText.concat(allocator, &.{
        .{ .text = "$(sync) Working. " },
        .{ .content = &link },
    });
    defer message.deinit();

    var mapped = try message.mapText(.{ .context = @ptrFromInt(1), .map = StripMapper.map });
    defer mapped.deinit();

    const original = try message.toString(allocator);
    defer allocator.free(original);
    try std.testing.expectEqualStrings("$(sync) Working. $(info) [Logs](command:unexpected)", original);

    const nodes = mapped.getNodes();
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqualStrings(" Working. ", nodes[0].text);
    try std.testing.expectEqualStrings(" [Logs](command:unexpected)", nodes[1].link.label);
    try std.testing.expectEqualStrings("command:showLogs?%5B%22file%22%5D", nodes[1].link.href);
    try std.testing.expectEqualStrings(link_title, nodes[1].link.title.?);

    const text = try mapped.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(" Working.  [Logs](command:unexpected)", text);
}
