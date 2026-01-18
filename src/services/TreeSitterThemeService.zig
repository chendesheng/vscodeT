const std = @import("std");
const Allocator = std.mem.Allocator;
const TreeSitterTree = @import("../tokenize/treeSitter/TreeSitterTree.zig").TreeSitterTree;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const Emitter = @import("../basics/event.zig").Emitter;

const Self = @This();

_onChange: Emitter(void),

pub fn init(allocator: Allocator) Self {
    return Self{
        ._onChange = Emitter(void).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self._onChange.deinit();
}

pub fn findMetadata(self: *const Self, captureNames: []const []const u8, languageId: u32, bracket: bool) TokenMetadata {
    _ = self;
    _ = captureNames;
    _ = languageId;
    _ = bracket;
    return .default;
}

pub fn onChange(self: *Self, ctx: anytype, callback: fn (ctx: @TypeOf(ctx)) anyerror!void) !void {
    try self._onChange.event(ctx, struct {
        fn cb(_: void, ctx_: @TypeOf(ctx)) void {
            callback(ctx_) catch unreachable;
        }
    }.cb);
}
