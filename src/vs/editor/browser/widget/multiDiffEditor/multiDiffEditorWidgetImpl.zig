// Port of `src/vs/editor/browser/widget/multiDiffEditor/multiDiffEditorWidgetImpl.ts`.
// The compressed scroll view drives typed bindings and retained header/body
// painting. Terminal input supplies integral dimensions and scroll deltas.
const std = @import("std");
const ui = @import("ui");
const Allocator = std.mem.Allocator;
const scroll_mod = @import("compressedVirtualizedScrollView.zig");
const layout_mod = @import("compressedVirtualizedScrollLayout.zig");
const item_template = @import("diffEditorItemTemplate.zig");
const vm = @import("virtualizedItemManager.zig");
const model = @import("multiDiffEditorViewModel.zig");
const variants = @import("multiDiffEditorOptions.zig");
const common = @import("../../../common/multiDiffEditor.zig");
const Selection = @import("../../../common/core/selection.zig").Selection;
const Range = @import("../../../common/core/range.zig").Range;
const OffsetRange = @import("../../../common/core/ranges/offsetRange.zig").OffsetRange;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const ThemeColors = @import("../../../../workbench/browser/themeColors.zig").ThemeColors;
const DiffWordWrap = @import("../diffEditor/diffEditorOptions.zig").DiffWordWrap;

/// Upstream layout debug DTO. Allocated URI labels and item arrays belong
/// to the caller's arena; the live scroll layout is never retained by a log.
pub const IMultiDiffEditorLayoutDebugState = struct {
    scrollLeft: usize,
    scrollDimensions: scroll_mod.ScrollDimensions,
    layout: Layout,
    geometryEdit: ?GeometryEdit,
    items: []const Item,
    pub const Layout = struct {
        revision: layout_mod.LayoutRevision,
        scrollTop: usize,
        logicalScrollHeight: usize,
        scrollHeight: usize,
        renderedHeight: usize,
        leadingScrollSlack: usize,
        trailingScrollSlack: usize,
        contentViewport: layout_mod.LogicalRange,
        renderedViewport: OffsetRange,
        hiddenContentHeightAboveViewport: usize,
    };
    pub const GeometryEdit = struct {
        fromRevision: layout_mod.LayoutRevision,
        toRevision: layout_mod.LayoutRevision,
        edits: []const layout_mod.ISizeEdit,
        anchorKind: @FieldType(scroll_mod.ICompressedVirtualizedGeometryEdit, "anchorKind"),
        anchorOffset: isize,
        mappedAnchorOffset: isize,
        anchorViewportOffset: isize,
        desiredScrollTop: usize,
        appliedScrollTop: usize,
        leadingScrollSlack: usize,
        trailingScrollSlack: usize,
    };
    pub const Item = struct {
        key: []const u8,
        label: []const u8,
        originalUri: ?[]const u8,
        modifiedUri: ?[]const u8,
        collapsed: bool,
        hasTemplate: bool,
        verticalState: struct { contentHeight: usize, itemViewportOffset: usize },
        maxScroll: usize,
        layout: layout_mod.ICompressedVirtualizedItemLayout,
    };
};

pub const IMultiDiffDocState = struct { key: []u8, collapsed: bool, selections: ?[]Selection };
pub const IMultiDiffEditorViewState = struct {
    allocator: Allocator,
    scrollState: scroll_mod.ScrollPosition,
    docStates: []IMultiDiffDocState,
    activeDiffItemKey: ?[]u8,
    pub fn deinit(self: *IMultiDiffEditorViewState) void {
        for (self.docStates) |state| {
            self.allocator.free(state.key);
            if (state.selections) |selections| self.allocator.free(selections);
        }
        self.allocator.free(self.docStates);
        if (self.activeDiffItemKey) |key| self.allocator.free(key);
    }
    pub fn clone(self: IMultiDiffEditorViewState, allocator: Allocator) !IMultiDiffEditorViewState {
        const states = try allocator.alloc(IMultiDiffDocState, self.docStates.len);
        var initialized: usize = 0;
        errdefer {
            for (states[0..initialized]) |state| {
                allocator.free(state.key);
                if (state.selections) |selections| allocator.free(selections);
            }
            allocator.free(states);
        }
        for (self.docStates, states) |state, *dest| {
            const key = try allocator.dupe(u8, state.key);
            errdefer allocator.free(key);
            dest.* = .{ .key = key, .collapsed = state.collapsed, .selections = if (state.selections) |values| try allocator.dupe(Selection, values) else null };
            initialized += 1;
        }
        return .{ .allocator = allocator, .scrollState = self.scrollState, .docStates = states, .activeDiffItemKey = if (self.activeDiffItemKey) |key| try allocator.dupe(u8, key) else null };
    }
};

const PaddingItem = struct {
    height: usize = 0,
    change: Emitter(void),
    fn interface(self: *PaddingItem) scroll_mod.ICompressedVirtualizedScrollItem {
        return .{ .context = self, .size = size, .max_scroll = maxScroll, .on_did_change = &self.change, .render = render, .hide = hide };
    }
    fn size(context: *anyopaque) usize {
        const self: *PaddingItem = @ptrCast(@alignCast(context));
        return self.height;
    }
    fn maxScroll(_: *anyopaque) usize {
        return 0;
    }
    fn render(_: *anyopaque, _: OffsetRange, _: usize, _: usize, _: OffsetRange, _: scroll_mod.ICompressedVirtualizedScrollItemContext) !void {}
    fn hide(_: *anyopaque) void {}
};

pub fn MultiDiffEditorWidgetImpl(comptime View: type) type {
    return struct {
        const Self = @This();
        const Template = item_template.DiffEditorItemTemplate(View);
        pub const Binding = Template.Binding;
        pub const Widget = Template.Widget;
        pub const Host = Template.Host;
        pub const Manager = vm.VirtualizedItemManager(model.DocumentDiffItemViewModel, Binding, Template);

        allocator: Allocator,
        io: std.Io,
        host: Host,
        queue: *dispatch.Queue,
        config: item_template.Configuration,
        variant: variants.MultiDiffEditorVariant,
        scroll_view: *scroll_mod.CompressedVirtualizedScrollView,
        manager: *Manager,
        padding: PaddingItem,
        model: ?*model.MultiDiffEditorViewModel = null,
        items_listener: ?usize = null,
        active_listener: ?usize = null,
        loading_listener: ?usize = null,
        context_keys_listener: ?usize = null,
        layout_listener: ?usize = null,
        preserve_focus_on_load: bool = false,
        initialized_active: bool = false,
        focused: bool = false,
        origin_x: usize = 0,
        origin_y: usize = 0,
        focus_transition: bool = false,
        pending_state: ?IMultiDiffEditorViewState = null,
        pending_scroll: ?scroll_mod.ScrollPosition = null,
        pending_dimensions: ?scroll_mod.ScrollDimensions = null,
        last_error: ?anyerror = null,
        on_did_change_layout: Emitter(void),
        on_did_change_active_control: Emitter(void),

        pub fn create(allocator: Allocator, io: std.Io, queue: *dispatch.Queue, host: Host, variant: variants.MultiDiffEditorVariant) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const scroll_view = try scroll_mod.CompressedVirtualizedScrollView.create(allocator, queue, null);
            errdefer scroll_view.destroy();
            self.* = .{
                .allocator = allocator,
                .io = io,
                .queue = queue,
                .host = host,
                .variant = variant,
                .config = .{ .variant = variants.getMultiDiffEditorVariantConfiguration(variant) },
                .scroll_view = scroll_view,
                .manager = undefined,
                .padding = .{ .change = .init(allocator) },
                .on_did_change_layout = .init(allocator),
                .on_did_change_active_control = .init(allocator),
            };
            errdefer self.padding.change.deinit();
            errdefer self.on_did_change_layout.deinit();
            errdefer self.on_did_change_active_control.deinit();
            self.manager = try Manager.create(allocator, .{
                .context = self,
                .get_id = getItemId,
                .get_template_id = getTemplateId,
                .get_unbound_size = getUnboundSize,
                .on_unbound_change = getUnboundChange,
                .create_template = createTemplate,
                .on_will_unbind = onWillUnbind,
                .on_did_change_control = onBindingControlChanged,
                .on_unexpected_error = onUnexpectedError,
            }, scroll_view);
            errdefer self.manager.destroy();
            self.manager.trailing_item = self.padding.interface();
            self.layout_listener = try scroll_view.on_did_change_layout.listen(self, onLayoutChanged);
            errdefer scroll_view.on_did_change_layout.unlisten(self.layout_listener.?);
            try self.manager.setItems(&.{});
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.setFocused(false) catch {};
            self.detachModel();
            if (self.layout_listener) |id| self.scroll_view.on_did_change_layout.unlisten(id);
            self.manager.destroy();
            self.scroll_view.destroy();
            self.padding.change.deinit();
            self.on_did_change_layout.deinit();
            self.on_did_change_active_control.deinit();
            self.clearPendingRestorationState();
            self.allocator.destroy(self);
        }
        fn detachModel(self: *Self) void {
            if (self.model) |value| {
                if (self.items_listener) |id| value.on_did_change_items.unlisten(id);
                if (self.active_listener) |id| value.on_did_change_active_item.unlisten(id);
                if (self.loading_listener) |id| value.on_did_change_loading.unlisten(id);
                if (self.context_keys_listener) |id| if (value.model.on_did_change_context_keys) |changed| changed.unlisten(id);
            }
            self.context_keys_listener = null;
            self.items_listener = null;
            self.active_listener = null;
            self.loading_listener = null;
            self.model = null;
        }
        pub fn clearPendingRestorationState(self: *Self) void {
            if (self.pending_state) |*state| state.deinit();
            self.pending_state = null;
            self.pending_scroll = null;
            self.pending_dimensions = null;
        }
        pub fn setViewModel(self: *Self, value: ?*model.MultiDiffEditorViewModel, preserve_focus: bool, state: ?IMultiDiffEditorViewState) !void {
            self.preserve_focus_on_load = preserve_focus;
            const model_changed = self.model != value;
            if (model_changed) {
                try self.setFocused(false);
                self.detachModel();
                try self.manager.setItems(&.{});
                self.model = value;
                self.initialized_active = false;
                if (value) |source| {
                    self.items_listener = try source.on_did_change_items.listen(self, onItemsChanged);
                    self.active_listener = try source.on_did_change_active_item.listen(self, onActiveChanged);
                    self.loading_listener = try source.on_did_change_loading.listen(self, onLoadingChanged);
                    if (source.model.on_did_change_context_keys) |changed| self.context_keys_listener = try changed.listen(self, onContextKeysChanged);
                }
            }
            self.clearPendingRestorationState();
            if (state) |saved| {
                self.pending_state = try saved.clone(self.allocator);
                self.pending_scroll = saved.scrollState;
            }
            try self.updateItems();
            if (!model_changed) if (state) |saved| try self.setViewState(saved);
        }
        fn onItemsChanged(_: void, self: *Self) !void {
            try self.updateItems();
        }
        fn onContextKeysChanged(_: void, self: *Self) !void {
            try self.on_did_change_layout.fire({});
        }
        pub fn getContextKey(self: *const Self, key: []const u8) ?@import("../../../../platform/contextkey/common/contextkey.zig").ContextKeyValue {
            return if (self.model) |source| source.model.getContextKey(key) else null;
        }
        fn onLoadingChanged(_: void, self: *Self) !void {
            self.finishRestoredDocs();
            try self.on_did_change_layout.fire({});
        }
        fn finishRestoredDocs(self: *Self) void {
            if (self.model) |value| if (!value.isLoading) {
                if (self.pending_state) |*state| state.deinit();
                self.pending_state = null;
            };
        }
        fn onActiveChanged(_: void, self: *Self) !void {
            for (self.manager.items) |managed| if (managed.binding()) |binding| try binding.template.updateHeader(binding.item);
            try self.on_did_change_active_control.fire({});
            try self.on_did_change_layout.fire({});
        }
        fn onBindingControlChanged(context: *anyopaque, item: *model.DocumentDiffItemViewModel) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.model) |value| if (value.activeDiffItem == item) try self.on_did_change_active_control.fire({});
        }
        fn updateItems(self: *Self) !void {
            const items = if (self.model) |value| value.items else &.{};
            self.scroll_view.beginUpdate();
            var ended = false;
            errdefer if (!ended) self.scroll_view.endUpdate() catch {};
            if (self.pending_state) |state| for (items) |item| {
                const existing = for (self.manager.items) |managed| {
                    if (managed.item == item) break true;
                } else false;
                if (!existing) try self.applyDocState(item, state);
            };
            try self.manager.setItems(items);
            ended = true;
            try self.scroll_view.endUpdate();
            if (self.model) |value| {
                if (self.pending_state) |state| if (state.activeDiffItemKey) |key| {
                    if (self.findItem(key)) |item| {
                        try value.setActive(item);
                        self.initialized_active = true;
                    }
                };
                if (!self.initialized_active and items.len != 0) {
                    self.initialized_active = true;
                    if (value.activeDiffItem == null) {
                        if (self.pending_state != null) {
                            try value.setActive(items[0]);
                        } else {
                            try self.goToFile(0, true, !self.preserve_focus_on_load);
                        }
                    }
                }
            }
            try self.applyPendingScroll();
            self.finishRestoredDocs();
        }
        fn getItemId(_: *anyopaque, item: *model.DocumentDiffItemViewModel) []const u8 {
            return std.mem.asBytes(&item.identity);
        }
        fn getTemplateId(_: *anyopaque, _: *model.DocumentDiffItemViewModel) []const u8 {
            return "diffEditor";
        }
        fn getUnboundSize(context: *anyopaque, item: *model.DocumentDiffItemViewModel) usize {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.config.unboundSize(item);
        }
        fn getUnboundChange(_: *anyopaque, item: *model.DocumentDiffItemViewModel) *Emitter(void) {
            return &item.change;
        }
        fn createTemplate(context: *anyopaque, _: []const u8) !*Template {
            const self: *Self = @ptrCast(@alignCast(context));
            return Template.create(self.allocator, self.io, &self.config, self.queue, self.host);
        }
        fn saveTemplateData(self: *Self, binding: *Binding) !void {
            const selections = if (binding.editor) |editor| try editor.modified_editor.getSelections() else null;
            defer if (selections) |values| self.allocator.free(values);
            try binding.item.setLastTemplateData(binding.getExpandedContentHeight(), selections);
        }
        fn onWillUnbind(context: *anyopaque, binding: *Binding) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.saveTemplateData(binding) catch |err| {
                self.last_error = err;
            };
        }
        fn onUnexpectedError(context: *anyopaque, err: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.last_error = err;
        }
        fn onLayoutChanged(_: void, self: *Self) !void {
            for (self.manager.items) |managed| if (managed.binding()) |binding| binding.setScrollLeft(self.scroll_view.scroll_left);
            try self.applyPendingScroll();
            try self.on_did_change_layout.fire({});
        }

        pub fn getLayoutDebugState(self: *const Self, a: Allocator) !IMultiDiffEditorLayoutDebugState {
            const current_layout = self.scroll_view.layout;
            const entries = self.manager.items;
            if (entries.len > current_layout.items.len) return error.LayoutNotReady;
            const items = try a.alloc(IMultiDiffEditorLayoutDebugState.Item, entries.len);
            for (entries, items, current_layout.items[0..entries.len]) |entry, *item, geometry| {
                const doc = entry.item.documentDiffItem;
                const uri = if (doc.modified) |side| side.uri else if (doc.original) |side| side.uri else null;
                const label = if (uri) |resource| blk: {
                    const path = try std_uri.path(resource, a);
                    const name = std.fs.path.basename(path);
                    if (name.len > 0) break :blk name;
                    if (resource.host) |host| break :blk try host.toRawMaybeAlloc(a);
                    break :blk resource.scheme;
                } else "<none>";
                item.* = .{
                    .key = try a.dupe(u8, entry.item.getKey()),
                    .label = try a.dupe(u8, label),
                    .originalUri = if (doc.original) |side| try std_uri.encodedResource(a, side.uri) else null,
                    .modifiedUri = if (doc.modified) |side| try std_uri.encodedResource(a, side.uri) else null,
                    .collapsed = entry.item.collapsed,
                    .hasTemplate = entry.binding() != null,
                    .verticalState = .{ .contentHeight = entry.size(), .itemViewportOffset = geometry.scrollOffset },
                    .maxScroll = entry.maxScroll(),
                    .layout = geometry,
                };
            }
            return .{
                .scrollLeft = self.scroll_view.scroll_left,
                .scrollDimensions = self.scroll_view.scroll_dimensions,
                .layout = .{
                    .revision = current_layout.revision,
                    .scrollTop = current_layout.scrollTop,
                    .logicalScrollHeight = current_layout.logicalScrollHeight,
                    .scrollHeight = current_layout.scrollHeight,
                    .renderedHeight = current_layout.renderedHeight,
                    .leadingScrollSlack = current_layout.leadingScrollSlack,
                    .trailingScrollSlack = current_layout.trailingScrollSlack,
                    .contentViewport = current_layout.contentViewport,
                    .renderedViewport = current_layout.renderedViewport,
                    .hiddenContentHeightAboveViewport = current_layout.hiddenContentHeightAboveViewport,
                },
                .geometryEdit = if (self.scroll_view.last_geometry_edit) |geometry| .{
                    .fromRevision = geometry.fromRevision,
                    .toRevision = geometry.toRevision,
                    .edits = try a.dupe(layout_mod.ISizeEdit, geometry.edits),
                    .anchorKind = geometry.anchorKind,
                    .anchorOffset = geometry.anchorOffset,
                    .mappedAnchorOffset = geometry.mappedAnchorOffset,
                    .anchorViewportOffset = geometry.anchorViewportOffset,
                    .desiredScrollTop = geometry.desiredScrollTop,
                    .appliedScrollTop = geometry.appliedScrollTop,
                    .leadingScrollSlack = geometry.leadingScrollSlack,
                    .trailingScrollSlack = geometry.trailingScrollSlack,
                } else null,
                .items = items,
            };
        }

        pub fn layout(self: *Self, width: usize, height: usize) !void {
            self.config.width = width;
            try self.scroll_view.setDimensions(width, height, 0);
        }
        pub fn setPaddingBottom(self: *Self, height: usize) !void {
            if (self.padding.height == height) return;
            self.padding.height = height;
            try self.padding.change.fire({});
        }
        pub fn setThemeColors(self: *Self, theme: ?*const ThemeColors) !void {
            self.config.theme = theme;
            for (self.manager.items) |managed| if (managed.binding()) |binding| try binding.updateOptions();
            try self.scroll_view.invalidateLayout();
        }
        pub fn setDiffLayoutOptions(self: *Self, mode: item_template.ViewMode, wrap: ?DiffWordWrap) !void {
            self.config.render_side_by_side = mode != .inline_view;
            self.config.use_inline_when_limited = mode == .automatic;
            if (wrap) |value| self.config.word_wrap = value;
            for (self.manager.items) |managed| if (managed.binding()) |binding| try binding.updateOptions();
            try self.scroll_view.invalidateLayout();
        }
        pub fn setRenderSideBySide(self: *Self, side_by_side: bool) !void {
            try self.setDiffLayoutOptions(if (side_by_side) .side_by_side else .inline_view, null);
        }
        pub fn collapseAll(self: *Self) !void {
            const value = self.model orelse return;
            self.scroll_view.beginUpdate();
            const result = value.collapseAll();
            const ended = self.scroll_view.endUpdate();
            try result;
            try ended;
        }
        pub fn expandAll(self: *Self) !void {
            const value = self.model orelse return;
            self.scroll_view.beginUpdate();
            const result = value.expandAll();
            const ended = self.scroll_view.endUpdate();
            try result;
            try ended;
        }
        pub fn allCollapsed(self: *const Self) bool {
            for (self.manager.items) |managed| if (!managed.item.collapsed) return false;
            return true;
        }
        pub fn bindingFor(self: *const Self, item: *model.DocumentDiffItemViewModel) ?*Binding {
            for (self.manager.items) |managed| if (managed.item == item) return managed.binding();
            return null;
        }
        /// The file list selection follows the active visible item, otherwise
        /// the topmost visible diff. The compressed layout owns visibility.
        pub fn currentVisibleItem(self: *const Self) ?*model.DocumentDiffItemViewModel {
            const active = if (self.model) |value| value.activeDiffItem else null;
            var first: ?*model.DocumentDiffItemViewModel = null;
            for (self.manager.items, 0..) |managed, index| {
                if (index >= self.scroll_view.layout.items.len) break;
                if (self.scroll_view.layout.items[index].visibility != .visible) continue;
                if (managed.item == active) return managed.item;
                if (first == null) first = managed.item;
            }
            return first orelse active;
        }
        pub fn activeControl(self: *Self) ?*Widget {
            const value = self.model orelse return null;
            const active = value.activeDiffItem orelse return null;
            const binding = self.bindingFor(active) orelse return null;
            return binding.editor;
        }
        pub fn getViewState(self: *Self, allocator: Allocator) !IMultiDiffEditorViewState {
            if (self.pending_state) |state| return state.clone(allocator);
            const states = try allocator.alloc(IMultiDiffDocState, self.manager.items.len);
            var initialized: usize = 0;
            errdefer {
                for (states[0..initialized]) |state| {
                    allocator.free(state.key);
                    if (state.selections) |selections| allocator.free(selections);
                }
                allocator.free(states);
            }
            for (self.manager.items, states) |managed, *state| {
                const item = managed.item;
                if (managed.binding()) |binding| try self.saveTemplateData(binding);
                const key = try allocator.dupe(u8, item.key);
                errdefer allocator.free(key);
                const selections = if (item.lastTemplateData.selections) |values| try allocator.dupe(Selection, values) else null;
                state.* = .{ .key = key, .collapsed = item.collapsed, .selections = selections };
                initialized += 1;
            }
            const active = if (self.model) |value| value.activeDiffItem else null;
            return .{ .allocator = allocator, .scrollState = self.scroll_view.getScrollPosition(), .docStates = states, .activeDiffItemKey = if (active) |item| try allocator.dupe(u8, item.key) else null };
        }
        pub fn setViewState(self: *Self, state: IMultiDiffEditorViewState) !void {
            self.clearPendingRestorationState();
            self.pending_state = try state.clone(self.allocator);
            self.pending_scroll = state.scrollState;
            self.scroll_view.beginUpdate();
            for (self.manager.items) |managed| self.applyDocState(managed.item, state) catch |err| {
                self.scroll_view.endUpdate() catch {};
                return err;
            };
            try self.scroll_view.endUpdate();
            if (state.activeDiffItemKey) |key| if (self.findItem(key)) |item| try item.setActive();
            try self.applyPendingScroll();
            self.finishRestoredDocs();
        }
        fn applyDocState(self: *Self, item: *model.DocumentDiffItemViewModel, state: IMultiDiffEditorViewState) !void {
            for (state.docStates) |saved| {
                if (!std.mem.eql(u8, saved.key, item.key)) continue;
                try item.setCollapsed(saved.collapsed);
                try item.setLastTemplateData(item.lastTemplateData.expandedContentHeight, saved.selections);
                if (self.bindingFor(item)) |binding| if (binding.editor) |editor| if (saved.selections) |selections| try editor.modified_editor.setSelections(selections);
                break;
            }
        }
        fn findItem(self: *Self, key: []const u8) ?*model.DocumentDiffItemViewModel {
            const value = self.model orelse return null;
            for (value.items) |item| if (std.mem.eql(u8, item.key, key)) return item;
            return null;
        }
        fn applyPendingScroll(self: *Self) !void {
            const pending = self.pending_scroll orelse return;
            const dims = self.scroll_view.scroll_dimensions;
            if (self.pending_dimensions != null and std.meta.eql(self.pending_dimensions.?, dims)) return;
            self.pending_dimensions = dims;
            try self.scroll_view.setScrollPosition(@intCast(pending.scrollTop), @intCast(pending.scrollLeft));
            const top = @min(pending.scrollTop, dims.scrollHeight -| dims.height);
            const left = @min(pending.scrollLeft, dims.scrollWidth -| dims.width);
            if (top == pending.scrollTop and left == pending.scrollLeft) self.pending_scroll = null;
        }
        pub fn setScrollState(self: *Self, top: ?isize, left: ?isize) !void {
            self.pending_scroll = null;
            self.pending_dimensions = null;
            try self.scroll_view.setScrollPosition(top, left);
        }
        fn uriEquals(self: *Self, a: ?std.Uri, b: ?std.Uri) !bool {
            if (a == null or b == null) return a == null and b == null;
            const a_key = try std_uri.resourceKey(self.allocator, a.?);
            defer self.allocator.free(a_key);
            const b_key = try std_uri.resourceKey(self.allocator, b.?);
            defer self.allocator.free(b_key);
            return std.mem.eql(u8, a_key, b_key);
        }
        pub fn reveal(self: *Self, resource: common.IMultiDiffResourceId, range: ?Range) !void {
            for (self.manager.items, 0..) |managed, index| {
                const item = managed.item.documentDiffItem;
                const original = if (item.original) |source| source.uri else null;
                const modified = if (item.modified) |source| source.uri else null;
                if (try self.uriEquals(original, resource.original) and try self.uriEquals(modified, resource.modified)) {
                    try self.revealIndex(index);
                    if (range) |r| if (managed.binding()) |binding| if (binding.editor) |editor| {
                        const target = if (resource.original != null) editor.original_editor else editor.modified_editor;
                        _ = target.revealRange(r, .Center);
                        try binding.highlightRange(target, r);
                        try self.syncInnerScroll(binding, target.scrollTop());
                    };
                    return;
                }
            }
            return error.DiffResourceNotFound;
        }
        fn revealIndex(self: *Self, index: usize) !void {
            const item = self.manager.items[index].item;
            try item.setActive();
            self.pending_scroll = null;
            self.pending_dimensions = null;
            const top = self.scroll_view.layout.items[index].contentRange.start;
            try self.scroll_view.setLogicalScrollPosition(@intCast(top));
        }
        pub fn goToNextChange(self: *Self) !void {
            try self.navigateToChange(true);
        }
        pub fn goToPreviousChange(self: *Self) !void {
            try self.navigateToChange(false);
        }
        fn navigateToChange(self: *Self, next: bool) !void {
            if (self.manager.items.len == 0) return;
            const value = self.model orelse return;
            const index = for (self.manager.items, 0..) |managed, i| {
                if (managed.item == value.activeDiffItem) break i;
            } else return self.goToFile(0, true, true);
            const item = self.manager.items[index].item;
            if (item.collapsed) try item.setCollapsed(false);
            if (self.bindingFor(item)) |binding| if (binding.editor) |editor| {
                const pos = editor.modified_editor.modelCursorPosition().lineNumber;
                for (editor.state().?.mappings) |mapping| {
                    const modified = mapping.line_range_mapping.modified;
                    if ((next and modified.startLineNumber > pos) or (!next and modified.endLineNumberExclusive <= pos)) {
                        _ = if (next) editor.nextChange() else editor.previousChange();
                        try self.syncInnerScroll(binding, editor.modified_editor.scrollTop());
                        return;
                    }
                }
            };
            const count = self.manager.items.len;
            try self.goToFile(if (next) (index + 1) % count else (index + count - 1) % count, next, true);
        }
        fn goToFile(self: *Self, index: usize, first: bool, focus: bool) !void {
            const item = self.manager.items[index].item;
            if (item.collapsed) try item.setCollapsed(false);
            try self.revealIndex(index);
            if (self.bindingFor(item)) |binding| {
                if (binding.editor) |editor| {
                    const mappings = editor.state().?.mappings;
                    if (mappings.len != 0) {
                        const mapping = mappings[if (first) 0 else mappings.len - 1].line_range_mapping;
                        try editor.modified_editor.setCursorPosition(.{ .lineNumber = @min(mapping.modified.startLineNumber, editor.modifiedModel().getLineCount()), .column = 1 });
                        try self.syncInnerScroll(binding, editor.modified_editor.scrollTop());
                    }
                }
                if (focus) try self.focusItem(item);
            }
        }
        fn syncInnerScroll(self: *Self, binding: *Binding, actual_top: usize) !void {
            if (actual_top == binding.scroll_offset) return;
            const delta = @as(isize, @intCast(actual_top)) - @as(isize, @intCast(binding.scroll_offset));
            try self.setScrollState(@as(isize, @intCast(self.scroll_view.getScrollPosition().scrollTop)) + delta, null);
        }
        pub fn setFocused(self: *Self, value: bool) !void {
            if (self.focus_transition) return;
            self.focused = value;
            const source = self.model orelse return;
            if (value) {
                if (source.activeDiffItem) |item| {
                    const header = if (self.bindingFor(item)) |binding| binding.hasHeaderFocus() else false;
                    try self.focusItemWithHeader(item, header);
                }
            } else if (source.focusedDiffItem) |item| {
                self.focus_transition = true;
                defer self.focus_transition = false;
                const binding = self.bindingFor(item);
                if (binding) |b| {
                    b.blurHeader();
                    if (b.editor) |editor| editor.setEditorFocused(false);
                }
                try item.setFocused(false);
                if (binding) |b| try b.context.notifyChanged();
            }
        }
        fn focusItem(self: *Self, item: *model.DocumentDiffItemViewModel) !void {
            return self.focusItemWithHeader(item, false);
        }
        fn focusItemWithHeader(self: *Self, item: *model.DocumentDiffItemViewModel, header: bool) !void {
            if (self.focus_transition) return;
            self.focus_transition = true;
            defer self.focus_transition = false;
            const value = self.model orelse return;
            if (value.focusedDiffItem) |old| {
                if (old != item) {
                    const old_binding = self.bindingFor(old);
                    if (old_binding) |binding| {
                        binding.blurHeader();
                        if (binding.editor) |editor| editor.setEditorFocused(false);
                    }
                    try old.setFocused(false);
                    if (old_binding) |binding| try binding.context.notifyChanged();
                }
            }
            try item.setFocused(true);
            self.focused = true;
            if (self.bindingFor(item)) |binding| {
                if (header or item.collapsed) {
                    if (!binding.hasHeaderFocus()) _ = binding.focusHeader(false);
                    if (binding.editor) |editor| editor.setEditorFocused(false);
                } else {
                    binding.blurHeader();
                    if (binding.editor) |editor| {
                        editor.setEditorFocused(true);
                        editor.focusedView().focusEditor();
                    }
                }
            }
        }
        fn moveHeaderTab(self: *Self, item: *model.DocumentDiffItemViewModel, direction: ui.dom.FocusDirection) !bool {
            if (direction == .forward and !item.collapsed) {
                try self.focusItem(item);
                return true;
            }
            const index = for (self.manager.items, 0..) |managed, i| {
                if (managed.item == item) break i;
            } else return false;
            const next = if (direction == .forward) index + 1 else if (index > 0) index - 1 else return false;
            if (next >= self.manager.items.len) return false;
            const adjacent = self.manager.items[next].item;
            try self.revealIndex(next);
            if (direction == .backward and !adjacent.collapsed) {
                try self.focusItem(adjacent);
            } else if (self.bindingFor(adjacent)) |binding| {
                _ = binding.focusHeader(direction == .backward);
                try self.focusItemWithHeader(adjacent, true);
            }
            return true;
        }
        pub fn dispatchKey(self: *Self, event: *ui.KeyEvent) !bool {
            const value = self.model orelse return false;
            const item = value.activeDiffItem orelse return false;
            if (self.bindingFor(item)) |binding| {
                if (binding.hasHeaderFocus()) {
                    const result = binding.dispatchHeaderKey(event);
                    if (result.leave) |direction| return self.moveHeaderTab(item, direction);
                    if (result.action) |action| {
                        if (action == .toolbar_action) try binding.runToolbarAction(binding.keyboardToolbarAnchor(self.origin_x, self.origin_y)) else try self.runItemAction(item, action);
                        return true;
                    }
                    return result.handled;
                }
                if (item.collapsed) {
                    if (event.key == .enter or (event.key == .char and event.key.char == ' ')) {
                        try item.setCollapsed(false);
                        return true;
                    }
                } else if (binding.editor) |editor| {
                    const handled = editor.dispatchKey(event);
                    try self.syncInnerScroll(binding, editor.focusedEditor().scrollTop());
                    return handled;
                } else if (event.key == .enter) {
                    try self.runItemAction(item, .open_binary_diff);
                    return true;
                }
            }
            return false;
        }
        pub fn openFile(self: *Self, resource: ?std.Uri) !void {
            if (resource) |uri| {
                if (self.host.open_file) |callback| try callback(self.host.context, uri);
                return;
            }
            const source = self.model orelse return;
            const item = source.activeDiffItem orelse return;
            try self.runItemAction(item, .open_file);
        }
        fn runItemAction(self: *Self, item: *model.DocumentDiffItemViewModel, action: item_template.ItemAction) !void {
            const doc = item.documentDiffItem;
            switch (action) {
                .collapse => try item.setCollapsed(!item.collapsed),
                .open_file => if (self.host.open_file) |callback| try callback(self.host.context, (doc.modified orelse doc.original.?).uri),
                .open_binary_diff => if (self.host.open_binary_diff) |callback| if (doc.original != null and doc.modified != null) try callback(self.host.context, doc.original.?.uri, doc.modified.?.uri),
                .toolbar_action => return error.MissingToolbarAnchor,
            }
        }
        pub fn dispatchMouse(self: *Self, event: *ui.MouseEvent) !bool {
            if (event.kind == .wheel) {
                const pos = self.scroll_view.getScrollPosition();
                try self.setScrollState(@as(isize, @intCast(pos.scrollTop)) + event.delta_y, @as(isize, @intCast(pos.scrollLeft)) + event.delta_x);
                return true;
            }
            const row = self.scroll_view.layout.renderedViewport.start + event.y;
            for (self.manager.items) |managed| if (managed.binding()) |binding| {
                if (binding.hidden) continue;
                const header = binding.headerRange();
                if (header.contains(row)) {
                    const item = binding.item;
                    if (event.kind == .down) try item.setActive();
                    const header_action = try binding.dispatchHeaderMouse(event, row - header.start);
                    if (event.kind == .down and binding.hasHeaderFocus()) try self.focusItemWithHeader(item, true);
                    if (header_action) |action| {
                        if (action == .toolbar_action) {
                            var absolute = event.*;
                            absolute.x += self.origin_x;
                            absolute.y += self.origin_y;
                            try binding.runToolbarAction(@import("../../../../platform/contextview/browser/contextMenuService.zig").Anchor.mouse(&absolute));
                        } else try self.runItemAction(item, action);
                        return true;
                    }
                    return event.default_prevented;
                }
                const body = binding.bodyRange();
                if (!binding.item.collapsed and body.contains(row)) {
                    if (event.kind == .down) try self.focusItem(binding.item);
                    if (binding.editor) |editor| {
                        var local = event.*;
                        local.x -|= self.config.variant.horizontalInsets.left;
                        local.y = row - body.start;
                        const handled = try editor.dispatchMouse(&local);
                        if (local.default_prevented) event.preventDefault();
                        try self.syncInnerScroll(binding, editor.focusedEditor().scrollTop());
                        return handled;
                    }
                    if (event.kind == .down and event.button == .left and binding.binaryActionHit(event.x, row)) {
                        try self.runItemAction(binding.item, .open_binary_diff);
                        return true;
                    }
                    return false;
                }
            };
            return false;
        }
        pub fn pointerAt(self: *Self, x: usize, y: usize) !ui.Pointer {
            const row = self.scroll_view.layout.renderedViewport.start + y;
            for (self.manager.items) |managed| if (managed.binding()) |binding| {
                if (!binding.hidden and binding.rendered_range.contains(row)) return binding.pointerAt(x, row);
            };
            return .default;
        }
        pub fn cursorCell(self: *Self) ?struct { row: usize, col: usize } {
            if (!self.focused) return null;
            const value = self.model orelse return null;
            const item = value.focusedDiffItem orelse return null;
            const binding = self.bindingFor(item) orelse return null;
            const editor = binding.editor orelse return null;
            if (item.collapsed or binding.hidden) return null;
            const cell = editor.cursorCell() orelse return null;
            const absolute = binding.bodyRange().start + cell.row;
            if (!binding.rendered_viewport.contains(absolute) or binding.headerRange().contains(absolute)) return null;
            return .{ .row = absolute - binding.rendered_viewport.start, .col = cell.col + self.config.variant.horizontalInsets.left };
        }
        pub fn paint(self: *Self, frame: *ui.Frame, x: usize, y: usize, width: usize, height: usize) !void {
            self.origin_x = x;
            self.origin_y = y;
            if (width == 0 or height == 0) return;
            if (self.scroll_view.width != width or self.scroll_view.height != height) try self.layout(width, height);
            const bg = if (self.config.theme) |theme| theme.color("multiDiffEditor.background", .{ 30, 30, 30 }) else ui.Color{ .r = 30, .g = 30, .b = 30 };
            const fg = if (self.config.theme) |theme| theme.foreground else ui.Color{ .r = 204, .g = 204, .b = 204 };
            const style: ui.cell.PaintStyle = .{ .bg = ui.cell.packColor(bg), .fg = ui.cell.packColor(fg) };
            frame.next.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), style);
            if (self.manager.items.len == 0) {
                const message = if (self.model == null or self.model.?.isLoading) "Loading..." else "No Changed Files";
                const col = x + (width -| message.len) / 2;
                const row = y + height / 2;
                if (col < frame.next.cols and row < frame.next.rows) frame.next.putAsciiSpan(frame.next.index(col, row), message[0..@min(message.len, @min(width, frame.next.cols - col))], style, false);
                return;
            }
            for (self.manager.items) |managed| if (managed.binding()) |binding| try binding.paint(frame, x, y);
        }
    };
}
