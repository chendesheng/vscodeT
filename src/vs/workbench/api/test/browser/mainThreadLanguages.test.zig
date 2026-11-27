// Status DTO, registry ordering and disposal regression for
// `src/vs/workbench/api/browser/mainThreadLanguages.ts`.
const std = @import("std");
const actor_mod = @import("../../browser/mainThreadLanguages.zig");
const service_mod = @import("../../../services/languageStatus/common/languageStatusService.zig");
const rpc = @import("../../../services/extensions/common/rpcProtocol.zig");
const TestModel = @import("../../../../editor/test/common/port/testSupport.zig").TestModel;

fn set(actor: *actor_mod.MainThreadLanguages, arena: std.mem.Allocator, handle: i64, json: []const u8) !void {
    const args = [_]rpc.Arg{ .{ .json = .{ .integer = handle } }, .{ .json = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) } };
    try std.testing.expect((try actor.invoke("$setLanguageStatus", &args)) == .empty);
}

test "MainThreadLanguages: replace, filter, order and dispose language statuses" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "sample", "zig");
    defer model.deinit();
    var service = service_mod.LanguageStatusService.init(allocator);
    defer service.deinit();
    var actor = actor_mod.MainThreadLanguages.init(allocator, service.interface());
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    try set(&actor, scratch, 1, "{\"id\":\"zig\",\"name\":\"Zig\",\"selector\":\"zig\",\"label\":\"Installing\",\"detail\":\"Wait\",\"busy\":true,\"severity\":1,\"source\":\"Zig\"}");
    try set(&actor, scratch, 2, "{\"id\":\"zls\",\"name\":\"ZLS\",\"selector\":\"zig\",\"label\":{\"value\":\"Unavailable\",\"shortValue\":\"ZLS\"},\"detail\":\"[Settings](command:workbench.action.openSettings)\",\"severity\":3,\"source\":\"Zig\",\"command\":{\"id\":\"zig.showOutput\",\"title\":\"Show Output\"}}");
    try set(&actor, scratch, 3, "{\"id\":\"other\",\"selector\":\"typescript\",\"label\":\"Other\"}");
    var items = try service.getLanguageStatus(scratch, model.model);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("zls", items[0].id);
    try std.testing.expectEqualStrings("ZLS", items[0].short_label.?);
    try std.testing.expectEqualStrings("zig.showOutput", items[0].command.?.id);
    try std.testing.expectEqualStrings("Settings", try items[0].detail.toString(scratch));
    try std.testing.expect(items[1].busy);
    try set(&actor, scratch, 1, "{\"id\":\"zig\",\"selector\":\"zig\",\"label\":\"Ready\",\"severity\":1}");
    _ = try actor.invoke("$removeLanguageStatus", &.{.{ .json = .{ .integer = 2 } }});
    items = try service.getLanguageStatus(scratch, model.model);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Ready", items[0].label);
    try std.testing.expect(!items[0].busy);
    model.model.setLanguage("typescript");
    items = try service.getLanguageStatus(scratch, model.model);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("other", items[0].id);
}
