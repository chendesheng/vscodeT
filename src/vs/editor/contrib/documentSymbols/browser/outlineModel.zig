// Port of `src/vs/editor/contrib/documentSymbols/browser/outlineModel.ts`.
//
// The portable tree, provider groups, duplicate-id handling, marker rollup,
// position lookup and breadcrumb chain are ported. The browser file's
// `OutlineModelService` LRU cache, cancellation plumbing and debounce
// information are not part of this module; the terminal outline pane debounces
// rebuilds through the main loop and the breadcrumbs create their outline
// synchronously (documented in `README.md` and `docs/terminal-ui.md`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const range_mod = @import("../../../common/core/range.zig");
const Range = range_mod.Range;
const MarkerSeverity = @import("../../../../platform/markers/common/markers.zig").MarkerSeverity;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

/// Upstream `IOutlineMarker`: the range and severity of a problem attached to
/// an outline element. `textModelEvents` markers keep the same shape.
pub const OutlineMarker = struct {
    range: Range,
    severity: u32,
};

/// Upstream `OutlineElement.marker` rollup.
pub const MarkerInfo = struct {
    count: usize,
    top_severity: u32,
};

pub const OutlineElement = struct {
    /// Stable identity within the outline model, matching upstream
    /// `TreeElement.id` (provider/name/line/column with duplicate suffixes).
    id: []const u8 = "",
    symbol: languages.DocumentSymbol,
    children: []*OutlineElement = &.{},
    marker: ?MarkerInfo = null,
    /// Parent symbol for breadcrumb sibling lookup. Top-level elements keep
    /// null, matching `TreeElement.parent === OutlineModel`.
    parent: ?*OutlineElement = null,
};

pub const OutlineGroup = struct {
    id: []const u8 = "",
    label: []const u8 = "",
    order: usize = 0,
    children: []*OutlineElement = &.{},
};

pub const OutlineModel = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    /// Provider groups. A single non-empty provider is compacted, exactly like
    /// upstream `_compact`: `roots` then holds that provider's elements.
    groups: []*OutlineGroup = &.{},
    roots: []*OutlineElement = &.{},

    pub fn create(allocator: Allocator, model: *TextModel, provider: languages.DocumentSymbolProvider) !*OutlineModel {
        return createWithProviders(allocator, model, &.{provider});
    }

    pub fn createWithProviders(
        allocator: Allocator,
        model: *TextModel,
        providers: []const languages.DocumentSymbolProvider,
    ) !*OutlineModel {
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
        var groups = std.array_list.Managed(*OutlineGroup).init(arena);

        for (providers, 0..) |provider, index| {
            const group = try arena.create(OutlineGroup);
            group.* = .{
                .id = try std.fmt.allocPrint(arena, "root/provider_{d}", .{index}),
                .label = provider.display_name,
                .order = index,
            };
            const symbols = provider.provide_document_symbols(
                provider.context,
                arena,
                model,
                CancellationToken.None,
            ) catch &.{};
            var children = std.array_list.Managed(*OutlineElement).init(arena);
            for (symbols) |symbol| {
                try children.append(try buildElement(arena, group.id, symbol, children.items, null));
            }
            group.children = try children.toOwnedSlice();
            if (group.children.len > 0) try groups.append(group);
        }

        self.groups = try groups.toOwnedSlice();
        if (self.groups.len == 1) {
            self.roots = self.groups[0].children;
        } else if (self.groups.len > 1) {
            // The terminal outline view has one provider group per row section;
            // expose all element roots for callers that only flatten the tree.
            var roots = std.array_list.Managed(*OutlineElement).init(arena);
            for (self.groups) |group| try roots.appendSlice(group.children);
            self.roots = try roots.toOwnedSlice();
        }
        return self;
    }

    fn buildElement(
        arena: Allocator,
        parent_id: []const u8,
        symbol: languages.DocumentSymbol,
        siblings: []*OutlineElement,
        parent: ?*OutlineElement,
    ) !*OutlineElement {
        const element = try arena.create(OutlineElement);
        element.* = .{ .symbol = symbol, .parent = parent };
        element.id = try findId(arena, parent_id, symbol, siblings);
        var children = std.array_list.Managed(*OutlineElement).init(arena);
        for (symbol.children) |child| {
            try children.append(try buildElement(arena, element.id, child, children.items, element));
        }
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
        var owned_position = position;
        try appendChain(&chain, self.roots, &owned_position);
        return chain.toOwnedSlice();
    }

    fn appendChain(
        chain: *std.array_list.Managed(*OutlineElement),
        elements: []*OutlineElement,
        position: *const Position,
    ) !void {
        for (elements) |element| {
            var range = element.symbol.range;
            if (!range.containsPosition(position)) continue;
            try chain.append(element);
            try appendChain(chain, element.children, position);
            return;
        }
    }

    /// Upstream `getItemEnclosingPosition`: the deepest symbol containing the
    /// cursor, or null when no symbol encloses it.
    pub fn getItemEnclosingPosition(self: *const OutlineModel, position: Position) ?*OutlineElement {
        var owned_position = position;
        return enclosingElement(self.roots, &owned_position);
    }

    fn enclosingElement(elements: []*OutlineElement, position: *const Position) ?*OutlineElement {
        for (elements) |element| {
            var range = element.symbol.range;
            if (!range.containsPosition(position)) continue;
            return enclosingElement(element.children, position) orelse element;
        }
        return null;
    }

    /// Upstream `TreeElement.size`.
    pub fn size(self: *const OutlineModel) usize {
        var count: usize = 1;
        for (self.roots) |root| count += elementSize(root);
        return count;
    }

    pub fn isEmpty(self: *const OutlineModel) bool {
        return self.roots.len == 0;
    }

    /// Upstream `updateMarker`. Markers are copied into a mutable list and
    /// recursively assigned to the deepest outline elements that contain them;
    /// only lowercased elements are rolled up into their parents.
    pub fn updateMarker(self: *OutlineModel, markers: []const OutlineMarker) !void {
        const allocator = self.allocator;
        if (self.groups.len == 0) {
            for (self.roots) |root| root.marker = null;
            return;
        }
        const sorted = try allocator.alloc(OutlineMarker, markers.len);
        defer allocator.free(sorted);
        @memcpy(sorted, markers);
        std.mem.sort(OutlineMarker, sorted, {}, struct {
            fn lessThan(_: void, a: OutlineMarker, b: OutlineMarker) bool {
                return range_mod.compareRangesUsingStarts(&a.range, &b.range) < 0;
            }
        }.lessThan);

        var work = std.array_list.Managed(?OutlineMarker).init(allocator);
        defer work.deinit();
        for (self.groups) |group| {
            work.clearRetainingCapacity();
            for (sorted) |marker| work.append(marker) catch continue;
            updateGroupMarkers(group, &work);
        }
    }

    /// Upstream `getTopLevelSymbols`.
    pub fn getTopLevelSymbols(self: *const OutlineModel, allocator: Allocator) ![]languages.DocumentSymbol {
        var roots = std.array_list.Managed(languages.DocumentSymbol).init(allocator);
        errdefer roots.deinit();
        for (self.roots) |element| try roots.append(element.symbol);
        std.mem.sort(languages.DocumentSymbol, roots.items, {}, struct {
            fn lessThan(_: void, a: languages.DocumentSymbol, b: languages.DocumentSymbol) bool {
                return range_mod.compareRangesUsingStarts(&a.range, &b.range) < 0;
            }
        }.lessThan);
        return roots.toOwnedSlice();
    }

    /// Upstream `asListOfDocumentSymbols`: a flattened, position sorted list.
    pub fn asListOfDocumentSymbols(self: *const OutlineModel, allocator: Allocator) ![]languages.DocumentSymbol {
        var bucket = std.array_list.Managed(languages.DocumentSymbol).init(allocator);
        errdefer bucket.deinit();
        for (self.roots) |root| try flattenDocumentSymbols(&bucket, root, "");
        std.mem.sort(languages.DocumentSymbol, bucket.items, {}, struct {
            fn lessThan(_: void, a: languages.DocumentSymbol, b: languages.DocumentSymbol) bool {
                const by_start = Position.compare(
                    Range.getStartPosition(&a.range),
                    Range.getStartPosition(&b.range),
                );
                if (by_start != 0) return by_start < 0;
                return Position.compare(
                    Range.getEndPosition(&a.range),
                    Range.getEndPosition(&b.range),
                ) > 0;
            }
        }.lessThan);
        return bucket.toOwnedSlice();
    }

    pub fn getItemById(self: *const OutlineModel, id: []const u8) ?*OutlineElement {
        if (id.len == 0) return null;
        for (self.roots) |root| {
            if (findElementById(root, id)) |element| return element;
        }
        return null;
    }
};

fn flattenDocumentSymbols(
    bucket: *std.array_list.Managed(languages.DocumentSymbol),
    element: *const OutlineElement,
    container_label: []const u8,
) !void {
    const symbol = element.symbol;
    try bucket.append(.{
        .name = symbol.name,
        .detail = symbol.detail,
        .kind = symbol.kind,
        .tags = symbol.tags,
        .container_name = symbol.container_name orelse if (container_label.len > 0) container_label else null,
        .range = symbol.range,
        .selection_range = symbol.selection_range,
        .children = &.{},
    });
    for (element.children) |child| try flattenDocumentSymbols(bucket, child, symbol.name);
}

fn updateGroupMarkers(group: *OutlineGroup, markers: *std.array_list.Managed(?OutlineMarker)) void {
    for (group.children) |child| updateElementMarkers(child, markers);
    compactMarkers(markers);
}

fn updateElementMarkers(
    element: *OutlineElement,
    markers: *std.array_list.Managed(?OutlineMarker),
) void {
    element.marker = null;
    var my_markers = std.array_list.Managed(?OutlineMarker).init(markers.allocator);
    defer my_markers.deinit();
    var top_severity: ?u32 = null;
    for (markers.items, 0..) |slot, index| {
        const marker = slot orelse continue;
        var element_range = element.symbol.range;
        if (!range_mod.areIntersecting(&element_range, &marker.range)) continue;
        my_markers.append(marker) catch continue;
        markers.items[index] = null;
        if (top_severity == null or marker.severity > top_severity.?) top_severity = marker.severity;
    }
    for (element.children) |child| updateElementMarkers(child, &my_markers);
    compactMarkers(&my_markers);
    if (top_severity) |severity| {
        element.marker = .{ .count = my_markers.items.len, .top_severity = severity };
    }
}

fn compactMarkers(markers: *std.array_list.Managed(?OutlineMarker)) void {
    var write: usize = 0;
    for (markers.items) |marker| {
        if (marker) |value| {
            markers.items[write] = value;
            write += 1;
        }
    }
    markers.items.len = write;
}

fn elementSize(element: *const OutlineElement) usize {
    var count: usize = 1;
    for (element.children) |child| count += elementSize(child);
    return count;
}

fn findElementById(element: *OutlineElement, id: []const u8) ?*OutlineElement {
    if (std.mem.eql(u8, element.id, id)) return element;
    for (element.children) |child| {
        if (findElementById(child, id)) |found| return found;
    }
    return null;
}

/// Upstream `TreeElement.findId`: ids include the parent path, and duplicate
/// names fall back to the symbol start line/column before the numeric suffix.
fn findId(
    arena: Allocator,
    parent_id: []const u8,
    symbol: languages.DocumentSymbol,
    siblings: []*OutlineElement,
) ![]const u8 {
    var candidate = try std.fmt.allocPrint(arena, "{s}/{s}", .{ parent_id, symbol.name });
    if (hasChildId(siblings, candidate)) {
        candidate = try std.fmt.allocPrint(arena, "{s}/{s}_{d}_{d}", .{
            parent_id,
            symbol.name,
            symbol.range.startLineNumber,
            symbol.range.startColumn,
        });
    }
    var attempt: usize = 0;
    var id = candidate;
    while (hasChildId(siblings, id)) : (attempt += 1) {
        id = try std.fmt.allocPrint(arena, "{s}_{d}", .{ candidate, attempt });
    }
    return id;
}

fn hasChildId(siblings: []*OutlineElement, id: []const u8) bool {
    for (siblings) |sibling| {
        if (std.mem.eql(u8, sibling.id, id)) return true;
    }
    return false;
}
