// Minimal synchronous port of
// `src/vs/editor/contrib/documentSymbols/browser/outlineModel.ts`.
//
// Deferred: the LRU cache, debounce, cancellation and provider-group UI. The
// portable tree, duplicate-id handling, position lookup and breadcrumb chain
// are ported for the terminal breadcrumb bar.

const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

pub const OutlineElement = struct {
    symbol: languages.DocumentSymbol,
    children: []*OutlineElement = &.{},
};

pub const OutlineModel = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    roots: []*OutlineElement = &.{},

    pub fn create(allocator: Allocator, model: *TextModel, provider: languages.DocumentSymbolProvider) !*OutlineModel {
        const self = try allocator.create(OutlineModel);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer {
            self.arena.deinit();
            allocator.destroy(self);
        }
        const arena = self.arena.allocator();
        const symbols = provider.provide_document_symbols(
            provider.context,
            arena,
            model,
            CancellationToken.None,
        ) catch &.{};
        var roots = std.array_list.Managed(*OutlineElement).init(arena);
        for (symbols) |symbol| try roots.append(try buildElement(arena, symbol));
        self.roots = try roots.toOwnedSlice();
        return self;
    }

    fn buildElement(arena: Allocator, symbol: languages.DocumentSymbol) !*OutlineElement {
        const element = try arena.create(OutlineElement);
        element.* = .{ .symbol = symbol };
        var children = std.array_list.Managed(*OutlineElement).init(arena);
        for (symbol.children) |child| try children.append(try buildElement(arena, child));
        element.children = try children.toOwnedSlice();
        return element;
    }

    pub fn deinit(self: *OutlineModel) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Returns the root-to-deepest path whose symbol range contains `position`.
    pub fn elementChain(self: *const OutlineModel, allocator: Allocator, position: Position) ![]*OutlineElement {
        var chain = std.array_list.Managed(*OutlineElement).init(allocator);
        errdefer chain.deinit();
        var current = self.roots;
        while (true) {
            var found: ?*OutlineElement = null;
            for (current) |element| {
                if (contains(element.symbol.range, position)) {
                    found = element;
                    break;
                }
            }
            if (found == null) break;
            try chain.append(found.?);
            current = found.?.children;
        }
        return chain.toOwnedSlice();
    }
};

fn contains(range: Range, position: Position) bool {
    var owned_range = range;
    var owned_position = position;
    return owned_range.containsPosition(&owned_position);
}
