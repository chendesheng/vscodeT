// Port of `src/vs/editor/contrib/codelens/browser/codelensController.ts`.
// The window deadline queue replaces RunOnceScheduler and provider promises
// complete by callback. View zones/decoration ranges and scroll anchoring use
// the regular editor layout so the same controller works in both diff panes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("../../../common/languages.zig");
const features_mod = @import("../../../common/services/languageFeatures.zig");
const model_mod = @import("./codelens.zig");
const widget_mod = @import("./codelensWidget.zig");
const CodeLensWidget = widget_mod.CodeLensWidget;
const CodeLensCache = @import("./codeLensCache.zig").CodeLensCache;
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ViewHost = @import("../../../browser/widget/codeEditor/terminalViewHost.zig").TerminalViewHost;
const ViewZones = @import("../../../browser/viewParts/viewZones/viewZones.zig").ViewZones;
const browser = @import("../../../browser/editorBrowser.zig");
const events = @import("../../../common/viewEvents.zig");
const Handler = @import("../../../common/viewEventHandler.zig").ViewEventHandler;
const model_events = @import("../../../common/textModelEvents.zig");
const scroll = @import("../../../browser/stableEditorScroll.zig").StableEditorScrollState;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const now = @import("../../../../base/common/async.zig").nowMs;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const quick_input = @import("../../../../platform/quickinput/common/quickInput.zig");
const debounce_mod = @import("../../../common/services/languageFeatureDebounce.zig");

pub const CodeLensContribution = struct {
    pub const ID = "editor.contrib.codeLens";
    allocator: Allocator,
    editor: *Editor,
    view_host: *ViewHost,
    zones: *ViewZones,
    features: features_mod.ILanguageFeaturesService,
    cache: *CodeLensCache,
    commands: widget_mod.CommandHost,
    colors: widget_mod.Colors = .{},
    handler: Handler = .{},
    handler_attached: bool = false,
    contribution_registered: bool = false,
    pending_picker: ?struct { service: quick_input.IQuickInputService, line: usize } = null,
    active_picker: ?*PickSession = null,
    registry_listener: ?usize = null,
    content_listener: ?usize = null,
    language_listener: ?usize = null,
    layout_listener: ?usize = null,
    provider_listeners: std.ArrayList(@import("../../../../base/common/event.zig").SignalSubscription) = .empty,
    providers: []languages.CodeLensProvider = &.{},
    provider_hashes: []u32 = &.{},
    model: ?*model_mod.CodeLensModel = null,
    old_models: std.ArrayList(*model_mod.CodeLensModel) = .empty,
    widgets: std.ArrayList(*CodeLensWidget) = .empty,
    fetch_task: dispatch.Task = .{},
    resolve_task: dispatch.Task = .{},
    pending_fetch: ?*model_mod.Request = null,
    pending_resolves: std.ArrayList(*ResolveSlot) = .empty,
    fetch_version: u32 = 0,
    fetch_start: i64 = 0,
    resolve_start: i64 = 0,
    resolving: bool = false,
    enabled: bool = false,
    debounce: debounce_mod.LanguageFeatureDebounceService,
    provide_info: debounce_mod.IFeatureDebounceInformation = undefined,
    resolve_info: debounce_mod.IFeatureDebounceInformation = undefined,

    const PickSession = struct {
        owner: ?*CodeLensContribution,
        allocator: Allocator,
        arena: std.heap.ArenaAllocator,
        line: usize,
        model: *model_mod.CodeLensModel,

        fn dispose(self: *PickSession) void {
            self.arena.deinit();
            self.allocator.destroy(self);
        }

        fn selected(context: *anyopaque, item: ?*const quick_input.Item) !void {
            const self: *PickSession = @ptrCast(@alignCast(context));
            defer self.dispose();
            const owner = self.owner orelse return;
            if (owner.active_picker == self) owner.active_picker = null;
            const selected_item = item orelse return;
            const model = owner.model orelse return;
            if (model == self.model) {
                const index = std.fmt.parseInt(usize, selected_item.id, 10) catch return;
                if (index >= model.lenses.items.len) return;
                const command = model.lenses.items[index].symbol.command orelse return;
                if (command.id.len != 0) try owner.commands.execute(owner.commands.context, command);
                return;
            }
            for (model.lenses.items) |lens| {
                if (lens.symbol.range.startLineNumber != self.line) continue;
                const command = lens.symbol.command orelse continue;
                if (command.id.len == 0 or !std.mem.eql(u8, command.title, selected_item.label)) continue;
                try owner.commands.execute(owner.commands.context, command);
                return;
            }
        }
    };

    const ResolveSlot = struct {
        owner: *CodeLensContribution,
        widget: *CodeLensWidget,
        item: *model_mod.CodeLensItem,
        pending: ?Disposable = null,
        starting: bool = true,
        done: bool = false,
        value: ?languages.CodeLens = null,

        fn ready(context: *anyopaque, symbol: ?languages.CodeLens) void {
            const self: *ResolveSlot = @ptrCast(@alignCast(context));
            self.done = true;
            self.value = symbol;
            self.pending = null;
            if (!self.starting) self.owner.finishResolve(self);
        }
    };

    pub fn create(allocator: Allocator, editor: *Editor, view_host: *ViewHost, zones: *ViewZones, features: features_mod.ILanguageFeaturesService, cache: *CodeLensCache, commands: widget_mod.CommandHost, window: *dispatch.Queue) !*CodeLensContribution {
        const self = try allocator.create(CodeLensContribution);
        self.* = .{ .allocator = allocator, .editor = editor, .view_host = view_host, .zones = zones, .features = features, .cache = cache, .commands = commands, .debounce = debounce_mod.LanguageFeatureDebounceService.init(allocator, false) };
        errdefer self.dispose();
        const key = @intFromPtr(features.code_lens_provider);
        self.provide_info = try self.debounce.for_(key, "CodeLensProvide", .{ .min = 250 });
        self.resolve_info = try self.debounce.for_(key, "CodeLensResolve", .{ .min = 250, .key = "resolve" });
        self.fetch_task = .{ .queue = window, .context = self, .run = onFetchDeadline };
        self.resolve_task = .{ .queue = window, .context = self, .run = onResolveDeadline };
        self.handler = Handler.init(self, .{ .onConfigurationChanged = onConfiguration, .onScrollChanged = onScroll, .onFocusChanged = onFocus, .onLineMappingChanged = onLineMapping });
        editor.addViewEventHandler(&self.handler);
        self.handler_attached = true;
        self.registry_listener = try features.code_lens_provider.on_did_change.listen(self, onProvidersChanged);
        self.content_listener = try editor.model.onDidChangeContentWithContextId(self, onContent);
        self.language_listener = try editor.model.listenDidChangeLanguage(self, onLanguage);
        self.layout_listener = try editor.on_did_layout_change.listen(self, onLayout);
        try editor.registerContribution(CodeLensContribution, self);
        self.contribution_registered = true;
        try self.onModelChange();
        return self;
    }

    pub fn dispose(self: *CodeLensContribution) void {
        if (self.active_picker) |picker| picker.owner = null;
        self.active_picker = null;
        if (self.contribution_registered) self.editor.unregisterContribution(CodeLensContribution, self);
        self.editor.setHasCodeLensProvider(false);
        if (self.handler_attached) self.editor.removeViewEventHandler(&self.handler);
        if (self.registry_listener) |id| self.features.code_lens_provider.on_did_change.unlisten(id);
        if (self.content_listener) |id| self.editor.model.removeDidChangeContentListener(id);
        if (self.language_listener) |id| self.editor.model.removeDidChangeLanguageListener(id);
        if (self.layout_listener) |id| self.editor.on_did_layout_change.unlisten(id);
        self.localDispose();
        self.provider_listeners.deinit(self.allocator);
        self.widgets.deinit(self.allocator);
        self.old_models.deinit(self.allocator);
        self.pending_resolves.deinit(self.allocator);
        self.debounce.deinit();
        self.allocator.destroy(self);
    }

    fn localDispose(self: *CodeLensContribution) void {
        self.enabled = false;
        self.pending_picker = null;
        self.fetch_task.schedule(null);
        self.resolve_task.schedule(null);
        self.cancelFetch();
        self.cancelResolves();
        for (self.provider_listeners.items) |listener| listener.dispose();
        self.provider_listeners.clearRetainingCapacity();
        self.allocator.free(self.providers);
        self.providers = &.{};
        self.allocator.free(self.provider_hashes);
        self.provider_hashes = &.{};
        const anchor = scroll.capture(self.editor);
        self.zones.changeViewZones(self, removeWidgets) catch {};
        anchor.restore(self.editor);
        if (self.model) |model| model.dispose();
        self.model = null;
        self.clearOldModels();
    }

    fn clearOldModels(self: *CodeLensContribution) void {
        for (self.old_models.items) |model| model.dispose();
        self.old_models.clearRetainingCapacity();
    }

    fn removeWidgets(self: *CodeLensContribution, accessor: browser.IViewZoneChangeAccessor) !void {
        for (self.widgets.items) |widget| widget.dispose(accessor);
        self.widgets.clearRetainingCapacity();
    }

    fn onModelChange(self: *CodeLensContribution) !void {
        self.localDispose();
        const has_provider = self.features.code_lens_provider.has(self.editor.model);
        self.editor.setHasCodeLensProvider(has_provider);
        if (!self.view_host.options.get(.codeLens) or !has_provider) return;
        self.enabled = true;
        self.providers = try self.features.code_lens_provider.ordered(self.allocator, self.editor.model, false);
        self.provider_hashes = try self.allocator.alloc(u32, self.providers.len);
        for (self.providers, self.provider_hashes) |provider, *hash| {
            hash.* = @truncate(@intFromPtr(provider.context));
            if (provider.on_did_change) |event| {
                const listener = try event.listenDisposable(self, onProviderEvent);
                self.provider_listeners.append(self.allocator, listener) catch |err| {
                    listener.dispose();
                    return err;
                };
            }
        }
        self.model = try self.cache.get(self.editor.model);
        if (self.model) |model| try self.renderSymbols(model);
        self.scheduleFetch();
    }

    fn debounceRef(self: *CodeLensContribution) debounce_mod.ModelRef {
        return .{ .id = @intFromPtr(self.editor.model), .feature_hashes = self.provider_hashes };
    }

    fn scheduleFetch(self: *CodeLensContribution) void {
        if (self.enabled) self.fetch_task.schedule(now() + @as(i64, @intFromFloat(self.provide_info.get(self.debounceRef()))));
    }

    fn scheduleResolve(self: *CodeLensContribution) void {
        if (self.enabled and self.widgets.items.len > 0) self.resolve_task.schedule(now() + @as(i64, @intFromFloat(self.resolve_info.get(self.debounceRef()))));
    }

    fn cancelFetch(self: *CodeLensContribution) void {
        if (self.pending_fetch) |request| request.cancel();
        self.pending_fetch = null;
    }

    fn cancelResolves(self: *CodeLensContribution) void {
        for (self.pending_resolves.items) |slot| {
            if (slot.pending) |pending| pending.dispose();
            self.allocator.destroy(slot);
        }
        self.pending_resolves.clearRetainingCapacity();
    }

    fn onProvidersChanged(_: usize, self: *CodeLensContribution) !void {
        try self.onModelChange();
    }
    fn onProviderEvent(_: void, self: *CodeLensContribution) !void {
        self.scheduleFetch();
    }
    fn onLanguage(_: model_events.ModelLanguageChangedEvent, self: *CodeLensContribution) !void {
        try self.onModelChange();
    }
    fn onLayout(_: void, self: *CodeLensContribution) !void {
        self.scheduleResolve();
    }
    fn onContent(_: model_events.InternalModelContentChangeEvent, self: *CodeLensContribution) !void {
        if (!self.enabled) return;
        self.cancelFetch();
        self.resolve_task.schedule(null);
        self.cancelResolves();
        try self.zones.changeViewZones(self, reanchorWidgets);
        self.scheduleFetch();
    }

    fn reanchorWidgets(self: *CodeLensContribution, accessor: browser.IViewZoneChangeAccessor) !void {
        var index: usize = 0;
        var last_line: usize = 0;
        while (index < self.widgets.items.len) {
            const widget = self.widgets.items[index];
            const line = widget.validLine() orelse 0;
            if (line == 0 or line == last_line) {
                _ = self.widgets.orderedRemove(index);
                widget.dispose(accessor);
                continue;
            }
            last_line = line;
            widget.line_number = line;
            try widget.updateZone(accessor);
            index += 1;
        }
    }

    fn onConfiguration(context: *anyopaque, event: *const events.ViewConfigurationChangedEvent) bool {
        const self: *CodeLensContribution = @ptrCast(@alignCast(context));
        if (event.hasChanged(.codeLens)) self.onModelChange() catch {} else self.scheduleResolve();
        return false;
    }
    fn onScroll(context: *anyopaque, event: *const events.ViewScrollChangedEvent) bool {
        const self: *CodeLensContribution = @ptrCast(@alignCast(context));
        if (event.scrollTopChanged or event.scrollHeightChanged) self.scheduleResolve();
        return false;
    }
    fn onFocus(context: *anyopaque, event: *const events.ViewFocusChangedEvent) bool {
        const self: *CodeLensContribution = @ptrCast(@alignCast(context));
        if (event.isFocused) self.scheduleFetch() else self.fetch_task.schedule(null);
        return false;
    }
    fn onLineMapping(context: *anyopaque, _: *const events.ViewLineMappingChangedEvent) bool {
        const self: *CodeLensContribution = @ptrCast(@alignCast(context));
        self.scheduleResolve();
        return false;
    }

    fn onFetchDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeLensContribution = @ptrCast(@alignCast(context));
        if (!self.enabled) return false;
        self.cancelFetch();
        self.fetch_version = self.editor.model.getVersionId();
        self.fetch_start = now();
        self.pending_fetch = model_mod.Request.start(self.allocator, self.editor.model, self.providers, self, onFetched) catch null;
        return true;
    }

    fn onFetched(context: *anyopaque, model: *model_mod.CodeLensModel) void {
        const self: *CodeLensContribution = @ptrCast(@alignCast(context));
        self.pending_fetch = null;
        if (!self.enabled or self.fetch_version != self.editor.model.getVersionId()) {
            model.dispose();
            return;
        }
        self.cancelResolves();
        if (self.model) |previous| self.old_models.append(self.allocator, previous) catch {
            model.dispose();
            return;
        };
        self.model = model;
        self.cache.put(self.editor.model, model) catch {};
        _ = self.provide_info.update(self.debounceRef(), @floatFromInt(@max(0, now() - self.fetch_start))) catch 250;
        self.renderSymbols(model) catch {
            self.localDispose();
            return;
        };
        self.scheduleResolve();
        if (self.widgets.items.len == 0) {
            self.clearOldModels();
            self.finishPendingPicker();
        }
    }

    fn renderSymbols(self: *CodeLensContribution, model: *model_mod.CodeLensModel) !void {
        const anchor = scroll.capture(self.editor);
        defer anchor.restore(self.editor);
        try self.zones.changeViewZones(.{ self, model }, struct {
            fn run(ctx: struct { *CodeLensContribution, *model_mod.CodeLensModel }, accessor: browser.IViewZoneChangeAccessor) !void {
                const owner = ctx[0];
                const items = ctx[1].lenses.items;
                var index: usize = 0;
                var first: usize = 0;
                while (first < items.len) {
                    const line = items[first].symbol.range.startLineNumber;
                    var end = first + 1;
                    while (end < items.len and items[end].symbol.range.startLineNumber == line) end += 1;
                    const group = items[first..end];
                    first = end;
                    if (line < 1 or line > owner.editor.model.getLineCount()) continue;
                    while (index < owner.widgets.items.len and owner.widgets.items[index].line_number < line) {
                        owner.widgets.orderedRemove(index).dispose(accessor);
                    }
                    if (index < owner.widgets.items.len and owner.widgets.items[index].line_number == line) {
                        try owner.widgets.items[index].updateSymbols(group, accessor);
                    } else {
                        try owner.widgets.ensureUnusedCapacity(owner.allocator, 1);
                        const widget = try CodeLensWidget.create(owner.allocator, owner.editor, owner.zones, owner.commands, group, owner.colors, accessor);
                        owner.widgets.insertAssumeCapacity(index, widget);
                    }
                    index += 1;
                }
                while (index < owner.widgets.items.len) owner.widgets.orderedRemove(index).dispose(accessor);
            }
        }.run);
    }

    fn onResolveDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeLensContribution = @ptrCast(@alignCast(context));
        self.resolveInViewport() catch {};
        return true;
    }

    fn resolveInViewport(self: *CodeLensContribution) !void {
        if (!self.enabled) return;
        const model = self.model orelse return;
        self.cancelResolves();
        const visible = try self.editor.viewLayout().getWhitespaceViewportData(self.allocator);
        defer self.allocator.free(visible);
        self.resolve_start = now();
        self.resolving = true;
        defer {
            self.resolving = false;
            if (self.pending_resolves.items.len == 0) self.didResolve();
        }
        for (self.widgets.items) |widget| {
            if (!widget.visible(visible)) continue;
            for (widget.data, widget.decoration_ids) |*item, id| {
                if (item.symbol.command != null) continue;
                if (item.provider.resolve_code_lens == null and item.provider.request_resolve_code_lens == null) continue;
                const range = self.editor.model.getDecorationRange(id) orelse continue;
                if (range.isEmpty() != item.symbol.range.isEmpty()) continue;
                item.symbol.range = range;
                const a = model.arena.allocator();
                if (item.provider.request_resolve_code_lens) |request| {
                    const slot = try self.allocator.create(ResolveSlot);
                    slot.* = .{ .owner = self, .widget = widget, .item = item };
                    self.pending_resolves.append(self.allocator, slot) catch |err| {
                        self.allocator.destroy(slot);
                        return err;
                    };
                    const pending = request(item.provider.context, a, self.editor.model, item.symbol, .{ .context = slot, .complete = ResolveSlot.ready }) catch null;
                    slot.starting = false;
                    if (slot.done) self.finishResolve(slot) else if (pending) |active| {
                        slot.pending = active;
                    } else {
                        slot.done = true;
                        self.finishResolve(slot);
                    }
                } else if (item.provider.resolve_code_lens) |resolve| {
                    const symbol = resolve(item.provider.context, a, self.editor.model, item.symbol, CancellationToken.None) catch null;
                    self.applyResolved(widget, item, symbol);
                }
            }
        }
    }

    fn applyResolved(_: *CodeLensContribution, widget: *CodeLensWidget, item: *model_mod.CodeLensItem, symbol: ?languages.CodeLens) void {
        if (symbol) |resolved| {
            item.symbol = resolved;
        } else widget.resolved_empty = true;
        widget.invalidate();
    }
    fn finishResolve(self: *CodeLensContribution, slot: *ResolveSlot) void {
        for (self.pending_resolves.items, 0..) |candidate, index| {
            if (candidate != slot) continue;
            _ = self.pending_resolves.swapRemove(index);
            break;
        }
        self.applyResolved(slot.widget, slot.item, slot.value);
        self.allocator.destroy(slot);
        if (!self.resolving and self.pending_resolves.items.len == 0) self.didResolve();
    }
    fn didResolve(self: *CodeLensContribution) void {
        _ = self.resolve_info.update(self.debounceRef(), @floatFromInt(@max(0, now() - self.resolve_start))) catch 250;
        if (self.model) |model| self.cache.put(self.editor.model, model) catch {};
        self.clearOldModels();
        self.finishPendingPicker();
    }

    /// ShowLensesInCurrentLine waits for an in-flight provide/resolve, then
    /// displays the commands on the cursor's model line. The result resolves
    /// the same title in the current model if the old model was replaced.
    pub fn showLensesInCurrentLine(self: *CodeLensContribution, service: quick_input.IQuickInputService) !void {
        if (!self.enabled) return;
        const line = self.editor.modelCursorPosition().lineNumber;
        if (self.pending_fetch != null or self.fetch_task.at != null or self.pending_resolves.items.len != 0 or self.resolve_task.at != null) {
            self.pending_picker = .{ .service = service, .line = line };
            return;
        }
        try self.showOnLine(service, line);
    }

    fn finishPendingPicker(self: *CodeLensContribution) void {
        const pending = self.pending_picker orelse return;
        self.pending_picker = null;
        self.showOnLine(pending.service, pending.line) catch {};
    }

    fn showOnLine(self: *CodeLensContribution, service: quick_input.IQuickInputService, line: usize) !void {
        const model = self.model orelse return;
        const session = try self.allocator.create(PickSession);
        session.* = .{ .owner = self, .allocator = self.allocator, .arena = .init(self.allocator), .line = line, .model = model };
        var adopted = false;
        defer if (!adopted) session.dispose();
        const a = session.arena.allocator();
        var items: std.ArrayList(quick_input.QuickPickItem) = .empty;
        for (model.lenses.items, 0..) |lens, index| {
            if (lens.symbol.range.startLineNumber != line) continue;
            const command = lens.symbol.command orelse continue;
            if (command.id.len == 0) continue;
            try items.append(a, .{ .item = .{ .id = try std.fmt.allocPrint(a, "{d}", .{index}), .label = try a.dupe(u8, command.title) } });
        }
        if (items.items.len == 0) return;
        self.active_picker = session;
        errdefer {
            if (self.active_picker == session) self.active_picker = null;
        }
        try service.pick(items.items, .{ .placeholder = "Select a command" }, PickSession.selected, session);
        adopted = true;
    }

    pub fn setColors(self: *CodeLensContribution, colors: widget_mod.Colors) void {
        self.colors = colors;
        for (self.widgets.items) |widget| {
            widget.colors = colors;
            widget.invalidate();
        }
    }
};

const actions = @import("../../../../platform/actions/common/actions.zig");
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const has_provider_context = contextkey.Expr{ .Defined = "editorHasCodeLensProvider" };
pub const show_lenses_action: actions.Action2 = .{
    .command = .{ .id = "codelens.showLensesInCurrentLine", .title = "Show CodeLens Commands for Current Line", .precondition = &has_provider_context },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = struct {
        fn run(_: *anyopaque, accessor: instantiation.ServicesAccessor) !void {
            const editors = try accessor.get(@import("../../../browser/services/codeEditorService.zig").code_editor_service_id);
            const editor = editors.getFocusedCodeEditor() orelse editors.getActiveCodeEditor() orelse return;
            const controller = editor.getContribution(CodeLensContribution) orelse return;
            const quick = try accessor.get(quick_input.quick_input_service_id);
            try controller.showLensesInCurrentLine(quick.*);
        }
    }.run,
};
