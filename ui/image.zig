//! Terminal image rendering through the kitty graphics protocol.
//!
//! Images are placed with the protocol's *Unicode placeholders*: an image is
//! transmitted once (PNG, or raw RGBA when a decoded image cannot be encoded as
//! PNG) and a virtual placement declares its `columns x rows` grid. Each cell
//! of that grid is then an ordinary text cell containing `U+10EEEE` followed by
//! one combining diacritic for the row and one for the column; the foreground
//! color carries the 24-bit image id. Because the placeholder is normal text,
//! it moves with the cell grid when the application scrolls or repaints, and
//! the existing frame diff can compare it with `CellGrid.sameCell`.
//!
//! This module owns the wire format and the terminal capability probe. File
//! reading and decoding live in the workbench media-preview code; the host owns
//! when to transmit/place/delete and the lifecycle of its image ids.
//!
//! The protocol requires a truecolor foreground color, so placeholders are only
//! useful when the host encodes frames with `ColorDepth.rgb`. Terminals that do
//! not answer the graphics query keep the caller's text fallback.

const std = @import("std");
const cell = @import("cell.zig");
const cell_border = @import("cell_border.zig");
const style = @import("style.zig");

const CellGrid = cell.CellGrid;

pub const Capability = enum { none, unicode_placeholders };

/// The protocol reserves 24 bits for the image id because it is encoded in the
/// placeholder's foreground color.
pub const max_image_id: u32 = 0xFFFFFF;

/// The diacritic table has 297 entries; a placement grid larger than that cannot
/// be addressed and callers cap their rendered size to this value.
pub const max_grid_index: usize = 296;

pub const placeholder_codepoint: u21 = 0x10EEEE;

/// Combining marks used to encode a row/column index. The list is the kitty
/// project's `gen/rowcolumn-diacritics.txt` (Unicode 6.0 combining marks of
/// combining class 230, with normalization-fusing characters removed). Index 0
/// is `U+0305`, index 1 is `U+030D`, and so on.
pub const rowcolumn_diacritics = [_]u21{
    0x0305,  0x030D,  0x030E,  0x0310,  0x0312,  0x033D,  0x033E,  0x033F,
    0x0346,  0x034A,  0x034B,  0x034C,  0x0350,  0x0351,  0x0352,  0x0357,
    0x035B,  0x0363,  0x0364,  0x0365,  0x0366,  0x0367,  0x0368,  0x0369,
    0x036A,  0x036B,  0x036C,  0x036D,  0x036E,  0x036F,  0x0483,  0x0484,
    0x0485,  0x0486,  0x0487,  0x0592,  0x0593,  0x0594,  0x0595,  0x0597,
    0x0598,  0x0599,  0x059C,  0x059D,  0x059E,  0x059F,  0x05A0,  0x05A1,
    0x05A8,  0x05A9,  0x05AB,  0x05AC,  0x05AF,  0x05C4,  0x0610,  0x0611,
    0x0612,  0x0613,  0x0614,  0x0615,  0x0616,  0x0617,  0x0657,  0x0658,
    0x0659,  0x065A,  0x065B,  0x065D,  0x065E,  0x06D6,  0x06D7,  0x06D8,
    0x06D9,  0x06DA,  0x06DB,  0x06DC,  0x06DF,  0x06E0,  0x06E1,  0x06E2,
    0x06E4,  0x06E7,  0x06E8,  0x06EB,  0x06EC,  0x0730,  0x0732,  0x0733,
    0x0735,  0x0736,  0x073A,  0x073D,  0x073F,  0x0740,  0x0741,  0x0743,
    0x0745,  0x0747,  0x0749,  0x074A,  0x07EB,  0x07EC,  0x07ED,  0x07EE,
    0x07EF,  0x07F0,  0x07F1,  0x07F3,  0x0816,  0x0817,  0x0818,  0x0819,
    0x081B,  0x081C,  0x081D,  0x081E,  0x081F,  0x0820,  0x0821,  0x0822,
    0x0823,  0x0825,  0x0826,  0x0827,  0x0829,  0x082A,  0x082B,  0x082C,
    0x082D,  0x0951,  0x0953,  0x0954,  0x0F82,  0x0F83,  0x0F86,  0x0F87,
    0x135D,  0x135E,  0x135F,  0x17DD,  0x193A,  0x1A17,  0x1A75,  0x1A76,
    0x1A77,  0x1A78,  0x1A79,  0x1A7A,  0x1A7B,  0x1A7C,  0x1B6B,  0x1B6D,
    0x1B6E,  0x1B6F,  0x1B70,  0x1B71,  0x1B72,  0x1B73,  0x1CD0,  0x1CD1,
    0x1CD2,  0x1CDA,  0x1CDB,  0x1CE0,  0x1DC0,  0x1DC1,  0x1DC3,  0x1DC4,
    0x1DC5,  0x1DC6,  0x1DC7,  0x1DC8,  0x1DC9,  0x1DCB,  0x1DCC,  0x1DD1,
    0x1DD2,  0x1DD3,  0x1DD4,  0x1DD5,  0x1DD6,  0x1DD7,  0x1DD8,  0x1DD9,
    0x1DDA,  0x1DDB,  0x1DDC,  0x1DDD,  0x1DDE,  0x1DDF,  0x1DE0,  0x1DE1,
    0x1DE2,  0x1DE3,  0x1DE4,  0x1DE5,  0x1DE6,  0x1DFE,  0x20D0,  0x20D1,
    0x20D4,  0x20D5,  0x20D6,  0x20D7,  0x20DB,  0x20DC,  0x20E1,  0x20E7,
    0x20E9,  0x20F0,  0x2CEF,  0x2CF0,  0x2CF1,  0x2DE0,  0x2DE1,  0x2DE2,
    0x2DE3,  0x2DE4,  0x2DE5,  0x2DE6,  0x2DE7,  0x2DE8,  0x2DE9,  0x2DEA,
    0x2DEB,  0x2DEC,  0x2DED,  0x2DEE,  0x2DEF,  0x2DF0,  0x2DF1,  0x2DF2,
    0x2DF3,  0x2DF4,  0x2DF5,  0x2DF6,  0x2DF7,  0x2DF8,  0x2DF9,  0x2DFA,
    0x2DFB,  0x2DFC,  0x2DFD,  0x2DFE,  0x2DFF,  0xA66F,  0xA67C,  0xA67D,
    0xA6F0,  0xA6F1,  0xA8E0,  0xA8E1,  0xA8E2,  0xA8E3,  0xA8E4,  0xA8E5,
    0xA8E6,  0xA8E7,  0xA8E8,  0xA8E9,  0xA8EA,  0xA8EB,  0xA8EC,  0xA8ED,
    0xA8EE,  0xA8EF,  0xA8F0,  0xA8F1,  0xAAB0,  0xAAB2,  0xAAB3,  0xAAB7,
    0xAAB8,  0xAABE,  0xAABF,  0xAAC1,  0xFE20,  0xFE21,  0xFE22,  0xFE23,
    0xFE24,  0xFE25,  0xFE26,  0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
    0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243,
    0x1D244,
};

/// The kitty graphics capability query (a 1x1 RGB query) and an optional
/// feature query asking whether the `T` action supports Unicode placeholders.
pub const graphics_query = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";
pub const feature_query = "\x1b_Ga=q,i=32,e=T,U=1\x1b\\";
const da1 = "\x1b[c";
pub const probe_timeout_ms: i64 = 250;

/// Writes the placeholder grapheme for one image cell. Indices outside the
/// diacritic table are clamped; callers cap placement grids at
/// `max_grid_index + 1` cells.
pub fn placeholderText(buffer: *[12]u8, image_row: usize, image_col: usize) []const u8 {
    const row = rowcolumn_diacritics[@min(image_row, max_grid_index)];
    const col = rowcolumn_diacritics[@min(image_col, max_grid_index)];
    var length: usize = 0;
    length += std.unicode.utf8Encode(placeholder_codepoint, buffer[length..]) catch 0;
    length += std.unicode.utf8Encode(row, buffer[length..]) catch 0;
    length += std.unicode.utf8Encode(col, buffer[length..]) catch 0;
    return buffer[0..length];
}

/// Publishes one cell of a virtual image placement into the cell grid. The cell
/// is a normal one-cell grapheme; its foreground color is the image id, which
/// is what the terminal uses to find the image.
pub fn putPlaceholder(
    grid: *CellGrid,
    col: usize,
    row: usize,
    image_id: u32,
    image_row: usize,
    image_col: usize,
) !void {
    return putPlaceholderWithBackground(grid, col, row, image_id, image_row, image_col, 0);
}

/// As `putPlaceholder`, but gives the cell a background color. Kitty treats
/// the placeholder's background as the image background behind transparent
/// pixels, so views pass their pane background here.
pub fn putPlaceholderWithBackground(
    grid: *CellGrid,
    col: usize,
    row: usize,
    image_id: u32,
    image_row: usize,
    image_col: usize,
    background: u32,
) !void {
    if (image_id == 0 or image_id > max_image_id) return;
    var buffer: [12]u8 = undefined;
    const text = placeholderText(&buffer, image_row, image_col);
    const color = style.Color{
        .r = @intCast((image_id >> 16) & 0xFF),
        .g = @intCast((image_id >> 8) & 0xFF),
        .b = @intCast(image_id & 0xFF),
    };
    try grid.putGrapheme(col, row, text, 1, .{ .fg = cell.packColor(color), .bg = background });
}

/// Host I/O for the capability probe; the shape matches
/// `cell_border.ProbeHost` so the app can pass the same adapter.
pub const ProbeHost = struct {
    context: *anyopaque,
    poll: *const fn (context: *anyopaque, timeout_ms: i32) anyerror!bool,
    read: *const fn (context: *anyopaque, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) anyerror!void,
};

pub const ProbeResult = struct {
    capability: Capability = .none,
    graphics_ok: bool = false,
    /// The terminal answered the feature query (present but possibly without
    /// the `U=1` key).
    feature_ok: bool = false,
    /// Bytes read while probing. The caller feeds them through the normal input
    /// decoder, which swallows the replies, so a key typed during startup is not
    /// lost.
    leftover: ?[]u8 = null,

    pub fn deinit(self: *const ProbeResult, allocator: std.mem.Allocator) void {
        if (self.leftover) |bytes| allocator.free(bytes);
    }
};

/// Sends the graphics query, the feature query and DA1, then reads replies
/// until DA1 (or the timeout). `placeholders_hint` lets the host enable
/// Unicode placeholders for terminals known to implement them but too old for
/// the feature query (kitty before 0.50 and current Ghostty fall in this
/// group).
pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    host: ProbeHost,
    placeholders_hint: bool,
) !ProbeResult {
    try out.writeAll(graphics_query);
    try out.writeAll(feature_query);
    try out.writeAll(da1);
    try out.flush();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const deadline = std.Io.Timestamp.now(io, .real).toMilliseconds() + probe_timeout_ms;
    while (true) {
        const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
        if (now >= deadline) break;
        const remaining: i32 = @intCast(@min(deadline - now, probe_timeout_ms));
        if (!try host.poll(host.context, remaining)) break;
        const before = buffer.items.len;
        try host.read(host.context, allocator, &buffer);
        if (buffer.items.len == before) break;
        if (cell_border.containsDa1(buffer.items)) break;
    }

    const graphics_ok = kittyReplyOk(buffer.items, 31);
    const feature_ok = kittyReplyOk(buffer.items, 32);
    const feature_placeholders = feature_ok and featureReplyHasPlaceholders(buffer.items, 32);
    const capability: Capability = if (!graphics_ok)
        .none
    else if (feature_placeholders or placeholders_hint)
        .unicode_placeholders
    else
        .none;

    return .{
        .capability = capability,
        .graphics_ok = graphics_ok,
        .feature_ok = feature_ok,
        .leftover = if (buffer.items.len == 0) null else try allocator.dupe(u8, buffer.items),
    };
}

/// Finds an APC graphics reply `ESC _ G...` with `i=<id>` whose message is
/// `OK`.
fn kittyReplyOk(input: []const u8, id: u32) bool {
    var index: usize = 0;
    while (index + 3 < input.len) : (index += 1) {
        if (input[index] != 0x1B or input[index + 1] != '_' or input[index + 2] != 'G') continue;
        const end = replyEnd(input, index + 3) orelse continue;
        const body = input[index + 3 .. end];
        const semicolon = std.mem.indexOfScalar(u8, body, ';') orelse {
            index = end;
            continue;
        };
        if (!controlHasId(body[0..semicolon], id)) {
            index = end;
            continue;
        }
        if (std.mem.eql(u8, body[semicolon + 1 ..], "OK")) return true;
        index = end;
    }
    return false;
}

fn featureReplyHasPlaceholders(input: []const u8, id: u32) bool {
    var index: usize = 0;
    while (index + 3 < input.len) : (index += 1) {
        if (input[index] != 0x1B or input[index + 1] != '_' or input[index + 2] != 'G') continue;
        const end = replyEnd(input, index + 3) orelse continue;
        const body = input[index + 3 .. end];
        const semicolon = std.mem.indexOfScalar(u8, body, ';') orelse {
            index = end;
            continue;
        };
        const control = body[0..semicolon];
        if (!controlHasId(control, id)) {
            index = end;
            continue;
        }
        var fields = std.mem.splitScalar(u8, control, ',');
        var has_u1 = false;
        while (fields.next()) |field| {
            if (std.mem.eql(u8, field, "U=1")) has_u1 = true;
        }
        if (has_u1) return true;
        index = end;
    }
    return false;
}

fn replyEnd(input: []const u8, start: usize) ?usize {
    var index = start;
    while (index < input.len) : (index += 1) {
        if (input[index] == 0x9C) return index;
        if (input[index] == 0x1B and index + 1 < input.len and input[index + 1] == '\\') return index;
    }
    return null;
}

fn controlHasId(control: []const u8, id: u32) bool {
    var fields = std.mem.splitScalar(u8, control, ',');
    while (fields.next()) |field| {
        if (!std.mem.startsWith(u8, field, "i=")) continue;
        const value = std.fmt.parseUnsigned(u32, field[2..], 10) catch continue;
        if (value == id) return true;
    }
    return false;
}

/// Terminal image output state. A host owns one runtime and flushes it into the
/// output stream before painting the frame body, so pending transmissions and
/// virtual placements are known to the terminal before placeholder cells arrive.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    protocol: Capability = .none,
    cell_width_px: usize = 8,
    cell_height_px: usize = 16,
    next_id: u32 = 1,
    pending: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Runtime) void {
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn enabled(self: *const Runtime) bool {
        return self.protocol != .none;
    }

    pub fn hasPending(self: *const Runtime) bool {
        return self.pending.items.len != 0;
    }

    pub fn setProtocol(self: *Runtime, protocol: Capability) void {
        if (self.protocol == protocol) return;
        self.protocol = protocol;
        // Pending image commands belong to the old capability; drop them.
        self.pending.clearRetainingCapacity();
    }

    pub fn setCellSize(self: *Runtime, width_px: usize, height_px: usize) void {
        if (width_px > 0) self.cell_width_px = width_px;
        if (height_px > 0) self.cell_height_px = height_px;
    }

    pub fn allocId(self: *Runtime) u32 {
        const id = self.next_id;
        self.next_id = if (self.next_id >= max_image_id) 1 else self.next_id + 1;
        return id;
    }

    /// Queues a PNG image transmission. The grid placement is separate so a
    /// view can change its rendered size without resending the pixels.
    pub fn transmitPng(self: *Runtime, image_id: u32, bytes: []const u8) !void {
        if (!self.enabled() or image_id == 0 or bytes.len == 0) return;
        try self.transmit(image_id, "f=100", bytes);
    }

    pub fn transmitRgba(
        self: *Runtime,
        image_id: u32,
        width: usize,
        height: usize,
        pixels: []const u8,
    ) !void {
        if (!self.enabled() or image_id == 0 or pixels.len == 0) return;
        var control: [48]u8 = undefined;
        const description = try std.fmt.bufPrint(&control, "f=32,s={d},v={d}", .{ width, height });
        try self.transmit(image_id, description, pixels);
    }

    fn transmit(self: *Runtime, image_id: u32, description: []const u8, bytes: []const u8) !void {
        const max_raw = 3072; // 4096 base64 characters
        var offset: usize = 0;
        var first = true;
        while (offset < bytes.len) {
            const chunk_length = @min(max_raw, bytes.len - offset);
            const more = offset + chunk_length < bytes.len;
            const chunk = bytes[offset .. offset + chunk_length];
            var encoded: [4096]u8 = undefined;
            const encoded_len = std.base64.standard.Encoder.encode(&encoded, chunk).len;
            var header: [128]u8 = undefined;
            const control = if (first)
                try std.fmt.bufPrint(&header, "a=t,{s},i={d},q=2,m={d}", .{
                    description,
                    image_id,
                    @intFromBool(more),
                })
            else
                try std.fmt.bufPrint(&header, "m={d}", .{@intFromBool(more)});
            try self.append(control, encoded[0..encoded_len]);
            offset += chunk_length;
            first = false;
        }
    }

    /// Creates (or replaces) the virtual placement that maps the image to a
    /// `cols x rows` cell grid. The caller deletes the previous placement first
    /// with `removePlacement` when the size changes.
    pub fn placeVirtual(
        self: *Runtime,
        image_id: u32,
        placement_id: u32,
        cols: usize,
        rows: usize,
    ) !void {
        if (!self.enabled() or image_id == 0 or cols == 0 or rows == 0) return;
        var control: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&control, "a=p,U=1,i={d},p={d},c={d},r={d},C=1,q=2", .{
            image_id,
            placement_id,
            @min(cols, max_grid_index + 1),
            @min(rows, max_grid_index + 1),
        });
        try self.append(text, "");
    }

    pub fn removePlacement(self: *Runtime, image_id: u32, placement_id: u32) !void {
        if (!self.enabled() or image_id == 0) return;
        var control: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&control, "a=d,d=i,i={d},p={d},q=2", .{ image_id, placement_id });
        try self.append(text, "");
    }

    /// Deletes the image data and every placement that refers to it.
    pub fn deleteImage(self: *Runtime, image_id: u32) !void {
        if (!self.enabled() or image_id == 0) return;
        var control: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&control, "a=d,d=I,i={d},q=2", .{image_id});
        try self.append(text, "");
    }

    fn append(self: *Runtime, control: []const u8, payload: []const u8) !void {
        try self.pending.appendSlice(self.allocator, "\x1b_G");
        try self.pending.appendSlice(self.allocator, control);
        if (payload.len > 0) {
            try self.pending.append(self.allocator, ';');
            try self.pending.appendSlice(self.allocator, payload);
        }
        try self.pending.appendSlice(self.allocator, "\x1b\\");
    }

    pub fn flush(self: *Runtime, writer: *std.Io.Writer) !void {
        if (self.pending.items.len == 0) return;
        try writer.writeAll(self.pending.items);
        self.pending.clearRetainingCapacity();
    }
};

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
    const io = std.Io.Threaded.global_single_threaded.io();
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
