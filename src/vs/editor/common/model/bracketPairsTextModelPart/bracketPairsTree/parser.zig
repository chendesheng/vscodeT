// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/parser.ts`.
//
// Uses the ported `concat23Trees.ts` helpers for list construction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const ast = @import("./ast.zig");
const AstNode = ast.AstNode;
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
const BeforeEditPositionMapper = @import("./beforeEditPositionMapper.zig").BeforeEditPositionMapper;

pub const Parser = struct {
    allocator: Allocator,
    scratch: Allocator,
    region: *ast.NodeRegion,
    tokenizer: *Tokenizer,
    oldRoot: ?*AstNode = null,
    oldReader: ?NodeReader = null,
    positionMapper: ?BeforeEditPositionMapper = null,

    pub fn peek(self: *Parser) !?Token {
        try self.tokenizer.prepare();
        return self.tokenizer.peek();
    }

    pub fn parseList(self: *Parser, opened: SmallImmutableSet, level: usize) !*AstNode {
        var items = ArrayList(*AstNode).init(self.scratch);
        defer items.deinit();
        while (true) {
            if (try self.tryReadChildFromCache(opened)) |cached| {
                try items.append(cached);
                continue;
            }
            const token = (try self.peek()) orelse break;
            if (token.kind == .closing_bracket and token.bracket_ids.intersects(opened)) break;
            const child = try self.parseChild(opened, level + 1);
            if (child.kind == .list and child.data.list.children.items.len == 0) {
                child.release();
                continue;
            }
            try items.append(child);
        }
        const result = if (self.oldReader != null)
            try concat_mod.concat23TreesIn(self.allocator, self.scratch, items.items, self.region)
        else
            try concat_mod.concat23TreesOfSameHeightIn(self.allocator, self.scratch, items.items, self.region);
        return result orelse try ast.makeListIn(self.allocator, &.{}, 0, self.region);
    }

    fn tryReadChildFromCache(self: *Parser, opened: SmallImmutableSet) !?*AstNode {
        if (self.oldReader == null or self.positionMapper == null) return null;
        const maxCacheableLength = self.positionMapper.?.getDistanceToNextChange(self.tokenizer.offset);
        if (maxCacheableLength != null and lengthIsZero(maxCacheableLength.?)) return null;
        const oldOffset = self.positionMapper.?.getOffsetBeforeChange(self.tokenizer.offset);
        const cached = self.oldReader.?.readLongestNodeAt(oldOffset, opened, maxCacheableLength) orelse return null;
        self.tokenizer.skip(cached.length);
        return try self.region.retain(cached);
    }

    fn parseChild(self: *Parser, opened: SmallImmutableSet, level: usize) anyerror!*AstNode {
        const token = self.tokenizer.read().?;
        switch (token.kind) {
            .text => return try ast.makeTextIn(self.allocator, token.length, self.region),
            .closing_bracket => return try ast.makeInvalidIn(self.allocator, token, self.region),
            .opening_bracket => {
                if (level > 300) return try ast.makeTextIn(self.allocator, token.length, self.region);
                const opening = try ast.makeBracketIn(self.allocator, token, self.region);
                const child = try self.parseList(opened.merge(token.bracket_ids), level + 1);
                if (try self.peek()) |next| {
                    if (next.kind == .closing_bracket and next.bracket_ids.intersects(token.bracket_ids)) {
                        _ = self.tokenizer.read();
                        const closing = try ast.makeBracketIn(self.allocator, next, self.region);
                        return try ast.makePairIn(self.allocator, opening, child, closing, self.region);
                    }
                }
                return try ast.makePairIn(self.allocator, opening, child, null, self.region);
            },
        }
    }
};
