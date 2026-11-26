// Terminal subset of `src/vs/workbench/services/textfile/common/encoding.ts`.
//
// The synchronous terminal port covers BOM detection and UTF-8/UTF-16
// decode/encode. The streaming encoders/decoders and the heuristic
// `detectEncodingFromBuffer` guesses (which use jschardet/ICU in the browser
// and node hosts) are not ported; the exact reasons are documented in
// README.md and `docs/porting-inventory.md`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Encoding = enum {
    utf8,
    utf8_with_bom,
    utf16le,
    utf16be,
    utf16le_with_bom,
    utf16be_with_bom,
};

pub const BomInfo = struct {
    encoding: Encoding,
    /// Number of bytes occupied by the BOM.
    length: usize,
};

pub const UTF8_BOM = [_]u8{ 0xEF, 0xBB, 0xBF };
pub const UTF16LE_BOM = [_]u8{ 0xFF, 0xFE };
pub const UTF16BE_BOM = [_]u8{ 0xFE, 0xFF };

/// Detects a byte-order mark at the start of `bytes`.
pub fn detectBOM(bytes: []const u8) ?BomInfo {
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], &UTF8_BOM)) {
        return .{ .encoding = .utf8_with_bom, .length = 3 };
    }
    if (bytes.len >= 2 and std.mem.eql(u8, bytes[0..2], &UTF16LE_BOM)) {
        return .{ .encoding = .utf16le_with_bom, .length = 2 };
    }
    if (bytes.len >= 2 and std.mem.eql(u8, bytes[0..2], &UTF16BE_BOM)) {
        return .{ .encoding = .utf16be_with_bom, .length = 2 };
    }
    return null;
}

pub fn isUTF16(encoding: Encoding) bool {
    return switch (encoding) {
        .utf16le, .utf16be, .utf16le_with_bom, .utf16be_with_bom => true,
        else => false,
    };
}

pub fn hasBOM(encoding: Encoding) bool {
    return switch (encoding) {
        .utf8_with_bom, .utf16le_with_bom, .utf16be_with_bom => true,
        else => false,
    };
}

fn baseEncoding(encoding: Encoding) Encoding {
    return switch (encoding) {
        .utf8_with_bom => .utf8,
        .utf16le_with_bom => .utf16le,
        .utf16be_with_bom => .utf16be,
        else => encoding,
    };
}

pub const DecodedText = struct { text: []u8, encoding: Encoding };

/// The native text-file boundary for reads that require text. A NUL without
/// a UTF-16 BOM identifies binary data. Both disk and registered virtual
/// providers use the same decoding policy.
pub fn decodeText(allocator: Allocator, bytes: []const u8) !?DecodedText {
    const detected = if (detectBOM(bytes)) |bom| bom.encoding else Encoding.utf8;
    if (!isUTF16(detected) and std.mem.indexOfScalar(u8, bytes, 0) != null) return null;
    return .{ .text = try decode(allocator, bytes, detected), .encoding = detected };
}

/// Decodes `bytes` to UTF-8, stripping the BOM when present.
pub fn decode(allocator: Allocator, bytes: []const u8, encoding: Encoding) ![]u8 {
    var offset: usize = 0;
    if (detectBOM(bytes)) |bom| {
        if (bom.encoding == encoding or baseEncoding(bom.encoding) == baseEncoding(encoding)) {
            offset = bom.length;
        }
    }
    const content = bytes[offset..];

    return switch (baseEncoding(encoding)) {
        .utf8 => decodeUTF8(allocator, content),
        .utf16le => decodeUTF16(allocator, content, .little),
        .utf16be => decodeUTF16(allocator, content, .big),
        else => unreachable,
    };
}

/// VS Code decodes invalid UTF-8 sequences as U+FFFD instead of rejecting the
/// file. The terminal port does the same so opening a binary or mis-encoded
/// file as text (for example the image editor's "Open in Text Editor") cannot
/// feed invalid bytes into the text model.
fn decodeUTF8(allocator: Allocator, bytes: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return allocator.dupe(u8, bytes);

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    const replacement = [_]u8{ 0xEF, 0xBF, 0xBD };
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            try result.appendSlice(&replacement);
            index += 1;
            continue;
        };
        if (index + length > bytes.len or !std.unicode.utf8ValidateSlice(bytes[index .. index + length])) {
            try result.appendSlice(&replacement);
            index += 1;
            continue;
        }
        try result.appendSlice(bytes[index .. index + length]);
        index += length;
    }
    return result.toOwnedSlice();
}

fn decodeUTF16(allocator: Allocator, bytes: []const u8, endian: std.builtin.Endian) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 2) {
        const unit = std.mem.readInt(u16, bytes[index..][0..2], endian);
        var code_point: u21 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF and index + 3 < bytes.len) {
            const next = std.mem.readInt(u16, bytes[index + 2 ..][0..2], endian);
            if (next >= 0xDC00 and next <= 0xDFFF) {
                code_point = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (next - 0xDC00);
                index += 2;
            }
        }
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code_point, &buffer) catch {
            try result.appendSlice(&.{ 0xEF, 0xBF, 0xBD });
            continue;
        };
        try result.appendSlice(buffer[0..length]);
    }
    return result.toOwnedSlice();
}

/// Encodes UTF-8 `text` into `encoding`, adding the BOM for the `*_with_bom`
/// variants.
pub fn encode(allocator: Allocator, text: []const u8, encoding: Encoding) ![]u8 {
    switch (baseEncoding(encoding)) {
        .utf8 => {
            if (hasBOM(encoding)) {
                const result = try allocator.alloc(u8, UTF8_BOM.len + text.len);
                @memcpy(result[0..UTF8_BOM.len], &UTF8_BOM);
                @memcpy(result[UTF8_BOM.len..], text);
                return result;
            }
            return allocator.dupe(u8, text);
        },
        .utf16le => return encodeUTF16(allocator, text, .little, hasBOM(encoding)),
        .utf16be => return encodeUTF16(allocator, text, .big, hasBOM(encoding)),
        else => unreachable,
    }
}

fn encodeUTF16(allocator: Allocator, text: []const u8, endian: std.builtin.Endian, with_bom: bool) ![]u8 {
    var units = std.array_list.Managed(u16).init(allocator);
    defer units.deinit();
    if (with_bom) try units.append(0xFEFF);

    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const code_point = std.unicode.utf8Decode(text[index .. index + length]) catch 0xFFFD;
        index += length;
        if (code_point < 0x10000) {
            try units.append(@intCast(code_point));
        } else {
            const value = code_point - 0x10000;
            try units.append(@intCast(0xD800 + (value >> 10)));
            try units.append(@intCast(0xDC00 + (value & 0x3FF)));
        }
    }

    const result = try allocator.alloc(u8, units.items.len * 2);
    for (units.items, 0..) |unit, unit_index| {
        std.mem.writeInt(u16, result[unit_index * 2 ..][0..2], unit, endian);
    }
    return result;
}

test "encoding: invalid UTF-8 is decoded with replacement characters" {
    const allocator = std.testing.allocator;
    const decoded = try decode(allocator, &.{ 'a', 0x89, 0xFF, 'b' }, .utf8);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("a\u{FFFD}\u{FFFD}b", decoded);

    const valid = try decode(allocator, "caf\u{00E9}", .utf8);
    defer allocator.free(valid);
    try std.testing.expectEqualStrings("caf\u{00E9}", valid);
}
