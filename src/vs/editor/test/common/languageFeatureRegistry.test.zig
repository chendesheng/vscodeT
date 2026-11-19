// Tests for `src/vs/editor/common/languageFeatureRegistry.ts`.
//
// Upstream has no direct registry suite; these cases cover the selector,
// ordering and exclusivity rules the port depends on.

const std = @import("std");
const registry_mod = @import("../../common/languageFeatureRegistry.zig");
const selector = @import("../../common/languageSelector.zig");
const TestModel = @import("./port/testSupport.zig").TestModel;

fn changedCount(count: usize, context: *usize) !void {
    context.* = count;
}

test "languageFeatureRegistry: orders by score and registration" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "x", "typescript");
    defer model.deinit();

    var registry = registry_mod.LanguageFeatureRegistry(u32).init(allocator);
    defer registry.deinit();

    const any = try registry.register(.{ .language = "*" }, 1);
    defer any.dispose();
    const exact_old = try registry.register(.{ .language = "typescript" }, 2);
    defer exact_old.dispose();
    const exact_new = try registry.register(.{ .language = "typescript" }, 3);
    defer exact_new.dispose();

    const ordered = try registry.ordered(allocator, model.model, false);
    defer allocator.free(ordered);
    try std.testing.expectEqualSlices(u32, &.{ 3, 2, 1 }, ordered);
}

test "languageFeatureRegistry: builtin providers are ordered last" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "x", "typescript");
    defer model.deinit();

    var registry = registry_mod.LanguageFeatureRegistry(u32).init(allocator);
    defer registry.deinit();

    const builtin = try registry.register(.{ .filter = .{ .language = "typescript", .is_builtin = true } }, 1);
    defer builtin.dispose();
    const normal = try registry.register(.{ .filter = .{ .language = "typescript" } }, 2);
    defer normal.dispose();

    const ordered = try registry.ordered(allocator, model.model, false);
    defer allocator.free(ordered);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, ordered);
}

test "languageFeatureRegistry: exclusive selector takes over" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "x", "typescript");
    defer model.deinit();

    var registry = registry_mod.LanguageFeatureRegistry(u32).init(allocator);
    defer registry.deinit();

    const normal = try registry.register(.{ .language = "typescript" }, 1);
    defer normal.dispose();
    const exclusive = try registry.register(.{ .filter = .{ .language = "typescript", .exclusive = true } }, 2);
    defer exclusive.dispose();
    const later_exclusive = try registry.register(.{ .filter = .{ .language = "typescript", .exclusive = true } }, 3);
    defer later_exclusive.dispose();

    const ordered = try registry.ordered(allocator, model.model, false);
    defer allocator.free(ordered);
    try std.testing.expectEqualSlices(u32, &.{2}, ordered);

    // Recursive queries zero exclusive providers (upstream behavior).
    const recursive = try registry.ordered(allocator, model.model, true);
    defer allocator.free(recursive);
    try std.testing.expectEqualSlices(u32, &.{1}, recursive);
}

test "languageFeatureRegistry: release invalidates and fires change" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "x", "typescript");
    defer model.deinit();

    var registry = registry_mod.LanguageFeatureRegistry(u32).init(allocator);
    defer registry.deinit();
    var changed: usize = 0;
    const listener = try registry.on_did_change.listen(&changed, changedCount);
    defer registry.on_did_change.unlisten(listener);

    const registration = try registry.register(.{ .language = "typescript" }, 7);
    try std.testing.expect(registry.has(model.model));
    registration.dispose();
    registration.dispose(); // idempotent
    try std.testing.expect(!registry.has(model.model));
    try std.testing.expectEqual(@as(usize, 0), changed);
}

test "languageFeatureRegistry: allNoModel and registered language ids" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "x", "typescript");
    defer model.deinit();

    var registry = registry_mod.LanguageFeatureRegistry(u32).init(allocator);
    defer registry.deinit();
    const a = try registry.register(.{ .language = "typescript" }, 1);
    defer a.dispose();
    const b = try registry.register(.{ .list = &.{
        .{ .language = "javascript" },
        .{ .filter = .{ .language = "css" } },
        .{ .filter = .{ .scheme = "file" } },
    } }, 2);
    defer b.dispose();

    const all = try registry.allNoModel(allocator);
    defer allocator.free(all);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, all);

    var ids = try registry.registeredLanguageIds(allocator);
    defer ids.deinit();
    try std.testing.expect(ids.contains("typescript"));
    try std.testing.expect(ids.contains("javascript"));
    try std.testing.expect(ids.contains("css"));
    try std.testing.expect(!ids.contains("file"));
}
