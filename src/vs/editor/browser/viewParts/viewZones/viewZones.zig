// Port of `src/vs/editor/browser/viewParts/viewZones/viewZones.ts`.
// Terminal adaptations: integer cells, document-owned nodes built from the
// zone delegate on entry/explicit layout, and a retained container translated
// on scroll. Model-to-view anchoring, hidden areas, whitespace transactions,
// view events, and content/margin zone ownership follow the upstream part.
const std = @import("std");
const ui = @import("ui");
const browser = @import("../../editorBrowser.zig");
const model = @import("../../../common/viewModel.zig");
const Position = @import("../../../common/core/position.zig").Position;
const ViewContext = @import("../../../common/viewModel/viewContext.zig").ViewContext;
const ViewPart = @import("../../view/viewPart.zig").ViewPart;
const rendering = @import("../../view/renderingContext.zig");
const events = @import("../../../common/viewEvents.zig");
const Editor = @import("../../widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

pub const IViewZone = browser.IViewZone;
pub const IViewZoneChangeAccessor = browser.IViewZoneChangeAccessor;
const WhitespaceAccessor = model.IWhitespaceChangeAccessor;

pub const ViewZones = struct {
    allocator: std.mem.Allocator,
    editor: ?*Editor = null,
    base: ViewPart = undefined,
    zones: std.StringHashMapUnmanaged(Zone) = .empty,
    retired_nodes: std.ArrayList(*ui.Node) = .empty,
    render_error: ?anyerror = null,

    const Props = struct {
        after_view_line: usize,
        height: usize,
        hidden: bool,
    };

    const Zone = struct {
        delegate: IViewZone,
        props: Props,
        visible: bool = false,
        top: f64 = 0,
        height: usize = 0,
        content: NodeState = .{},
        margin: NodeState = .{},
        dirty: bool = true,
    };

    const NodeState = struct {
        node: ?*ui.Node = null,
        top: f64 = 0,
        left: usize = 0,
        width: usize = 0,
        height: usize = 0,
        scroll_left: usize = 0,
        visible_start: usize = 0,
        visible_end: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator) ViewZones {
        return .{ .allocator = allocator };
    }

    pub fn attach(self: *ViewZones, editor: *Editor, context: *ViewContext) void {
        std.debug.assert(self.editor == null);
        self.editor = editor;
        self.base.initWithHandlerContext(context, self, .{
            .onConfigurationChanged = onConfigurationChanged,
            .onLineMappingChanged = onLineMappingChanged,
            .onFlushed = onFlushed,
            .onLinesInserted = onLinesInserted,
            .onLinesDeleted = onLinesDeleted,
            .onScrollChanged = onScrollChanged,
            .onZonesChanged = onZonesChanged,
        }, prepareRender, render);
    }

    pub fn deinit(self: *ViewZones) void {
        if (self.editor) |editor| {
            self.base.deinit();
            editor.changeWhitespace(self, struct {
                fn removeAll(zones: *ViewZones, accessor: WhitespaceAccessor) anyerror!void {
                    var keys = zones.zones.keyIterator();
                    while (keys.next()) |id| try accessor.remove(id.*);
                }
            }.removeAll) catch {};
        }
        self.zones.deinit(self.allocator);
        self.retired_nodes.deinit(self.allocator);
    }

    fn computeProps(self: *ViewZones, zone: IViewZone) Props {
        const editor = self.editor.?;
        if (zone.after_line_number == 0) return .{
            .after_view_line = 0,
            .height = zone.height_in_lines,
            .hidden = false,
        };
        const line = @min(zone.after_line_number, editor.model.getLineCount());
        const max_column = editor.model.getLineMaxColumn(line);
        const after = editor.model.validatePosition(Position.init(line, zone.after_column orelse max_column));
        const before = editor.model.validatePosition(if (after.column == max_column)
            Position.init(after.lineNumber + 1, 1)
        else
            Position.init(after.lineNumber, after.column + 1));
        const converter = editor.converter.interface();
        const view_position = converter.convertModelPositionToViewPosition(converter.context, after, zone.after_column_affinity, true, false);
        const visible = zone.show_in_hidden_areas or editor.isModelLineVisible(before.lineNumber);
        return .{
            .after_view_line = view_position.lineNumber,
            .height = if (visible) zone.height_in_lines else 0,
            .hidden = !visible,
        };
    }

    pub fn changeViewZones(
        self: *ViewZones,
        context: anytype,
        comptime callback: fn (@TypeOf(context), IViewZoneChangeAccessor) anyerror!void,
    ) !void {
        const editor = self.editor orelse return error.ViewZonePartNotAttached;
        const Transaction = struct {
            owner: *ViewZones,
            user_context: @TypeOf(context),
            fn run(transaction: *@This(), whitespace: WhitespaceAccessor) anyerror!void {
                var accessor = TransactionAccessor{
                    .owner = transaction.owner,
                    .whitespace = whitespace,
                };
                try callback(transaction.user_context, accessor.interface());
            }
        };
        var transaction = Transaction{ .owner = self, .user_context = context };
        try editor.changeWhitespace(&transaction, Transaction.run);
    }

    const TransactionAccessor = struct {
        owner: *ViewZones,
        whitespace: WhitespaceAccessor,

        fn interface(self: *TransactionAccessor) IViewZoneChangeAccessor {
            return .{ .context = self, .add_zone = add, .remove_zone = remove, .layout_zone = layout };
        }

        fn add(context: *anyopaque, delegate: IViewZone) anyerror![]const u8 {
            const self: *TransactionAccessor = @ptrCast(@alignCast(context));
            const owner = self.owner;
            try owner.zones.ensureUnusedCapacity(owner.allocator, 1);
            const props = owner.computeProps(delegate);
            const ordinal = delegate.ordinal orelse if (delegate.after_column) |col| @as(i32, @intCast(@min(col, std.math.maxInt(i32)))) else 10000;
            const id = try self.whitespace.insert(props.after_view_line, ordinal, @floatFromInt(props.height), @floatFromInt(delegate.min_width));
            owner.zones.putAssumeCapacity(id, .{ .delegate = delegate, .props = props });
            if (delegate.on_computed_height) |notify| notify(delegate.context, props.height);
            owner.base.handler.forceShouldRender();
            return id;
        }

        fn remove(context: *anyopaque, id: []const u8) anyerror!void {
            const self: *TransactionAccessor = @ptrCast(@alignCast(context));
            const owner = self.owner;
            const zone = owner.zones.get(id) orelse return;
            try owner.retired_nodes.ensureUnusedCapacity(owner.allocator, 2);
            try self.whitespace.remove(id);
            if (zone.content.node) |node| owner.retired_nodes.appendAssumeCapacity(node);
            if (zone.margin.node) |node| owner.retired_nodes.appendAssumeCapacity(node);
            _ = owner.zones.remove(id);
            owner.base.handler.forceShouldRender();
        }

        fn layout(context: *anyopaque, id: []const u8, delegate: IViewZone) anyerror!void {
            const self: *TransactionAccessor = @ptrCast(@alignCast(context));
            const owner = self.owner;
            const zone = owner.zones.getPtr(id) orelse return;
            const props = owner.computeProps(delegate);
            try self.whitespace.changeOne(id, props.after_view_line, @floatFromInt(props.height));
            zone.delegate = delegate;
            zone.props = props;
            zone.dirty = true;
            if (delegate.on_computed_height) |notify| notify(delegate.context, props.height);
            owner.base.handler.forceShouldRender();
        }
    };

    pub fn shouldSuppressMouseDownOnViewZone(self: *const ViewZones, id: []const u8) bool {
        return if (self.zones.get(id)) |zone| zone.delegate.suppress_mouse_down else false;
    }

    fn recomputeWhitespacesProps(self: *ViewZones) !void {
        if (self.zones.count() == 0) return;
        const editor = self.editor.?;
        const old = try editor.viewLayout().getWhitespaces(self.allocator);
        defer self.allocator.free(old);
        const Transaction = struct {
            zones: *ViewZones,
            old: []const model.IEditorWhitespace,
            fn run(transaction: @This(), accessor: WhitespaceAccessor) anyerror!void {
                for (transaction.old) |whitespace| {
                    const zone = transaction.zones.zones.getPtr(whitespace.id) orelse continue;
                    const props = transaction.zones.computeProps(zone.delegate);
                    zone.props = props;
                    if (whitespace.afterLineNumber != props.after_view_line or whitespace.height != @as(f64, @floatFromInt(props.height))) {
                        try accessor.changeOne(whitespace.id, props.after_view_line, @floatFromInt(props.height));
                        if (zone.delegate.on_computed_height) |notify| notify(zone.delegate.context, props.height);
                    }
                }
            }
        };
        try editor.changeWhitespace(Transaction{ .zones = self, .old = old }, Transaction.run);
    }

    fn onLineMappingChanged(context: *anyopaque, _: *const events.ViewLineMappingChangedEvent) bool {
        const self: *ViewZones = @ptrCast(@alignCast(context));
        self.recomputeWhitespacesProps() catch |err| {
            self.render_error = err;
        };
        return true;
    }
    fn onConfigurationChanged(_: *anyopaque, _: *const events.ViewConfigurationChangedEvent) bool {
        return true;
    }
    fn onFlushed(_: *anyopaque, _: *const events.ViewFlushedEvent) bool {
        return true;
    }
    fn onLinesInserted(_: *anyopaque, _: *const events.ViewLinesInsertedEvent) bool {
        return true;
    }
    fn onLinesDeleted(_: *anyopaque, _: *const events.ViewLinesDeletedEvent) bool {
        return true;
    }
    fn onScrollChanged(_: *anyopaque, e: *const events.ViewScrollChangedEvent) bool {
        return e.scrollTopChanged or e.scrollWidthChanged or e.scrollLeftChanged;
    }
    fn onZonesChanged(_: *anyopaque, _: *const events.ViewZonesChangedEvent) bool {
        return true;
    }

    fn prepareRender(_: *ViewPart, _: *rendering.RenderingContext) void {}

    fn render(part: *ViewPart, ctx: *rendering.RestrictedRenderingContext) void {
        const self: *ViewZones = @fieldParentPtr("base", part);
        var values = self.zones.valueIterator();
        while (values.next()) |zone| zone.visible = false;
        for (ctx.viewportData.whitespaceViewportData) |whitespace| {
            const zone = self.zones.getPtr(whitespace.id) orelse continue;
            if (zone.props.hidden or whitespace.height <= 0) continue;
            zone.visible = true;
            zone.top = ctx.getScrolledTopFromAbsoluteTop(whitespace.verticalOffset);
            zone.height = @intFromFloat(whitespace.height);
        }
        values = self.zones.valueIterator();
        while (values.next()) |zone| {
            if (zone.delegate.on_dom_node_top) |notify| notify(zone.delegate.context, if (zone.visible) zone.top else ctx.getScrolledTopFromAbsoluteTop(-1000000));
        }
    }

    /// Content has changed without changing the model anchor or whitespace.
    pub fn invalidateZoneContent(self: *ViewZones, id: []const u8) void {
        if (self.zones.getPtr(id)) |zone| {
            zone.dirty = true;
            self.base.handler.forceShouldRender();
        }
    }

    pub fn resetNodes(self: *ViewZones) void {
        var values = self.zones.valueIterator();
        while (values.next()) |zone| {
            zone.content = .{};
            zone.margin = .{};
            zone.dirty = true;
        }
        self.retired_nodes.clearRetainingCapacity();
    }

    pub fn renderDocument(self: *ViewZones, doc: *ui.Document, content_root: *ui.Node, margin_root: *ui.Node, gutter: usize, text_width: usize, scroll_left: usize, host: ?*browser.RetainedViewPartHost) !void {
        if (self.render_error) |err| {
            self.render_error = null;
            return err;
        }
        for (self.retired_nodes.items) |node| destroyNode(doc, node, host);
        self.retired_nodes.clearRetainingCapacity();
        const viewport_height = if (self.editor) |editor| editor.textHeight() else 0;
        var values = self.zones.valueIterator();
        while (values.next()) |zone| {
            try renderNode(doc, host, content_root, &zone.content, zone, zone.delegate.build, zone.delegate.update, gutter, text_width, scroll_left, viewport_height);
            try renderNode(doc, host, margin_root, &zone.margin, zone, zone.delegate.build_margin, zone.delegate.update_margin, 0, gutter, 0, viewport_height);
            zone.dirty = false;
        }
    }

    fn destroyNode(doc: *ui.Document, node: *ui.Node, host: ?*browser.RetainedViewPartHost) void {
        if (host) |retained| retained.removeSubtree(node);
        doc.destroy(node);
    }

    fn renderNode(doc: *ui.Document, host: ?*browser.RetainedViewPartHost, root: *ui.Node, state: *NodeState, zone: *Zone, builder: ?IViewZone.Build, updater: ?IViewZone.Update, left: usize, width: usize, scroll_left: usize, viewport_height: usize) !void {
        if (!zone.visible or builder == null or width == 0) {
            if (state.node) |node| destroyNode(doc, node, host);
            state.* = .{};
            return;
        }
        const visible_start: usize = if (zone.delegate.clip_to_viewport) @intFromFloat(@max(0, -zone.top)) else 0;
        const visible_end: usize = if (zone.delegate.clip_to_viewport)
            @min(zone.height, @as(usize, @intFromFloat(@max(0, @as(f64, @floatFromInt(viewport_height)) - zone.top))))
        else
            zone.height;
        const height = visible_end -| visible_start;
        const top = zone.top + @as(f64, @floatFromInt(visible_start));
        if (height == 0) {
            if (state.node) |node| destroyNode(doc, node, host);
            state.* = .{};
            return;
        }
        const rebuild = zone.dirty or state.left != left or state.width != width or state.height != height or state.scroll_left != scroll_left or state.visible_start != visible_start or state.visible_end != visible_end;
        const info: IViewZone.RenderInfo = .{ .width = width, .height = zone.height, .scroll_left = scroll_left, .visible_start_row = visible_start, .visible_end_row = visible_end };
        if (rebuild and updater != null and state.node != null) {
            const node = state.node.?;
            var style = node.asElement().style;
            style.left = .{ .cells = @floatFromInt(left) };
            style.top = .{ .cells = top };
            style.width = .{ .cells = @floatFromInt(width) };
            style.height = .{ .cells = @floatFromInt(height) };
            node.setStyle(style);
            try updater.?(zone.delegate.context, node.first_child.?, info);
            if (host) |retained| try retained.rebuildSubtree(node);
            state.* = .{ .node = node, .top = top, .left = left, .width = width, .height = height, .scroll_left = scroll_left, .visible_start = visible_start, .visible_end = visible_end };
            return;
        }
        if (rebuild) {
            if (state.node) |node| destroyNode(doc, node, host);
            state.* = .{};
        }
        if (state.node) |node| {
            if (state.top != top) {
                var style = node.asElement().style;
                style.top = .{ .cells = top };
                node.setStyle(style);
                if (host) |retained| retained.translateSubtree(node, top - state.top);
                state.top = top;
            }
            return;
        }
        const node = try doc.createElement(.div);
        errdefer doc.destroy(node);
        node.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(left) },
            .top = .{ .cells = top },
            .width = .{ .cells = @floatFromInt(width) },
            .height = .{ .cells = @floatFromInt(height) },
            .overflow = .hidden,
        });
        const content = try builder.?(zone.delegate.context, doc, info);
        _ = try node.appendChild(content);
        _ = try root.appendChild(node);
        if (host) |retained| try retained.addSubtree(node);
        state.* = .{ .node = node, .top = top, .left = left, .width = width, .height = height, .scroll_left = scroll_left, .visible_start = visible_start, .visible_end = visible_end };
    }
};
