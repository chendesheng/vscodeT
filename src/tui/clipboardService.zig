// Terminal adapter for IClipboardService. OSC 52 delivers user-invoked text
// copies to the outer terminal's clipboard; the in-memory value retains the
// copied bytes for terminals that do not support clipboard escape sequences.
// Reading the system clipboard is intentionally not emulated with OSC queries.
const std = @import("std");
const IClipboardService = @import("../vs/platform/clipboard/common/clipboardService.zig").IClipboardService;

pub const ClipboardService = struct {
    allocator: std.mem.Allocator,
    text: ?[]u8 = null,
    output: ?*std.Io.Writer = null,

    pub fn init(allocator: std.mem.Allocator) ClipboardService {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ClipboardService) void {
        if (self.text) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn attachOutput(self: *ClipboardService, output: ?*std.Io.Writer) void {
        self.output = output;
    }

    pub fn interface(self: *ClipboardService) IClipboardService {
        return .{ .context = self, .write_text = writeText };
    }

    fn writeText(context: *anyopaque, text: []const u8) !void {
        const self: *ClipboardService = @ptrCast(@alignCast(context));
        const copy = try self.allocator.dupe(u8, text);
        if (self.text) |old| self.allocator.free(old);
        self.text = copy;
        if (self.output) |writer| {
            const encoder = std.base64.standard.Encoder;
            const encoded = try self.allocator.alloc(u8, encoder.calcSize(copy.len));
            defer self.allocator.free(encoded);
            _ = encoder.encode(encoded, copy);
            try writer.print("\x1b]52;c;{s}\x1b\\", .{encoded});
            try writer.flush();
        }
    }
};

test "clipboardService: explicit text copy emits OSC 52 and retains exact bytes" {
    const allocator = std.testing.allocator;
    var service = ClipboardService.init(allocator);
    defer service.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    service.attachOutput(&output.writer);
    try service.interface().writeText("a\n");
    try std.testing.expectEqualStrings("a\n", service.text.?);
    try std.testing.expectEqualStrings("\x1b]52;c;YQo=\x1b\\", output.written());
    service.attachOutput(null);
    try service.interface().writeText("b");
    try std.testing.expectEqualStrings("b", service.text.?);
}
