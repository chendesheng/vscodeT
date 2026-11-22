// Port of the portable portions of
// `src/vs/workbench/contrib/codeEditor/browser/outline/documentSymbolsOutline.ts`
// and `documentSymbolsTree.ts`.
//
// The browser outline supplies a data tree, renderers, quick pick source and
// drag/drop. The terminal port supplies the same tree *data* as a snapshot of
// `TreeElement` values, the symbol comparator, kind filtering and the
// breadcrumbs data source through the ported `IOutline` contract. The terminal
// outline pane renders that snapshot with the shared list widget; the
// breadcrumb popup lists siblings through `getParent`.
//
// Terminal adaptations: the tree snapshot is rebuilt when the outline model is
// replaced (the terminal service creates outlines synchronously), markers are
// rolled up into `OutlineElement.marker` before the snapshot is built, and
// browser-only drag/drop, accessibility labels and quick-pick source are not
// ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const outline = @import("../../../../services/outline/browser/outline.zig");
const IOutline = outline.IOutline;
const TreeElement = outline.TreeElement;

const BreadcrumbsOutlineElement = outline.BreadcrumbsOutlineElement;
const OutlineChangeEvent = outline.OutlineChangeEvent;
const RevealOptions = outline.RevealOptions;
const Emitter = @import("../../../../../base/common/event.zig").Emitter;
const Position = @import("../../../../../editor/common/core/position.zig").Position;
const range_mod = @import("../../../../../editor/common/core/range.zig");
const Range = range_mod.Range;
const outline_model_mod = @import("../../../../../editor/contrib/documentSymbols/browser/outlineModel.zig");
const OutlineModel = outline_model_mod.OutlineModel;
const SymbolElement = outline_model_mod.OutlineElement;

/// Upstream `SymbolTag.Deprecated`.
const deprecated_tag: u32 = 2;

pub const Host = struct {
    context: *anyopaque,
    current_position: *const fn (context: *anyopaque) ?Position,
    reveal_range: *const fn (context: *anyopaque, range: Range) anyerror!void,
    request_render: *const fn (context: *anyopaque) void,
    /// `outline.show*` configuration for one symbol kind. Upstream
    /// `DocumentSymbolFilter` reads the same keys from the text resource
    /// configuration service; the terminal callback keeps this module free of
    /// the configuration service.
    is_symbol_visible: ?*const fn (context: *anyopaque, kind: u32) bool = null,
};

pub const DocumentSymbolsOutline = struct {
    allocator: Allocator,
    model: *OutlineModel,
    host: Host,
    emitter: Emitter(OutlineChangeEvent),
    elements: std.array_list.Managed(BreadcrumbsOutlineElement),
    tree_arena: std.heap.ArenaAllocator,
    tree_roots: []const TreeElement = &.{},
    interface_value: IOutline = undefined,

    pub fn create(allocator: Allocator, model: *OutlineModel, host: Host) !*DocumentSymbolsOutline {
        const self = try allocator.create(DocumentSymbolsOutline);
        self.* = .{
            .allocator = allocator,
            .model = model,
            .host = host,
            .emitter = Emitter(OutlineChangeEvent).init(allocator),
            .elements = std.array_list.Managed(BreadcrumbsOutlineElement).init(allocator),
            .tree_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer {
            self.tree_arena.deinit();
            self.elements.deinit();
            self.emitter.deinit();
            allocator.destroy(self);
        }
        self.rebuildTree();
        self.interface_value = self.buildInterface();
        return self;
    }

    fn buildInterface(self: *DocumentSymbolsOutline) IOutline {
        return .{
            .context = self,
            .uri = null,
            .outline_kind = "documentSymbols",
            .is_empty = self.model.isEmpty(),
            .config = .{
                .breadcrumbs_data_source = .{
                    .context = self,
                    .get_breadcrumb_elements = getBreadcrumbElements,
                },
                .tree_data_source = .{
                    .context = self,
                    .get_roots = getTreeRoots,
                },
                .comparator = .{
                    .context = self,
                    .compare_by_position = compareByPosition,
                    .compare_by_type = compareByType,
                    .compare_by_name = compareByName,
                },
                .filter = .{
                    .context = self,
                    .is_visible = isSymbolVisible,
                },
                .collapse_by_default = false,
            },
            .on_did_change = &self.emitter,
            .active_element_fn = activeElement,
            .parent_fn = getParent,
            .revealFn = reveal,
            .disposeFn = dispose,
        };
    }

    pub fn interfacePtr(self: *DocumentSymbolsOutline) *IOutline {
        return &self.interface_value;
    }

    /// Replaces the outline model after a provider/content change and emits
    /// upstream's `onDidChange`, retargeting the breadcrumb chain and the
    /// outline tree snapshot.
    pub fn setModel(self: *DocumentSymbolsOutline, model: *OutlineModel) void {
        if (self.model != model) self.model.deinit();
        self.model = model;
        self.interface_value.is_empty = self.model.isEmpty();
        self.rebuildTree();
        self.emitter.fire(.{}) catch {};
    }

    pub fn modelPtr(self: *DocumentSymbolsOutline) *OutlineModel {
        return self.model;
    }

    fn rebuildTree(self: *DocumentSymbolsOutline) void {
        _ = self.tree_arena.reset(.retain_capacity);
        const arena = self.tree_arena.allocator();
        var roots = std.array_list.Managed(TreeElement).init(arena);
        for (self.model.roots) |element| {
            const tree = buildTreeElement(arena, element) catch break;
            roots.append(tree) catch break;
        }
        self.tree_roots = roots.toOwnedSlice() catch &.{};
    }

    fn buildTreeElement(arena: Allocator, element: *SymbolElement) !TreeElement {
        var children = std.array_list.Managed(TreeElement).init(arena);
        for (element.children) |child| try children.append(try buildTreeElement(arena, child));
        return .{
            .element = @ptrCast(element),
            .label = element.symbol.name,
            .symbol_kind = element.symbol.kind,
            .collapsible = element.children.len > 0,
            .id = element.id,
            .marker_count = if (element.marker) |marker| marker.count else 0,
            .marker_severity = if (element.marker) |marker| marker.top_severity else null,
            .deprecated = hasTag(element.symbol, deprecated_tag),
            .children = try children.toOwnedSlice(),
        };
    }

    fn getBreadcrumbElements(context: *anyopaque) []const BreadcrumbsOutlineElement {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        self.elements.clearRetainingCapacity();
        const position = self.host.current_position(self.host.context) orelse return &.{};
        const chain = self.model.elementChain(self.allocator, position) catch return &.{};
        defer self.allocator.free(chain);
        for (chain) |element| {
            if (!self.visible(element.symbol.kind)) break;
            self.elements.append(.{
                .element = @ptrCast(element),
                .label = element.symbol.name,
                .symbol_kind = element.symbol.kind,
            }) catch break;
        }
        return self.elements.items;
    }

    fn getTreeRoots(context: *anyopaque) []const TreeElement {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        return self.tree_roots;
    }

    fn activeElement(context: *anyopaque) ?*anyopaque {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        const position = self.host.current_position(self.host.context) orelse return null;
        const element = self.model.getItemEnclosingPosition(position) orelse return null;
        return @ptrCast(element);
    }

    fn getParent(context: *anyopaque, element: *anyopaque) ?*anyopaque {
        _ = context;
        const symbol: *SymbolElement = @ptrCast(@alignCast(element));
        const parent = symbol.parent orelse return null;
        return @ptrCast(parent);
    }

    fn visible(self: *DocumentSymbolsOutline, kind: u32) bool {
        const callback = self.host.is_symbol_visible orelse return true;
        return callback(self.host.context, kind);
    }

    fn isSymbolVisible(context: *anyopaque, element: *anyopaque) bool {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        const symbol: *SymbolElement = @ptrCast(@alignCast(element));
        return self.visible(symbol.symbol.kind);
    }

    fn compareByPosition(context: *anyopaque, a: *anyopaque, b: *anyopaque) std.math.Order {
        _ = context;
        const left: *SymbolElement = @ptrCast(@alignCast(a));
        const right: *SymbolElement = @ptrCast(@alignCast(b));
        var left_range = left.symbol.range;
        var right_range = right.symbol.range;
        const by_range = range_mod.compareRangesUsingStarts(&left_range, &right_range);
        if (by_range != 0) return if (by_range < 0) .lt else .gt;
        return compareNames(left.symbol.name, right.symbol.name);
    }

    fn compareByType(context: *anyopaque, a: *anyopaque, b: *anyopaque) std.math.Order {
        _ = context;
        const left: *SymbolElement = @ptrCast(@alignCast(a));
        const right: *SymbolElement = @ptrCast(@alignCast(b));
        if (left.symbol.kind != right.symbol.kind) {
            return if (left.symbol.kind < right.symbol.kind) .lt else .gt;
        }
        return compareNames(left.symbol.name, right.symbol.name);
    }

    fn compareByName(context: *anyopaque, a: *anyopaque, b: *anyopaque) std.math.Order {
        _ = context;
        const left: *SymbolElement = @ptrCast(@alignCast(a));
        const right: *SymbolElement = @ptrCast(@alignCast(b));
        const by_name = compareNames(left.symbol.name, right.symbol.name);
        if (by_name != .eq) return by_name;
        var left_range = left.symbol.range;
        var right_range = right.symbol.range;
        const by_range = range_mod.compareRangesUsingStarts(&left_range, &right_range);
        return if (by_range < 0) .lt else if (by_range > 0) .gt else .eq;
    }

    fn reveal(context: *anyopaque, element: *anyopaque, options: RevealOptions) !void {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        const target: *SymbolElement = @ptrCast(@alignCast(element));
        const range = if (options.select) target.symbol.range else target.symbol.selection_range;
        try self.host.reveal_range(self.host.context, range);
        self.host.request_render(self.host.context);
    }

    fn dispose(context: *anyopaque) void {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        self.elements.deinit();
        self.tree_arena.deinit();
        self.emitter.deinit();
        self.model.deinit();
        self.allocator.destroy(self);
    }
};

fn compareNames(a: []const u8, b: []const u8) std.math.Order {
    // Upstream uses an Intl collator. The terminal uses a case-insensitive
    // comparison with a case-sensitive tie break so the ordering is stable.
    if (std.ascii.lessThanIgnoreCase(a, b)) return .lt;
    if (std.ascii.lessThanIgnoreCase(b, a)) return .gt;
    return std.mem.order(u8, a, b);
}

fn hasTag(symbol: @import("../../../../../editor/common/languages.zig").DocumentSymbol, tag: u32) bool {
    for (symbol.tags) |candidate| {
        if (candidate == tag) return true;
    }
    return false;
}

test "DocumentSymbolsOutline: tree snapshot, active element and comparator" {
    const allocator = std.testing.allocator;
    const languages = @import("../../../../../editor/common/languages.zig");
    const TextModel = @import("../../../../../editor/common/model/textModel.zig").TextModel;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor.createFromText(
        allocator,
        io,
        "class A {\n  method() {}\n}\n",
        "test.ts",
        60,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const Provider = struct {
        fn provide(_: *anyopaque, arena: Allocator, _: *TextModel, _: @import("../../../../../base/common/cancellation.zig").CancellationToken) anyerror![]const languages.DocumentSymbol {
            const method = languages.DocumentSymbol{
                .name = "method",
                .kind = 5,
                .range = Range.init(2, 3, 2, 14),
                .selection_range = Range.init(2, 9, 2, 15),
            };
            const methods = [_]languages.DocumentSymbol{method};
            const class = [_]languages.DocumentSymbol{.{
                .name = "A",
                .kind = 4,
                .range = Range.init(1, 1, 3, 2),
                .selection_range = Range.init(1, 7, 1, 8),
                .children = try arena.dupe(languages.DocumentSymbol, &methods),
            }};
            return arena.dupe(languages.DocumentSymbol, &class);
        }
    };
    var context: u8 = 0;
    const provider = languages.DocumentSymbolProvider{
        .context = @ptrCast(&context),
        .provide_document_symbols = Provider.provide,
    };
    const outline_model = try OutlineModel.create(allocator, editor.model, provider);

    const HostImpl = struct {
        var position: Position = Position.init(2, 10);
        fn current(_: *anyopaque) ?Position {
            return position;
        }
        fn reveal(_: *anyopaque, _: Range) !void {}
        fn render(_: *anyopaque) void {}
    };
    const outline_view = try DocumentSymbolsOutline.create(allocator, outline_model, .{
        .context = @ptrCast(&context),
        .current_position = HostImpl.current,
        .reveal_range = HostImpl.reveal,
        .request_render = HostImpl.render,
    });
    defer outline_view.interface_value.dispose();

    const roots = outline_view.tree_roots;
    try std.testing.expectEqual(@as(usize, 1), roots.len);
    try std.testing.expectEqualStrings("A", roots[0].label);
    try std.testing.expectEqual(@as(usize, 1), roots[0].children.len);
    try std.testing.expectEqualStrings("method", roots[0].children[0].label);

    const active = outline_view.interface_value.activeElement().?;
    const active_element: *SymbolElement = @ptrCast(@alignCast(active));
    try std.testing.expectEqualStrings("method", active_element.symbol.name);
    const child = &roots[0].children[0];
    const parent = outline_view.interface_value.getParent(child.element).?;
    try std.testing.expectEqualStrings("A", @as(*SymbolElement, @ptrCast(@alignCast(parent))).symbol.name);
}
