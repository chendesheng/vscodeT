// Port of the text clipboard contract in
// src/vs/platform/clipboard/common/clipboardService.ts.
const instantiation = @import("../../instantiation/common/instantiation.zig");

pub const clipboard_service_id = instantiation.ServiceIdentifier(IClipboardService, "clipboardService");

pub const IClipboardService = struct {
    context: *anyopaque,
    write_text: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn writeText(self: IClipboardService, text: []const u8) !void {
        try self.write_text(self.context, text);
    }
};
