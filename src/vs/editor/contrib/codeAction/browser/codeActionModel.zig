// Port of `src/vs/editor/contrib/codeAction/browser/codeActionModel.ts`.
// Cursor/marker changes schedule the oracle through the native window queue;
// provider and model changes cancel the old result before rebuilding it.
const std = @import("std");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Selection = @import("../../../common/core/selection.zig").Selection;
const Range = @import("../../../common/core/range.zig").Range;
const Position = @import("../../../common/core/position.zig").Position;
const language = @import("../../../common/languages.zig");
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(language.CodeActionProvider);
const MarkerService = @import("../../../../platform/markers/common/markerService.zig").MarkerService;
const MarkerChangeEvent = @import("../../../../platform/markers/common/markerService.zig").MarkerChangeEvent;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");
const ResourceConfiguration = @import("../../../common/services/textResourceConfiguration.zig").ITextResourceConfigurationService;
const MarkerResource = @import("../../../../platform/markers/common/markers.zig").Resource;
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const codeAction = @import("codeAction.zig");
const types = @import("../common/types.zig");
pub const LightbulbMode = @import("../../../common/config/editorOptions.zig").EditorLightbulbOptions.Enabled;

pub const CodeActionsState = union(enum) {
    Empty,
    Triggered: struct { trigger: types.CodeActionTrigger, position: Position, actions: ?*codeAction.ManagedCodeActionSet = null },
};

pub const CodeActionOracle = struct {
    task: dispatch.Task = .{},
    ignore_lightbulb_off: bool = false,

    pub fn selectionUnlessWhitespaceEnclosed(editor: *Editor, trigger: language.CodeActionTriggerType, enabled: LightbulbMode, ignore_off: bool) ?Selection {
        const model = editor.getModel() orelse return null;
        const selection = editor.modelSelection();
        if (trigger == .Invoke) return selection;
        if (enabled == .off and !ignore_off) return null;
        if (enabled == .off or enabled == .on or !selection.isEmpty()) return selection;
        const position = selection.getPosition();
        const contents = model.borrowLineContent(position.lineNumber) catch return null;
        if (contents.len == 0) return null;
        if (position.column <= 1) {
            if (std.ascii.isWhitespace(contents[0])) return null;
        } else if (position.column >= model.getLineMaxColumn(position.lineNumber)) {
            if (std.ascii.isWhitespace(contents[contents.len - 1])) return null;
        } else if (std.ascii.isWhitespace(contents[position.column - 2]) and std.ascii.isWhitespace(contents[position.column - 1])) return null;
        return selection;
    }
};

pub const CodeActionModel = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    registry: *Registry,
    marker_service: ?*MarkerService,
    configuration: ?ResourceConfiguration,
    oracle: CodeActionOracle = .{},
    state: CodeActionsState = .Empty,
    trigger_arena: std.heap.ArenaAllocator,
    pending: ?Disposable = null,
    owned_actions: ?*codeAction.ManagedCodeActionSet = null,
    completion_task: dispatch.Task = .{},
    publication_task: dispatch.Task = .{},
    mode: LightbulbMode = .on_code,
    bound: bool = false,
    can_trigger: bool = false,
    cursor_listener: ?usize = null,
    model_will_listener: ?usize = null,
    model_did_listener: ?usize = null,
    readonly_listener: ?usize = null,
    registry_listener: ?usize = null,
    marker_listener: ?usize = null,
    language_listener: ?usize = null,
    attached_model: ?*TextModel = null,
    resource_key: ?[]u8 = null,
    context: *anyopaque,
    on_change: *const fn (*anyopaque, CodeActionsState) void,

    pub fn create(a: std.mem.Allocator, editor: *Editor, registry: *Registry, marker_service: ?*MarkerService, configuration: ?ResourceConfiguration, queue: *dispatch.Queue, context: *anyopaque, on_change: *const fn (*anyopaque, CodeActionsState) void) !*CodeActionModel {
        const self = try a.create(CodeActionModel);
        self.* = .{ .allocator = a, .editor = editor, .registry = registry, .marker_service = marker_service, .configuration = configuration, .trigger_arena = .init(a), .context = context, .on_change = on_change };
        self.oracle.task = .{ .queue = queue, .context = self, .run = onAutoTrigger };
        self.completion_task = .{ .queue = queue, .context = self, .run = onCompleted };
        self.publication_task = .{ .queue = queue, .context = self, .run = onPublish };
        errdefer self.dispose();
        try self.bind();
        return self;
    }

    fn bind(self: *CodeActionModel) !void {
        self.bound = true;
        self.cursor_listener = try self.editor.on_did_change_cursor_position.listen(self, onCursor);
        self.model_will_listener = try self.editor.on_will_change_model.listen(self, onWillChangeModel);
        self.model_did_listener = try self.editor.on_did_change_model.listen(self, onDidChangeModel);
        self.readonly_listener = try self.editor.on_did_change_read_only.listen(self, onReadOnly);
        self.registry_listener = try self.registry.on_did_change.listen(self, onRegistry);
        if (self.marker_service) |markers| self.marker_listener = try markers.on_marker_changed.listen(self, onMarkers);
        try self.attachModel();
        self.update();
    }

    pub fn dispose(self: *CodeActionModel) void {
        self.clear();
        if (self.cursor_listener) |id| self.editor.on_did_change_cursor_position.unlisten(id);
        if (self.model_will_listener) |id| self.editor.on_will_change_model.unlisten(id);
        if (self.model_did_listener) |id| self.editor.on_did_change_model.unlisten(id);
        if (self.readonly_listener) |id| self.editor.on_did_change_read_only.unlisten(id);
        if (self.registry_listener) |id| self.registry.on_did_change.unlisten(id);
        if (self.marker_service) |markers| if (self.marker_listener) |id| markers.on_marker_changed.unlisten(id);
        self.detachModel();
        self.editor.setSupportedCodeActions("");
        self.trigger_arena.deinit();
        self.allocator.destroy(self);
    }

    fn attachModel(self: *CodeActionModel) !void {
        const model = self.editor.getModel() orelse return;
        self.attached_model = model;
        self.resource_key = try @import("../../../../base/common/stdUri.zig").resourceKey(self.allocator, model.uri());
        self.language_listener = try model.listenDidChangeLanguage(self, onLanguage);
    }

    fn detachModel(self: *CodeActionModel) void {
        if (self.attached_model) |model| if (self.language_listener) |id| model.removeDidChangeLanguageListener(id);
        if (self.resource_key) |key| self.allocator.free(key);
        self.resource_key = null;
        self.language_listener = null;
        self.attached_model = null;
    }

    fn onCursor(_: @import("../../../common/cursorEvents.zig").ICursorPositionChangedEvent, self: *CodeActionModel) !void {
        self.scheduleAuto();
    }
    fn onMarkers(event: MarkerChangeEvent, self: *CodeActionModel) !void {
        const key = self.resource_key orelse return;
        for (event.resources) |resource| if (std.mem.eql(u8, key, resource)) {
            self.scheduleAuto();
            return;
        };
    }
    fn onWillChangeModel(_: @import("../../../common/editorCommon.zig").IModelChangedEvent, self: *CodeActionModel) !void {
        self.clear();
        self.detachModel();
        self.editor.setSupportedCodeActions("");
    }
    fn onDidChangeModel(_: @import("../../../common/editorCommon.zig").IModelChangedEvent, self: *CodeActionModel) !void {
        try self.attachModel();
        self.update();
    }
    fn onReadOnly(_: bool, self: *CodeActionModel) !void {
        self.update();
    }
    fn onRegistry(_: usize, self: *CodeActionModel) !void {
        self.update();
    }
    fn onLanguage(_: @import("../../../common/textModelEvents.zig").ModelLanguageChangedEvent, self: *CodeActionModel) !void {
        self.update();
    }

    pub fn setMode(self: *CodeActionModel, mode: LightbulbMode) void {
        if (self.mode == mode) return;
        self.mode = mode;
        self.update();
    }

    pub fn setIgnoreLightbulbOff(self: *CodeActionModel, ignore: bool) void {
        if (self.oracle.ignore_lightbulb_off == ignore) return;
        self.oracle.ignore_lightbulb_off = ignore;
        if (ignore) self.trigger(.{ .type = .Auto, .trigger_action = .Default });
    }

    pub fn update(self: *CodeActionModel) void {
        self.clear();
        const model = self.editor.getModel() orelse return;
        const has_provider = self.registry.has(model);
        self.can_trigger = has_provider and !self.editor.isReadOnly();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var supported: std.ArrayList(u8) = .empty;
        if (self.can_trigger) {
            const providers = self.registry.all(a, model) catch &.{};
            for (providers) |provider| if (provider.provided_kinds) |kinds| {
                for (kinds) |kind| {
                    if (supported.items.len > 0) supported.append(a, ' ') catch break;
                    supported.appendSlice(a, kind) catch break;
                }
            };
        }
        self.editor.setSupportedCodeActions(supported.items);
        if (self.can_trigger) self.trigger(.{ .type = .Auto, .trigger_action = .Default });
    }

    pub fn scheduleAuto(self: *CodeActionModel) void {
        if (self.can_trigger) self.oracle.task.schedule(time.milliTimestamp(self.editor.clockIo()) + 250);
    }
    fn onAutoTrigger(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeActionModel = @ptrCast(@alignCast(context));
        self.trigger(.{ .type = .Auto, .trigger_action = .Default });
        return false;
    }

    pub fn clear(self: *CodeActionModel) void {
        self.oracle.task.schedule(null);
        self.publication_task.schedule(null);
        self.cancelPending();
        self.clearOwnedActions();
        self.can_trigger = false;
        self.state = .Empty;
        self.on_change(self.context, .Empty);
        _ = self.trigger_arena.reset(.retain_capacity);
    }

    fn cancelPending(self: *CodeActionModel) void {
        if (self.pending) |request| request.dispose();
        self.pending = null;
    }

    fn clearOwnedActions(self: *CodeActionModel) void {
        self.completion_task.schedule(null);
        if (self.owned_actions) |set| set.dispose();
        self.owned_actions = null;
    }

    // Like the upstream MutableDisposable, the model retains completed
    // provider results until the controller explicitly transfers ownership.
    pub fn takeCodeActions(self: *CodeActionModel, actions: *codeAction.ManagedCodeActionSet) ?*codeAction.ManagedCodeActionSet {
        if (self.owned_actions != actions) return null;
        self.owned_actions = null;
        return actions;
    }

    pub fn trigger(self: *CodeActionModel, trigger_value: types.CodeActionTrigger) void {
        if (!self.can_trigger) return;
        const model = self.editor.getModel() orelse return;
        self.oracle.task.schedule(null);
        self.publication_task.schedule(null);
        const manual_to_auto = self.state == .Triggered and self.state.Triggered.trigger.type == .Invoke and trigger_value.type == .Auto;
        self.cancelPending();
        self.clearOwnedActions();
        _ = self.trigger_arena.reset(.retain_capacity);
        const selection = CodeActionOracle.selectionUnlessWhitespaceEnclosed(self.editor, trigger_value.type, self.mode, self.oracle.ignore_lightbulb_off) orelse {
            self.state = .Empty;
            self.on_change(self.context, .Empty);
            return;
        };
        var trigger_copy = codeAction.copyTrigger(self.trigger_arena.allocator(), trigger_value) catch return;
        trigger_copy.selection = selection;
        self.state = .{ .Triggered = .{ .trigger = trigger_copy, .position = selection.getStartPosition() } };
        if (manual_to_auto) self.publication_task.schedule(time.milliTimestamp(self.editor.clockIo()) + 500) else self.on_change(self.context, self.state);
        const range = Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn);
        const nearby = self.settingEnabledNearbyQuickfixes(model) and trigger_copy.type == .Invoke and
            (trigger_copy.trigger_action == .QuickFix or (if (trigger_copy.filter.include) |kind| kind.contains(types.CodeActionKind.QuickFix) else false));
        const listener: codeAction.Listener = .{ .context = self, .complete = provideResult };
        const result = if (nearby and self.marker_service != null)
            NearbyQuickFixQuery.start(self.allocator, self.registry, model, self.marker_service.?, range, selection.getPosition(), trigger_copy, listener)
        else
            codeAction.getCodeActions(self.allocator, self.registry, model, range, trigger_copy, .None, listener);
        self.pending = result catch |err| blk: {
            provideResult(self, err);
            break :blk null;
        };
    }

    fn settingEnabledNearbyQuickfixes(self: *CodeActionModel, model: *TextModel) bool {
        const configuration = self.configuration orelse return false;
        const value = configuration.getValue(model, "editor.codeActionWidget.includeNearbyQuickFixes") orelse return true;
        return value.* == .bool and value.bool;
    }

    fn provideResult(context: *anyopaque, result: anyerror!*codeAction.ManagedCodeActionSet) void {
        const self: *CodeActionModel = @ptrCast(@alignCast(context));
        self.pending = null;
        const set = result catch {
            self.state = .Empty;
            self.publication_task.schedule(null);
            self.completion_task.post();
            return;
        };
        if (self.state != .Triggered) {
            set.dispose();
            return;
        }
        self.clearOwnedActions();
        self.owned_actions = set;
        // Provider completion may be synchronous, but the upstream promise
        // continuation runs after the trigger has installed its state.
        self.completion_task.schedule(self.publication_task.at orelse time.milliTimestamp(self.editor.clockIo()));
    }

    fn onPublish(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeActionModel = @ptrCast(@alignCast(context));
        self.on_change(self.context, self.state);
        return false;
    }

    fn onCompleted(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeActionModel = @ptrCast(@alignCast(context));
        if (self.state == .Empty) {
            self.on_change(self.context, .Empty);
        } else if (self.owned_actions) |set| {
            var next = self.state.Triggered;
            next.actions = set;
            self.on_change(self.context, .{ .Triggered = next });
        }
        return false;
    }
};

/// The upstream manual Quick Fix path searches diagnostics on the current
/// line if the initial position has no non-AI quick fix. Provider sets remain
/// owned by the combined result, including their resolve IDs and commands.
const NearbyQuickFixQuery = struct {
    const Set = codeAction.ManagedCodeActionSet;
    const Item = types.CodeActionItem;
    allocator: std.mem.Allocator,
    registry: *Registry,
    model: *TextModel,
    markers: *MarkerService,
    range: Range,
    cursor: Position,
    trigger: types.CodeActionTrigger,
    listener: codeAction.Listener,
    result: *Set,
    pending: ?Disposable = null,
    response: ?anyerror!*Set = null,
    output: ?anyerror!*Set = null,
    driving: bool = false,
    phase: enum { initial, retry, marker } = .initial,
    positions: []Position = &.{},
    index: usize = 0,
    distance: usize = std.math.maxInt(usize),
    collect_all: bool = false,
    all: std.ArrayList(Item) = .empty,
    valid: std.ArrayList(Item) = .empty,

    fn start(allocator: std.mem.Allocator, registry: *Registry, model: *TextModel, markers: *MarkerService, range: Range, cursor: Position, trigger: types.CodeActionTrigger, listener: codeAction.Listener) !?Disposable {
        const result = try Set.create(allocator);
        errdefer result.dispose();
        const self = try allocator.create(NearbyQuickFixQuery);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .registry = registry, .model = model, .markers = markers, .range = range, .cursor = cursor, .trigger = try codeAction.copyTrigger(result.arena.allocator(), trigger), .listener = listener, .result = result };
        if (self.drive()) {
            self.finish();
            return null;
        }
        return Disposable.from(NearbyQuickFixQuery, self, cancel);
    }

    fn query(self: *NearbyQuickFixQuery, range: Range, trigger_value: types.CodeActionTrigger) void {
        var query_trigger = trigger_value;
        if (query_trigger.selection) |selection| {
            if (selection.startLineNumber != range.startLineNumber or selection.startColumn != range.startColumn or selection.endLineNumber != range.endLineNumber or selection.endColumn != range.endColumn) query_trigger.selection = null;
        }
        const pending = codeAction.getCodeActions(self.allocator, self.registry, self.model, range, query_trigger, .None, .{ .context = self, .complete = received }) catch |err| {
            self.response = err;
            return;
        };
        if (self.response == null) self.pending = pending;
    }

    fn received(context: *anyopaque, result: anyerror!*Set) void {
        const self: *NearbyQuickFixQuery = @ptrCast(@alignCast(context));
        self.pending = null;
        self.response = result;
        if (!self.driving and self.drive()) self.finish();
    }

    fn drive(self: *NearbyQuickFixQuery) bool {
        self.driving = true;
        defer self.driving = false;
        while (true) {
            if (self.response) |response| {
                self.response = null;
                const set = response catch |err| {
                    self.output = err;
                    return true;
                };
                const complete = self.consume(set) catch |err| {
                    self.output = err;
                    return true;
                };
                if (complete) |result| {
                    self.output = result;
                    return true;
                }
            }
            switch (self.phase) {
                .initial, .retry => self.query(self.range, self.trigger),
                .marker => {
                    if (self.index == self.positions.len) {
                        self.finalize() catch |err| {
                            self.output = err;
                            return true;
                        };
                        self.output = self.result;
                        return true;
                    }
                    const position = self.positions[self.index];
                    var trigger_value = self.trigger;
                    trigger_value.filter = .{ .include = self.trigger.filter.include orelse types.CodeActionKind.QuickFix };
                    trigger_value.context = .{ .not_available_message = if (self.trigger.context) |value| value.not_available_message else "", .position = position };
                    self.query(Range.fromPositions(position, position), trigger_value);
                },
            }
            if (self.response == null) return false;
        }
    }

    fn consume(self: *NearbyQuickFixQuery, set: *Set) !?*Set {
        // Each original provider result remains alive while its actions are
        // borrowed by the aggregate. Failed allocations also release it.
        const a = self.result.arena.allocator();
        switch (self.phase) {
            .retry => return set,
            .initial => {
                for (set.valid_actions) |item| if (item.action.kind) |kind| {
                    if (!item.action.is_ai and types.CodeActionKind.QuickFix.contains(.init(kind))) return set;
                };
                var resource = MarkerResource.fromUri(a, self.model.uri()) catch |err| {
                    set.dispose();
                    return err;
                };
                defer resource.deinit(a);
                const all_markers = self.markers.read(a, .{ .resource = resource }) catch |err| {
                    set.dispose();
                    return err;
                };
                if (all_markers.len == 0) {
                    set.dispose();
                    self.phase = .retry;
                    return null;
                }
                self.result.disposables.append(a, Disposable.from(Set, set, Set.dispose)) catch |err| {
                    set.dispose();
                    return err;
                };
                var positions: std.ArrayList(Position) = .empty;
                for (all_markers) |marker| {
                    if (marker.start_line_number == self.cursor.lineNumber or marker.end_line_number == self.cursor.lineNumber) {
                        try positions.append(a, Position.init(marker.end_line_number, marker.end_column));
                    }
                }
                self.positions = positions.items;
                self.result.documentation = set.documentation;
                self.result.summary_flags = .{ .auto_fix = set.hasAutoFix(), .ai_fix = set.hasAIFix(), .all_ai = set.allAIFixes() };
                self.collect_all = set.all_actions.len == 0;
                try self.all.appendSlice(a, set.all_actions);
                try self.valid.appendSlice(a, set.valid_actions);
                self.phase = .marker;
            },
            .marker => {
                self.result.disposables.append(a, Disposable.from(Set, set, Set.dispose)) catch |err| {
                    set.dispose();
                    return err;
                };
                const column = self.positions[self.index].column;
                const distance = if (column >= self.cursor.column) column - self.cursor.column else self.cursor.column - column;
                if (set.valid_actions.len != 0) {
                    if (self.collect_all) try self.all.appendSlice(a, set.all_actions);
                    if (distance < self.distance) try self.valid.insertSlice(a, 0, set.valid_actions) else try self.valid.appendSlice(a, set.valid_actions);
                }
                self.distance = distance;
                self.index += 1;
            },
        }
        return null;
    }

    fn finalize(self: *NearbyQuickFixQuery) !void {
        const a = self.result.arena.allocator();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var deduplicated: std.ArrayList(Item) = .empty;
        for (self.valid.items) |item| {
            const entry = try seen.getOrPut(a, item.action.title);
            if (!entry.found_existing) try deduplicated.append(a, item);
        }
        std.mem.sort(Item, deduplicated.items, {}, struct {
            fn lessThan(_: void, lhs: Item, rhs: Item) bool {
                if (lhs.action.is_preferred != rhs.action.is_preferred) return lhs.action.is_preferred;
                return !lhs.action.is_ai and rhs.action.is_ai;
            }
        }.lessThan);
        self.result.all_actions = self.all.items;
        self.result.valid_actions = deduplicated.items;
    }

    fn finish(self: *NearbyQuickFixQuery) void {
        const output = self.output.?;
        if (output) |set| {
            if (set != self.result) self.result.dispose();
        } else |_| self.result.dispose();
        const listener = self.listener;
        self.allocator.destroy(self);
        listener.complete(listener.context, output);
    }

    fn cancel(self: *NearbyQuickFixQuery) void {
        if (self.pending) |pending| pending.dispose();
        if (self.response) |response| if (response) |set| {
            set.dispose();
        } else |_| {};
        self.result.dispose();
        self.allocator.destroy(self);
    }
};
