// Port of the terminal-facing part of
// `src/vs/workbench/browser/parts/statusbar/statusbarPart.ts`.
//
// The browser part creates one DOM entry per status-bar item and lays them out
// left/right. The terminal part consumes the already-ported `StatusbarModel`
// and produces the two cell-row strings; `src/tui/view.zig` paints them in the
// status row. This keeps alignment and priority in the model/part and cell
// paint in the terminal view.

const std = @import("std");
const model_mod = @import("statusbarModel.zig");
const StatusbarModel = model_mod.StatusbarModel;

pub const StatusbarPart = struct {
    model: *StatusbarModel,
    left: [512]u8 = undefined,
    left_len: usize = 0,
    right: [256]u8 = undefined,
    right_len: usize = 0,
    gap: []const u8 = "  ",

    pub fn init(model: *StatusbarModel) StatusbarPart {
        return .{ .model = model };
    }

    /// Lays out the visible entries into the left and right row strings.
    pub fn layout(self: *StatusbarPart) void {
        self.left_len = 0;
        self.right_len = 0;
        for (self.model.entries()) |entry| {
            if (self.model.isHidden(entry.id)) continue;
            switch (entry.alignment) {
                .left => append(&self.left, &self.left_len, self.gap, entry.text),
                .right => append(&self.right, &self.right_len, self.gap, entry.text),
            }
        }
    }

    pub fn leftText(self: *const StatusbarPart) []const u8 {
        return self.left[0..self.left_len];
    }

    pub fn rightText(self: *const StatusbarPart) []const u8 {
        return self.right[0..self.right_len];
    }
};

fn append(buffer: []u8, length: *usize, gap: []const u8, text: []const u8) void {
    if (text.len == 0) return;
    if (length.* > 0 and length.* + gap.len <= buffer.len) {
        @memcpy(buffer[length.* .. length.* + gap.len], gap);
        length.* += gap.len;
    }
    const available = buffer.len - length.*;
    const count = @min(text.len, available);
    @memcpy(buffer[length.* .. length.* + count], text[0..count]);
    length.* += count;
}

test "StatusbarPart: composes left and right entries in model order" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();
    try model.add(.{
        .id = "left",
        .name = "left",
        .text = "L",
        .alignment = .left,
        .priority = .{ .primary = .{ .number = 1 }, .secondary = 1 },
    });
    try model.add(.{
        .id = "right",
        .name = "right",
        .text = "R",
        .alignment = .right,
        .priority = .{ .primary = .{ .number = 1 }, .secondary = 1 },
    });
    try model.add(.{
        .id = "left2",
        .name = "left2",
        .text = "L2",
        .alignment = .left,
        .priority = .{ .primary = .{ .number = 0 }, .secondary = 1 },
    });

    var part = StatusbarPart.init(&model);
    part.layout();
    try std.testing.expectEqualStrings("L  L2", part.leftText());
    try std.testing.expectEqualStrings("R", part.rightText());

    model.hide("left");
    part.layout();
    try std.testing.expectEqualStrings("L2", part.leftText());
}
