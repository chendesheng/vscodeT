// Port of the ConfigurationModel parsing cases of
// `src/vs/platform/configuration/test/common/configurationModels.test.ts`.
// The scope-filter cases need the configuration registry and are not ported.
const std = @import("std");
const configuration_models = @import("../../common/configurationModels.zig");

test "parse configuration model with single override identifier" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJson(allocator, "{\"[x]\":{\"a\":1}}");
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 1), model.overrides.len);
    try std.testing.expectEqual(@as(usize, 1), model.overrides[0].identifiers.len);
    try std.testing.expectEqualStrings("x", model.overrides[0].identifiers[0]);
    try std.testing.expectEqual(@as(usize, 1), model.overrides[0].keys.len);
    try std.testing.expectEqualStrings("a", model.overrides[0].keys[0]);
    try std.testing.expectEqual(@as(i64, 1), model.overrides[0].contents.object.get("a").?.integer);
}

test "parse configuration model with multiple override identifiers" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJson(allocator, "{\"[x][y]\":{\"a\":1}}");
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 2), model.overrides[0].identifiers.len);
    try std.testing.expectEqualStrings("x", model.overrides[0].identifiers[0]);
    try std.testing.expectEqualStrings("y", model.overrides[0].identifiers[1]);
}

test "parse configuration model with duplicate override identifiers" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJson(allocator, "{\"[x][y][x][z]\":{\"a\":1}}");
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 3), model.overrides[0].identifiers.len);
    try std.testing.expectEqualStrings("x", model.overrides[0].identifiers[0]);
    try std.testing.expectEqualStrings("y", model.overrides[0].identifiers[1]);
    try std.testing.expectEqualStrings("z", model.overrides[0].identifiers[2]);
}

test "parse configuration model with exclude option" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"a\":1,\"b\":2}", .{ .exclude = &.{"a"} });
    defer model.deinit();
    try std.testing.expect(model.getValue("a") == null);
    try std.testing.expectEqual(@as(i64, 2), model.getValue("b").?.integer);
}

test "parse configuration model with exclude option even included" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"a\":1,\"b\":2}", .{ .exclude = &.{"a"}, .include = &.{"a"} });
    defer model.deinit();
    try std.testing.expect(model.getValue("a") == null);
    try std.testing.expectEqual(@as(i64, 2), model.getValue("b").?.integer);
}

test "parse configuration model with invalid setting key" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJson(allocator, "{\"a\":null,\"a.b.c\":{\"c\":1}}");
    defer model.deinit();
    try std.testing.expect(model.getValue("a").?.* == .null);
    try std.testing.expect(model.getValue("a.b") == null);
    try std.testing.expect(model.getValue("a.b.c") == null);
}
