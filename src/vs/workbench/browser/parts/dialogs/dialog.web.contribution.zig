// Port of src/vs/workbench/browser/parts/dialogs/dialog.web.contribution.ts.
// The native cell dialog consumes the first item in DialogsModel and closes
// it before displaying the next. Input and frame composition remain at the
// terminal boundary.
const std = @import("std");
const ui = @import("ui");
const DialogsModel = @import("../../../common/dialogs.zig").DialogsModel;
const BrowserDialogHandler = @import("dialogHandler.zig").BrowserDialogHandler;
const ThemeColors = @import("../../themeColors.zig").ThemeColors;

pub const DialogHandlerContribution = struct {
    allocator: std.mem.Allocator,
    model: *DialogsModel,
    handler: BrowserDialogHandler = .{},
    current: ?*ui.Dialog = null,
    current_id: ?usize = null,
    will_show: usize,
    did_show: usize,

    pub fn create(allocator: std.mem.Allocator, model: *DialogsModel) !*DialogHandlerContribution {
        const self = try allocator.create(DialogHandlerContribution);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .model = model, .will_show = undefined, .did_show = undefined };
        self.will_show = try model.on_will_show_dialog.listen(self, onWillShow);
        errdefer model.on_will_show_dialog.unlisten(self.will_show);
        self.did_show = try model.on_did_show_dialog.listen(self, onDidShow);
        errdefer model.on_did_show_dialog.unlisten(self.did_show);
        try self.processDialogs();
        return self;
    }

    fn onWillShow(_: void, self: *DialogHandlerContribution) !void {
        try self.processDialogs();
    }

    fn onDidShow(_: void, self: *DialogHandlerContribution) !void {
        // A queued prompt can be unsupported by the terminal widget. Resolve
        // it as cancelled rather than leaving the rest of the queue blocked.
        self.processDialogs() catch self.model.close(null);
    }

    fn processDialogs(self: *DialogHandlerContribution) !void {
        const first = self.model.first();
        const id = if (first) |item| item.id else null;
        if (self.current_id == id) return;
        if (self.current) |dialog| dialog.deinit();
        self.current = null;
        self.current_id = null;
        if (first) |item| {
            self.current = try self.handler.show(self.allocator, item.args);
            self.current_id = item.id;
        }
    }

    pub fn setThemeColors(self: *DialogHandlerContribution, palette: ?*const ThemeColors) void {
        self.handler.setThemeColors(palette);
        if (self.current) |dialog| dialog.theme = self.handler.theme;
    }

    pub fn handleKey(self: *DialogHandlerContribution, event: *ui.KeyEvent) bool {
        const dialog = self.current orelse return false;
        switch (dialog.handleKey(event)) {
            .none => {},
            .activate => |index| self.close(index),
            .cancel => self.close(null),
        }
        return true;
    }

    pub fn handleMouse(self: *DialogHandlerContribution, event: *ui.MouseEvent) bool {
        const dialog = self.current orelse return false;
        if (dialog.handleMouse(event)) |index| self.close(index);
        return true;
    }

    pub fn pointerAt(self: *const DialogHandlerContribution, x: usize, y: usize) ui.Pointer {
        const dialog = self.current orelse return .default;
        return dialog.pointerAt(x, y);
    }

    fn close(self: *DialogHandlerContribution, selected: ?usize) void {
        self.model.close(selected);
    }

    pub fn destroy(self: *DialogHandlerContribution) void {
        self.model.on_will_show_dialog.unlisten(self.will_show);
        self.model.on_did_show_dialog.unlisten(self.did_show);
        if (self.current) |dialog| dialog.deinit();
        self.allocator.destroy(self);
    }
};
