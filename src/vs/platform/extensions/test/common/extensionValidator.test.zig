// Port of engine-version compatibility cases in
// `src/vs/platform/extensions/test/common/extensionValidator.test.ts`.
const std = @import("std");
const validator = @import("../../common/extensionValidator.zig");

test "extensionValidator: engine range compatibility" {
    const version = try std.SemanticVersion.parse("1.147.0");
    for ([_][]const u8{ "*", "^1.90.0", ">=1.120.0", "1.147.x", "^0.10.0" }) |range| try std.testing.expect(validator.isEngineValid(version, range));
    for ([_][]const u8{ "^1.148.0", "^2.0.0", "1.146.0", "0.10.0", "invalid" }) |range| try std.testing.expect(!validator.isEngineValid(version, range));
}
