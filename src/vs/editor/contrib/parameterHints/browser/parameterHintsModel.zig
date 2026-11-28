// Port of `src/vs/editor/contrib/parameterHints/browser/parameterHintsModel.ts`.
// Native deadline tasks replace the browser Delayer; request disposal cancels
// asynchronous provider calls before a model, registry or editor is detached.
const std = @import("std");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const languages = @import("../../../common/languages.zig");
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.SignatureHelpProvider);
const Request = @import("provideSignatureHelp.zig").Request;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const model_events = @import("../../../common/textModelEvents.zig");
const cursor_events = @import("../../../common/cursorEvents.zig");
const editor_common = @import("../../../common/editorCommon.zig");

pub const TriggerContext = struct {
    trigger_kind: languages.SignatureHelpTriggerKind,
    trigger_character: ?[]const u8 = null,
};

pub const ParameterHintsModel = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    registry: ?*Registry = null,
    registry_listener: ?usize = null,
    on_changed_hints: Emitter(?languages.SignatureHelp),
    timer: dispatch.Task = .{},
    trigger_context: ?TriggerContext = null,
    active: ?*Request = null,
    pending: ?*Request = null,
    enabled: bool = true,
    cycle: bool = true,
    attached: bool = false,
    type_listener: ?usize = null,
    cursor_listener: ?usize = null,
    focus_listener: ?usize = null,
    will_change_listener: ?usize = null,
    did_change_listener: ?usize = null,
    content_listener: ?usize = null,
    language_listener: ?usize = null,

    const delay_ms = 120;

    pub fn init(allocator: std.mem.Allocator, editor: *Editor) ParameterHintsModel {
        return .{ .allocator = allocator, .editor = editor, .on_changed_hints = .init(allocator) };
    }

    pub fn attach(self: *ParameterHintsModel, registry: ?*Registry, window: ?*dispatch.Queue) !void {
        self.detach();
        self.registry = registry;
        self.timer = .{ .queue = window, .context = self, .run = onDeadline };
        errdefer self.detach();
        if (registry) |value| self.registry_listener = try value.on_did_change.listen(self, registryChanged);
        self.type_listener = try self.editor.on_did_type.listen(self, onDidType);
        self.cursor_listener = try self.editor.on_did_change_cursor_selection.listen(self, onCursor);
        self.focus_listener = try self.editor.on_did_change_text_focus.listen(self, onFocus);
        self.will_change_listener = try self.editor.on_will_change_model.listen(self, onWillChangeModel);
        self.did_change_listener = try self.editor.on_did_change_model.listen(self, onDidChangeModel);
        try self.attachModel();
    }

    pub fn attachWindow(self: *ParameterHintsModel, window: *dispatch.Queue) void {
        self.timer.schedule(null);
        self.timer.queue = window;
        if (self.trigger_context != null) self.timer.schedule(time.milliTimestamp(self.editor.clockIo()) + delay_ms);
    }

    pub fn detach(self: *ParameterHintsModel) void {
        self.cancel();
        self.detachModel();
        if (self.registry_listener) |id| self.registry.?.on_did_change.unlisten(id);
        if (self.type_listener) |id| self.editor.on_did_type.unlisten(id);
        if (self.cursor_listener) |id| self.editor.on_did_change_cursor_selection.unlisten(id);
        if (self.focus_listener) |id| self.editor.on_did_change_text_focus.unlisten(id);
        if (self.will_change_listener) |id| self.editor.on_will_change_model.unlisten(id);
        if (self.did_change_listener) |id| self.editor.on_did_change_model.unlisten(id);
        self.registry_listener = null;
        self.type_listener = null;
        self.cursor_listener = null;
        self.focus_listener = null;
        self.will_change_listener = null;
        self.did_change_listener = null;
        self.registry = null;
        self.timer.queue = null;
    }

    pub fn deinit(self: *ParameterHintsModel) void {
        self.detach();
        self.on_changed_hints.deinit();
    }

    fn attachModel(self: *ParameterHintsModel) !void {
        if (!self.editor.hasModel() or self.attached) return;
        self.content_listener = try self.editor.model.onDidChangeContentWithContextId(self, onContent);
        errdefer self.editor.model.removeDidChangeContentListener(self.content_listener.?);
        self.language_listener = try self.editor.model.listenDidChangeLanguage(self, onLanguage);
        self.attached = true;
    }

    fn detachModel(self: *ParameterHintsModel) void {
        if (!self.attached) return;
        if (self.content_listener) |id| self.editor.model.removeDidChangeContentListener(id);
        if (self.language_listener) |id| self.editor.model.removeDidChangeLanguageListener(id);
        self.content_listener = null;
        self.language_listener = null;
        self.attached = false;
    }

    fn registryChanged(_: usize, self: *ParameterHintsModel) !void {
        self.cancel();
    }
    fn onLanguage(_: model_events.ModelLanguageChangedEvent, self: *ParameterHintsModel) !void {
        self.cancel();
    }
    fn onWillChangeModel(_: editor_common.IModelChangedEvent, self: *ParameterHintsModel) !void {
        self.cancel();
        self.detachModel();
    }
    fn onDidChangeModel(_: editor_common.IModelChangedEvent, self: *ParameterHintsModel) !void {
        try self.attachModel();
        try self.on_changed_hints.fire(null);
    }
    fn onFocus(focused: bool, self: *ParameterHintsModel) !void {
        if (!focused) self.cancel();
    }
    fn onContent(_: model_events.InternalModelContentChangeEvent, self: *ParameterHintsModel) !void {
        if (self.isTriggered()) try self.trigger(.{ .trigger_kind = .ContentChange }, null);
    }
    fn onCursor(event: cursor_events.ICursorSelectionChangedEvent, self: *ParameterHintsModel) !void {
        if (std.mem.eql(u8, event.source, "mouse")) {
            self.cancel();
        } else if (self.isTriggered()) try self.trigger(.{ .trigger_kind = .ContentChange }, null);
    }
    fn onDidType(text: []const u8, self: *ParameterHintsModel) !void {
        if (!self.enabled or text.len == 0 or !self.editor.hasModel()) return;
        const registry = self.registry orelse return;
        const providers = try registry.ordered(self.allocator, self.editor.model, false);
        defer self.allocator.free(providers);
        for (providers) |provider| {
            for (provider.trigger_characters) |char| {
                if (char.len > 0 and std.mem.endsWith(u8, text, char)) return self.trigger(.{ .trigger_kind = .TriggerCharacter, .trigger_character = char }, null);
            }
            if (self.isTriggered()) for (provider.retrigger_characters) |char| {
                if (char.len > 0 and std.mem.endsWith(u8, text, char)) return self.trigger(.{ .trigger_kind = .TriggerCharacter, .trigger_character = char }, null);
            };
        }
    }

    pub fn hints(self: *const ParameterHintsModel) ?languages.SignatureHelp {
        const active = self.active orelse return null;
        return if (active.result) |value| value.value else null;
    }

    pub fn isTriggered(self: *const ParameterHintsModel) bool {
        return self.active != null or self.pending != null or self.trigger_context != null;
    }

    pub fn cancel(self: *ParameterHintsModel) void {
        self.timer.schedule(null);
        self.trigger_context = null;
        if (self.pending) |request| request.deinit();
        self.pending = null;
        if (self.active) |request| request.deinit();
        self.active = null;
        self.on_changed_hints.fire(null) catch {};
    }

    pub fn configure(self: *ParameterHintsModel, enabled: bool, cycle: bool) void {
        self.enabled = enabled;
        self.cycle = cycle;
        if (!enabled) self.cancel();
    }

    pub fn trigger(self: *ParameterHintsModel, context: TriggerContext, delay: ?i64) !void {
        const registry = self.registry orelse return;
        if (!self.editor.hasModel() or !registry.has(self.editor.model)) return;
        if (self.trigger_context == null or context.trigger_kind != .ContentChange) self.trigger_context = context;
        if (self.timer.queue != null) {
            self.timer.schedule(null);
            self.timer.schedule(time.milliTimestamp(self.editor.clockIo()) + (delay orelse delay_ms));
        } else try self.doTrigger();
    }

    fn onDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ParameterHintsModel = @ptrCast(@alignCast(context));
        self.doTrigger() catch self.cancel();
        return true;
    }

    fn doTrigger(self: *ParameterHintsModel) !void {
        const registry = self.registry orelse return;
        const context = self.trigger_context orelse return;
        self.trigger_context = null;
        if (!self.editor.hasModel()) return;
        const retrigger = self.pending != null or self.active != null;
        if (self.pending) |request| request.deinit();
        self.pending = null;
        const request = try Request.create(self.allocator, self.editor.model, self.editor.modelCursorPosition(), .{
            .trigger_kind = context.trigger_kind,
            .trigger_character = context.trigger_character,
            .is_retrigger = retrigger,
            .active_signature_help = self.hints(),
        }, .{ .context = self, .complete = ready });
        self.pending = request;
        errdefer {
            self.pending = null;
            request.deinit();
        }
        try request.provideSignatureHelp(registry);
    }

    fn ready(context: *anyopaque, request: *Request) void {
        const self: *ParameterHintsModel = @ptrCast(@alignCast(context));
        // A result that arrives after a newer trigger was queued is stale.
        // Retain the last visible result for the upcoming retrigger.
        if (self.trigger_context != null) return;
        self.pending = null;
        if (self.active) |old| old.deinit();
        self.active = null;
        if (request.result) |value| {
            if (value.value.signatures.len > 0) {
                request.result.?.value.active_signature = @min(value.value.active_signature, value.value.signatures.len - 1);
                self.active = request;
                self.on_changed_hints.fire(self.hints()) catch {};
                return;
            }
        }
        request.deinit();
        self.on_changed_hints.fire(null) catch {};
    }

    pub fn move(self: *ParameterHintsModel, forward: bool) void {
        const active = self.active orelse return;
        const result = &active.result.?.value;
        const count = result.signatures.len;
        if (count == 0) return;
        const index = result.active_signature;
        const at_end = if (forward) index + 1 == count else index == 0;
        if ((count < 2 or at_end) and !self.cycle) return self.cancel();
        result.active_signature = if (forward) (index + 1) % count else if (index == 0) count - 1 else index - 1;
        self.on_changed_hints.fire(result.*) catch {};
    }
};
