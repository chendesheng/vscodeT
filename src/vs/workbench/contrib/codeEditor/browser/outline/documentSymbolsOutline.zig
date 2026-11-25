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
// replaced after provider completion, markers are
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

const Service = @import("../../../../../editor/contrib/documentSymbols/browser/outlineModel.zig").OutlineModelService;
const TextModel = @import("../../../../../editor/common/model/textModel.zig").TextModel;
const ContentEvent = @import("../../../../../editor/common/textModelEvents.zig").InternalModelContentChangeEvent;
const Features = @import("../../../../../editor/common/services/languageFeaturesService.zig").LanguageFeaturesService;
const Disposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;

const Editor = @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Selection = @import("../../../../../editor/common/core/selection.zig").Selection;
const ConfigurationService = @import("../../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const MarkerDecorationsService = @import("../../../../../editor/common/services/markerDecorationsService.zig").MarkerDecorationsService;
const MarkerSeverity = @import("../../../../../platform/markers/common/markers.zig").MarkerSeverity;
const outline_config = @import("../../../outline/browser/outline.zig");
const OutlineService = @import("../../../../services/outline/browser/outlineService.zig").OutlineService;

pub const Host = struct {
    context: *anyopaque,
    current_position: *const fn (context: *anyopaque) ?Position,
    reveal_range: *const fn (context: *anyopaque, range: Range) anyerror!void,
    request_render: *const fn (context: *anyopaque) void,
    /// The terminal adapter for `DocumentSymbolFilter` and breadcrumb kind
    /// filtering. As in upstream, the settings lookup has its own context,
    /// separate from the editor used for selection and reveal.
    symbol_filter: ?struct {
        context: *anyopaque,
        is_visible: *const fn (context: *anyopaque, kind: u32) bool,
    } = null,
};

pub const DocumentSymbolsOutline = struct {
    allocator: Allocator,
    model: *OutlineModel,
    host: Host,
    service: ?*Service = null,
    buffer: ?*TextModel = null,
    features: ?*Features = null,
    content_listener: ?usize = null,
    provider_listener: ?usize = null,
    marker_listener: ?usize = null,
    creator: ?*DocumentSymbolsOutlineCreator = null,
    pending: ?Disposable = null,
    pending_model: ?*OutlineModel = null,
    version: u32 = 0,
    removed_length: ?usize = null,
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
            .retain_picker_input = retainPickerInput,
            .revealFn = reveal,
            .disposeFn = dispose,
        };
    }

    pub fn bind(self: *DocumentSymbolsOutline, service: *Service, buffer: *TextModel, features: *Features) !void {
        self.service = service;
        self.buffer = buffer;
        self.features = features;
        self.content_listener = try buffer.onDidChangeContentWithContextId(self, onContent);
        self.provider_listener = try features.document_symbol_provider.on_did_change.listen(self, onProvidersChanged);
        try self.createOutline();
    }

    fn onProvidersChanged(_: usize, self: *DocumentSymbolsOutline) !void {
        self.removed_length = null;
        if (self.service) |service| service.cancelTimer(self);
        self.setModel(try OutlineModel.empty(self.allocator));
        try self.createOutline();
    }

    fn onContent(event: ContentEvent, self: *DocumentSymbolsOutline) !void {
        var length: usize = 0;
        for (event.contentChangedEvent.changes.items) |change| length += change.rangeLength;
        self.removed_length = length;
        try self.service.?.schedule(self, self.service.?.getDebounceValue(self.buffer.?), refresh);
    }

    fn refresh(context: *anyopaque) void {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        self.createOutline() catch {};
    }

    fn createOutline(self: *DocumentSymbolsOutline) !void {
        self.cancelRequest();
        self.removeMarkerListener();
        const buffer = self.buffer.?;
        if (!self.features.?.document_symbol_provider.has(buffer)) return;
        self.version = buffer.getVersionId();
        const providers = try self.features.?.document_symbol_provider.ordered(self.allocator, buffer, false);
        defer self.allocator.free(providers);
        self.pending = try self.service.?.getOrCreate(buffer, providers, self, ready);
    }
    fn cancelRequest(self: *DocumentSymbolsOutline) void {
        if (self.pending) |pending| pending.dispose();
        self.pending = null;
        if (self.pending_model) |model| model.deinit();
        self.pending_model = null;
    }
    fn ready(context: *anyopaque, model: *OutlineModel) void {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        self.pending = null;
        const buffer = self.buffer.?;
        if (self.version != buffer.getVersionId()) {
            model.deinit();
            return;
        }
        self.pending_model = model;
        if (self.removed_length) |removed| {
            if (!model.isEmpty() and !self.model.isEmpty() and buffer.getLineCount() >= 25) {
                const length: f64 = @floatFromInt(buffer.getValueLength(.TextDefined, false));
                const ratio = @as(f64, @floatFromInt(model.size())) / length;
                const old_ratio = @as(f64, @floatFromInt(self.model.size())) / (length - @as(f64, @floatFromInt(removed)));
                if (ratio <= old_ratio * 0.5 or ratio >= old_ratio * 1.5) {
                    self.service.?.schedule(self, 2000, publish) catch publish(self);
                    return;
                }
            }
        }
        publish(self);
    }

    fn publish(context: *anyopaque) void {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        const model = self.pending_model orelse return;
        self.pending_model = null;
        if (self.version != self.buffer.?.getVersionId()) {
            model.deinit();
            return;
        }
        if (!model.isEmpty()) if (self.creator) |creator| {
            self.applyMarkersToOutline(model) catch {};
            self.marker_listener = creator.markers.on_did_change_marker.listen(self, onMarkersChanged) catch null;
        };
        if (self.model == model) model.deinit();
        self.setModel(model);
        self.host.request_render(self.host.context);
    }

    fn removeMarkerListener(self: *DocumentSymbolsOutline) void {
        if (self.marker_listener) |id| self.creator.?.markers.on_did_change_marker.unlisten(id);
        self.marker_listener = null;
    }

    fn onMarkersChanged(buffer: *TextModel, self: *DocumentSymbolsOutline) !void {
        if (self.buffer != buffer) return;
        try self.applyMarkersToOutline(self.model);
        self.rebuildTree();
        try self.emitter.fire(.{});
    }

    fn applyMarkersToOutline(self: *DocumentSymbolsOutline, model: *OutlineModel) !void {
        const creator = self.creator orelse return;
        if (!creator.enabled("problems.visibility") or !creator.enabled("outline.problems.enabled")) {
            try model.updateMarker(&.{});
            return;
        }
        const live = try creator.markers.getLiveMarkers(self.allocator, self.buffer.?);
        defer self.allocator.free(live);
        var markers: std.ArrayList(outline_model_mod.OutlineMarker) = .empty;
        defer markers.deinit(self.allocator);
        for (live) |entry| {
            const severity = entry.marker.severity;
            if (severity == MarkerSeverity.Error or severity == MarkerSeverity.Warning) {
                try markers.append(self.allocator, .{ .range = entry.range, .severity = severity });
            }
        }
        try model.updateMarker(markers.items);
    }

    pub fn interfacePtr(self: *DocumentSymbolsOutline) *IOutline {
        return &self.interface_value;
    }

    fn retainPickerInput(context: *anyopaque) !*IOutline {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        self.model.retain();
        errdefer self.model.deinit();
        const input = try create(self.allocator, self.model, self.host);
        return input.interfacePtr();
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
        const filter = self.host.symbol_filter orelse return true;
        return filter.is_visible(filter.context, kind);
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
        const range = if (options.select) target.symbol.range else target.symbol.selection_range.collapseToStart();
        try self.host.reveal_range(self.host.context, range);
        self.host.request_render(self.host.context);
    }

    fn dispose(context: *anyopaque) void {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        if (self.service) |service| service.cancelTimer(self);
        self.cancelRequest();
        self.removeMarkerListener();
        if (self.provider_listener) |id| self.features.?.document_symbol_provider.on_did_change.unlisten(id);
        if (self.content_listener) |id| self.buffer.?.removeDidChangeContentListener(id);
        self.elements.deinit();
        self.tree_arena.deinit();
        self.emitter.deinit();
        self.model.deinit();
        self.allocator.destroy(self);
    }
};

/// The terminal returns its outline handle immediately. The shared model
/// service publishes the first result through on_did_change.
pub const DocumentSymbolsOutlineCreator = struct {
    models: *Service,
    features: *Features,
    // Configuration can be installed after language services during startup.
    configuration: *const ?*ConfigurationService,
    markers: *MarkerDecorationsService,
    registration: ?Disposable = null,

    pub fn register(self: *@This(), service: *OutlineService) !void {
        self.registration = try service.registerOutlineCreator(self.interface());
    }

    pub fn dispose(self: *@This()) void {
        if (self.registration) |registration| registration.dispose();
        self.registration = null;
    }

    pub fn interface(self: *@This()) outline.IOutlineCreator {
        return .{ .context = self, .matches = matches, .create_outline = createOutline };
    }

    fn matches(_: *anyopaque, pane: outline.OutlineEditor) bool {
        return pane.control != null;
    }

    fn createOutline(context: *anyopaque, pane: outline.OutlineEditor, target: outline.OutlineTarget) !?*IOutline {
        const self: *@This() = @ptrCast(@alignCast(context));
        const editor = pane.control orelse return null;
        const model = try OutlineModel.empty(self.models.allocator);
        const instance = DocumentSymbolsOutline.create(self.models.allocator, model, .{
            .context = editor,
            .current_position = currentPosition,
            .reveal_range = revealRange,
            .request_render = requestRender,
            .symbol_filter = switch (target) {
                .OutlinePane => .{ .context = self, .is_visible = outlineSymbolVisible },
                .Breadcrumbs => .{ .context = self, .is_visible = breadcrumbSymbolVisible },
                .QuickPick => null,
            },
        }) catch |err| {
            model.deinit();
            return err;
        };
        const result = instance.interfacePtr();
        errdefer result.dispose();
        instance.creator = self;
        result.uri = pane.resource;
        result.config.collapse_by_default = target == .Breadcrumbs or (target == .OutlinePane and self.initiallyCollapsed(pane.resource));
        try instance.bind(self.models, editor.model, self.features);
        return result;
    }

    fn initiallyCollapsed(self: *@This(), resource: ?[]const u8) bool {
        const configuration = self.configuration.* orelse return false;
        const initial = configuration.getValue(outline_config.OutlineConfigKeys.collapse_items, .{ .resource = resource }) orelse return false;
        return initial.* == .string and std.mem.eql(u8, initial.string, outline_config.OutlineConfigCollapseItemsValues.collapsed);
    }

    fn enabled(self: *@This(), key: []const u8) bool {
        const configuration = self.configuration.* orelse return true;
        const value = configuration.getValue(key, .{}) orelse return true;
        return value.* != .bool or value.bool;
    }

    fn outlineSymbolVisible(context: *anyopaque, kind: u32) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.enabled(outline_config.showConfigForKind(kind));
    }

    fn breadcrumbSymbolVisible(context: *anyopaque, kind: u32) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.enabled(outline_config.breadcrumbConfigForKind(kind));
    }

    fn currentPosition(context: *anyopaque) ?Position {
        const editor: *Editor = @ptrCast(@alignCast(context));
        return editor.modelSelection().getStartPosition();
    }

    fn revealRange(context: *anyopaque, range: Range) !void {
        const editor: *Editor = @ptrCast(@alignCast(context));
        try editor.setSelections(&.{Selection.init(range.startLineNumber, range.startColumn, range.endLineNumber, range.endColumn)});
    }

    fn requestRender(_: *anyopaque) void {}
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
        fn reveal(ctx: *anyopaque, range: Range) !void {
            const selection: *Range = @ptrCast(@alignCast(ctx));
            selection.* = range;
        }
        fn render(_: *anyopaque) void {}
    };
    var selection: Range = undefined;
    const outline_view = try DocumentSymbolsOutline.create(allocator, outline_model, .{
        .context = &selection,
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

    const input = try outline_view.interface_value.retain_picker_input.?(outline_view);
    defer input.dispose();
    const source = input.config.tree_data_source.?;
    const selected = &source.get_roots(source.context)[0].children[0];
    outline_view.setModel(try OutlineModel.empty(allocator));
    try std.testing.expectEqualStrings("method", selected.label);
    try std.testing.expectEqual(active, selected.element);
    try input.reveal(selected.element, .{});
    try std.testing.expectEqual(Range.init(2, 9, 2, 9), selection);
    try input.reveal(selected.element, .{ .select = true });
    try std.testing.expectEqual(Range.init(2, 3, 2, 14), selection);
}
