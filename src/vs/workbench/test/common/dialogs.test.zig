// Terminal regression for the DialogsModel/BrowserDialogHandler queue in
// src/vs/workbench/common/dialogs.ts and browser/parts/dialogs/dialog.web.contribution.ts.
const std = @import("std");
const ui = @import("ui");
const dialogs = @import("../../../platform/dialogs/common/dialogs.zig");
const DialogService = @import("../../services/dialogs/common/dialogService.zig").DialogService;
const DialogHandlerContribution = @import("../../browser/parts/dialogs/dialog.web.contribution.zig").DialogHandlerContribution;

test "DialogsModel: prompts queue, complete after close, preserve callback lifetimes" {
    const allocator = std.testing.allocator;
    var service = DialogService.init(allocator);
    defer service.deinit();
    const handler = try DialogHandlerContribution.create(allocator, &service.model);
    defer handler.destroy();

    const Observed = struct {
        service: *DialogService,
        handler: *DialogHandlerContribution,
        first_result: ?usize = null,
        confirmation: ?bool = null,
        completed: usize = 0,
        disposed: usize = 0,
        next_already_visible: bool = false,
        fn promptComplete(context: *anyopaque, selected: ?usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.first_result = selected;
            self.completed += 1;
            self.next_already_visible = self.service.hasDialog() and
                self.handler.current != null and
                std.mem.eql(u8, self.handler.current.?.message, "second");
        }
        fn confirmComplete(context: *anyopaque, result: dialogs.IConfirmationResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.confirmation = result.confirmed;
            self.completed += 1;
        }
        fn dispose(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.disposed += 1;
        }
    };
    var observed = Observed{ .service = &service, .handler = handler };
    const api = service.interface();
    var message = [_]u8{ 'f', 'i', 'r', 's', 't' };
    _ = try api.prompt(.{ .message = &message, .buttons = &.{ "Accept", "Cancel" } }, .{
        .context = &observed,
        .complete = Observed.promptComplete,
        .dispose = Observed.dispose,
    });
    @memset(&message, 'x');
    _ = try api.confirm(.{ .message = "second" }, .{
        .context = &observed,
        .complete = Observed.confirmComplete,
        .dispose = Observed.dispose,
    });
    try std.testing.expectEqual(@as(usize, 2), service.model.dialogs.items.len);
    try std.testing.expectEqualStrings("first", handler.current.?.message);

    var enter: ui.KeyEvent = .{ .key = .enter };
    try std.testing.expect(handler.handleKey(&enter));
    try std.testing.expectEqual(@as(?usize, 0), observed.first_result);
    try std.testing.expect(observed.next_already_visible);
    try std.testing.expectEqual(@as(usize, 1), observed.disposed);

    var escape: ui.KeyEvent = .{ .key = .escape };
    try std.testing.expect(handler.handleKey(&escape));
    try std.testing.expectEqual(@as(?bool, false), observed.confirmation);
    try std.testing.expectEqual(@as(usize, 2), observed.completed);
    try std.testing.expectEqual(@as(usize, 2), observed.disposed);
    try std.testing.expect(!api.hasDialog());
    try std.testing.expect(handler.current == null);
}
