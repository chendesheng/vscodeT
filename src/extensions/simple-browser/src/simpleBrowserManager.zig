// Terminal adaptation of extensions/simple-browser/src/{extension,simpleBrowserManager}.ts.
// The terminal editor hosts Lynx for the upstream browser view. URL input is a
// free-input quick pick, shared by the command palette and extension API.
const std = @import("std");
const QuickInput = @import("../../../vs/platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../vs/platform/quickinput/browser/quickInput.zig").QuickPick;
const terminal = @import("../../../vs/platform/terminal/common/terminal.zig");
const profiles = @import("../../../vs/platform/terminal/node/terminalProfiles.zig");

pub const SimpleBrowserManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    quick_input: *QuickInput,
    context: *anyopaque,
    open_editor: *const fn (*anyopaque, terminal.ITerminalProfile) anyerror!void,
    report_error: *const fn (*anyopaque, []const u8) bool,

    pub fn show(self: *SimpleBrowserManager, address: ?[]const u8) !void {
        const url = std.mem.trim(u8, address orelse "", " \t\r\n");
        if (url.len == 0) {
            try self.quick_input.showPick(&.{}, .{ .placeholder = "Enter an HTTP or HTTPS URL", .allow_free_input = true }, accept, self);
            return;
        }
        const uri = std.Uri.parse(url) catch return error.InvalidBrowserAddress;
        if (uri.host == null or (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https"))) return error.InvalidBrowserAddress;
        for (url) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidBrowserAddress;
        const executable = try profiles.findTerminalExecutable(self.allocator, self.io, "lynx") orelse return error.LynxNotInstalled;
        defer self.allocator.free(executable);
        try self.open_editor(self.context, .{ .path = executable, .args = &.{ "-restrictions=exec,shell", url }, .profile_name = "Simple Browser" });
    }

    pub fn run(context: *anyopaque) !void {
        const self: *SimpleBrowserManager = @ptrCast(@alignCast(context));
        try self.show(null);
    }

    fn accept(context: *anyopaque, picker: *QuickPick) !void {
        const self: *SimpleBrowserManager = @ptrCast(@alignCast(context));
        if (picker.value.items.len == 0) return;
        self.show(picker.value.items) catch |err| {
            const message = switch (err) {
                error.LynxNotInstalled => "Install Lynx and add lynx to PATH to use Simple Browser.",
                error.InvalidBrowserAddress => "Simple Browser requires an HTTP or HTTPS URL.",
                else => return err,
            };
            if (!self.report_error(self.context, message)) return err;
        };
    }
};
