// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/parser.ts`.
//
// Uses the ported `concat23Trees.ts` helpers for list construction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const ast = @import("./ast.zig");
const AstNode = ast.AstNode;
const makeText = ast.makeText;
const makeBracket = ast.makeBracket;
const makeInvalid = ast.makeInvalid;
const makePair = ast.makePair;
const makeList = ast.makeList;
const makeEmptyList = ast.makeEmptyList;
const Length = @import("./length.zig").Length;
const lengthAdd = @import("./length.zig").lengthAdd;
const lengthIsZero = @import("./length.zig").lengthIsZero;
const set_mod = @import("./smallImmutableSet.zig");
const SmallImmutableSet = set_mod.SmallImmutableSet;
const tokenizer_mod = @import("./tokenizer.zig");
const Token = tokenizer_mod.Token;
const Tokenizer = tokenizer_mod.Tokenizer;
const NodeReader = @import("./nodeReader.zig").NodeReader;
const concat_mod = @import("./concat23Trees.zig");
const concat23Trees = concat_mod.concat23Trees;
const concat23TreesOfSameHeight = concat_mod.concat23TreesOfSameHeight;
const BeforeEditPositionMapper = @import("./beforeEditPositionMapper.zig").BeforeEditPositionMapper;

pub const Parser = struct {
    allocator: Allocator,
    tokenizer: *Tokenizer,
    oldRoot: ?*AstNode = null,
    oldReader: ?NodeReader = null,
    positionMapper: ?BeforeEditPositionMapper = null,

    pub fn peek(self: *Parser) ?Token {
        return self.tokenizer.peek();
    }

    pub fn parseList(self: *Parser, opened: SmallImmutableSet, level: usize) !*AstNode {
        var items = ArrayList(*AstNode).init(self.allocator);
        while (true) {
            if (try self.tryReadChildFromCache(opened)) |cached| {
                try items.append(cached);
                continue;
            }
            const token = self.peek() orelse break;
            if (token.kind == .closing_bracket and token.bracket_ids.intersects(opened)) break;
            const child = try self.parseChild(opened, level + 1);
            if (child.kind == .list and child.data.list.children.items.len == 0) continue;
            try items.append(child);
        }
        const result = if (self.oldReader != null)
            try concat23Trees(self.allocator, items.items)
        else
            try concat23TreesOfSameHeight(self.allocator, items.items);
        return result orelse try makeEmptyList(self.allocator);
    }

    fn tryReadChildFromCache(self: *Parser, opened: SmallImmutableSet) !?*AstNode {
        if (self.oldReader == null or self.positionMapper == null) return null;
        const maxCacheableLength = self.positionMapper.?.getDistanceToNextChange(self.tokenizer.offset);
        if (maxCacheableLength != null and lengthIsZero(maxCacheableLength.?)) return null;
        const oldOffset = self.positionMapper.?.getOffsetBeforeChange(self.tokenizer.offset);
        const cached = self.oldReader.?.readLongestNodeAt(oldOffset, opened, maxCacheableLength) orelse return null;
        self.tokenizer.skip(cached.length);
        return try cached.clone(self.allocator);
    }

    fn parseChild(self: *Parser, opened: SmallImmutableSet, level: usize) anyerror!*AstNode {
        const token = self.tokenizer.read().?;
        switch (token.kind) {
            .text => return try makeText(self.allocator, token.length),
            .closing_bracket => return try makeInvalid(self.allocator, token),
            .opening_bracket => {
                if (level > 300) return try makeText(self.allocator, token.length);
                const opening = try makeBracket(self.allocator, token);
                const child = try self.parseList(opened.merge(token.bracket_ids), level + 1);
                if (self.peek()) |next| {
                    if (next.kind == .closing_bracket and next.bracket_ids.intersects(token.bracket_ids)) {
                        _ = self.tokenizer.read();
                        const closing = try makeBracket(self.allocator, next);
                        return try makePair(self.allocator, opening, child, closing);
                    }
                }
                return try makePair(self.allocator, opening, child, null);
            },
        }
    }
};
