// Native service binding for the context keys owned by terminalService.ts,
// terminalGroupService.ts, terminalEditorService.ts and terminalView.ts.
// Context updates run at instance, active-editor and view visibility events.
const std = @import("std");
const keys_mod = @import("../common/terminalContextKey.zig");
const Keys = keys_mod.TerminalContextKeyStrings;
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const Subscription = @import("../../../../base/common/event.zig").SignalSubscription;
const TerminalService = @import("terminalService.zig").TerminalService;
const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);
const PanelPart = @import("../../../browser/parts/panel/panelPart.zig").PanelPart;
const IWorkbenchLayoutService = @import("../../../services/layout/browser/layoutService.zig").IWorkbenchLayoutService;
const pty = @import("../../../../platform/terminal/node/pty.zig");

pub const TerminalContextKeysHandler = struct {
    part: *EditorPart,
    panel: *PanelPart,
    layout: IWorkbenchLayoutService,
    service: ?*TerminalService = null,
    is_open: contextkey.IContextKey,
    count: contextkey.IContextKey,
    group_count: contextkey.IContextKey,
    has_been_created: contextkey.IContextKey,
    editor_active: contextkey.IContextKey,
    view_showing: contextkey.IContextKey,
    split_active: contextkey.IContextKey,
    subscriptions: [5]?Subscription = @splat(null),
    terminal_subscriptions: [3]?Subscription = @splat(null),

    pub fn init(self: *TerminalContextKeysHandler, keys: contextkey.IContextKeyService, part: *EditorPart, panel: *PanelPart, layout: IWorkbenchLayoutService) !void {
        _ = try keys.createKey(Keys.ProcessSupported, .{ .boolean = pty.is_supported });
        self.* = .{
            .part = part,
            .panel = panel,
            .layout = layout,
            .is_open = try keys.createKey(Keys.IsOpen, .{ .boolean = false }),
            .count = try keys.createKey(Keys.Count, .{ .number = 0 }),
            .group_count = try keys.createKey(Keys.GroupCount, .{ .number = 0 }),
            .has_been_created = try keys.createKey(Keys.TerminalHasBeenCreated, .{ .boolean = false }),
            .editor_active = try keys.createKey(Keys.TerminalEditorActive, .{ .boolean = false }),
            .view_showing = try keys.createKey(Keys.ViewShowing, .{ .boolean = false }),
            .split_active = try keys.createKey(Keys.SplitPaneActive, .{ .boolean = false }),
        };
        errdefer self.deinit();
        inline for (.{ &part.service.on_did_active_editor_change, &part.service.on_did_visible_editors_change, &panel.pane.on_did_pane_composite_open, &panel.pane.on_did_pane_composite_close, layout.on_did_change_part_visibility }, 0..) |source, index| {
            self.subscriptions[index] = try source.listenSignal(self, update);
        }
        try self.update();
    }

    pub fn attach(self: *TerminalContextKeysHandler, service: *TerminalService) !void {
        self.detach();
        self.service = service;
        errdefer self.detach();
        inline for (.{ &service.group.on_did_change_active_instance, &service.group.on_did_change_instances, &service.editor.on_did_change_instances }, 0..) |source, index| {
            self.terminal_subscriptions[index] = try source.listenSignal(self, update);
        }
        try self.update();
    }

    fn detach(self: *TerminalContextKeysHandler) void {
        for (&self.terminal_subscriptions) |*entry| {
            if (entry.*) |subscription| subscription.dispose();
            entry.* = null;
        }
        self.service = null;
    }

    pub fn deinit(self: *TerminalContextKeysHandler) void {
        self.detach();
        for (&self.subscriptions) |*entry| {
            if (entry.*) |subscription| subscription.dispose();
            entry.* = null;
        }
    }

    fn update(self: *TerminalContextKeysHandler) !void {
        const count = if (self.service) |service| service.instanceCount() else 0;
        const group_count = if (self.service) |service| service.group.groupCount() else 0;
        self.is_open.set(.{ .boolean = count > 0 });
        if (count > 0) self.has_been_created.set(.{ .boolean = true });
        self.count.set(.{ .number = @floatFromInt(count) });
        self.group_count.set(.{ .number = @floatFromInt(group_count) });
        const active_editor = if (self.part.activeView()) |pane| pane.panes.activePane() else null;
        self.editor_active.set(.{ .boolean = active_editor != null and active_editor.?.terminal_input != null });
        self.view_showing.set(.{ .boolean = self.layout.isVisible(.panel) and std.mem.eql(u8, self.panel.pane.active_id orelse "", "terminal") });
        const split = if (self.service) |service| blk: {
            if (service.group.activeInstance() == null) break :blk false;
            const range = service.group.groupRange(service.group.active);
            break :blk range.end - range.first > 1;
        } else false;
        self.split_active.set(.{ .boolean = split });
    }
};
