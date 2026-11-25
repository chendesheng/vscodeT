// Terminal integration tests for the provider and picker contracts in
// `src/vs/workbench/contrib/tasks/browser/abstractTaskService.ts`.
const std = @import("std");
const AbstractTaskService = @import("../../browser/abstractTaskService.zig").AbstractTaskService;
const ExtensionDescription = @import("../../../../services/extensions/common/extensionHostManager.zig").ExtensionDescription;
const CommandRegistry = @import("../../../../browser/commands.zig").CommandRegistry;
const QuickInputService = @import("../../../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../../../platform/quickinput/browser/quickInput.zig").QuickPick;

test "Run Task activates its type, requests contributed tasks and runs the selected execution" {
    const Host = struct {
        ran: bool = false,
        activations: usize = 0,
        changes: usize = 0,
        fn show(_: *anyopaque, _: *QuickPick) !void {}
        fn hide(_: *anyopaque) void {}
        fn activate(context: *anyopaque, _: std.mem.Allocator, event: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("onTaskType:build", event);
            self.activations += 1;
        }
        fn provide(context: *anyopaque, arena: std.mem.Allocator, valid_types: std.json.Value) ![]const std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(@as(usize, 1), self.activations);
            try std.testing.expect(valid_types.object.get("build").?.bool);
            const tasks = try std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\[{"name":"Compile","execution":{"process":"zig","args":["build"],"options":{"cwd":"/example"}}}]
            , .{});
            return tasks.array.items;
        }
        fn run(context: *anyopaque, name: []const u8, executable: []const u8, args: []const []const u8, cwd: ?[]const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("Compile", name);
            try std.testing.expectEqualStrings("/usr/bin/env", executable);
            try std.testing.expectEqual(@as(usize, 3), args.len);
            try std.testing.expectEqualStrings("--", args[0]);
            try std.testing.expectEqualStrings("zig", args[1]);
            try std.testing.expectEqualStrings("build", args[2]);
            try std.testing.expectEqualStrings("/example", cwd.?);
            self.ran = true;
        }
        fn changed(_: void, self: *@This()) !void {
            self.changes += 1;
        }
    };
    const allocator = std.testing.allocator;
    var host: Host = .{};
    var commands = CommandRegistry.init(allocator);
    defer commands.deinit();
    const input = try QuickInputService.init(allocator, .{ .context = &host, .show = Host.show, .hide = Host.hide });
    defer input.deinit();
    const manifest = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"contributes":{"taskDefinitions":[{"type":"build"}]}}
    , .{});
    defer manifest.deinit();
    const extension = ExtensionDescription{ .path = "", .parsed = manifest, .manifest = manifest.value, .identifier = "test.tasks", .activation_events = &.{} };
    var service: AbstractTaskService = undefined;
    try service.init(allocator, &commands, input, &.{extension}, .{ .context = &host, .activate = Host.activate, .run_terminal = Host.run });
    defer service.deinit();
    const listener = try service.on_did_change_task_providers.listen(&host, Host.changed);
    defer service.on_did_change_task_providers.unlisten(listener);
    {
        const registration = try service.interface().registerTaskProvider(.{ .context = &host, .provide_tasks = Host.provide }, "build");
        defer registration.dispose();
        try commands.execute("workbench.action.tasks.runTask");
        const picker = input.pickerRef();
        try std.testing.expectEqualStrings("build", picker.items.items[0].item.id);
        picker.accept();
        try std.testing.expectEqualStrings("Compile", picker.items.items[0].item.label);
        picker.accept();
        try std.testing.expect(host.ran);
    }
    try std.testing.expectEqual(@as(usize, 2), host.changes);
}
