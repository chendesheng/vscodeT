// Terminal controller for the suggest contribution.
//
// Upstream `suggestController.ts` wires a large editor contribution and
// actions. The terminal forwards keys through the editor and adapts timers
// and provider promise settlement to the shared window dispatcher.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Position = @import("../../../common/core/position.zig").Position;
const completion = @import("../../../common/languages/completion.zig");
const SuggestModel = @import("./suggestModel.zig").SuggestModel;
const SuggestWidget = @import("./suggestWidget.zig").SuggestWidget;
const SnippetSession = @import("../../snippet/browser/snippetSession.zig").SnippetSession;
const OvertypingCapturer = @import("./suggestOvertypingCapturer.zig").OvertypingCapturer;
const suggestWidget = @import("./suggestWidget.zig");

pub const SuggestControllerHost = struct {
    context: *anyopaque,
    text_height: *const fn (context: *anyopaque) usize,
    visible_row_of: *const fn (context: *anyopaque, position: Position) ?usize,
    request_frame: *const fn (context: *anyopaque) void,
    focus_editor: *const fn (context: *anyopaque) void,
    has_editor_focus: *const fn (context: *anyopaque) bool,
};

pub const SuggestController = struct {
    pub const ID = "editor.contrib.suggestController";
    allocator: Allocator,
    editor: *Editor,
    model: SuggestModel,
    widget: *SuggestWidget,
    snippet_session: ?*SnippetSession = null,
    choice_active: bool = false,
    overtyping_capturer: OvertypingCapturer,
    host: SuggestControllerHost,
    will_type_listener: ?usize = null,
    will_change_listener: ?usize = null,
    did_change_listener: ?usize = null,
    host_bound: bool = true,
    model_attached: bool = false,

    pub fn init(
        allocator: Allocator,
        editor: *Editor,
        providers: []const completion.CompletionItemProvider,
        host: SuggestControllerHost,
    ) !*SuggestController {
        return initWithRegistry(allocator, editor, providers, host, null);
    }

    pub fn initWithRegistry(
        allocator: Allocator,
        editor: *Editor,
        providers: []const completion.CompletionItemProvider,
        host: SuggestControllerHost,
        registry: ?*@import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(completion.CompletionItemProvider),
    ) !*SuggestController {
        const self = try allocator.create(SuggestController);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .model = SuggestModel.initWithRegistry(allocator, editor, providers, registry),
            .widget = undefined,
            .overtyping_capturer = OvertypingCapturer.init(allocator),
            .host = host,
        };
        errdefer self.model.deinit();
        self.widget = try SuggestWidget.init(allocator, &self.model, .{
            .context = self,
            .text_height = widgetTextHeight,
            .visible_row_of = widgetVisibleRowOf,
            .request_frame = widgetRequestFrame,
        });
        errdefer self.widget.deinit();
        self.model.overtyping_capturer = self.overtyping_capturer.interface();
        self.model.listener = .{ .context = self, .on_change = onModelChanged };
        self.will_change_listener = try editor.on_will_change_model.listen(self, onWillChangeModel);
        errdefer editor.on_will_change_model.unlisten(self.will_change_listener.?);
        self.did_change_listener = try editor.on_did_change_model.listen(self, onDidChangeModel);
        errdefer editor.on_did_change_model.unlisten(self.did_change_listener.?);
        try self.attachModel();
        return self;
    }

    pub fn getOrCreate(editor: *Editor, providers: []const completion.CompletionItemProvider, host: SuggestControllerHost, registry: ?*@import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(completion.CompletionItemProvider)) !*SuggestController {
        if (editor.getContribution(SuggestController)) |self| {
            self.unbindHost();
            self.host = host;
            self.host_bound = true;
            self.model.providers = providers;
            self.model.active_providers = providers;
            self.model.registry = registry;
            errdefer self.unbindHost();
            try self.attachModel();
            return self;
        }
        const self = try initWithRegistry(editor.allocator, editor, providers, host, registry);
        errdefer self.deinit();
        try editor.registerOwnedContribution(SuggestController, self, deinit);
        return self;
    }

    fn onWillChangeModel(_: @import("../../../common/editorCommon.zig").IModelChangedEvent, self: *SuggestController) !void {
        self.detachModel();
    }

    fn onDidChangeModel(_: @import("../../../common/editorCommon.zig").IModelChangedEvent, self: *SuggestController) !void {
        try self.attachModel();
    }

    fn attachModel(self: *SuggestController) !void {
        if (!self.host_bound or !self.editor.hasModel() or self.model_attached) return;
        try self.model.registerListeners();
        errdefer self.model.unregisterListeners();
        self.will_type_listener = try self.editor.on_will_type.listen(self, onWillType);
        self.model_attached = true;
    }

    fn detachModel(self: *SuggestController) void {
        if (!self.model_attached) return;
        if (self.will_type_listener) |id| self.editor.on_will_type.unlisten(id);
        self.will_type_listener = null;
        self.model.unregisterListeners();
        self.model.cancel();
        self.cancelSnippetSession();
        self.overtyping_capturer.reset();
        self.hideWidget();
        self.model.active_providers = self.model.providers;
        self.model_attached = false;
    }

    pub fn unbindHost(self: *SuggestController) void {
        self.detachModel();
        self.host_bound = false;
        self.model.providers = &.{};
        self.model.active_providers = &.{};
        self.model.registry = null;
    }

    pub fn deinit(self: *SuggestController) void {
        if (self.will_change_listener) |id| self.editor.on_will_change_model.unlisten(id);
        if (self.did_change_listener) |id| self.editor.on_did_change_model.unlisten(id);
        self.detachModel();
        self.overtyping_capturer.deinit();
        self.widget.deinit();
        self.model.deinit();
        self.allocator.destroy(self);
    }

    pub fn widgetInterface(self: *SuggestController) @import("../../../browser/editorBrowser.zig").IContentWidget {
        return self.widget.interface();
    }

    pub fn hasSnippetSession(self: *const SuggestController) bool {
        return self.snippet_session != null;
    }

    pub fn nextSnippetPlaceholder(self: *SuggestController) !bool {
        const session = self.snippet_session orelse return false;
        if (session.isAtLastPlaceholder()) {
            session.deinit();
            self.snippet_session = null;
            return false;
        }
        return try session.next();
    }

    pub fn previousSnippetPlaceholder(self: *SuggestController) !bool {
        const session = self.snippet_session orelse return false;
        if (session.isAtFirstPlaceholder()) return false;
        return try session.previous();
    }

    pub fn cancelSnippetSession(self: *SuggestController) void {
        if (self.snippet_session) |session| session.deinit();
        self.snippet_session = null;
        self.choice_active = false;
    }

    pub fn setTheme(self: *SuggestController, theme: suggestWidget.Theme) void {
        self.widget.setTheme(theme);
    }

    pub fn isOpen(self: *const SuggestController) bool {
        return self.model.isOpen();
    }

    pub fn attachWindow(self: *SuggestController, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        self.model.attachWindow(window, self, onDeadline);
    }

    fn onDeadline(context: *anyopaque, now: i64, _: bool) bool {
        const self: *SuggestController = @ptrCast(@alignCast(context));
        return self.onTick(now) catch false;
    }

    fn onModelChanged(context: *anyopaque) void {
        const self: *SuggestController = @ptrCast(@alignCast(context));
        if (!self.model_attached) return;
        if (!self.host.has_editor_focus(self.host.context)) {
            self.cancel();
        } else if (self.model.isOpen()) {
            self.showWidget();
        } else {
            self.hideWidget();
        }
    }

    pub fn onTick(self: *SuggestController, now_ms: i64) !bool {
        if (!self.model_attached or !self.model.hasPendingTrigger()) return false;
        if (!self.host.has_editor_focus(self.host.context)) {
            self.cancel();
            return false;
        }
        const changed = try self.model.onTick(now_ms);
        if (self.model.isOpen()) self.showWidget() else self.hideWidget();
        return changed;
    }

    /// Allows isolated controller tests to deliver typed line context.
    pub fn onTypedCharacter(self: *SuggestController, ch: u8, now_ms: i64) !bool {
        if (!self.model_attached) return false;
        if (!self.host.has_editor_focus(self.host.context)) {
            self.cancel();
            return false;
        }
        const changed = try self.model.onTypedCharacter(ch, now_ms);
        if (self.model.isOpen()) self.showWidget() else self.hideWidget();
        return changed;
    }

    fn onWillType(_: []const u8, self: *SuggestController) !void {
        self.overtyping_capturer.capture(self.editor);
    }

    pub fn onCursorMoved(self: *SuggestController) void {
        if (!self.model_attached) return;
        if (self.snippet_session) |session| {
            const within = session.isSelectionWithinPlaceholders() catch false;
            if (!within or session.isAtLastPlaceholder()) {
                self.choice_active = false;
                session.deinit();
                self.snippet_session = null;
            }
        }
        if (self.model.onCursorMoved()) self.hideWidget();
    }

    /// Returns true when suggest consumed the key.
    pub fn handleKey(self: *SuggestController, event: *ui.KeyEvent, now_ms: i64) !bool {
        if (!self.model_attached) return false;
        if (self.choice_active and self.model.isOpen()) {
            switch (event.key) {
                .up => {
                    _ = self.model.move(-1);
                    self.showWidget();
                    return true;
                },
                .down => {
                    _ = self.model.move(1);
                    self.showWidget();
                    return true;
                },
                .enter, .tab => {
                    _ = try self.acceptSelected();
                    return true;
                },
                .escape => {
                    self.choice_active = false;
                    self.cancel();
                    return true;
                },
                else => {},
            }
        }
        if (self.snippet_session) |session| {
            switch (event.key) {
                .tab => {
                    const moved = try session.next();
                    if (!moved) {
                        session.deinit();
                        self.snippet_session = null;
                        self.choice_active = false;
                        self.hideWidget();
                    } else {
                        try self.maybeShowChoice();
                    }
                    self.host.focus_editor(self.host.context);
                    self.host.request_frame(self.host.context);
                    return true;
                },
                .backtab => {
                    _ = try session.previous();
                    try self.maybeShowChoice();
                    self.host.focus_editor(self.host.context);
                    self.host.request_frame(self.host.context);
                    return true;
                },
                .escape => {
                    session.deinit();
                    self.snippet_session = null;
                    self.choice_active = false;
                    self.hideWidget();
                    self.host.request_frame(self.host.context);
                    return true;
                },
                else => {},
            }
        }
        if (isCtrlSpace(event)) {
            if (!self.model.isOpen() and !self.host.has_editor_focus(self.host.context)) return false;
            self.host.focus_editor(self.host.context);
            if (self.model.isOpen()) {
                self.cancel();
            } else {
                _ = try self.model.triggerExplicit(now_ms);
                if (self.model.isOpen()) self.showWidget();
            }
            return true;
        }

        if (!self.model.isOpen()) return false;

        switch (event.key) {
            .escape => {
                self.cancel();
                return true;
            },
            .up => {
                _ = self.model.move(-1);
                self.showWidget();
                return true;
            },
            .down => {
                _ = self.model.move(1);
                self.showWidget();
                return true;
            },
            .page_up => {
                _ = self.model.page(8, false);
                self.showWidget();
                return true;
            },
            .page_down => {
                _ = self.model.page(8, true);
                self.showWidget();
                return true;
            },
            .enter, .tab => {
                _ = try self.acceptSelected();
                return true;
            },
            .char, .text => {
                if (!event.mods.ctrl and !event.mods.alt) {
                    if (keyChar(event)) |ch| {
                        if (ch <= 0x7f and self.model.hasCommitCharacter(@intCast(ch))) {
                            _ = try self.acceptSelected();
                            return true;
                        }
                    }
                }
                if (event.mods.ctrl) {
                    const ch = keyChar(event) orelse return false;
                    if (ch == 'n' or ch == 'j') {
                        _ = self.model.move(1);
                        self.showWidget();
                        return true;
                    }
                    if (ch == 'p' or ch == 'k') {
                        _ = self.model.move(-1);
                        self.showWidget();
                        return true;
                    }
                }
                // Typing continues to edit the document and refilter. Return
                // the keyboard to the editor if a mouse click focused the row.
                self.widget.focused = false;
                self.host.focus_editor(self.host.context);
                return false;
            },
            .left, .right, .home, .end => {
                self.onCursorMoved();
                return false;
            },
            else => {
                self.widget.focused = false;
                self.host.focus_editor(self.host.context);
                return false;
            },
        }
    }

    pub fn cancel(self: *SuggestController) void {
        if (!self.model_attached) return;
        self.overtyping_capturer.unlock();
        self.model.cancel();
        self.hideWidget();
        self.host.request_frame(self.host.context);
    }

    fn acceptSelected(self: *SuggestController) !bool {
        const old_suspend = self.model.suspend_events;
        self.model.suspend_events = true;
        defer self.model.suspend_events = old_suspend;
        const was_choice = self.choice_active;
        if (!was_choice and self.snippet_session != null) {
            if (self.model.selectedItem()) |item| {
                if (item.insert_text_rules & @backingInt(completion.CompletionItemInsertTextRule.InsertAsSnippet) != 0) {
                    try self.snippet_session.?.merge(item.insert_text, .{});
                    self.model.cancel();
                    self.hideWidget();
                    try self.maybeShowChoice();
                    self.host.focus_editor(self.host.context);
                    self.host.request_frame(self.host.context);
                    return true;
                }
            }
        }
        if (try self.model.accept()) |result| {
            self.overtyping_capturer.unlock();
            self.hideWidget();
            self.host.focus_editor(self.host.context);
            if (result.snippet_session) |session| {
                self.snippet_session = session;
            }
            if (was_choice) {
                self.choice_active = false;
                if (self.snippet_session) |session| {
                    const moved = try session.next();
                    if (!moved) {
                        session.deinit();
                        self.snippet_session = null;
                    }
                }
                try self.maybeShowChoice();
            } else if (self.snippet_session != null) {
                try self.maybeShowChoice();
            }
            self.host.request_frame(self.host.context);
            return true;
        }
        self.cancel();
        return false;
    }

    fn maybeShowChoice(self: *SuggestController) !void {
        self.choice_active = false;
        if (self.snippet_session) |session| {
            if (session.activeChoice()) |active| {
                var options = std.array_list.Managed([]const u8).init(self.allocator);
                defer options.deinit();
                for (active.choice.options.items) |option| try options.append(option.value);
                try self.model.showChoice(options.items, active.range);
                self.choice_active = true;
                self.showWidget();
                return;
            }
        }
        if (self.model.isOpen()) {
            self.model.cancel();
            self.hideWidget();
        }
    }

    fn showWidget(self: *SuggestController) void {
        self.overtyping_capturer.lock();
        _ = self.model.resolveSelected() catch {};
        const anchor = self.model.anchor orelse self.editor.modelCursorPosition();
        self.widget.show(anchor);
        self.host.request_frame(self.host.context);
    }

    fn hideWidget(self: *SuggestController) void {
        if (!self.model.isOpen()) self.overtyping_capturer.unlock();
        self.widget.hide();
        self.host.request_frame(self.host.context);
    }
};

fn isCtrlSpace(event: *const ui.KeyEvent) bool {
    if (!event.mods.ctrl or event.mods.alt or event.mods.shift) return false;
    return keyChar(event) != null and (keyChar(event).? == ' ' or keyChar(event).? == '@');
}

fn keyChar(event: *const ui.KeyEvent) ?u21 {
    return switch (event.key) {
        .char => |ch| ch,
        .text => |text| if (text.len == 1) text[0] else null,
        else => null,
    };
}

fn widgetTextHeight(context: *anyopaque) usize {
    const self: *SuggestController = @ptrCast(@alignCast(context));
    return self.host.text_height(self.host.context);
}

fn widgetVisibleRowOf(context: *anyopaque, position: Position) ?usize {
    const self: *SuggestController = @ptrCast(@alignCast(context));
    return self.host.visible_row_of(self.host.context, position);
}

fn widgetRequestFrame(context: *anyopaque) void {
    const self: *SuggestController = @ptrCast(@alignCast(context));
    self.host.request_frame(self.host.context);
}
