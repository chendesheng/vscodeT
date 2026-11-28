// Port of `src/vs/platform/extensions/common/extensionValidator.ts` version
// range normalization and comparison. Terminal product builds have a pinned
// version; the optional product-date prerelease gate follows upstream when
// no product date is supplied.
const std = @import("std");

pub fn isEngineValid(version: std.SemanticVersion, requested: []const u8) bool {
    var range = std.mem.trim(u8, requested, " \t\r\n");
    if (std.mem.eql(u8, range, "*")) return true;
    const minimum = std.mem.startsWith(u8, range, ">=");
    const caret = std.mem.startsWith(u8, range, "^");
    if (minimum) range = range[2..] else if (caret) range = range[1..];
    const release = if (std.mem.indexOfScalar(u8, range, '-')) |index| range[0..index] else range;
    var segments = std.mem.splitScalar(u8, release, '.');
    var desired: [3]usize = undefined;
    var must_equal: [3]bool = undefined;
    for (0..3) |i| {
        const segment = segments.next() orelse return false;
        must_equal[i] = !std.mem.eql(u8, segment, "x");
        desired[i] = if (must_equal[i]) std.fmt.parseInt(usize, segment, 10) catch return false else 0;
    }
    if (segments.next() != null) return false;
    if (caret) {
        must_equal[2] = false;
        if (desired[0] != 0) must_equal[1] = false;
    }
    const actual = [3]usize{ version.major, version.minor, version.patch };
    if (!minimum and actual[0] == 1 and desired[0] == 0 and (!must_equal[0] or !must_equal[1] or !must_equal[2])) {
        desired = .{ 1, 0, 0 };
        must_equal = .{ true, false, false };
    }
    for (actual, desired, must_equal) |a, d, exact| {
        if (a < d) return false;
        if (a > d) return minimum or !exact;
    }
    return true;
}
