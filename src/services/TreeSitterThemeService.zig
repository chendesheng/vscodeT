const std = @import("std");
const Allocator = std.mem.Allocator;
const TreeSitterTree = @import("../tokenize/treeSitter/treeSitterTree.zig").TreeSitterTree;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const Emitter = @import("../basics/event.zig").Emitter;

const Self = @This();

onChange: Emitter(void),

pub fn init(allocator: Allocator) Self {
    return Self{
        .onChange = Emitter(void).init(allocator),
    };
}

pub fn findMetadata(self: *const Self, captureNames: []const []const u8, languageId: u32, bracket: bool) TokenMetadata {
    _ = self;
    _ = captureNames;
    _ = languageId;
    _ = bracket;
    return .default;
}
