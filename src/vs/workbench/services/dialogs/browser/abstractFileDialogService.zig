// Port of doShowSaveConfirm in src/vs/workbench/services/dialogs/browser/abstractFileDialogService.ts.
// Dialog labels have no browser mnemonics in the terminal. A completion callback
// replaces the awaited IPromptResult, with its ownership transferred on success.
const std = @import("std");
const dialogs = @import("../../../../platform/dialogs/common/dialogs.zig");

pub const SaveConfirmHandler = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, dialogs.ConfirmResult) void,
    dispose: ?*const fn (*anyopaque) void = null,
};

pub fn showSaveConfirm(allocator: std.mem.Allocator, dialog_service: dialogs.IDialogService, file_names: []const []const u8, handler: SaveConfirmHandler) !?dialogs.IDialogHandle {
    var prompt = (try dialogs.saveConfirmPrompt(allocator, file_names)) orelse {
        handler.complete(handler.context, .DONT_SAVE);
        if (handler.dispose) |dispose| dispose(handler.context);
        return null;
    };
    defer prompt.deinit();
    const callback = try allocator.create(Callback);
    errdefer allocator.destroy(callback);
    callback.* = .{ .allocator = allocator, .handler = handler };
    return try dialog_service.prompt(.{
        .message = prompt.message,
        .detail = prompt.detail,
        .buttons = &.{ prompt.save_label, dialogs.dont_save_label, dialogs.cancel_label },
    }, .{ .context = callback, .complete = Callback.complete, .dispose = Callback.dispose });
}

const Callback = struct {
    allocator: std.mem.Allocator,
    handler: SaveConfirmHandler,

    fn complete(context: *anyopaque, selected: ?usize) void {
        const self: *Callback = @ptrCast(@alignCast(context));
        self.handler.complete(self.handler.context, switch (selected orelse 2) {
            0 => .SAVE,
            1 => .DONT_SAVE,
            else => .CANCEL,
        });
    }

    fn dispose(context: *anyopaque) void {
        const self: *Callback = @ptrCast(@alignCast(context));
        if (self.handler.dispose) |cleanup| cleanup(self.handler.context);
        self.allocator.destroy(self);
    }
};
