// Port of `src/vs/editor/common/services/semanticTokensDto.ts`.
//
// The upstream module converts semantic token DTOs to and from a little endian
// `VSBuffer`. There is no `VSBuffer` here, so the encoded form is a plain byte
// slice. The decoder owns everything it returns, because Zig has no zero-copy
// typed views over aligned buffers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

pub const EncodedSemanticTokensType = enum(u32) {
    full = 1,
    delta = 2,
};

/// A single delta edit of a `DeltaSemanticTokensDto`; `data` is `null` when the
/// delta only deletes tokens.
pub const Delta = struct {
    start: u32,
    delete_count: u32,
    data: ?[]const u32 = null,
};

pub const FullSemanticTokensDto = struct {
    id: u32,
    data: []const u32,
};

pub const DeltaSemanticTokensDto = struct {
    id: u32,
    deltas: []const Delta,
};

pub const SemanticTokensDto = union(enum) {
    full: FullSemanticTokensDto,
    delta: DeltaSemanticTokensDto,

    pub fn id(self: SemanticTokensDto) u32 {
        return switch (self) {
            .full => |full| full.id,
            .delta => |delta| delta.id,
        };
    }
};

/// A decoded delta edit. `data` is empty when the encoded delta had no payload.
pub const DecodedDelta = struct {
    start: u32,
    delete_count: u32,
    data: []u32,
};

pub const DecodedPayload = union(enum) {
    full: []u32,
    delta: []DecodedDelta,
};

/// The owned result of `decodeSemanticTokensDto`.
pub const DecodedSemanticTokensDto = struct {
    allocator: Allocator,
    id: u32,
    payload: DecodedPayload,

    pub fn deinit(self: *DecodedSemanticTokensDto) void {
        switch (self.payload) {
            .full => |data| if (data.len > 0) self.allocator.free(data),
            .delta => |deltas| {
                for (deltas) |delta| {
                    if (delta.data.len > 0) self.allocator.free(delta.data);
                }
                if (deltas.len > 0) self.allocator.free(deltas);
            },
        }
    }

    pub fn kind(self: DecodedSemanticTokensDto) EncodedSemanticTokensType {
        return switch (self.payload) {
            .full => .full,
            .delta => .delta,
        };
    }
};

pub fn encodeSemanticTokensDto(allocator: Allocator, semanticTokens: SemanticTokensDto) ![]u8 {
    const words = encodeSemanticTokensDtoSize(semanticTokens);
    const buffer = try allocator.alloc(u8, words * 4);
    errdefer allocator.free(buffer);

    var offset: usize = 0;
    writeU32(buffer, &offset, semanticTokens.id());
    switch (semanticTokens) {
        .full => |full| {
            writeU32(buffer, &offset, @backingInt(EncodedSemanticTokensType.full));
            writeU32(buffer, &offset, @intCast(full.data.len));
            for (full.data) |value| writeU32(buffer, &offset, value);
        },
        .delta => |delta| {
            writeU32(buffer, &offset, @backingInt(EncodedSemanticTokensType.delta));
            writeU32(buffer, &offset, @intCast(delta.deltas.len));
            for (delta.deltas) |edit| {
                writeU32(buffer, &offset, edit.start);
                writeU32(buffer, &offset, edit.delete_count);
                if (edit.data) |data| {
                    writeU32(buffer, &offset, @intCast(data.len));
                    for (data) |value| writeU32(buffer, &offset, value);
                } else {
                    writeU32(buffer, &offset, 0);
                }
            }
        },
    }
    std.debug.assert(offset == buffer.len);
    return buffer;
}

/// The size of the encoded DTO, in 32 bit words.
pub fn encodeSemanticTokensDtoSize(semanticTokens: SemanticTokensDto) usize {
    var result: usize = 0;
    // id + type
    result += 2;
    switch (semanticTokens) {
        .full => |full| {
            // data length + data
            result += 1 + full.data.len;
        },
        .delta => |delta| {
            // delta count
            result += 1;
            // start + delete count + data length, per delta
            result += 3 * delta.deltas.len;
            for (delta.deltas) |edit| {
                if (edit.data) |data| result += data.len;
            }
        },
    }
    return result;
}

/// Decodes an encoded DTO. The returned value owns its data.
pub fn decodeSemanticTokensDto(allocator: Allocator, buff: []const u8) !DecodedSemanticTokensDto {
    if (buff.len % 4 != 0) return error.InvalidSemanticTokensBuffer;
    const word_count = buff.len / 4;
    var offset: usize = 0;

    const id = try readU32(buff, word_count, &offset);
    const encoded_type: EncodedSemanticTokensType = switch (try readU32(buff, word_count, &offset)) {
        @backingInt(EncodedSemanticTokensType.full) => .full,
        @backingInt(EncodedSemanticTokensType.delta) => .delta,
        else => return error.InvalidSemanticTokensBuffer,
    };

    if (encoded_type == .full) {
        const length = try readU32(buff, word_count, &offset);
        const data = try allocator.alloc(u32, length);
        errdefer allocator.free(data);
        for (data) |*value| value.* = try readU32(buff, word_count, &offset);
        return .{ .allocator = allocator, .id = id, .payload = .{ .full = data } };
    }

    const delta_count = try readU32(buff, word_count, &offset);
    const deltas = try allocator.alloc(DecodedDelta, delta_count);
    errdefer allocator.free(deltas);
    var initialized: usize = 0;
    errdefer for (deltas[0..initialized]) |delta| {
        if (delta.data.len > 0) allocator.free(delta.data);
    };
    for (deltas) |*delta| {
        delta.data = &.{};
        const start = try readU32(buff, word_count, &offset);
        const delete_count = try readU32(buff, word_count, &offset);
        const length = try readU32(buff, word_count, &offset);
        if (length > 0) {
            const data = try allocator.alloc(u32, length);
            for (data) |*value| value.* = try readU32(buff, word_count, &offset);
            delta.* = .{ .start = start, .delete_count = delete_count, .data = data };
        } else {
            delta.* = .{ .start = start, .delete_count = delete_count, .data = &.{} };
        }
        initialized += 1;
    }
    return .{ .allocator = allocator, .id = id, .payload = .{ .delta = deltas } };
}

fn writeU32(buffer: []u8, offset: *usize, value: u32) void {
    std.mem.writeInt(u32, buffer[offset.*..][0..4], value, .little);
    offset.* += 4;
}

fn readU32(buff: []const u8, word_count: usize, offset: *usize) !u32 {
    if (offset.* / 4 >= word_count) return error.InvalidSemanticTokensBuffer;
    const value = std.mem.readInt(u32, buff[offset.*..][0..4], .little);
    offset.* += 4;
    return value;
}

test "semanticTokensDto: round-trips a full DTO" {
    const allocator = std.testing.allocator;
    const encoded = try encodeSemanticTokensDto(allocator, .{ .full = .{ .id = 7, .data = &.{ 1, 2, 3, 4, 5 } } });
    defer allocator.free(encoded);
    try std.testing.expectEqual(@as(usize, 8 * 4), encoded.len);

    var decoded = try decodeSemanticTokensDto(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 7), decoded.id);
    try std.testing.expectEqual(EncodedSemanticTokensType.full, decoded.kind());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5 }, decoded.payload.full);
}

test "semanticTokensDto: round-trips a delta DTO" {
    const allocator = std.testing.allocator;
    const deltas = [_]Delta{
        .{ .start = 0, .delete_count = 2, .data = &.{ 9, 8 } },
        .{ .start = 6, .delete_count = 1 },
        .{ .start = 7, .delete_count = 0, .data = &.{} },
    };
    // 2 (header) + 1 (count) + (3 + 2) + 3 + 3 words
    const encoded = try encodeSemanticTokensDto(allocator, .{ .delta = .{ .id = 42, .deltas = &deltas } });
    defer allocator.free(encoded);
    try std.testing.expectEqual(@as(usize, 14 * 4), encoded.len);

    var decoded = try decodeSemanticTokensDto(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 42), decoded.id);
    try std.testing.expectEqual(EncodedSemanticTokensType.delta, decoded.kind());

    const round_tripped = decoded.payload.delta;
    try std.testing.expectEqual(@as(usize, 3), round_tripped.len);
    try std.testing.expectEqual(@as(u32, 0), round_tripped[0].start);
    try std.testing.expectEqual(@as(u32, 2), round_tripped[0].delete_count);
    try std.testing.expectEqualSlices(u32, &.{ 9, 8 }, round_tripped[0].data);
    try std.testing.expectEqual(@as(u32, 6), round_tripped[1].start);
    try std.testing.expectEqual(@as(u32, 1), round_tripped[1].delete_count);
    try std.testing.expectEqual(@as(usize, 0), round_tripped[1].data.len);
    try std.testing.expectEqual(@as(usize, 0), round_tripped[2].data.len);
}

test "semanticTokensDto: rejects a truncated buffer" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidSemanticTokensBuffer, decodeSemanticTokensDto(allocator, &.{ 1, 2, 3 }));
    // A full DTO that claims five words of data but carries none.
    const truncated = [_]u8{ 0, 0, 0, 0 } ++ [_]u8{ 1, 0, 0, 0 } ++ [_]u8{ 5, 0, 0, 0 };
    try std.testing.expectError(error.InvalidSemanticTokensBuffer, decodeSemanticTokensDto(allocator, &truncated));
}
