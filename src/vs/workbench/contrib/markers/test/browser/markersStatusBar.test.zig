// Tests for the terminal MarkersStatusBar port.

const std = @import("std");
const status_mod = @import("../../browser/markersStatusBar.zig");

test "markersStatusBar: packNumber thresholds" {
    var buffer: [12]u8 = undefined;
    try std.testing.expectEqualStrings("0", status_mod.packNumber(&buffer, 0));
    try std.testing.expectEqualStrings("999", status_mod.packNumber(&buffer, 999));
    try std.testing.expectEqualStrings("1K", status_mod.packNumber(&buffer, 1000));
    try std.testing.expectEqualStrings("9K", status_mod.packNumber(&buffer, 9999));
    try std.testing.expectEqualStrings("10K+", status_mod.packNumber(&buffer, 10000));
}
