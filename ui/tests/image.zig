const std = @import("std");
const ui = @import("ui");
const cell = ui.cell;
const CellGrid = cell.CellGrid;
const Capability = ui.image.Capability;
const max_image_id = ui.image.max_image_id;
const placeholderText = ui.image.placeholderText;
const putPlaceholder = ui.image.putPlaceholder;
const ProbeHost = ui.image.ProbeHost;
const ProbeResult = ui.image.ProbeResult;
const probe = ui.image.probe;
const Runtime = ui.image.Runtime;

test "image: placeholder encoding follows the row/column diacritics" {
    var buffer: [12]u8 = undefined;
    // kitty's documentation uses image 42 printed as `U+10EEEE U+0305 U+0305`
    // for cell (0, 0), `U+10EEEE U+0305 U+030D` for (0, 1), and `U+10EEEE
    // U+030D U+0305` for (1, 0).
    try std.testing.expectEqualSlices(u8, "\u{10EEEE}\u{0305}\u{0305}", placeholderText(&buffer, 0, 0));
    try std.testing.expectEqualSlices(u8, "\u{10EEEE}\u{0305}\u{030D}", placeholderText(&buffer, 0, 1));
    try std.testing.expectEqualSlices(u8, "\u{10EEEE}\u{030D}\u{0305}", placeholderText(&buffer, 1, 0));
}

test "image: placeholder cells carry the image id in the foreground" {
    var grid = try CellGrid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();

    try putPlaceholder(&grid, 1, 1, 0x123456, 0, 1);
    try std.testing.expectEqual(@as(u32, 0x123456), grid.fg[grid.index(1, 1)] & 0xFFFFFF);
    try std.testing.expectEqual(@as(usize, 1), grid.widthAt(1, 1));
    try std.testing.expectEqual(@as(u32, 0x10EEEE), grid.cluster[grid.index(1, 1)]);
    try std.testing.expectEqualStrings("\u{10EEEE}\u{0305}\u{030D}", grid.graphemeAt(1, 1));

    // Zero and out-of-range ids are ignored rather than producing broken text.
    try putPlaceholder(&grid, 0, 0, 0, 0, 0);
    try putPlaceholder(&grid, 0, 0, max_image_id + 1, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(0, 0)]);
}

test "image: runtime chunks PNG transmissions and places a virtual grid" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    runtime.setProtocol(.unicode_placeholders);

    const pixels = try allocator.alloc(u8, 7000);
    defer allocator.free(pixels);
    @memset(pixels, 0xAB);

    try runtime.transmitPng(7, pixels);
    try runtime.placeVirtual(7, 3, 10, 5);
    try runtime.removePlacement(7, 3);
    try runtime.deleteImage(7);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try runtime.flush(&output.writer);
    const text = output.written();

    try std.testing.expect(std.mem.startsWith(u8, text, "\x1b_Ga=t,f=100,i=7,q=2,m=1;"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b_Gm=1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b_Gm=0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b_Ga=p,U=1,i=7,p=3,c=10,r=5,C=1,q=2\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b_Ga=d,d=i,i=7,p=3,q=2\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b_Ga=d,d=I,i=7,q=2\x1b\\") != null);
    try std.testing.expect(!runtime.hasPending());
}

test "image: a disabled runtime emits nothing" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    try runtime.transmitPng(1, "not an image");
    try runtime.placeVirtual(1, 1, 2, 2);
    try runtime.deleteImage(1);
    try std.testing.expect(!runtime.hasPending());
}

const FakeProbeHost = struct {
    reply: []const u8,
    sent: bool = false,

    fn poll(context: *anyopaque, _: i32) anyerror!bool {
        const self: *FakeProbeHost = @ptrCast(@alignCast(context));
        return !self.sent or self.reply.len == 0;
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) anyerror!void {
        const self: *FakeProbeHost = @ptrCast(@alignCast(context));
        if (self.sent) return;
        self.sent = true;
        try buffer.appendSlice(allocator, self.reply);
    }

    fn host(self: *FakeProbeHost) ProbeHost {
        return .{ .context = self, .poll = poll, .read = read };
    }
};

fn fakeProbe(reply: []const u8, hint: bool) !ProbeResult {
    const allocator = std.testing.allocator;
    var host = FakeProbeHost{ .reply = reply };
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const io = std.testing.io;
    return probe(allocator, io, &output.writer, host.host(), hint);
}

test "image: feature query confirms Unicode placeholders" {
    const reply = "\x1b_Gi=31;OK\x1b\\\x1b_Gi=32,e=T,U=1;OK\x1b\\\x1b[?62;22c";
    const result = try fakeProbe(reply, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.graphics_ok);
    try std.testing.expect(result.feature_ok);
    try std.testing.expectEqual(Capability.unicode_placeholders, result.capability);
}

test "image: known terminals fall back to the environment hint" {
    const reply = "\x1b_Gi=31;OK\x1b\\\x1b_Gi=32;OK\x1b\\\x1b[?62;22c";
    const hinted = try fakeProbe(reply, true);
    defer hinted.deinit(std.testing.allocator);
    try std.testing.expectEqual(Capability.unicode_placeholders, hinted.capability);

    const unhinted = try fakeProbe(reply, false);
    defer unhinted.deinit(std.testing.allocator);
    try std.testing.expectEqual(Capability.none, unhinted.capability);
}

test "image: no graphics reply disables images even with the hint" {
    const reply = "\x1b[?62;22c";
    const result = try fakeProbe(reply, true);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.graphics_ok);
    try std.testing.expectEqual(Capability.none, result.capability);
}
