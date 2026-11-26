// Port of `src/vs/editor/contrib/peekView/browser/peekView.ts`'s
// PeekViewWidget. The title/action bar and body are retained nodes on a real
// model-anchored ZoneWidget. The browser's thin border and arrow are projected
// to one header/bottom cell row; the body is a mounted editor, not copied text.
const std = @import("std");
const ui = @import("ui");
const browser = @import("../../../browser/editorBrowser.zig");
const view_mod = @import("../../../browser/widget/codeEditor/terminalEditorView.zig");
const Position = @import("../../../common/core/position.zig").Position;
const ZoneWidget = @import("../../zoneWidget/browser/zoneWidget.zig").ZoneWidget;
const css = @import("media/peekViewWidget_css.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const PeekViewWidget = struct {
    allocator: std.mem.Allocator,
    zone: ZoneWidget = undefined,
    body_delegate: BodyDelegate,
    title: []u8 = &.{},
    detail: []u8 = &.{},
    actions: []const Action = &.{},
    extra_actions: ?ActionSet = null,
    pending_actions: ?ActionSet = null,
    picker_action: ?Action = null,
    picker_label: []u8 = &.{},
    picker_node: ?*ui.Node = null,
    frame_color: ui.Color = .{ .r = 0, .g = 122, .b = 204 },
    node: ?*ui.Node = null,
    header: ?*ui.Node = null,
    title_node: ?*ui.Node = null,
    detail_node: ?*ui.Node = null,
    action_bar: ?*ui.Node = null,
    body: ?*ui.Node = null,
    bottom: ?*ui.Node = null,
    on_did_close: Emitter(void),

    pub const Action = struct {
        id: []const u8,
        label: []const u8,
        glyph: []const u8,
        context: *anyopaque,
        run: *const fn (*anyopaque) void,
        run_with_id: ?*const fn (*anyopaque, []const u8) void = null,
        enabled: bool = true,
    };
    const ActionSet = struct {
        arena: std.heap.ArenaAllocator,
        actions: []Action,
        fn deinit(self: *ActionSet) void {
            self.arena.deinit();
        }
    };
    pub const BodyDelegate = struct {
        context: *anyopaque,
        layout: *const fn (*anyopaque, *ui.Node, browser.IViewZone.RenderInfo, usize) anyerror!void,
        remove: *const fn (*anyopaque) void,
        position: ?*const fn (*anyopaque, f64) void = null,
    };

    pub fn init(self: *PeekViewWidget, allocator: std.mem.Allocator, view: *view_mod.IEditorView, actions: []const Action, body_delegate: BodyDelegate) !void {
        self.* = .{ .allocator = allocator, .body_delegate = body_delegate, .actions = actions, .on_did_close = .init(allocator) };
        errdefer self.on_did_close.deinit();
        try self.zone.init(allocator, view.editor, view, .{ .is_resizeable = true, .keep_editor_selection = true, .is_accessible = true }, .{ .context = self, .build = build, .update = update, .before_remove = beforeRemove, .on_top = onTop });
    }

    pub fn deinit(self: *PeekViewWidget) void {
        self.zone.deinit();
        self.on_did_close.fire({}) catch {};
        self.on_did_close.deinit();
        self.allocator.free(self.title);
        self.allocator.free(self.detail);
        self.allocator.free(self.picker_label);
        if (self.extra_actions) |*set| set.deinit();
        if (self.pending_actions) |*set| set.deinit();
    }

    pub fn setTitle(self: *PeekViewWidget, title: []const u8, detail: []const u8) !void {
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);
        const detail_copy = try self.allocator.dupe(u8, detail);
        self.allocator.free(self.title);
        self.allocator.free(self.detail);
        self.title = title_copy;
        self.detail = detail_copy;
        if (self.zone.zone_id != null) try self.zone.refresh();
    }

    /// The action bar is rebuilt in the next zone update: event dispatch may
    /// still have a reference to one of the old action nodes.
    pub fn setExtraActions(self: *PeekViewWidget, actions: []const Action) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const copy = try a.dupe(Action, actions);
        for (copy) |*action| {
            action.id = try a.dupe(u8, action.id);
            action.label = try a.dupe(u8, action.label);
            action.glyph = try a.dupe(u8, action.glyph);
        }
        if (self.pending_actions) |*pending| pending.deinit();
        self.pending_actions = .{ .arena = arena, .actions = copy };
        if (self.zone.zone_id != null) self.zone.refresh() catch {};
    }

    pub fn setPickerLabel(self: *PeekViewWidget, label: []const u8) !void {
        const copy = try self.allocator.dupe(u8, label);
        self.allocator.free(self.picker_label);
        self.picker_label = copy;
        if (self.zone.zone_id != null) try self.zone.refresh();
    }

    pub fn style(self: *PeekViewWidget, frame_color: ui.Color) void {
        self.frame_color = frame_color;
        if (self.zone.zone_id != null) self.zone.refresh() catch {};
    }

    pub fn show(self: *PeekViewWidget, anchor: Position, height: usize) !void {
        try self.zone.show(anchor, height);
    }

    fn color(self: *PeekViewWidget, id: []const u8, default: [3]u8) ui.Color {
        return if (self.zone.view.themeColors()) |colors| colors.color(id, default) else .{ .r = default[0], .g = default[1], .b = default[2] };
    }

    fn element(parent: *ui.Node, class: css.Class, tag: ui.dom.Tag) !*ui.Node {
        const node = try parent.document.createElement(tag);
        errdefer parent.document.destroy(node);
        try node.addClass(class);
        _ = try parent.appendChild(node);
        return node;
    }

    fn build(context: *anyopaque, root: *ui.Node, info: browser.IViewZone.RenderInfo) !void {
        const self: *PeekViewWidget = @ptrCast(@alignCast(context));
        self.node = root;
        try root.addClass(css.Class.peekview_widget);
        self.header = try element(root, .head, .div);
        const title = try element(self.header.?, .peekview_title, .div);
        if (self.picker_action) |*action| {
            const picker = try element(title, .dropdown, .span);
            try picker.setAttribute("role", "button");
            try picker.setAttribute("aria-label", action.label);
            try picker.addEventListener(.{ .context = action, .mouse_down = actionClick });
            self.picker_node = picker;
        }
        self.title_node = try element(title, .filename, .span);
        self.detail_node = try element(title, .meta, .span);
        self.action_bar = try element(self.header.?, .peekview_actions, .div);
        try self.renderActions();
        self.body = try element(root, .body, .div);
        self.bottom = try root.document.createElement(.div);
        _ = try root.appendChild(self.bottom.?);
        try self.updateLayout(info);
    }

    fn renderActions(self: *PeekViewWidget) !void {
        const bar = self.action_bar orelse return;
        bar.document.destroyChildren(bar);
        if (self.pending_actions) |pending| {
            if (self.extra_actions) |*old| old.deinit();
            self.extra_actions = pending;
            self.pending_actions = null;
        }
        if (self.extra_actions) |set| for (set.actions) |*action| try self.renderAction(action);
        for (self.actions) |*action| try self.renderAction(action);
    }

    fn renderAction(self: *PeekViewWidget, action: *const Action) !void {
        const bar = self.action_bar.?;
        const button = try bar.document.createElement(.span);
        errdefer bar.document.destroy(button);
        try button.setAttribute("role", "button");
        try button.setAttribute("aria-label", action.label);
        try button.setAttribute("data-peek-action", action.id);
        if (!action.enabled) try button.setAttribute("aria-disabled", "true");
        button.setStyle(.{ .width = .{ .cells = 3 }, .height = .{ .cells = 1 }, .pointer = if (action.enabled) .pointer else .default, .text_align = .center });
        if (action.enabled) button.setHoverStyle(.{ .background = self.color("toolbar.hoverBackground", .{ 64, 64, 64 }) });
        try button.setTextContent(action.glyph);
        try button.addEventListener(.{ .context = @constCast(action), .mouse_down = actionClick });
        _ = try bar.appendChild(button);
    }

    fn update(context: *anyopaque, _: *ui.Node, info: browser.IViewZone.RenderInfo) !void {
        const self: *PeekViewWidget = @ptrCast(@alignCast(context));
        try self.updateLayout(info);
    }

    fn updateLayout(self: *PeekViewWidget, info: browser.IViewZone.RenderInfo) !void {
        if (self.pending_actions != null) try self.renderActions();
        const bg = self.color("peekViewTitle.background", .{ 30, 30, 30 });
        self.header.?.setStyle(.{ .width = .{ .percent = 100 }, .background = bg });
        self.title_node.?.setStyle(.{ .color = self.color("peekViewTitleLabel.foreground", .{ 204, 204, 204 }), .bold = true });
        self.detail_node.?.setStyle(.{ .color = self.color("peekViewTitleDescription.foreground", .{ 153, 153, 153 }) });
        if (self.picker_node) |picker| {
            picker.setStyle(.{ .display = if (self.picker_label.len == 0) .none else .inline_block });
            try picker.setTextContent(self.picker_label);
        }
        try self.title_node.?.setTextContent(self.title);
        try self.detail_node.?.setTextContent(self.detail);
        const body_rows = info.height -| 2;
        self.body.?.setStyle(.{ .position = .absolute, .top = .{ .cells = 1 }, .left = .{ .cells = 0 }, .width = .{ .percent = 100 }, .height = .{ .cells = @floatFromInt(body_rows) } });
        self.bottom.?.setStyle(.{ .position = .absolute, .top = .{ .cells = @floatFromInt(info.height -| 1) }, .width = .{ .percent = 100 }, .height = .{ .cells = @floatFromInt(@min(info.height -| 1, 1)) }, .background = self.frame_color, .pointer = .ns_resize });
        if (body_rows != 0) {
            try self.body_delegate.layout(self.body_delegate.context, self.body.?, info, body_rows);
        } else self.body_delegate.remove(self.body_delegate.context);
    }

    fn actionClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
        if (event.button != .left) return;
        const action: *const Action = @ptrCast(@alignCast(context.?));
        event.preventDefault();
        event.stopPropagation();
        if (!action.enabled) return;
        if (action.run_with_id) |run| run(action.context, action.id) else action.run(action.context);
    }

    fn beforeRemove(context: *anyopaque) void {
        const self: *PeekViewWidget = @ptrCast(@alignCast(context));
        self.body_delegate.remove(self.body_delegate.context);
        self.node = null;
        self.header = null;
        self.title_node = null;
        self.picker_node = null;
        self.detail_node = null;
        self.action_bar = null;
        self.body = null;
        self.bottom = null;
    }
    fn onTop(context: *anyopaque, top: f64) void {
        const self: *PeekViewWidget = @ptrCast(@alignCast(context));
        if (self.body_delegate.position) |update_position| update_position(self.body_delegate.context, top);
    }
};
