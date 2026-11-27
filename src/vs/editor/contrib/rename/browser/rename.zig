// Port of `RenameSkeleton` from `src/vs/editor/contrib/rename/browser/rename.ts`.
// Native cancellable continuations replace provider promises. The skeleton
// owns the provider order, prepare location, and accumulated rejection messages.
const std = @import("std");
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.RenameProvider);
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

pub const RenameSkeleton = struct {
    arena: std.heap.ArenaAllocator,
    model: *TextModel,
    position: Position,
    providers: []const languages.RenameProvider,
    provider_index: usize = 0,
    pending: ?IDisposable = null,
    rejects: std.ArrayList([]const u8) = .empty,
    prepare_callback: ?languages.RenameLocationCallback = null,
    edits_callback: ?languages.RenameEditCallback = null,
    new_name: []const u8 = "",

    pub fn init(a: std.mem.Allocator, model: *TextModel, position: Position, registry: *Registry) !RenameSkeleton {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const providers = try registry.ordered(arena.allocator(), model, false);
        return .{ .arena = arena, .model = model, .position = position, .providers = providers };
    }
    pub fn deinit(self: *RenameSkeleton) void {
        self.cancel();
        self.arena.deinit();
    }
    pub fn cancel(self: *RenameSkeleton) void {
        if (self.pending) |pending| pending.dispose();
        self.pending = null;
        self.prepare_callback = null;
        self.edits_callback = null;
    }
    pub fn hasProvider(self: *const RenameSkeleton) bool {
        return self.providers.len > 0;
    }

    pub fn resolveRenameLocation(self: *RenameSkeleton, callback: languages.RenameLocationCallback) void {
        self.cancel();
        self.provider_index = 0;
        self.rejects.clearRetainingCapacity();
        self.prepare_callback = callback;
        self.advanceLocation() catch |err| self.finishLocation(err);
    }
    fn finishLocation(self: *RenameSkeleton, result: anyerror!?languages.RenameLocation) void {
        const callback = self.prepare_callback orelse return;
        self.prepare_callback = null;
        callback.complete(callback.context, result);
    }
    fn acceptLocation(self: *RenameSkeleton, result: ?languages.RenameLocation) !bool {
        const value = result orelse return false;
        if (value.reject_reason) |reason| {
            try self.rejects.append(self.arena.allocator(), reason);
            return false;
        }
        self.finishLocation(value);
        return true;
    }
    fn locationReady(context: *anyopaque, result: anyerror!?languages.RenameLocation) void {
        const self: *RenameSkeleton = @ptrCast(@alignCast(context));
        self.pending = null;
        const value = result catch |err| return self.finishLocation(err);
        if (self.acceptLocation(value) catch |err| return self.finishLocation(err)) return;
        self.provider_index += 1;
        self.advanceLocation() catch |err| self.finishLocation(err);
    }
    fn advanceLocation(self: *RenameSkeleton) !void {
        const a = self.arena.allocator();
        while (self.provider_index < self.providers.len) : (self.provider_index += 1) {
            const provider = self.providers[self.provider_index];
            const resolve = provider.resolve_rename_location orelse break;
            if (provider.request_rename_location) |request| {
                self.pending = try request(provider.context, a, self.model, self.position, .{ .context = self, .complete = locationReady });
                return;
            }
            if (try self.acceptLocation(try resolve(provider.context, a, self.model, self.position, .None))) return;
        }
        // No provider could prepare a location. Use the word at the cursor
        // and restart rename edits at the first ranked provider.
        self.provider_index = 0;
        const reason = if (self.rejects.items.len > 0) try std.mem.join(a, "\n", self.rejects.items) else null;
        if (self.model.getWordAtPosition(self.position)) |value| {
            var word = value;
            defer word.deinit();
            self.finishLocation(.{ .range = Range.init(self.position.lineNumber, word.startColumn, self.position.lineNumber, word.endColumn), .text = try a.dupe(u8, word.word.items), .reject_reason = reason });
        } else self.finishLocation(.{ .range = Range.fromPositions(self.position, self.position), .reject_reason = reason });
    }

    pub fn provideRenameEdits(self: *RenameSkeleton, new_name: []const u8, callback: languages.RenameEditCallback) void {
        self.cancel();
        self.rejects.clearRetainingCapacity();
        self.edits_callback = callback;
        self.new_name = self.arena.allocator().dupe(u8, new_name) catch |err| return self.finishEdits(err);
        self.advanceEdits() catch |err| self.finishEdits(err);
    }
    fn finishEdits(self: *RenameSkeleton, result: anyerror!?languages.RenameEdit) void {
        const callback = self.edits_callback orelse return;
        self.edits_callback = null;
        callback.complete(callback.context, result);
    }
    fn acceptEdit(self: *RenameSkeleton, result: ?languages.RenameEdit) !bool {
        const value = result orelse {
            try self.rejects.append(self.arena.allocator(), "No result.");
            return false;
        };
        if (value.reject_reason) |reason| {
            try self.rejects.append(self.arena.allocator(), reason);
            return false;
        }
        self.finishEdits(value);
        return true;
    }
    fn editsReady(context: *anyopaque, result: anyerror!?languages.RenameEdit) void {
        const self: *RenameSkeleton = @ptrCast(@alignCast(context));
        self.pending = null;
        const value = result catch |err| return self.finishEdits(err);
        if (self.acceptEdit(value) catch |err| return self.finishEdits(err)) return;
        self.provider_index += 1;
        self.advanceEdits() catch |err| self.finishEdits(err);
    }
    fn advanceEdits(self: *RenameSkeleton) !void {
        const a = self.arena.allocator();
        while (self.provider_index < self.providers.len) : (self.provider_index += 1) {
            const provider = self.providers[self.provider_index];
            if (provider.request_rename_edits) |request| {
                self.pending = try request(provider.context, a, self.model, self.position, self.new_name, .{ .context = self, .complete = editsReady });
                return;
            }
            if (try self.acceptEdit(try provider.provide_rename_edits(provider.context, a, self.model, self.position, self.new_name, .None))) return;
        }
        self.finishEdits(.{ .reject_reason = try std.mem.join(a, "\n", self.rejects.items) });
    }
};

const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const RenameWidget = @import("renameWidget.zig").RenameWidget;
const bulk = @import("../../../browser/services/bulkEditService.zig");
const resource_config = @import("../../../common/services/textResourceConfiguration.zig");
const events = @import("../../../common/textModelEvents.zig");
const cursor = @import("../../../common/cursorEvents.zig");
const editor_common = @import("../../../common/editorCommon.zig");
const EditorCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const keys = @import("../../../../base/common/keyCodes.zig");
const weight = @backingInt(@import("../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingWeight.EditorContrib);

pub const Services = struct {
    registry: *Registry,
    bulk_edit: bulk.IBulkEditService,
    configuration: ?resource_config.ITextResourceConfigurationService = null,
};

pub const RenameController = struct {
    pub const ID = "editor.contrib.renameController";
    editor: *Editor,
    view: ?*View = null,
    services: ?Services = null,
    widget: RenameWidget,
    skeleton: ?RenameSkeleton = null,
    location: ?languages.RenameLocation = null,
    state: enum { idle, preparing, input, requesting, applying } = .idle,
    wants_preview: bool = false,
    apply_request: ?IDisposable = null,
    registry_listener: ?usize = null,
    cursor_listener: ?usize = null,
    will_change_listener: ?usize = null,
    did_change_listener: ?usize = null,
    content_listener: ?usize = null,
    language_listener: ?usize = null,
    attached_model: ?*TextModel = null,

    pub fn getOrCreate(editor: *Editor, view: *View, services: Services) !*RenameController {
        if (editor.getInstantiatedContribution(RenameController)) |existing| {
            try existing.bind(view, services);
            return existing;
        }
        const self = try editor.allocator.create(RenameController);
        self.* = .{ .editor = editor, .widget = .init(editor.allocator) };
        errdefer self.dispose();
        try self.bind(view, services);
        try editor.registerOwnedContribution(RenameController, self, dispose);
        return self;
    }
    fn bind(self: *RenameController, view: *View, services: Services) !void {
        self.unbind();
        self.view = view;
        self.services = services;
        errdefer self.unbind();
        self.registry_listener = try services.registry.on_did_change.listen(self, onRegistry);
        self.cursor_listener = try self.editor.on_did_change_cursor_position.listen(self, onCursor);
        self.will_change_listener = try self.editor.on_will_change_model.listen(self, onWillChange);
        self.did_change_listener = try self.editor.on_did_change_model.listen(self, onDidChange);
        try self.attachModel();
        self.updateState();
    }
    pub fn unbind(self: *RenameController) void {
        self.cancel(false);
        self.detachModel();
        if (self.registry_listener) |id| self.services.?.registry.on_did_change.unlisten(id);
        if (self.cursor_listener) |id| self.editor.on_did_change_cursor_position.unlisten(id);
        if (self.will_change_listener) |id| self.editor.on_will_change_model.unlisten(id);
        if (self.did_change_listener) |id| self.editor.on_did_change_model.unlisten(id);
        self.registry_listener = null;
        self.cursor_listener = null;
        self.will_change_listener = null;
        self.did_change_listener = null;
        self.services = null;
        self.view = null;
        self.updateState();
    }
    fn dispose(self: *RenameController) void {
        self.unbind();
        self.widget.deinit();
        self.editor.allocator.destroy(self);
    }
    fn attachModel(self: *RenameController) !void {
        if (!self.editor.hasModel()) return;
        const model = self.editor.model;
        self.content_listener = try model.onDidChangeContentWithContextId(self, onContent);
        errdefer model.removeDidChangeContentListener(self.content_listener.?);
        self.language_listener = try model.listenDidChangeLanguage(self, onLanguage);
        self.attached_model = model;
    }
    fn detachModel(self: *RenameController) void {
        const model = self.attached_model orelse return;
        if (self.content_listener) |id| model.removeDidChangeContentListener(id);
        if (self.language_listener) |id| model.removeDidChangeLanguageListener(id);
        self.attached_model = null;
        self.content_listener = null;
        self.language_listener = null;
    }
    fn updateState(self: *RenameController) void {
        const available = if (self.services) |svc| if (self.editor.hasModel()) svc.registry.has(self.editor.model) else false else false;
        self.editor.setRenameState(available, self.widget.visible, self.widget.visible and self.widget.preview);
    }
    fn onRegistry(_: usize, self: *RenameController) !void {
        self.cancel(false);
    }
    fn onLanguage(_: events.ModelLanguageChangedEvent, self: *RenameController) !void {
        self.cancel(false);
    }
    fn onWillChange(_: editor_common.IModelChangedEvent, self: *RenameController) !void {
        self.cancel(false);
        self.detachModel();
    }
    fn onDidChange(_: editor_common.IModelChangedEvent, self: *RenameController) !void {
        try self.attachModel();
        self.updateState();
    }
    fn onContent(_: events.InternalModelContentChangeEvent, self: *RenameController) !void {
        if (self.state != .idle and self.state != .applying) self.cancel(false);
    }
    fn onCursor(event: cursor.ICursorPositionChangedEvent, self: *RenameController) !void {
        switch (self.state) {
            .preparing => self.cancel(false),
            .input, .requesting => if (self.location) |loc| if (loc.range) |range| {
                if (!range.containsPosition(&event.position)) self.cancel(false);
            },
            else => {},
        }
    }
    pub fn cancel(self: *RenameController, focus: bool) void {
        const visible = self.widget.visible;
        self.state = .idle;
        self.widget.hide();
        if (self.apply_request) |request| request.dispose();
        self.apply_request = null;
        if (self.skeleton) |*skeleton| skeleton.deinit();
        self.skeleton = null;
        self.location = null;
        self.updateState();
        if (visible and focus) if (self.view) |view| view.focusEditor();
    }
    pub fn run(self: *RenameController) !void {
        self.cancel(false);
        const svc = self.services orelse return;
        if (!self.editor.hasModel() or self.editor.isReadOnly()) return;
        self.skeleton = try RenameSkeleton.init(self.editor.allocator, self.editor.model, self.editor.modelCursorPosition(), svc.registry);
        if (!self.skeleton.?.hasProvider()) return self.cancel(false);
        self.state = .preparing;
        self.skeleton.?.resolveRenameLocation(.{ .context = self, .complete = prepared });
    }
    fn message(self: *RenameController, reason: []const u8) void {
        self.editor.setMessage("{s}", .{reason});
    }
    fn prepared(context: *anyopaque, result: anyerror!?languages.RenameLocation) void {
        const self: *RenameController = @ptrCast(@alignCast(context));
        if (self.state != .preparing) return;
        const maybe = result catch {
            self.message("Unable to prepare rename");
            return self.cancel(false);
        };
        const loc = maybe orelse return self.cancel(false);
        if (loc.reject_reason) |reason| {
            self.message(reason);
            return self.cancel(false);
        }
        const range = loc.range orelse return self.cancel(false);
        const view = self.view orelse return self.cancel(false);
        const svc = self.services orelse return self.cancel(false);
        var enable_preview = svc.bulk_edit.hasPreviewHandler();
        if (svc.configuration) |cfg| if (cfg.getValue(self.editor.model, "editor.rename.enablePreview")) |value| {
            if (value.* == .bool) enable_preview = enable_preview and value.bool;
        };
        self.location = loc;
        self.state = .input;
        self.widget.show(view, range.getStartPosition(), loc.text, enable_preview, .{ .context = self, .accept = acceptWidget, .cancel = cancelWidget }) catch return self.cancel(false);
        self.updateState();
    }
    fn acceptWidget(context: *anyopaque, preview: bool) void {
        const self: *RenameController = @ptrCast(@alignCast(context));
        self.accept(preview);
    }
    fn cancelWidget(context: *anyopaque) void {
        const self: *RenameController = @ptrCast(@alignCast(context));
        self.cancel(true);
    }
    pub fn accept(self: *RenameController, preview: bool) void {
        if (self.state != .input) return;
        const name = self.widget.input.getValue();
        const loc = self.location orelse return self.cancel(true);
        // Empty/unchanged input cancels the rename, preserving the document.
        if (std.mem.trim(u8, name, " \t\r\n").len == 0 or std.mem.eql(u8, name, loc.text)) return self.cancel(true);
        self.wants_preview = preview and self.widget.preview;
        self.widget.hide();
        self.updateState();
        if (self.view) |view| view.focusEditor();
        self.state = .requesting;
        self.skeleton.?.provideRenameEdits(name, .{ .context = self, .complete = edited });
    }
    fn edited(context: *anyopaque, result: anyerror!?languages.RenameEdit) void {
        const self: *RenameController = @ptrCast(@alignCast(context));
        if (self.state != .requesting) return;
        const maybe = result catch {
            self.message("Unable to compute rename edits");
            return self.cancel(false);
        };
        const value = maybe orelse return self.cancel(false);
        if (value.reject_reason) |reason| {
            self.message(reason);
            return self.cancel(false);
        }
        const svc = self.services orelse return self.cancel(false);
        const a = self.skeleton.?.arena.allocator();
        const label = std.fmt.allocPrint(a, "Renaming '{s}' to '{s}'", .{ self.location.?.text, self.skeleton.?.new_name }) catch return self.cancel(false);
        self.state = .applying;
        self.editor.setCursorPosition(self.editor.modelCursorPosition()) catch {};
        const pending = svc.bulk_edit.apply(value.edit, .{ .editor = self.editor, .show_preview = self.wants_preview, .label = label, .quotable_label = label, .code = "undoredo.rename", .respect_auto_save_config = true }, .{ .context = self, .complete = applied }) catch {
            self.message("Rename failed to apply edits");
            return self.cancel(false);
        };
        if (self.state == .applying) self.apply_request = pending;
    }
    fn applied(context: *anyopaque, result: anyerror!bulk.IBulkEditResult) void {
        const self: *RenameController = @ptrCast(@alignCast(context));
        self.apply_request = null;
        if (result) |_| {} else |_| self.message("Rename failed to apply edits");
        self.cancel(false);
    }
};

const writable = contextkey.Expr{ .Not = "editorReadonly" };
const has_provider = contextkey.Expr{ .Defined = "editorHasRenameProvider" };
const can_rename = contextkey.Expr{ .And = @constCast(&[_]*const contextkey.Expr{ &writable, &has_provider }) };
const text_focus = contextkey.Expr{ .Defined = "editorTextFocus" };
const editor_focus = contextkey.Expr{ .Defined = "editorFocus" };
const input_visible = contextkey.Expr{ .Defined = "renameInputVisible" };
const preview_enabled = contextkey.Expr{ .Defined = "config.editor.rename.enablePreview" };
const visible_preview = contextkey.Expr{ .And = @constCast(&[_]*const contextkey.Expr{ &input_visible, &preview_enabled }) };
const rename_action = blk: {
    var action = EditorCommand.action(.{ .id = "editor.action.rename", .title = "Rename Symbol", .precondition = &can_rename }, true, struct {
        fn run(editor: *Editor) !void {
            if (editor.getContribution(RenameController)) |controller| try controller.run();
        }
    }.run);
    action.menus = &.{.{ .id = actions.menu_ids.EditorContext, .group = "1_modification", .order = 1.1 }};
    action.keybindings = &.{.{ .id = "editor.action.rename", .weight = weight, .when = &text_focus, .bindings = .{ .primary = @backingInt(keys.KeyCode.F2) } }};
    break :blk action;
};
fn acceptAction(comptime with_preview: bool) actions.Action2 {
    const id = if (with_preview) "acceptRenameInputWithPreview" else "acceptRenameInput";
    var action = EditorCommand.action(.{ .id = id, .title = if (with_preview) "Accept Rename with Preview" else "Accept Rename", .precondition = if (with_preview) &visible_preview else &input_visible }, false, struct {
        fn run(editor: *Editor) !void {
            if (editor.getInstantiatedContribution(RenameController)) |controller| controller.accept(with_preview);
        }
    }.run);
    action.f1 = false;
    action.keybindings = &.{.{ .id = id, .weight = weight + 99, .when = &editor_focus, .bindings = .{ .primary = (if (with_preview) keys.KeyMod.CtrlCmd else 0) | @backingInt(keys.KeyCode.Enter) } }};
    return action;
}
const cancel_action = blk: {
    var action = EditorCommand.action(.{ .id = "cancelRenameInput", .title = "Cancel Rename", .precondition = &input_visible }, false, struct {
        fn run(editor: *Editor) !void {
            if (editor.getInstantiatedContribution(RenameController)) |controller| controller.cancel(true);
        }
    }.run);
    action.f1 = false;
    action.keybindings = &.{.{ .id = "cancelRenameInput", .weight = weight + 99, .when = &editor_focus, .bindings = .{ .primary = @backingInt(keys.KeyCode.Escape), .secondary = &.{keys.KeyMod.Shift | @backingInt(keys.KeyCode.Escape)} } }};
    break :blk action;
};
pub const editor_actions = [_]actions.Action2{ rename_action, acceptAction(false), acceptAction(true), cancel_action };
