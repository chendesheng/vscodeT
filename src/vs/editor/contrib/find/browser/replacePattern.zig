// Port of `src/vs/editor/contrib/find/browser/replacePattern.ts`.
//
// Ownership is arena-based: pieces and their static strings/case ops live in
// the pattern's arena, and `buildReplaceString` allocates its result with the
// caller's allocator.

const std = @import("std");
const search = @import("../../../../base/common/search.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum {
    static_value,
    dynamic_pieces,
};

/// A static string, or an index into the match array. Upstream's
/// `ReplacePiece` uses `staticValue === null` to distinguish the two.
pub const Piece = struct {
    static_value: ?[]const u8 = null,
    match_index: usize = 0,
    case_ops: []const u8 = &.{},

    pub fn staticValue(value: []const u8) Piece {
        return .{ .static_value = value };
    }

    pub fn matchIndex(index: usize) Piece {
        return .{ .match_index = index };
    }

    pub fn caseOps(index: usize, ops: []const u8) Piece {
        return .{ .match_index = index, .case_ops = ops };
    }
};

pub const ReplacePattern = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    kind: Kind = .static_value,
    static_value: []const u8 = "",
    pieces: []const Piece = &.{},

    pub fn init(allocator: Allocator, pieces: []const Piece) !ReplacePattern {
        var self = ReplacePattern{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.arena.deinit();

        const arena = self.arena.allocator();
        if (pieces.len == 0) {
            self.kind = .static_value;
            self.static_value = "";
            return self;
        }
        if (pieces.len == 1 and pieces[0].static_value != null) {
            self.kind = .static_value;
            self.static_value = try arena.dupe(u8, pieces[0].static_value.?);
            return self;
        }

        self.kind = .dynamic_pieces;
        const copied = try arena.alloc(Piece, pieces.len);
        for (pieces, 0..) |piece, index| {
            copied[index] = piece;
            if (piece.static_value) |value| {
                copied[index].static_value = try arena.dupe(u8, value);
            }
            copied[index].case_ops = try arena.dupe(u8, piece.case_ops);
        }
        self.pieces = copied;
        return self;
    }

    pub fn fromStaticValue(allocator: Allocator, value: []const u8) !ReplacePattern {
        return init(allocator, &.{Piece.staticValue(value)});
    }

    pub fn deinit(self: *ReplacePattern) void {
        self.arena.deinit();
    }

    pub fn hasReplacementPatterns(self: *const ReplacePattern) bool {
        return self.kind == .dynamic_pieces;
    }

    pub fn buildReplaceString(
        self: *const ReplacePattern,
        allocator: Allocator,
        matches: ?[]const []const u8,
        preserve_case: bool,
    ) ![]u8 {
        if (self.kind == .static_value) {
            if (preserve_case) {
                return search.buildReplaceStringWithCasePreserved(allocator, matches, self.static_value);
            }
            return allocator.dupe(u8, self.static_value);
        }

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        for (self.pieces) |piece| {
            if (piece.static_value) |value| {
                try result.appendSlice(allocator, value);
                continue;
            }

            const start = result.items.len;
            try appendSubstitute(&result, allocator, piece.match_index, matches);
            if (piece.case_ops.len > 0) {
                applyCaseOps(result.items[start..], piece.case_ops);
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

fn appendSubstitute(
    result: *std.ArrayList(u8),
    allocator: Allocator,
    match_index: usize,
    matches: ?[]const []const u8,
) !void {
    const values = matches orelse return;
    if (match_index == 0) {
        if (values.len > 0) try result.appendSlice(allocator, values[0]);
        return;
    }

    var remainder: [32]u8 = undefined;
    var remainder_len: usize = 0;
    var index = match_index;
    while (index > 0) {
        if (index < values.len) {
            try result.appendSlice(allocator, values[index]);
            var digit = remainder_len;
            while (digit > 0) {
                digit -= 1;
                try result.append(allocator, remainder[digit]);
            }
            return;
        }
        if (remainder_len == remainder.len) break;
        remainder[remainder_len] = '0' + @as(u8, @intCast(index % 10));
        remainder_len += 1;
        index /= 10;
    }

    try result.append(allocator, '$');
    var digit = remainder_len;
    while (digit > 0) {
        digit -= 1;
        try result.append(allocator, remainder[digit]);
    }
}

/// Applies `\U`, `\u`, `\L`, `\l` to the substituted text. Case mapping is
/// ASCII-only (see `search.zig`), but a non-ASCII codepoint still consumes one
/// `u`/`l` operation, as a UTF-16 code unit does upstream.
fn applyCaseOps(buffer: []u8, ops: []const u8) void {
    var op_index: usize = 0;
    var offset: usize = 0;
    while (offset < buffer.len) {
        if (op_index >= ops.len) return;
        const length = std.unicode.utf8ByteSequenceLength(buffer[offset]) catch 1;
        const end = @min(offset + length, buffer.len);
        switch (ops[op_index]) {
            'U' => buffer[offset] = std.ascii.toUpper(buffer[offset]),
            'u' => {
                buffer[offset] = std.ascii.toUpper(buffer[offset]);
                op_index += 1;
            },
            'L' => buffer[offset] = std.ascii.toLower(buffer[offset]),
            'l' => {
                buffer[offset] = std.ascii.toLower(buffer[offset]);
                op_index += 1;
            },
            else => {},
        }
        offset = end;
    }
}

const Builder = struct {
    outer: Allocator,
    arena: Allocator,
    source: []const u8,
    last: usize = 0,
    pieces: std.array_list.Managed(Piece),
    current_static: std.array_list.Managed(u8),

    fn init(outer: Allocator, arena: Allocator, source: []const u8) Builder {
        return .{
            .outer = outer,
            .arena = arena,
            .source = source,
            .pieces = std.array_list.Managed(Piece).init(outer),
            .current_static = std.array_list.Managed(u8).init(outer),
        };
    }

    fn deinit(self: *Builder) void {
        self.pieces.deinit();
        self.current_static.deinit();
    }

    fn emitUnchanged(self: *Builder, to: usize) !void {
        try self.current_static.appendSlice(self.source[self.last..to]);
        self.last = to;
    }

    fn emitStatic(self: *Builder, value: []const u8, to: usize) !void {
        try self.current_static.appendSlice(value);
        self.last = to;
    }

    fn emitMatchIndex(self: *Builder, index: usize, to: usize, case_ops: []const u8) !void {
        if (self.current_static.items.len != 0) {
            try self.pieces.append(.{ .static_value = try self.arena.dupe(u8, self.current_static.items) });
            self.current_static.clearRetainingCapacity();
        }
        try self.pieces.append(.{
            .match_index = index,
            .case_ops = try self.arena.dupe(u8, case_ops),
        });
        self.last = to;
    }

    fn finalize(self: *Builder) !ReplacePattern {
        try self.emitUnchanged(self.source.len);
        if (self.current_static.items.len != 0) {
            try self.pieces.append(.{ .static_value = try self.arena.dupe(u8, self.current_static.items) });
            self.current_static.clearRetainingCapacity();
        }
        return ReplacePattern.init(self.outer, self.pieces.items);
    }
};

pub fn parseReplaceString(allocator: Allocator, replace_string: []const u8) !ReplacePattern {
    if (replace_string.len == 0) {
        return ReplacePattern.init(allocator, &.{});
    }

    var temp = std.heap.ArenaAllocator.init(allocator);
    defer temp.deinit();

    var builder = Builder.init(allocator, temp.allocator(), replace_string);
    defer builder.deinit();

    var case_ops = std.array_list.Managed(u8).init(allocator);
    defer case_ops.deinit();

    const length = replace_string.len;
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const byte = replace_string[index];

        if (byte == '\\') {
            index += 1;
            if (index >= length) break;

            switch (replace_string[index]) {
                '\\' => {
                    try builder.emitUnchanged(index - 1);
                    try builder.emitStatic("\\", index + 1);
                },
                'n' => {
                    try builder.emitUnchanged(index - 1);
                    try builder.emitStatic("\n", index + 1);
                },
                't' => {
                    try builder.emitUnchanged(index - 1);
                    try builder.emitStatic("\t", index + 1);
                },
                'u', 'U', 'l', 'L' => {
                    try builder.emitUnchanged(index - 1);
                    try builder.emitStatic("", index + 1);
                    try case_ops.append(replace_string[index]);
                },
                else => {},
            }
            continue;
        }

        if (byte != '$') continue;

        index += 1;
        if (index >= length) break;

        const next = replace_string[index];
        if (next == '$') {
            try builder.emitUnchanged(index - 1);
            try builder.emitStatic("$", index + 1);
            continue;
        }

        if (next == '0' or next == '&') {
            try builder.emitUnchanged(index - 1);
            try builder.emitMatchIndex(0, index + 1, case_ops.items);
            case_ops.clearRetainingCapacity();
            continue;
        }

        if (next >= '1' and next <= '9') {
            var match_index: usize = next - '0';
            if (index + 1 < length) {
                const next_next = replace_string[index + 1];
                if (next_next >= '0' and next_next <= '9') {
                    index += 1;
                    match_index = match_index * 10 + (next_next - '0');
                    try builder.emitUnchanged(index - 2);
                    try builder.emitMatchIndex(match_index, index + 1, case_ops.items);
                    case_ops.clearRetainingCapacity();
                    continue;
                }
            }
            try builder.emitUnchanged(index - 1);
            try builder.emitMatchIndex(match_index, index + 1, case_ops.items);
            case_ops.clearRetainingCapacity();
        }
    }

    return builder.finalize();
}
