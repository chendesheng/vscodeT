// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/ast.ts`.
//
// Node lengths are UTF-8 byte lengths; the AST is immutable from the query
// side and built from the parser's arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../../textModel.zig").TextModel;
const CursorColumns = @import("../../../core/cursorColumns.zig").CursorColumns;
const length_mod = @import("./length.zig");
const Length = length_mod.Length;
const lengthAdd = length_mod.lengthAdd;
const lengthLineCount = length_mod.lengthLineCount;
const lengthColumnCount = length_mod.lengthColumnCount;
const set_mod = @import("./smallImmutableSet.zig");
const SmallImmutableSet = set_mod.SmallImmutableSet;
const tokenizer_mod = @import("./tokenizer.zig");
const Token = tokenizer_mod.Token;
const BracketInfo = tokenizer_mod.BracketInfo;

pub const NodeKind = enum { text, bracket, pair, invalid_bracket, list };

pub const Data = union(enum) {
    text: void,
    bracket: BracketData,
    pair: PairData,
    invalid_bracket: InvalidData,
    list: ListData,
};

pub const BracketData = struct {
    info: BracketInfo,
    bracket_ids: SmallImmutableSet,
    colorized_bracket_ids: SmallImmutableSet = .{},
};

pub const PairData = struct {
    opening: *AstNode,
    child: ?*AstNode,
    closing: ?*AstNode,
};

pub const InvalidData = struct {
    info: BracketInfo,
    missing: SmallImmutableSet,
};

pub const ListData = struct {
    children: ArrayList(*AstNode),
    mutable: bool,
    cached_min_indentation: i64 = -1,
};

pub const AstNode = struct {
    kind: NodeKind,
    length: Length,
    list_height: u32,
    missing: SmallImmutableSet,
    data: Data,

    pub fn childrenLength(self: *const AstNode) usize {
        return switch (self.data) {
            .text, .bracket, .invalid_bracket => 0,
            .pair => blk: {
                const pair = self.data.pair;
                break :blk 1 + @as(usize, if (pair.child != null) 1 else 0) + @as(usize, if (pair.closing != null) 1 else 0);
            },
            .list => self.data.list.children.items.len,
        };
    }

    pub fn child(self: *const AstNode, index: usize) ?*AstNode {
        return switch (self.data) {
            .pair => |pair| switch (index) {
                0 => pair.opening,
                1 => pair.child,
                2 => pair.closing,
                else => null,
            },
            .list => |list| if (index < list.children.items.len) list.children.items[index] else null,
            else => null,
        };
    }

    pub fn clone(self: *const AstNode, allocator: Allocator) !*AstNode {
        const node = try allocator.create(AstNode);
        node.* = self.*;
        switch (self.data) {
            .text => {},
            .bracket => {},
            .invalid_bracket => {},
            .pair => |pair| {
                node.data.pair.opening = try pair.opening.clone(allocator);
                node.data.pair.child = if (pair.child) |c| try c.clone(allocator) else null;
                node.data.pair.closing = if (pair.closing) |closing| try closing.clone(allocator) else null;
            },
            .list => |list| {
                var children = ArrayList(*AstNode).init(allocator);
                for (list.children.items) |c| try children.append(try c.clone(allocator));
                node.data.list.children = children;
                node.data.list.mutable = true;
            },
        }
        return node;
    }

    pub fn canBeReused(self: *const AstNode, opened: SmallImmutableSet) bool {
        return switch (self.data) {
            .text => true,
            .invalid_bracket => false,
            .bracket => false,
            .pair => |pair| pair.closing != null and !opened.intersects(self.missing),
            .list => |list| list.children.items.len > 0 and !opened.intersects(self.missing),
        };
    }
};

/// Upstream uses `Number.MAX_SAFE_INTEGER` for "no indentation found".
pub const max_safe_integer: i64 = 9007199254740991;

/// Upstream `AstNode.computeMinIndentation`.
///
/// The minimum visible column of the first non-whitespace character in the
/// subtree's text. Text nodes that start mid-line contribute nothing for that
/// first line (the tokenizer guarantees they have no partial indentation).
/// Bracket leaf nodes contribute nothing.
pub fn computeMinIndentation(node: *AstNode, offset: Length, model: *TextModel) anyerror!i64 {
    switch (node.data) {
        .text => {
            const start_line_count = lengthLineCount(offset);
            const start_column_count = lengthColumnCount(offset);
            const start_line_number = (if (start_column_count == 0) start_line_count else start_line_count + 1) + 1;
            const end_line_number = lengthLineCount(lengthAdd(offset, node.length)) + 1;

            var result = max_safe_integer;
            var line_number = start_line_number;
            while (line_number <= end_line_number) : (line_number += 1) {
                const first_non_ws_column = try model.getLineFirstNonWhitespaceColumn(line_number);
                if (first_non_ws_column == 0) continue;

                var line_content = try model.getLineContent(line_number);
                defer line_content.deinit();
                const visible_column = CursorColumns.visibleColumnFromColumn(
                    line_content.items,
                    first_non_ws_column,
                    model.getOptions().tabSize,
                );
                result = @min(result, @as(i64, @intCast(visible_column)));
            }
            return result;
        },
        .bracket, .invalid_bracket => return max_safe_integer,
        .pair => |pair| {
            if (pair.child) |child| {
                return computeMinIndentation(child, lengthAdd(offset, pair.opening.length), model);
            }
            return max_safe_integer;
        },
        .list => |*list| {
            if (list.cached_min_indentation != -1) {
                return list.cached_min_indentation;
            }

            var min_indentation = max_safe_integer;
            var child_offset = offset;
            for (list.children.items) |child| {
                min_indentation = @min(min_indentation, try computeMinIndentation(child, child_offset, model));
                child_offset = lengthAdd(child_offset, child.length);
            }

            list.cached_min_indentation = min_indentation;
            return min_indentation;
        },
    }
}

pub fn allocNode(allocator: Allocator) !*AstNode {
    return try allocator.create(AstNode);
}

pub fn makeText(allocator: Allocator, length: Length) !*AstNode {
    const node = try allocNode(allocator);
    node.* = .{ .kind = .text, .length = length, .list_height = 0, .missing = SmallImmutableSet.empty(), .data = .{ .text = {} } };
    return node;
}

pub fn makeBracket(allocator: Allocator, token: Token) !*AstNode {
    const node = try allocNode(allocator);
    node.* = .{
        .kind = .bracket,
        .length = token.length,
        .list_height = 0,
        .missing = SmallImmutableSet.empty(),
        .data = .{ .bracket = .{
            .info = token.bracket.?,
            .bracket_ids = token.bracket_ids,
            .colorized_bracket_ids = token.colorized_bracket_ids,
        } },
    };
    return node;
}

pub fn makeInvalid(allocator: Allocator, token: Token) !*AstNode {
    const node = try allocNode(allocator);
    node.* = .{
        .kind = .invalid_bracket,
        .length = token.length,
        .list_height = 0,
        .missing = token.bracket_ids,
        .data = .{ .invalid_bracket = .{ .info = token.bracket.?, .missing = token.bracket_ids } },
    };
    return node;
}

pub fn makePair(allocator: Allocator, opening: *AstNode, child: *AstNode, closing: ?*AstNode) !*AstNode {
    const node = try allocNode(allocator);
    var length = opening.length;
    length = lengthAdd(length, child.length);
    if (closing) |c| length = lengthAdd(length, c.length);
    node.* = .{
        .kind = .pair,
        .length = length,
        .list_height = 0,
        .missing = child.missing,
        .data = .{ .pair = .{ .opening = opening, .child = child, .closing = closing } },
    };
    return node;
}

pub fn makeList(allocator: Allocator, items: []*AstNode, height: u32) !*AstNode {
    var children = ArrayList(*AstNode).init(allocator);
    try children.appendSlice(items);
    var length: Length = 0;
    var missing = SmallImmutableSet.empty();
    for (items) |item| {
        length = lengthAdd(length, item.length);
        missing = missing.merge(item.missing);
    }
    const node = try allocNode(allocator);
    node.* = .{
        .kind = .list,
        .length = length,
        .list_height = height,
        .missing = missing,
        .data = .{ .list = .{ .children = children, .mutable = true } },
    };
    return node;
}

pub fn makeEmptyList(allocator: Allocator) !*AstNode {
    return try makeList(allocator, &[_]*AstNode{}, 0);
}
