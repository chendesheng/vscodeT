// Port of `src/vs/editor/contrib/semanticTokens/browser/viewportSemanticTokens.ts`.
// Editor scroll/model events schedule a cancellable visible-range query while
// complete document coloring is unavailable. The shared sparse token store
// merges the result and emits the normal token-view events.
const std = @import("std");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Range = @import("../../../common/core/range.zig").Range;
const languages = @import("../../../common/languages.zig");
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.DocumentRangeSemanticTokensProvider);
const DocumentFeature = @import("documentSemanticTokens.zig").DocumentSemanticTokensFeature;
const config = @import("../common/semanticTokensConfig.zig");
const styling = @import("../../../common/services/semanticTokensProviderStyling.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");
const events = @import("../../../common/textModelEvents.zig");
const editor_common = @import("../../../common/editorCommon.zig");
const ScrollEvent = @import("../../../../base/common/scrollable.zig").ScrollEvent;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const Services = struct { registry: *Registry, document: *DocumentFeature, window: *dispatch.Queue };
pub const ViewportSemanticTokensContribution = struct {
    pub const ID = "editor.contrib.viewportSemanticTokens";
    editor: *Editor,
    services: ?Services = null,
    model: ?*TextModel = null,
    timer: dispatch.Task = .{},
    scroll_listener: ?usize = null,
    registry_listener: ?usize = null,
    theme_listener: ?usize = null,
    content_listener: ?usize = null,
    language_listener: ?usize = null,
    will_change_listener: ?usize = null,
    did_change_listener: ?usize = null,
    provider_listeners: std.ArrayList(ProviderListener) = .empty,
    arena: ?std.heap.ArenaAllocator = null,
    pending: ?IDisposable = null,
    inline_reply: ?anyerror!?languages.SemanticTokensResult = null,
    starting: bool = false,
    providers: []const languages.DocumentRangeSemanticTokensProvider = &.{},
    next_provider: usize = 0,
    range: Range = Range.init(1, 1, 1, 1),
    request_version: u32 = 0,
    const ProviderListener = struct { emitter: *Emitter(void), id: usize };

    pub fn getOrCreate(editor: *Editor, services: Services) !*ViewportSemanticTokensContribution {
        if (editor.getInstantiatedContribution(ViewportSemanticTokensContribution)) |self| {
            try self.bind(services);
            return self;
        }
        const self = try editor.allocator.create(ViewportSemanticTokensContribution);
        self.* = .{ .editor = editor };
        errdefer self.dispose();
        try self.bind(services);
        try editor.registerOwnedContribution(ViewportSemanticTokensContribution, self, dispose);
        return self;
    }
    fn bind(self: *ViewportSemanticTokensContribution, services: Services) !void {
        self.unbind();
        self.services = services;
        errdefer self.unbind();
        self.timer = .{ .queue = services.window, .context = self, .run = onDeadline };
        self.scroll_listener = try self.editor.view_layout.onDidScroll().listen(self, onScroll);
        self.registry_listener = try services.registry.on_did_change.listen(self, onRegistry);
        self.theme_listener = try services.document.on_changed.listen(self, onTheme);
        self.will_change_listener = try self.editor.on_will_change_model.listen(self, onWillChange);
        self.did_change_listener = try self.editor.on_did_change_model.listen(self, onDidChange);
        try self.attachModel();
    }
    pub fn unbind(self: *ViewportSemanticTokensContribution) void {
        self.detachModel();
        if (self.scroll_listener) |id| self.editor.view_layout.onDidScroll().unlisten(id);
        if (self.registry_listener) |id| self.services.?.registry.on_did_change.unlisten(id);
        if (self.theme_listener) |id| self.services.?.document.on_changed.unlisten(id);
        if (self.will_change_listener) |id| self.editor.on_will_change_model.unlisten(id);
        if (self.did_change_listener) |id| self.editor.on_did_change_model.unlisten(id);
        self.scroll_listener = null;
        self.registry_listener = null;
        self.theme_listener = null;
        self.will_change_listener = null;
        self.did_change_listener = null;
        self.timer.queue = null;
        self.services = null;
    }
    fn dispose(self: *ViewportSemanticTokensContribution) void {
        self.unbind();
        self.editor.allocator.destroy(self);
    }
    fn attachModel(self: *ViewportSemanticTokensContribution) !void {
        if (!self.editor.hasModel()) return;
        self.model = self.editor.model;
        self.content_listener = try self.model.?.onDidChangeContentWithContextId(self, onContent);
        self.language_listener = try self.model.?.listenDidChangeLanguage(self, onLanguage);
        try self.rebindProviders();
    }
    fn detachModel(self: *ViewportSemanticTokensContribution) void {
        self.cancel();
        self.unbindProviders();
        if (self.model) |model| {
            if (self.content_listener) |id| model.removeDidChangeContentListener(id);
            if (self.language_listener) |id| model.removeDidChangeLanguageListener(id);
        }
        self.content_listener = null;
        self.language_listener = null;
        self.model = null;
    }
    fn unbindProviders(self: *ViewportSemanticTokensContribution) void {
        for (self.provider_listeners.items) |listener| listener.emitter.unlisten(listener.id);
        self.provider_listeners.deinit(self.editor.allocator);
        self.provider_listeners = .empty;
    }
    fn rebindProviders(self: *ViewportSemanticTokensContribution) !void {
        self.cancel();
        self.unbindProviders();
        const model = self.model orelse return;
        const svc = self.services orelse return;
        const providers = try svc.registry.ordered(self.editor.allocator, model, false);
        defer self.editor.allocator.free(providers);
        for (providers) |provider| if (provider.on_did_change) |event| {
            const id = try event.listen(self, onProviderChanged);
            errdefer event.unlisten(id);
            try self.provider_listeners.append(self.editor.allocator, .{ .emitter = event, .id = id });
        };
        self.schedule();
    }
    fn onWillChange(_: editor_common.IModelChangedEvent, self: *ViewportSemanticTokensContribution) !void {
        self.detachModel();
    }
    fn onDidChange(_: editor_common.IModelChangedEvent, self: *ViewportSemanticTokensContribution) !void {
        try self.attachModel();
    }
    fn onRegistry(_: usize, self: *ViewportSemanticTokensContribution) !void {
        try self.rebindProviders();
    }
    fn onLanguage(_: events.ModelLanguageChangedEvent, self: *ViewportSemanticTokensContribution) !void {
        try self.rebindProviders();
    }
    fn onTheme(_: void, self: *ViewportSemanticTokensContribution) !void {
        self.schedule();
    }
    fn onProviderChanged(_: void, self: *ViewportSemanticTokensContribution) !void {
        self.schedule();
    }
    fn onContent(_: events.InternalModelContentChangeEvent, self: *ViewportSemanticTokensContribution) !void {
        self.schedule();
    }
    fn onScroll(event: ScrollEvent, self: *ViewportSemanticTokensContribution) !void {
        if (event.scrollTopChanged or event.heightChanged) self.schedule();
    }
    fn enabled(self: *ViewportSemanticTokensContribution) bool {
        const model = self.model orelse return false;
        const svc = self.services orelse return false;
        return !model.hasCompleteSemanticTokens() and svc.document.styling_service.theme != null and config.isSemanticColoringEnabled(model, svc.document.styling_service.theme, svc.document.configuration) and svc.registry.has(model);
    }
    fn cancel(self: *ViewportSemanticTokensContribution) void {
        self.timer.schedule(null);
        if (self.pending) |pending| pending.dispose();
        self.pending = null;
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.providers = &.{};
    }
    fn schedule(self: *ViewportSemanticTokensContribution) void {
        self.cancel();
        if (self.enabled()) self.timer.schedule(time.milliTimestamp() + 100);
    }
    fn onDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ViewportSemanticTokensContribution = @ptrCast(@alignCast(context));
        self.begin() catch self.cancel();
        return true;
    }
    fn begin(self: *ViewportSemanticTokensContribution) !void {
        if (!self.enabled()) return;
        const model = self.model.?;
        const svc = self.services.?;
        const visible = self.editor.visibleModelRange();
        const first = @min(model.getLineCount(), @max(1, visible.startLineNumber));
        const last = @max(first, @min(model.getLineCount(), visible.endLineNumber));
        self.range = Range.init(first, 1, last, model.getLineMaxColumn(last));
        self.request_version = model.getVersionId();
        self.arena = .init(self.editor.allocator);
        const groups = try svc.registry.orderedGroups(self.arena.?.allocator(), model);
        self.providers = if (groups.len > 0) groups[0] else &.{};
        self.next_provider = 0;
        self.advance();
    }
    fn advance(self: *ViewportSemanticTokensContribution) void {
        while (self.next_provider < self.providers.len) {
            const provider = self.providers[self.next_provider];
            self.next_provider += 1;
            self.starting = true;
            const request = provider.request_document_range_semantic_tokens(provider.context, self.arena.?.allocator(), self.model.?, self.range, .{ .context = self, .complete = ready }) catch {
                self.starting = false;
                continue;
            };
            self.starting = false;
            if (self.inline_reply) |reply| {
                self.inline_reply = null;
                ready(self, reply);
            } else self.pending = request;
            return;
        }
        self.cancel();
    }
    fn ready(context: *anyopaque, result: anyerror!?languages.SemanticTokensResult) void {
        const self: *ViewportSemanticTokensContribution = @ptrCast(@alignCast(context));
        if (self.starting) {
            self.inline_reply = result;
            return;
        }
        self.pending = null;
        if (!self.enabled() or self.model.?.getVersionId() != self.request_version) return self.cancel();
        const maybe = result catch return self.advance();
        const value = maybe orelse return self.advance();
        if (value.payload != .full) return self.advance();
        const provider = self.providers[self.next_provider - 1];
        self.install(provider.legend, value.payload.full) catch {};
        self.cancel();
    }
    fn install(self: *ViewportSemanticTokensContribution, legend: languages.SemanticTokensLegend, data: []const u32) !void {
        const a = self.editor.allocator;
        const model = self.model.?;
        var style = self.services.?.document.styling_service.interface().getStyling(a, legend, model.getLanguageId()) orelse return;
        defer style.deinit();
        const pieces = try styling.toMultilineTokens2(a, data, &style, model);
        defer a.free(pieces);
        errdefer for (pieces) |*piece| piece.deinit();
        try model.setPartialSemanticTokens(self.range, pieces);
    }
};
