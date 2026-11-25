// Port of src/vs/platform/contextview/browser/contextMenuService.ts.
// Terminal mouse and key dispatch replace browser context-view listeners.
const std = @import("std");
const ui = @import("ui");
const Emitter = @import("../../../base/common/event.zig").Emitter;
pub const Menu = @import("contextMenuHandler.zig").Menu;
pub const Anchor = @import("contextMenuHandler.zig").Anchor;

pub const ContextMenuService = struct {
    disposed: bool = false,
    current: ?*Menu = null,
    on_did_show_context_menu: Emitter(void),
    on_did_hide_context_menu: Emitter(void),
    errors: struct { context: *anyopaque, report: *const fn (*anyopaque, anyerror) void },

    pub fn init(allocator: std.mem.Allocator, context: *anyopaque, report: *const fn (*anyopaque, anyerror) void) ContextMenuService {
        return .{ .errors = .{ .context = context, .report = report }, .on_did_show_context_menu = .init(allocator), .on_did_hide_context_menu = .init(allocator) };
    }

    pub fn deinit(self: *ContextMenuService) void {
        self.disposed = true;
        self.hideContextMenu();
        self.on_did_show_context_menu.deinit();
        self.on_did_hide_context_menu.deinit();
    }

    /// Takes ownership on success, including when the delegate has no actions.
    pub fn showContextMenu(self: *ContextMenuService, menu: *Menu, anchor: Anchor, theme: ui.ContextMenuTheme) !void {
        if (self.disposed) return error.Disposed;
        if (menu.items.items.len == 0) {
            menu.deinit();
            return;
        }
        try menu.show(anchor, theme);
        self.hideContextMenu();
        // A hide listener may have opened another context view synchronously.
        if (self.current != null or self.disposed) {
            menu.deinit();
            return;
        }
        self.current = menu;
        self.on_did_show_context_menu.fire({}) catch |err| self.errors.report(self.errors.context, err);
    }

    pub fn hideContextMenu(self: *ContextMenuService) void {
        self.finish(false);
    }

    fn finish(self: *ContextMenuService, run_action: bool) void {
        const menu = self.current orelse return;
        self.current = null;
        defer menu.deinit();
        self.on_did_hide_context_menu.fire({}) catch |err| self.errors.report(self.errors.context, err);
        if (run_action) menu.runSelected() catch |err| self.errors.report(self.errors.context, err);
    }

    pub fn handleKey(self: *ContextMenuService, event: *const ui.KeyEvent) bool {
        const menu = self.current orelse return false;
        if (menu.popup.?.handleKey(event) == .closed) self.finish(true);
        return true;
    }

    pub fn handleMouse(self: *ContextMenuService, event: *const ui.MouseEvent, pointer: *ui.Pointer) bool {
        const menu = self.current orelse return false;
        if (event.kind == .down) menu.opening_press = false;
        if (menu.opening_press and event.kind == .up) {
            menu.opening_press = false;
            return true;
        }
        pointer.* = menu.popup.?.pointerAt(event.x, event.y);
        if (menu.popup.?.handleMouse(event) == .closed) self.finish(true);
        return true;
    }
};
