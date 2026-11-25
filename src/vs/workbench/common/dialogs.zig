// Port of src/vs/workbench/common/dialogs.ts. The queue owns each dialog's
// arguments until it is closed. Zig completion callbacks replace promises;
// the platform result is delivered after onDidShowDialog, as promise
// continuations run after the synchronous close event in upstream.
const std = @import("std");
const Emitter = @import("../../base/common/event.zig").Emitter;
const dialogs = @import("../../platform/dialogs/common/dialogs.zig");

pub const DialogViewItem = struct {
    arena: std.heap.ArenaAllocator,
    args: dialogs.DialogPrompt,
    callback: dialogs.DialogCallback,

    fn create(allocator: std.mem.Allocator, args: dialogs.DialogPrompt, callback: dialogs.DialogCallback) !DialogViewItem {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const buttons = try a.alloc([]const u8, args.buttons.len);
        for (args.buttons, 0..) |label, index| buttons[index] = try a.dupe(u8, label);
        const message = try a.dupe(u8, args.message);
        const detail = try a.dupe(u8, args.detail);
        return .{
            .arena = arena,
            .args = .{
                .message = message,
                .detail = detail,
                .buttons = buttons,
                .initial_focus = args.initial_focus,
            },
            .callback = callback,
        };
    }

    fn dispose(self: *DialogViewItem) void {
        self.callback.dispose();
        self.arena.deinit();
    }
};

pub const DialogsModel = struct {
    allocator: std.mem.Allocator,
    dialogs: std.ArrayList(DialogViewItem) = .empty,
    on_will_show_dialog: Emitter(void),
    on_did_show_dialog: Emitter(void),

    pub fn init(allocator: std.mem.Allocator) DialogsModel {
        return .{
            .allocator = allocator,
            .on_will_show_dialog = .init(allocator),
            .on_did_show_dialog = .init(allocator),
        };
    }

    /// Callback ownership transfers only on success.
    pub fn show(self: *DialogsModel, args: dialogs.DialogPrompt, callback: dialogs.DialogCallback) !void {
        var item = try DialogViewItem.create(self.allocator, args, callback);
        errdefer item.arena.deinit();
        try self.dialogs.append(self.allocator, item);
        errdefer _ = self.dialogs.pop();
        try self.on_will_show_dialog.fire({});
    }

    pub fn first(self: *const DialogsModel) ?*const DialogViewItem {
        return if (self.dialogs.items.len == 0) null else &self.dialogs.items[0];
    }

    pub fn close(self: *DialogsModel, selected: ?usize) void {
        if (self.dialogs.items.len == 0) return;
        var item = self.dialogs.orderedRemove(0);
        defer item.dispose();
        self.on_did_show_dialog.fire({}) catch {};
        item.callback.complete(selected);
    }

    pub fn deinit(self: *DialogsModel) void {
        for (self.dialogs.items) |*item| item.dispose();
        self.dialogs.deinit(self.allocator);
        self.on_will_show_dialog.deinit();
        self.on_did_show_dialog.deinit();
    }
};
