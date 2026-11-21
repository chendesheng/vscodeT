//! Image decoding for the terminal media preview.
//!
//! Port of the image branch of `src/vs/workbench/contrib/mediaPreview/` where
//! the browser's `HTMLImageElement` decoder is replaced by the pinned `zigimg`
//! package. The terminal speaks either PNG (`f=100`) or raw RGBA (`f=32`):
//!
//!  * a PNG file is passed through unchanged (its IHDR gives the dimensions);
//!  * JPEG/GIF/BMP/TIFF are decoded by zigimg, converted to RGBA and encoded as
//!    PNG for a compact upload, with a raw-RGBA fallback when the encoder does
//!    not support the pixel data;
//!  * SVG, WebP, AVIF and ICO are not decodable here. SVG is a text format and
//!    opens in the text editor; the other formats report an unsupported-format
//!    message.
//!
//! Animated GIFs show their first frame. Remote resources and `data:` URLs are
//! not fetched; the caller only passes local file contents.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigimg = @import("zigimg");

pub const max_file_bytes: usize = 32 * 1024 * 1024;
pub const max_pixels: usize = 16 * 1024 * 1024;
pub const max_dimension: usize = 16384;

pub const DecodeError = error{
    UnsupportedFormat,
    CorruptImage,
    ImageTooLarge,
};

pub const Payload = union(enum) {
    png: []u8,
    rgba: []u8,

    pub fn bytes(self: Payload) []const u8 {
        return switch (self) {
            .png => |value| value,
            .rgba => |value| value,
        };
    }
};

pub const Decoded = struct {
    width: usize,
    height: usize,
    payload: Payload,

    pub fn deinit(self: *Decoded, allocator: Allocator) void {
        switch (self.payload) {
            .png => |value| allocator.free(value),
            .rgba => |value| allocator.free(value),
        }
        self.* = undefined;
    }
};

const png_signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

pub fn isPng(bytes: []const u8) bool {
    return bytes.len >= png_signature.len and std.mem.eql(u8, bytes[0..png_signature.len], &png_signature);
}

pub const Size = struct { width: usize, height: usize };

/// Reads the IHDR dimensions from a PNG file without decoding pixels.
pub fn pngSize(bytes: []const u8) ?Size {
    if (!isPng(bytes) or bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

/// Recognises formats this port cannot display. Returning a distinct error lets
/// the UI show "format not supported" instead of "image is corrupt".
pub fn unsupportedFormat(bytes: []const u8) bool {
    if (looksLikeSvg(bytes)) return true;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return true;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp")) {
        const brand = bytes[8..12];
        if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) return true;
    }
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], &.{ 0x00, 0x00, 0x01, 0x00 })) return true;
    return false;
}

fn looksLikeSvg(bytes: []const u8) bool {
    const probe = bytes[0..@min(bytes.len, 512)];
    const trimmed = std.mem.trimStart(u8, probe, " \t\r\n\u{FEFF}");
    return std.mem.startsWith(u8, trimmed, "<svg") or
        std.mem.startsWith(u8, trimmed, "<?xml") and std.mem.indexOf(u8, trimmed, "<svg") != null;
}

fn checkSize(width: usize, height: usize) DecodeError!void {
    if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.ImageTooLarge;
    if (width > max_pixels / height) return error.ImageTooLarge;
}

/// Decodes `bytes` (a complete local file) into a terminal-uploadable payload.
/// The returned payload is owned by the caller.
pub fn decode(allocator: Allocator, bytes: []const u8) (Allocator.Error || DecodeError)!Decoded {
    if (bytes.len > max_file_bytes) return error.ImageTooLarge;
    if (bytes.len == 0) return error.CorruptImage;

    if (pngSize(bytes)) |size| {
        try checkSize(size.width, size.height);
        const copy = try allocator.dupe(u8, bytes);
        return .{ .width = size.width, .height = size.height, .payload = .{ .png = copy } };
    }
    if (unsupportedFormat(bytes)) return error.UnsupportedFormat;

    // zigimg reads BITMAPV4/V5 headers only. Normalise the common Windows 3.x
    // header (and top-down pixel order) into a V4 buffer so ordinary BMP files
    // work too.
    const bmp = try normalizeBmp(allocator, bytes);
    defer if (bmp) |owned| allocator.free(owned);
    const image_bytes = bmp orelse bytes;

    var image = zigimg.Image.fromMemory(allocator, image_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptImage,
    };
    defer image.deinit(allocator);

    try checkSize(image.width, image.height);
    image.convert(allocator, .rgba32) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptImage,
    };

    const rgba = std.mem.sliceAsBytes(image.pixels.rgba32);
    if (encodePng(allocator, &image)) |png| {
        return .{ .width = image.width, .height = image.height, .payload = .{ .png = png } };
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }

    // The encoder rejected the pixel storage: upload the RGBA pixels directly.
    const copy = try allocator.dupe(u8, rgba);
    return .{ .width = image.width, .height = image.height, .payload = .{ .rgba = copy } };
}

/// Converts a Windows 3.x `BITMAPINFOHEADER` BMP with uncompressed 24/32-bit
/// pixels into a `BITMAPV4HEADER` buffer (and flips top-down rows to the
/// bottom-up order zigimg expects). Other BMP variants are returned as-is.
fn normalizeBmp(allocator: Allocator, bytes: []const u8) (Allocator.Error || DecodeError)!?[]u8 {
    if (bytes.len < 54 or !std.mem.eql(u8, bytes[0..2], "BM")) return null;
    const pixel_offset = std.mem.readInt(u32, bytes[10..14], .little);
    const dib_size = std.mem.readInt(u32, bytes[14..18], .little);
    if (dib_size != 40) return null;

    const width_bits = std.mem.readInt(i32, bytes[18..22], .little);
    const height_bits = std.mem.readInt(i32, bytes[22..26], .little);
    const bit_count = std.mem.readInt(u16, bytes[28..30], .little);
    const compression = std.mem.readInt(u32, bytes[30..34], .little);
    if (width_bits <= 0 or height_bits == 0 or height_bits == std.math.minInt(i32) or compression != 0) return null;
    if (bit_count != 24 and bit_count != 32) return error.UnsupportedFormat;

    const width: usize = @intCast(width_bits);
    const height: usize = @intCast(if (height_bits < 0) -height_bits else height_bits);
    const top_down = height_bits < 0;
    const bytes_per_pixel: usize = bit_count / 8;
    const row_size = std.mem.alignForward(usize, width * bytes_per_pixel, 4);
    const pixel_size = std.math.mul(usize, row_size, height) catch return error.ImageTooLarge;
    const offset: usize = pixel_offset;
    if (offset > bytes.len or pixel_size > bytes.len - offset) return error.CorruptImage;

    const new_offset: usize = 14 + 108;
    const total = std.math.add(usize, new_offset, pixel_size) catch return error.ImageTooLarge;
    const output = try allocator.alloc(u8, total);
    errdefer allocator.free(output);
    @memset(output, 0);

    // File header: keep the magic, rewrite the size and pixel-data offset.
    @memcpy(output[0..2], bytes[0..2]);
    std.mem.writeInt(u32, output[2..6], @intCast(total), .little);
    std.mem.writeInt(u32, output[10..14], @intCast(new_offset), .little);

    // BITMAPV4HEADER: copy the 40-byte core, set the size and the positive
    // height, and add the 32-bit channel masks that zigimg expects.
    @memcpy(output[14 .. 14 + 40], bytes[14 .. 14 + 40]);
    std.mem.writeInt(u32, output[14..18], 108, .little);
    std.mem.writeInt(i32, output[22..26], @intCast(height), .little);
    if (bit_count == 32) {
        std.mem.writeInt(u32, output[30..34], 3, .little); // BI_BITFIELDS
        std.mem.writeInt(u32, output[54..58], 0x00FF0000, .little);
        std.mem.writeInt(u32, output[58..62], 0x0000FF00, .little);
        std.mem.writeInt(u32, output[62..66], 0x000000FF, .little);
        std.mem.writeInt(u32, output[66..70], 0xFF000000, .little);
    }

    const source = bytes[offset .. offset + pixel_size];
    const destination = output[new_offset..];
    if (top_down) {
        var row: usize = 0;
        while (row < height) : (row += 1) {
            @memcpy(
                destination[row * row_size ..][0..row_size],
                source[(height - 1 - row) * row_size ..][0..row_size],
            );
        }
    } else {
        @memcpy(destination, source);
    }
    return output;
}

fn encodePng(allocator: Allocator, image: *const zigimg.Image) (Allocator.Error || zigimg.Image.WriteError)![]u8 {
    // Filtered scanlines + zlib/PNG framing; deflate worst-case expansion is
    // tiny, so this bound is comfortably above the compressed size.
    const filtered = std.math.mul(usize, image.height, 1 + image.width * 4) catch return error.OutOfMemory;
    const bound = std.math.add(usize, filtered + filtered / 1000, 65536) catch return error.OutOfMemory;
    const buffer = try allocator.alloc(u8, bound);
    errdefer allocator.free(buffer);
    const written = try image.writeToMemory(allocator, buffer, .{ .png = .{} });
    if (written.len == 0) return error.InvalidData;
    if (written.len == buffer.len) return buffer;
    return try allocator.realloc(buffer, written.len);
}
