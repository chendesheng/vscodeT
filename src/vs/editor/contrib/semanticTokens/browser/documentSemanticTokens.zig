// Port of `src/vs/editor/contrib/semanticTokens/browser/documentSemanticTokens.ts`.
// A model-service feature owns one coloring watcher per text model. Window
// deadlines and cancellable requests replace browser promises and timers.
// Stale version replies are discarded and requested again; the existing
// sparse store shifts installed tokens on content edits in the meantime.
const std = @import("std");
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const model_service = @import("../../../common/services/modelService.zig");
const resolver = @import("../../../common/services/resolverService.zig");
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.DocumentSemanticTokensProvider);
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");
const model_events = @import("../../../common/textModelEvents.zig");
const theme_service = @import("../../../../platform/theme/common/themeService.zig");
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const resource_config = @import("../../../common/services/textResourceConfiguration.zig");
const StylingService = @import("../../../common/services/semanticTokensStylingService.zig").SemanticTokensStylingService;
const styling = @import("../../../common/services/semanticTokensProviderStyling.zig");
const config = @import("../common/semanticTokensConfig.zig");
const get_tokens = @import("../common/getSemanticTokens.zig");

pub const DocumentSemanticTokensFeature = struct {
    allocator: std.mem.Allocator,
    models: model_service.IModelService,
    registry: *Registry,
    window: *dispatch.Queue,
    configuration: ?resource_config.ITextResourceConfigurationService,
    configuration_events: ?*@import("../../../../base/common/event.zig").Emitter(configuration.Change),
    styling_service: StylingService = .{},
    on_changed: @import("../../../../base/common/event.zig").Emitter(void),
    watchers: std.AutoHashMap(*TextModel, *ModelSemanticColoring),
    add_listener: ?usize = null,
    remove_listener: ?usize = null,
    registry_listener: ?usize = null,
    configuration_listener: ?usize = null,

    pub fn create(a: std.mem.Allocator, models: model_service.IModelService, registry: *Registry, window: *dispatch.Queue, cfg: ?resource_config.ITextResourceConfigurationService, cfg_events: ?*@import("../../../../base/common/event.zig").Emitter(configuration.Change), current_theme: ?theme_service.IColorTheme) !*DocumentSemanticTokensFeature {
        const self = try a.create(DocumentSemanticTokensFeature);
        self.* = .{ .allocator = a, .models = models, .registry = registry, .window = window, .configuration = cfg, .configuration_events = cfg_events, .styling_service = .{ .theme = current_theme }, .on_changed = .init(a), .watchers = .init(a) };
        errdefer self.dispose();
        self.add_listener = try models.on_model_added.listen(self, onAdded);
        self.remove_listener = try models.on_model_removed.listen(self, onRemoved);
        self.registry_listener = try registry.on_did_change.listen(self, onRegistry);
        if (cfg_events) |events| self.configuration_listener = try events.listen(self, onConfiguration);
        const existing = try models.getModels(a);
        defer a.free(existing);
        for (existing) |resolved| try self.add(resolved.textEditorModel);
        return self;
    }
    pub fn dispose(self: *DocumentSemanticTokensFeature) void {
        if (self.add_listener) |id| self.models.on_model_added.unlisten(id);
        if (self.remove_listener) |id| self.models.on_model_removed.unlisten(id);
        if (self.registry_listener) |id| self.registry.on_did_change.unlisten(id);
        if (self.configuration_listener) |id| self.configuration_events.?.unlisten(id);
        var it = self.watchers.valueIterator();
        while (it.next()) |watcher| watcher.*.dispose();
        self.watchers.deinit();
        self.on_changed.deinit();
        self.allocator.destroy(self);
    }
    pub fn shutdown(self: *DocumentSemanticTokensFeature) void {
        if (self.configuration_listener) |id| self.configuration_events.?.unlisten(id);
        self.configuration_listener = null;
        self.configuration_events = null;
        self.configuration = null;
        self.setTheme(null);
    }
    pub fn setTheme(self: *DocumentSemanticTokensFeature, current_theme: ?theme_service.IColorTheme) void {
        self.styling_service.theme = current_theme;
        self.resetAll();
    }
    fn resetAll(self: *DocumentSemanticTokensFeature) void {
        var models: std.ArrayList(*TextModel) = .empty;
        defer models.deinit(self.allocator);
        var it = self.watchers.keyIterator();
        while (it.next()) |model| models.append(self.allocator, model.*) catch break;
        for (models.items) |model| if (self.watchers.get(model)) |watcher| watcher.rebind() catch {};
        self.on_changed.fire({}) catch {};
    }
    fn onAdded(resolved: resolver.IResolvedTextEditorModel, self: *DocumentSemanticTokensFeature) !void {
        try self.add(resolved.textEditorModel);
    }
    fn onRemoved(resolved: resolver.IResolvedTextEditorModel, self: *DocumentSemanticTokensFeature) !void {
        if (self.watchers.fetchRemove(resolved.textEditorModel)) |removed| removed.value.dispose();
    }
    fn onRegistry(_: usize, self: *DocumentSemanticTokensFeature) !void {
        self.resetAll();
    }
    fn onConfiguration(change: configuration.Change, self: *DocumentSemanticTokensFeature) !void {
        if (change.keys.len == 0 and change.overrides.len == 0) return self.resetAll();
        for (change.keys) |key| if (std.mem.startsWith(u8, key, config.SETTING_ID)) return self.resetAll();
        for (change.overrides) |override| for (override.keys) |key| if (std.mem.startsWith(u8, key, config.SETTING_ID)) return self.resetAll();
    }
    fn add(self: *DocumentSemanticTokensFeature, model: *TextModel) !void {
        if (self.watchers.contains(model)) return;
        const watcher = try self.allocator.create(ModelSemanticColoring);
        watcher.* = .{ .owner = self, .model = model };
        errdefer watcher.dispose();
        watcher.timer = .{ .queue = self.window, .context = watcher, .run = ModelSemanticColoring.onDeadline };
        watcher.content_listener = try model.onDidChangeContentWithContextId(watcher, ModelSemanticColoring.onContent);
        watcher.language_listener = try model.listenDidChangeLanguage(watcher, ModelSemanticColoring.onLanguage);
        try watcher.rebind();
        try self.watchers.put(model, watcher);
    }
};

pub const ModelSemanticColoring = struct {
    owner: *DocumentSemanticTokensFeature,
    model: *TextModel,
    timer: dispatch.Task = .{},
    request: ?*get_tokens.FullRequest = null,
    request_version: u32 = 0,
    // The old successful data supplies the delta baseline.
    previous_provider: ?languages.DocumentSemanticTokensProvider = null,
    previous_id: ?u32 = null,
    previous_data: []u32 = &.{},
    content_listener: ?usize = null,
    language_listener: ?usize = null,
    provider_listeners: std.ArrayList(ProviderListener) = .empty,
    const ProviderListener = struct { emitter: *@import("../../../../base/common/event.zig").Emitter(void), id: usize };

    fn dispose(self: *ModelSemanticColoring) void {
        self.timer.schedule(null);
        self.cancelRequest();
        self.releasePrevious();
        self.unbindProviders();
        if (self.content_listener) |id| self.model.removeDidChangeContentListener(id);
        if (self.language_listener) |id| self.model.removeDidChangeLanguageListener(id);
        self.owner.allocator.destroy(self);
    }
    fn unbindProviders(self: *ModelSemanticColoring) void {
        for (self.provider_listeners.items) |listener| listener.emitter.unlisten(listener.id);
        self.provider_listeners.deinit(self.owner.allocator);
        self.provider_listeners = .empty;
    }
    fn cancelRequest(self: *ModelSemanticColoring) void {
        if (self.request) |request| request.deinit();
        self.request = null;
    }
    fn releasePrevious(self: *ModelSemanticColoring) void {
        if (self.previous_provider) |provider| if (self.previous_id) |id| provider.release_document_semantic_tokens(provider.context, id);
        self.owner.allocator.free(self.previous_data);
        self.previous_data = &.{};
        self.previous_provider = null;
        self.previous_id = null;
    }
    fn enabled(self: *ModelSemanticColoring) bool {
        return self.owner.styling_service.theme != null and config.isSemanticColoringEnabled(self.model, self.owner.styling_service.theme, self.owner.configuration);
    }
    fn rebind(self: *ModelSemanticColoring) !void {
        self.timer.schedule(null);
        self.cancelRequest();
        self.releasePrevious();
        self.unbindProviders();
        try self.model.setSemanticTokens(null, false);
        if (!self.enabled()) return;
        const providers = try self.owner.registry.ordered(self.owner.allocator, self.model, false);
        defer self.owner.allocator.free(providers);
        for (providers) |provider| if (provider.on_did_change) |event| {
            const id = try event.listen(self, onProviderChanged);
            errdefer event.unlisten(id);
            try self.provider_listeners.append(self.owner.allocator, .{ .emitter = event, .id = id });
        };
        self.schedule();
    }
    fn schedule(self: *ModelSemanticColoring) void {
        self.cancelRequest();
        if (self.enabled() and self.owner.registry.has(self.model)) self.timer.schedule(time.milliTimestamp() + 300);
    }
    fn onProviderChanged(_: void, self: *ModelSemanticColoring) !void {
        self.schedule();
    }
    fn onContent(_: model_events.InternalModelContentChangeEvent, self: *ModelSemanticColoring) !void {
        self.schedule();
    }
    fn onLanguage(_: model_events.ModelLanguageChangedEvent, self: *ModelSemanticColoring) !void {
        try self.rebind();
    }
    fn onDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ModelSemanticColoring = @ptrCast(@alignCast(context));
        self.begin() catch {};
        return true;
    }
    fn begin(self: *ModelSemanticColoring) !void {
        self.cancelRequest();
        if (!self.enabled() or !self.owner.registry.has(self.model)) return;
        const request = try get_tokens.FullRequest.create(self.owner.allocator, self.owner.registry, self.model, .{ .context = self, .complete = ready });
        self.request = request;
        self.request_version = self.model.getVersionId();
        request.start(self.model, if (self.previous_provider) |p| p.context else null, self.previous_id);
    }
    fn ready(context: *anyopaque, request: *get_tokens.FullRequest) void {
        const self: *ModelSemanticColoring = @ptrCast(@alignCast(context));
        self.request = null;
        defer request.deinit();
        if (self.request_version != self.model.getVersionId()) return self.schedule();
        const selected = request.takeSelected() catch return;
        if (selected) |result| {
            self.install(result) catch {
                result.provider.release_document_semantic_tokens(result.provider.context, result.result.id);
                self.releasePrevious();
                self.model.setSemanticTokens(null, false) catch {};
            };
        } else {
            self.releasePrevious();
            self.model.setSemanticTokens(null, false) catch {};
        }
    }
    fn install(self: *ModelSemanticColoring, selected: get_tokens.FullRequest.Selection) !void {
        const a = self.owner.allocator;
        const data = switch (selected.result.payload) {
            .full => |full| try a.dupe(u32, full),
            .delta => |deltas| if (self.previous_provider != null and self.previous_provider.?.context == selected.provider.context) try get_tokens.applyDelta(a, self.previous_data, deltas) else return error.InvalidSemanticDelta,
        };
        errdefer a.free(data);
        var style = self.owner.styling_service.interface().getStyling(a, selected.provider.legend, self.model.getLanguageId()) orelse return error.SemanticStylingUnavailable;
        defer style.deinit();
        const pieces = try styling.toMultilineTokens2(a, data, &style, self.model);
        defer a.free(pieces);
        errdefer for (pieces) |*piece| piece.deinit();
        try self.model.setSemanticTokens(pieces, true);
        self.releasePrevious();
        self.previous_provider = selected.provider;
        self.previous_id = selected.result.id;
        self.previous_data = data;
    }
};
