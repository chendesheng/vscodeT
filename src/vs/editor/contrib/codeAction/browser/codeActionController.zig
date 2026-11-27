// Port of `src/vs/editor/contrib/codeAction/browser/codeActionController.ts`.
// Model queries, lightbulb presentation, action list and apply requests retain
// distinct ownership. The terminal action widget delegates native input to
// the window context view, not the workbench editor shell.
const std = @import("std");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const Position = @import("../../../common/core/position.zig").Position;
const language = @import("../../../common/languages.zig");
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(language.CodeActionProvider);
const MarkerService = @import("../../../../platform/markers/common/markerService.zig").MarkerService;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const cancellation = @import("../../../../base/common/cancellation.zig");
const Disposable = cancellation.IDisposable;
const bulk = @import("../../../browser/services/bulkEditService.zig");
const menu = @import("../../../../platform/contextview/browser/contextMenuService.zig");
const action_widget = @import("../../../../platform/actionWidget/browser/actionWidget.zig");
const action_list = @import("../../../../platform/actionWidget/browser/actionList.zig");
const resource_config = @import("../../../common/services/textResourceConfiguration.zig");
const codeAction = @import("codeAction.zig");
const model_mod = @import("codeActionModel.zig");
const types = @import("../common/types.zig");
const LightBulbWidget = @import("lightBulbWidget.zig").LightBulbWidget;

pub const Services = struct {
    registry: *Registry,
    markers: ?*MarkerService,
    window: *dispatch.Queue,
    action_widget: action_widget.IActionWidgetService,
    bulk_edit: bulk.IBulkEditService,
    commands: language.CommandHost,
    configuration: ?resource_config.ITextResourceConfigurationService = null,
};

pub const CodeActionController = struct {
    pub const ID = "editor.contrib.codeActionController";
    allocator: std.mem.Allocator,
    editor: *Editor,
    view: ?*View = null,
    services: ?Services = null,
    model: ?*model_mod.CodeActionModel = null,
    lightbulb: ?LightBulbWidget = null,
    active: ?*codeAction.ManagedCodeActionSet = null,
    apply_request: ?*ApplyRequest = null,
    model_will_listener: ?usize = null,
    show_disabled: bool = false,
    menu_all: bool = false,
    menu_include_disabled: bool = false,
    menu_from_lightbulb: bool = false,
    menu_anchor: menu.Anchor = .{ .x = 0, .y = 0 },
    bound: bool = false,

    pub fn getOrCreate(editor: *Editor, view: *View, services: Services) !*CodeActionController {
        if (editor.getInstantiatedContribution(CodeActionController)) |existing| {
            try existing.bind(view, services);
            return existing;
        }
        const self = try editor.allocator.create(CodeActionController);
        self.* = .{ .allocator = editor.allocator, .editor = editor };
        errdefer self.dispose();
        try self.bind(view, services);
        try editor.registerOwnedContribution(CodeActionController, self, dispose);
        return self;
    }

    pub fn registerFactory(editor: *Editor, context: *anyopaque, instantiate: *const fn (*anyopaque) anyerror!void) !void {
        try editor.registerContributionFactory(.{ .id = ID, .context = context, .instantiate = instantiate, .instantiation = .eventually });
    }

    fn bind(self: *CodeActionController, view: *View, services: Services) !void {
        if (self.bound and self.view == view) return;
        self.unbind();
        self.view = view;
        self.services = services;
        self.bound = true;
        errdefer self.unbind();
        self.lightbulb = .{ .view = view, .context = self, .on_click = onLightbulb };
        try self.lightbulb.?.bind();
        self.model_will_listener = try self.editor.on_will_change_model.listen(self, onWillChangeModel);
        self.model = try model_mod.CodeActionModel.create(self.allocator, self.editor, services.registry, services.markers, services.window, self, onState);
        self.updateSettings();
    }

    pub fn unbind(self: *CodeActionController) void {
        self.bound = false;
        if (self.model_will_listener) |id| self.editor.on_will_change_model.unlisten(id);
        self.model_will_listener = null;
        self.cancelApply();
        if (self.model) |model| model.dispose();
        self.model = null;
        self.clearActive();
        if (self.lightbulb) |*widget| widget.unbind();
        self.lightbulb = null;
        self.services = null;
        self.view = null;
    }

    pub fn dispose(self: *CodeActionController) void {
        self.unbind();
        self.allocator.destroy(self);
    }

    fn onWillChangeModel(_: @import("../../../common/editorCommon.zig").IModelChangedEvent, self: *CodeActionController) !void {
        self.cancelApply();
        self.clearActive();
    }

    pub fn updateSettings(self: *CodeActionController) void {
        if (self.model) |model| if (self.view) |view| model.setMode(view.terminal_view_host.options.get(.lightbulb).enabled);
    }

    fn clearActive(self: *CodeActionController) void {
        if (self.services) |services| services.action_widget.hide(self);
        if (self.lightbulb) |*widget| widget.hide();
        if (self.active) |set| set.dispose();
        self.active = null;
    }

    pub fn manualTriggerAtCurrentPosition(self: *CodeActionController, not_available: []const u8, source: types.CodeActionTriggerSource, filter: types.CodeActionFilter, auto_apply: ?types.CodeActionAutoApply) void {
        if (!self.editor.hasModel() or self.editor.isReadOnly()) return;
        self.editor.clearMessage();
        if (self.model) |model| model.trigger(.{ .type = .Invoke, .trigger_action = source, .filter = filter, .auto_apply = auto_apply, .context = .{ .not_available_message = not_available, .position = self.editor.modelCursorPosition() } });
    }

    fn onState(context: *anyopaque, state: model_mod.CodeActionsState) void {
        const self: *CodeActionController = @ptrCast(@alignCast(context));
        switch (state) {
            .Empty => self.clearActive(),
            .Triggered => |triggered| {
                const result = triggered.actions orelse return;
                const actions = (self.model orelse return).takeCodeActions(result) orelse return;
                if (!self.bound or self.editor.modelSelection().startLineNumber != triggered.position.lineNumber) {
                    actions.dispose();
                    return;
                }
                const services = self.services.?;
                if (triggered.trigger.type == .Auto and services.action_widget.isVisible()) {
                    actions.dispose();
                    return;
                }
                self.clearActive();
                self.active = actions;
                if (self.lightbulb) |*widget| widget.update(actions, triggered.position, self.view.?.terminal_view_host.options.get(.lightbulb).enabled);
                if (triggered.trigger.type != .Invoke) return;
                const trigger = triggered.trigger;
                const scoped = trigger.filter.include != null;
                if (scoped and actions.valid_actions.len > 0) {
                    if (trigger.auto_apply == .First or (trigger.auto_apply == .IfSingle and actions.valid_actions.len == 1)) {
                        self.applyCodeAction(actions.valid_actions[0], false, false);
                        return;
                    }
                }
                if (scoped and actions.all_actions.len > 0 and ((trigger.auto_apply == .First and actions.valid_actions.len == 0) or (trigger.auto_apply == .IfSingle and actions.all_actions.len == 1))) {
                    for (actions.all_actions) |item| if (item.action.disabled) |reason| {
                        self.showMessage(reason);
                        return;
                    };
                }
                if (actions.all_actions.len == 0 or (!scoped and actions.valid_actions.len == 0)) {
                    if (trigger.context) |message| self.showMessage(message.not_available_message);
                    return;
                }
                self.showCodeActionList(self.anchor(), scoped, false) catch |err| self.showMessage(@errorName(err));
            },
        }
    }

    fn showMessage(self: *CodeActionController, message: []const u8) void {
        self.editor.setMessage("{s}", .{message});
        if (self.view) |view| view.invalidate();
    }

    fn anchor(self: *CodeActionController) menu.Anchor {
        const view = self.view orelse return .{ .x = 0, .y = 0 };
        const mount = view.surfaceContext();
        const cursor = view.cursorCell() orelse return .{ .x = mount.x + self.editor.gutterWidth(), .y = mount.y + 1 };
        return .{ .x = mount.x + cursor.col, .y = mount.y + cursor.row + 1 };
    }

    fn onLightbulb(context: *anyopaque, at: menu.Anchor) void {
        const self: *CodeActionController = @ptrCast(@alignCast(context));
        const actions = self.active orelse return;
        if (@import("lightBulbWidget.zig").computeLightBulbInfo(actions)) |info| if (info.auto_run) {
            self.applyCodeAction(actions.valid_actions[0], true, false);
            return;
        };
        self.showCodeActionList(at, false, true) catch |err| self.showMessage(@errorName(err));
    }

    fn showHeaders(self: *CodeActionController) bool {
        if (self.services.?.configuration) |configuration| if (self.editor.getModel()) |model| if (configuration.getValue(model, "editor.codeActionWidget.showHeaders")) |value| {
            if (value.* == .bool) return value.bool;
        };
        return true;
    }

    fn showCodeActionList(self: *CodeActionController, at: menu.Anchor, include_disabled: bool, from_lightbulb: bool) !void {
        const active = self.active orelse return;
        self.menu_anchor = at;
        self.menu_include_disabled = include_disabled;
        self.menu_from_lightbulb = from_lightbulb;
        self.menu_all = include_disabled and (self.show_disabled or active.valid_actions.len == 0);
        const actions = if (self.menu_all) active.all_actions else active.valid_actions;
        if (actions.len == 0) return;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var items: std.ArrayList(action_list.IActionListItem) = .empty;
        try items.appendSlice(a, try @import("codeActionMenu.zig").toMenuItems(a, actions, self.showHeaders()));
        if (!from_lightbulb) {
            if (active.documentation.len > 0 or (include_disabled and active.valid_actions.len != 0 and active.all_actions.len != active.valid_actions.len)) try items.append(a, .{ .kind = .Header, .label = "Options" });
            for (active.documentation, 0..) |doc, i| try items.append(a, .{ .kind = .Action, .item = actions.len + i, .label = doc.title });
            if (include_disabled and active.valid_actions.len > 0 and active.all_actions.len != active.valid_actions.len) try items.append(a, .{ .kind = .Action, .item = actions.len + active.documentation.len, .label = if (self.show_disabled) "Hide Disabled" else "Show Disabled" });
        }
        try self.services.?.action_widget.show(items.items, .{ .context = self, .on_select = onSelect, .on_hide = onHide }, at);
    }

    fn onHide(context: *anyopaque, _: bool) void {
        const self: *CodeActionController = @ptrCast(@alignCast(context));
        if (self.bound) if (self.view) |view| view.focusEditor();
    }
    fn onSelect(context: *anyopaque, index: usize, preview: bool) !void {
        const self: *CodeActionController = @ptrCast(@alignCast(context));
        const active = self.active orelse return;
        const actions = if (self.menu_all) active.all_actions else active.valid_actions;
        if (index < actions.len) {
            if (actions[index].action.disabled == null) self.applyCodeAction(actions[index], true, preview);
        } else if (index - actions.len < active.documentation.len) {
            const command = active.documentation[index - actions.len];
            try self.services.?.commands.execute(self.services.?.commands.context, command);
        } else if (self.menu_include_disabled and !self.menu_from_lightbulb) {
            self.show_disabled = !self.show_disabled;
            self.menu_anchor.opening_press = false;
            try self.showCodeActionList(self.menu_anchor, self.menu_include_disabled, self.menu_from_lightbulb);
        }
    }

    fn cancelApply(self: *CodeActionController) void {
        const request = self.apply_request orelse return;
        self.apply_request = null;
        request.cancel();
    }

    fn applyCodeAction(self: *CodeActionController, item: types.CodeActionItem, retrigger: bool, preview: bool) void {
        self.cancelApply();
        const set = self.active orelse return;
        const request = self.allocator.create(ApplyRequest) catch return;
        const token = cancellation.CancellationTokenSource.init(self.allocator) catch {
            self.allocator.destroy(request);
            return;
        };
        self.active = null;
        if (self.lightbulb) |*widget| widget.hide();
        request.* = .{ .allocator = self.allocator, .owner = self, .set = set, .item = item, .action = item.action, .token = token, .retrigger = retrigger, .preview = preview };
        self.apply_request = request;
        request.start();
    }

    const ApplyRequest = struct {
        allocator: std.mem.Allocator,
        owner: ?*CodeActionController,
        set: *codeAction.ManagedCodeActionSet,
        item: types.CodeActionItem,
        action: language.CodeAction,
        token: cancellation.CancellationTokenSource,
        retrigger: bool,
        preview: bool,
        stage: enum { resolving, applying, finished } = .resolving,
        depth: usize = 0,
        pending: ?Disposable = null,
        canceled: bool = false,

        fn start(self: *ApplyRequest) void {
            self.depth += 1;
            defer self.leave();
            if (self.action.edit == null) if (self.item.provider) |provider| {
                const registered = if (self.item.registration_time) |identity| self.owner.?.services.?.registry.hasRegistration(identity) else true;
                if (registered) {
                    const token = self.token.token() catch |err| {
                        self.finish(err);
                        return;
                    };
                    if (provider.request_resolve_code_action) |request| {
                        const pending = request(provider.context, self.set.arena.allocator(), self.action, token, .{ .context = self, .complete = resolved }) catch |err| {
                            resolved(self, err);
                            return;
                        };
                        if (self.stage == .resolving) self.pending = pending else if (pending) |handle| handle.dispose();
                        return;
                    }
                    if (provider.resolve_code_action) |resolve| {
                        resolved(self, resolve(provider.context, self.set.arena.allocator(), self.action, token));
                        return;
                    }
                }
            };
            self.apply();
        }
        fn resolved(context: *anyopaque, value: anyerror!?language.CodeAction) void {
            const self: *ApplyRequest = @ptrCast(@alignCast(context));
            if (self.canceled or self.stage != .resolving) return;
            self.pending = null;
            if (value catch null) |action| self.action = action;
            self.apply();
        }
        fn apply(self: *ApplyRequest) void {
            self.stage = .applying;
            self.depth += 1;
            defer self.leave();
            if (self.action.edit) |edit| if (edit.edits.len != 0) {
                const token = self.token.token() catch |err| {
                    self.finish(err);
                    return;
                };
                const pending = self.owner.?.services.?.bulk_edit.apply(edit, .{ .editor = self.owner.?.editor, .token = token, .show_preview = self.preview, .label = self.action.title, .code = "undoredo.codeAction", .respect_auto_save_config = true }, .{ .context = self, .complete = applied }) catch |err| {
                    self.finish(err);
                    return;
                };
                if (self.stage == .applying) self.pending = pending else if (pending) |handle| handle.dispose();
                return;
            };
            self.executeCommand();
        }
        fn applied(context: *anyopaque, result: anyerror!bulk.IBulkEditResult) void {
            const self: *ApplyRequest = @ptrCast(@alignCast(context));
            if (self.canceled or self.stage != .applying) return;
            self.pending = null;
            const value = result catch |err| {
                self.finish(err);
                return;
            };
            if (value.is_applied) self.executeCommand() else self.finish(null);
        }
        fn executeCommand(self: *ApplyRequest) void {
            self.depth += 1;
            defer self.leave();
            if (self.action.command) |command| {
                const owner = self.owner orelse return;
                const services = owner.services orelse {
                    self.finish(null);
                    return;
                };
                services.commands.execute(services.commands.context, command) catch |err| {
                    self.finish(err);
                    return;
                };
            }
            self.finish(null);
        }
        fn finish(self: *ApplyRequest, failure: ?anyerror) void {
            if (self.stage == .finished) return;
            self.stage = .finished;
            self.pending = null;
            if (self.owner) |owner| if (!self.canceled and owner.bound) {
                if (failure) |err| owner.showMessage(@errorName(err));
                if (self.retrigger) if (owner.model) |model| model.scheduleAuto();
            };
            if (self.depth == 0) self.destroy();
        }
        fn cancel(self: *ApplyRequest) void {
            if (self.stage == .finished) return;
            self.canceled = true;
            self.owner = null;
            if (self.pending) |pending| pending.dispose();
            self.pending = null;
            self.token.cancel();
            self.finish(null);
        }
        fn leave(self: *ApplyRequest) void {
            self.depth -= 1;
            if (self.depth == 0 and self.stage == .finished) self.destroy();
        }
        fn destroy(self: *ApplyRequest) void {
            if (self.owner) |owner| if (owner.apply_request == self) {
                owner.apply_request = null;
            };
            self.token.deinit();
            self.set.dispose();
            self.allocator.destroy(self);
        }
    };
};
