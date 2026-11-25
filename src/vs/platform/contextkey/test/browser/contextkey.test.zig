// Port of the configuration-aware context key cases from
// src/vs/platform/contextkey/test/browser/contextkey.test.ts.
const std = @import("std");
const contextkey = @import("../../common/contextkey.zig");
const ConfigAwareContextValuesContainer = @import("../../browser/contextKeyService.zig").ConfigAwareContextValuesContainer;
const configuration = @import("../../../configuration/common/configuration.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

test "ConfigAwareContextValuesContainer: caches configuration and invalidates affected keys before context event" {
    const allocator = std.testing.allocator;
    const Configuration = struct {
        primary: configuration.Value = .{ .string = "first" },
        other: configuration.Value = .{ .bool = false },
        changes: Emitter(configuration.Change),

        fn get(context: *anyopaque, key: []const u8) ?*const configuration.Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, key, "editor.primary")) return &self.primary;
            if (std.mem.eql(u8, key, "other")) return &self.other;
            return null;
        }
    };
    var config = Configuration{ .changes = .init(allocator) };
    defer config.changes.deinit();
    var service = contextkey.ContextKeyService.init(allocator);
    defer service.deinit();
    var container = ConfigAwareContextValuesContainer.init(allocator, &service, .{
        .context = &config,
        .get_value = Configuration.get,
        .on_did_change_configuration = &config.changes,
    });
    defer container.deinit();
    try container.registerListeners();
    try std.testing.expectEqualStrings("first", service.getValue("config.editor.primary").string);
    try std.testing.expect(!service.getValue("config.other").boolean);
    config.primary = .{ .string = "second" };
    config.other = .{ .bool = true };
    try std.testing.expectEqualStrings("first", service.getValue("config.editor.primary").string);
    const Observer = struct {
        service: *contextkey.ContextKeyService,
        affected: bool = false,
        fn changed(change: contextkey.ContextKeyChangeEvent, self: *@This()) !void {
            if (!change.affectsSome(&.{"config.editor.primary"})) return;
            self.affected = true;
            try std.testing.expectEqualStrings("second", self.service.getValue("config.editor.primary").string);
        }
    };
    var observer = Observer{ .service = &service };
    const id = try service.onDidChangeContext.listen(&observer, Observer.changed);
    defer service.onDidChangeContext.unlisten(id);
    try config.changes.fire(.{ .source = .USER, .keys = &.{"editor.primary"} });
    try std.testing.expect(observer.affected);
    try std.testing.expect(!service.getValue("config.other").boolean);
    try config.changes.fire(.{ .source = .DEFAULT, .keys = &.{} });
    try std.testing.expect(service.getValue("config.other").boolean);
}
