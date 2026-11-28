const std = @import("std");
const builtin = @import("builtin");
const TerminalInstance = @import("../../browser/terminalInstance.zig").TerminalInstance;
const TerminalEditorInput = @import("../../browser/terminalEditorInput.zig").TerminalEditorInput;
const TerminalEditorService = @import("../../browser/terminalEditorService.zig").TerminalEditorService;

test "terminal editor input follows the terminal label and can detach its live instance" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const instance = TerminalInstance.create(allocator, io, 42, .{
        .shell = "/bin/true",
        .profile_name = "sh",
    }) catch |err| switch (err) {
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };
    defer instance.deinit();
    var service = TerminalEditorService.init(allocator);
    defer service.deinit();
    const input = try TerminalEditorInput.init(allocator, instance);
    defer input.deinit();

    try service.instances.ensureUnusedCapacity(1);
    input.registerInstance(&service);
    defer if (input.host != null) {
        _ = input.detachInstance();
    };

    try std.testing.expectEqualStrings("vscode-terminal:/42", input.interface().resource.?);
    try std.testing.expectEqualStrings("sh", input.interface().getName());
    try instance.rename("build shell");
    try std.testing.expectEqualStrings("build shell", input.interface().getName());
    try std.testing.expect(!input.interface().canReopen());
    try std.testing.expectEqual(instance, input.detachInstance());
    try std.testing.expectEqual(@as(usize, 0), service.instances.items.len);
}
