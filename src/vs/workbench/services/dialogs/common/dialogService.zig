// Port of src/vs/workbench/services/dialogs/common/dialogService.ts. The
// terminal service implements confirmation and prompt with explicit result
// callbacks; input/checkbox/about and visual details remain unported.
const std = @import("std");
const dialogs = @import("../../../../platform/dialogs/common/dialogs.zig");
const DialogsModel = @import("../../../common/dialogs.zig").DialogsModel;

pub const DialogService = struct {
    model: DialogsModel,

    pub fn init(allocator: std.mem.Allocator) DialogService {
        return .{ .model = DialogsModel.init(allocator) };
    }

    pub fn deinit(self: *DialogService) void {
        self.model.deinit();
    }

    pub fn hasDialog(self: *const DialogService) bool {
        return self.model.first() != null;
    }

    pub fn prompt(self: *DialogService, prompt_args: dialogs.DialogPrompt, handler: dialogs.PromptHandler) !void {
        try self.model.show(prompt_args, .{ .prompt = handler });
    }

    pub fn confirm(self: *DialogService, confirmation: dialogs.IConfirmation, handler: dialogs.ConfirmationHandler) !void {
        try self.model.show(.{
            .message = confirmation.message,
            .detail = confirmation.detail,
            .buttons = &.{ confirmation.primary_button, confirmation.cancel_button },
            .initial_focus = confirmation.initial_focus,
        }, .{ .confirm = handler });
    }

    pub fn interface(self: *DialogService) dialogs.IDialogService {
        return .{
            .context = self,
            .has_dialog = hasDialogContext,
            .prompt_fn = promptContext,
            .confirm_fn = confirmContext,
            .on_will_show_dialog = &self.model.on_will_show_dialog,
            .on_did_show_dialog = &self.model.on_did_show_dialog,
        };
    }

    fn hasDialogContext(context: *anyopaque) bool {
        const self: *DialogService = @ptrCast(@alignCast(context));
        return self.hasDialog();
    }

    fn promptContext(context: *anyopaque, args: dialogs.DialogPrompt, handler: dialogs.PromptHandler) !void {
        const self: *DialogService = @ptrCast(@alignCast(context));
        try self.prompt(args, handler);
    }

    fn confirmContext(context: *anyopaque, args: dialogs.IConfirmation, handler: dialogs.ConfirmationHandler) !void {
        const self: *DialogService = @ptrCast(@alignCast(context));
        try self.confirm(args, handler);
    }
};
