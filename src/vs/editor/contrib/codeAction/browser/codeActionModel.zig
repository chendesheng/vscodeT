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
    oracle: CodeActionOracle = .{},
    state: CodeActionsState = .Empty,
    trigger_arena: std.heap.ArenaAllocator,
    pending: ?Disposable = null,
    owned_actions: ?*codeAction.ManagedCodeActionSet = null,
    completion_task: dispatch.Task = .{},
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

    pub fn create(a: std.mem.Allocator, editor: *Editor, registry: *Registry, marker_service: ?*MarkerService, queue: *dispatch.Queue, context: *anyopaque, on_change: *const fn (*anyopaque, CodeActionsState) void) !*CodeActionModel {
        const self = try a.create(CodeActionModel);
        self.* = .{ .allocator = a, .editor = editor, .registry = registry, .marker_service = marker_service, .trigger_arena = .init(a), .context = context, .on_change = on_change };
        self.oracle.task = .{ .queue = queue, .context = self, .run = onAutoTrigger };
        self.completion_task = .{ .queue = queue, .context = self, .run = onCompleted };
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
        if (self.can_trigger) self.oracle.task.schedule(time.milliTimestamp() + 250);
    }
    fn onAutoTrigger(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeActionModel = @ptrCast(@alignCast(context));
        self.trigger(.{ .type = .Auto, .trigger_action = .Default });
        return false;
    }

    pub fn clear(self: *CodeActionModel) void {
        self.oracle.task.schedule(null);
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
        self.cancelPending();
        self.clearOwnedActions();
        _ = self.trigger_arena.reset(.retain_capacity);
        const selection = CodeActionOracle.selectionUnlessWhitespaceEnclosed(self.editor, trigger_value.type, self.mode, self.oracle.ignore_lightbulb_off) orelse {
            self.state = .Empty;
            self.on_change(self.context, .Empty);
            return;
        };
        const trigger_copy = codeAction.copyTrigger(self.trigger_arena.allocator(), trigger_value) catch return;
        self.state = .{ .Triggered = .{ .trigger = trigger_copy, .position = selection.getStartPosition() } };
        self.on_change(self.context, self.state);
        const range = Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn);
        self.pending = codeAction.getCodeActions(self.allocator, self.registry, model, range, trigger_copy, .None, .{ .context = self, .complete = provideResult }) catch |err| blk: {
            provideResult(self, err);
            break :blk null;
        };
    }

    fn provideResult(context: *anyopaque, result: anyerror!*codeAction.ManagedCodeActionSet) void {
        const self: *CodeActionModel = @ptrCast(@alignCast(context));
        self.pending = null;
        const set = result catch {
            self.state = .Empty;
            self.completion_task.schedule(time.milliTimestamp());
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
        self.completion_task.schedule(time.milliTimestamp());
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
