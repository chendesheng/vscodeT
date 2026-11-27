// Port of the action registration from `src/vs/editor/contrib/format/browser/formatActions.ts`.

const ActionEditor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ActionCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const action_registry = @import("../../../../platform/actions/common/actions.zig");

pub const editor_actions = [_]action_registry.Action2{
    ActionCommand.action(.{ .id = "editor.action.formatSelection", .title = "Format Selection", .category = "Editor", .precondition = &ActionCommand.writable }, true, ActionEditor.formatSelection),
};

// Port of FormatOnType. Its subscriptions belong to the widget contribution,
// and an owner-scoped window fiber runs each provider request and minimal diff.
const std = @import("std");
const Features = @import("../../../common/services/languageFeaturesService.zig").LanguageFeaturesService;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const languages = @import("../../../common/languages.zig");
const model_events = @import("../../../common/textModelEvents.zig");
const editor_common = @import("../../../common/editorCommon.zig");
const cancellation = @import("../../../../base/common/cancellation.zig");
const Window = @import("../../../../base/common/windowDispatch.zig");
const format = @import("format.zig");

pub const FormatOnType = struct {
    pub const ID = "editor.contrib.autoFormat";
    editor: *ActionEditor,
    features: ?*Features = null,
    enabled: bool = false,
    registry_listener: ?usize = null,
    typing_listener: ?usize = null,
    language_model: ?*TextModel = null,
    language_listener: ?usize = null,
    will_change_listener: usize = undefined,
    did_change_listener: usize = undefined,
    pending: ?*Request = null,

    pub fn getOrCreate(editor: *ActionEditor, features: *Features, enabled: bool) !*FormatOnType {
        if (editor.getContribution(FormatOnType)) |self| {
            try self.bind(features, enabled);
            return self;
        }
        const self = try editor.allocator.create(FormatOnType);
        errdefer editor.allocator.destroy(self);
        self.* = .{ .editor = editor };
        self.will_change_listener = try editor.on_will_change_model.listen(self, willChangeModel);
        errdefer editor.on_will_change_model.unlisten(self.will_change_listener);
        self.did_change_listener = try editor.on_did_change_model.listen(self, didChangeModel);
        errdefer editor.on_did_change_model.unlisten(self.did_change_listener);
        errdefer self.detachModel();
        errdefer self.detachRegistry();
        try self.bind(features, enabled);
        try editor.registerOwnedContribution(FormatOnType, self, deinit);
        return self;
    }

    pub fn bind(self: *FormatOnType, features: ?*Features, enabled: bool) !void {
        if (self.features == features and self.enabled == enabled and self.language_model == self.editor.getModel()) return;
        if (self.features != features) {
            self.cancelPending();
            self.detachRegistry();
            self.features = features;
            if (features) |value| self.registry_listener = try value.on_type_formatting_edit_provider.on_did_change.listen(self, registryChanged);
        }
        self.enabled = enabled;
        try self.update();
    }

    pub fn setEnabled(self: *FormatOnType, enabled: bool) !void {
        if (self.enabled == enabled) return;
        self.enabled = enabled;
        try self.update();
    }

    fn detachRegistry(self: *FormatOnType) void {
        if (self.registry_listener) |listener| self.features.?.on_type_formatting_edit_provider.on_did_change.unlisten(listener);
        self.registry_listener = null;
        self.features = null;
    }

    fn detachModel(self: *FormatOnType) void {
        self.cancelPending();
        if (self.typing_listener) |listener| self.editor.on_did_type.unlisten(listener);
        self.typing_listener = null;
        if (self.language_listener) |listener| self.language_model.?.removeDidChangeLanguageListener(listener);
        self.language_listener = null;
        self.language_model = null;
    }

    fn willChangeModel(_: editor_common.IModelChangedEvent, self: *FormatOnType) !void {
        self.detachModel();
    }

    fn didChangeModel(_: editor_common.IModelChangedEvent, self: *FormatOnType) !void {
        try self.update();
    }

    fn languageChanged(_: model_events.ModelLanguageChangedEvent, self: *FormatOnType) !void {
        try self.update();
    }

    fn registryChanged(_: usize, self: *FormatOnType) !void {
        try self.update();
    }

    fn update(self: *FormatOnType) !void {
        self.cancelPending();
        if (self.typing_listener) |listener| self.editor.on_did_type.unlisten(listener);
        self.typing_listener = null;
        const model = self.editor.getModel() orelse return;
        if (self.language_model != model) {
            if (self.language_listener) |listener| self.language_model.?.removeDidChangeLanguageListener(listener);
            self.language_listener = null;
            self.language_model = model;
            self.language_listener = try model.listenDidChangeLanguage(self, languageChanged);
        }
        if (!self.enabled) return;
        const features = self.features orelse return;
        const providers = try features.on_type_formatting_edit_provider.ordered(self.editor.allocator, model, false);
        defer self.editor.allocator.free(providers);
        if (providers.len == 0 or providers[0].auto_format_trigger_characters.len == 0) return;
        self.typing_listener = try self.editor.on_did_type.listen(self, didType);
    }

    fn didType(text: []const u8, self: *FormatOnType) !void {
        if (!self.enabled or self.editor.isReadOnly() or self.editor.cursorCount() != 1 or !self.editor.modelSelection().isEmpty()) return;
        const model = self.editor.getModel() orelse return;
        const features = self.features orelse return;
        const providers = try features.on_type_formatting_edit_provider.ordered(self.editor.allocator, model, false);
        defer self.editor.allocator.free(providers);
        if (providers.len == 0) return;
        for (providers[0].auto_format_trigger_characters) |character| {
            if (character.len != 0 and std.mem.endsWith(u8, text, character)) {
                try self.trigger(model, features, character);
                return;
            }
        }
    }

    const Request = struct {
        owner: *FormatOnType,
        model: *TextModel,
        features: *Features,
        position: Position,
        options: languages.FormattingOptions,
        ch: []const u8,
        source: cancellation.CancellationTokenSource,
        arena: std.heap.ArenaAllocator,
        window: *Window.Queue,
        content_listener: usize,
        future: std.Io.Future(anyerror![]const languages.TextEdit),
        completion: Window.Task,

        fn contentChanged(event: model_events.InternalModelContentChangeEvent, self: *Request) !void {
            const change = event.contentChangedEvent;
            if (change.isFlush) {
                self.source.cancel();
                return;
            }
            for (change.changes.items) |edit| {
                if (edit.range.endLineNumber <= self.position.lineNumber) {
                    self.source.cancel();
                    return;
                }
            }
        }

        fn run(self: *Request) anyerror![]const languages.TextEdit {
            defer self.completion.post();
            const token = try self.source.token();
            return format.getOnTypeFormattingEdits(self.arena.allocator(), self.features, self.model, self.position, self.ch, self.options, token, self.window.io);
        }

        fn complete(context: *anyopaque, _: i64, _: bool) bool {
            const self: *Request = @ptrCast(@alignCast(context));
            const owner = self.owner;
            owner.pending = null;
            defer self.destroy();
            const edits = self.future.await(self.window.io) catch return false;
            const token = self.source.token() catch return false;
            if (token.isCancellationRequested() or owner.editor.getModel() != self.model) return false;
            return owner.apply(edits) catch false;
        }

        fn destroy(self: *Request) void {
            self.model.removeDidChangeContentListener(self.content_listener);
            self.completion.schedule(null);
            self.source.deinit();
            self.arena.deinit();
            self.owner.editor.allocator.destroy(self);
        }
    };

    fn trigger(self: *FormatOnType, model: *TextModel, features: *Features, ch: []const u8) !void {
        self.cancelPending();
        const allocator = self.editor.allocator;
        const position = self.editor.modelCursorPosition();
        const resolved = model.getOptions();
        const options: languages.FormattingOptions = .{ .tab_size = @intCast(resolved.tabSize), .insert_spaces = resolved.insertSpaces };
        const window = self.editor.folding_task.queue;
        if (window == null or window.?.scheduler == null) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const edits = try format.getOnTypeFormattingEdits(arena.allocator(), features, model, position, ch, options, .None, null);
            _ = try self.apply(edits);
            return;
        }
        const request = try allocator.create(Request);
        errdefer allocator.destroy(request);
        var source = try cancellation.CancellationTokenSource.init(allocator);
        errdefer source.deinit();
        request.* = .{
            .owner = self,
            .model = model,
            .features = features,
            .position = position,
            .options = options,
            .ch = undefined,
            .source = source,
            .arena = .init(allocator),
            .window = window.?,
            .content_listener = undefined,
            .future = undefined,
            .completion = .{ .queue = window, .context = request, .run = Request.complete, .progress = true },
        };
        errdefer request.arena.deinit();
        request.ch = try request.arena.allocator().dupe(u8, ch);
        request.content_listener = try model.onDidChangeContentWithContextId(request, Request.contentChanged);
        errdefer model.removeDidChangeContentListener(request.content_listener);
        request.future = try window.?.io.concurrent(Request.run, .{request});
        self.pending = request;
    }

    fn apply(self: *FormatOnType, edits: []const languages.TextEdit) !bool {
        if (edits.len == 0 or self.editor.isReadOnly()) return false;
        const allocator = self.editor.allocator;
        const converted = try allocator.alloc(@import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").TextEdit, edits.len);
        defer allocator.free(converted);
        for (converted, edits) |*out, edit| out.* = .{ .range = edit.range, .text = edit.text };
        self.editor.pushUndoStop();
        try self.editor.applyTextEdits(converted, &.{});
        self.editor.pushUndoStop();
        return true;
    }

    fn cancelPending(self: *FormatOnType) void {
        const request = self.pending orelse return;
        self.pending = null;
        request.source.cancel();
        _ = request.future.cancel(request.window.io) catch &.{};
        request.destroy();
    }

    fn deinit(self: *FormatOnType) void {
        self.detachModel();
        self.detachRegistry();
        self.editor.on_will_change_model.unlisten(self.will_change_listener);
        self.editor.on_did_change_model.unlisten(self.did_change_listener);
        self.editor.allocator.destroy(self);
    }
};
