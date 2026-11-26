// Port of `src/vs/editor/contrib/diffEditorBreadcrumbs/browser/contribution.ts`.
// The shared OutlineModelService supplies the cancellable provider request and
// window deadline queue; its completion replaces the upstream observable model.
const std = @import("std");
const feature = @import("../../../browser/widget/diffEditor/features/hideUnchangedRegionsFeature.zig");
const outline = @import("../../documentSymbols/browser/outlineModel.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const ContentEvent = @import("../../../common/textModelEvents.zig").InternalModelContentChangeEvent;
const LineRange = @import("../../../common/core/ranges/lineRange.zig").LineRange;
const Features = @import("../../../common/services/languageFeatures.zig").ILanguageFeaturesService;
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const DocumentSymbol = @import("../../../common/languages.zig").DocumentSymbol;

pub const Factory = struct {
    allocator: std.mem.Allocator,
    features: Features,
    models: *outline.OutlineModelService,

    pub fn create(allocator: std.mem.Allocator, features: Features, models: *outline.OutlineModelService) !feature.BreadcrumbsSourceFactory {
        const self = try allocator.create(Factory);
        self.* = .{ .allocator = allocator, .features = features, .models = models };
        return self.interface();
    }

    pub fn interface(self: *Factory) feature.BreadcrumbsSourceFactory {
        return .{ .context = self, .create_source = createSource, .dispose_fn = dispose };
    }

    fn createSource(context: *anyopaque, model: *TextModel, listener: feature.BreadcrumbsListener) !feature.IDiffEditorBreadcrumbsSource {
        const self: *Factory = @ptrCast(@alignCast(context));
        const source = try DiffEditorBreadcrumbsSource.create(self.allocator, model, self.features, self.models, listener);
        return source.interface();
    }

    fn dispose(context: *anyopaque) void {
        const self: *Factory = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }
};

pub const DiffEditorBreadcrumbsSource = struct {
    allocator: std.mem.Allocator,
    text_model: *TextModel,
    features: Features,
    models: *outline.OutlineModelService,
    listener: feature.BreadcrumbsListener,
    current_model: ?*outline.OutlineModel = null,
    pending: ?Disposable = null,
    version: usize = 0,
    content_listener: ?usize = null,
    provider_listener: ?usize = null,

    pub fn create(allocator: std.mem.Allocator, text_model: *TextModel, features: Features, models: *outline.OutlineModelService, listener: feature.BreadcrumbsListener) !*DiffEditorBreadcrumbsSource {
        const self = try allocator.create(DiffEditorBreadcrumbsSource);
        self.* = .{ .allocator = allocator, .text_model = text_model, .features = features, .models = models, .listener = listener };
        errdefer self.destroy();
        self.content_listener = try text_model.onDidChangeContentWithContextId(self, onContent);
        self.provider_listener = try features.document_symbol_provider.on_did_change.listen(self, onProvidersChanged);
        try self.refresh();
        return self;
    }

    pub fn interface(self: *DiffEditorBreadcrumbsSource) feature.IDiffEditorBreadcrumbsSource {
        return .{ .context = self, .get_breadcrumb_items = getBreadcrumbItems, .get_at = getAt, .dispose_fn = dispose };
    }

    fn destroy(self: *DiffEditorBreadcrumbsSource) void {
        self.models.cancelTimer(self);
        if (self.pending) |pending| pending.dispose();
        if (self.content_listener) |id| self.text_model.removeDidChangeContentListener(id);
        if (self.provider_listener) |id| self.features.document_symbol_provider.on_did_change.unlisten(id);
        if (self.current_model) |model| model.deinit();
        self.allocator.destroy(self);
    }

    fn dispose(context: *anyopaque) void {
        const self: *DiffEditorBreadcrumbsSource = @ptrCast(@alignCast(context));
        self.destroy();
    }

    fn onProvidersChanged(_: usize, self: *DiffEditorBreadcrumbsSource) !void {
        try self.refresh();
    }

    fn onContent(_: ContentEvent, self: *DiffEditorBreadcrumbsSource) !void {
        try self.models.schedule(self, 100, onDeadline);
    }

    fn onDeadline(context: *anyopaque) void {
        const self: *DiffEditorBreadcrumbsSource = @ptrCast(@alignCast(context));
        self.refresh() catch {};
    }

    fn refresh(self: *DiffEditorBreadcrumbsSource) !void {
        if (self.pending) |pending| pending.dispose();
        self.pending = null;
        self.version = self.text_model.getVersionId();
        const providers = try self.features.document_symbol_provider.ordered(self.allocator, self.text_model, false);
        defer self.allocator.free(providers);
        self.pending = try self.models.getOrCreate(self.text_model, providers, self, ready);
    }

    fn ready(context: *anyopaque, model: *outline.OutlineModel) void {
        const self: *DiffEditorBreadcrumbsSource = @ptrCast(@alignCast(context));
        self.pending = null;
        if (self.version != self.text_model.getVersionId()) {
            model.deinit();
            return;
        }
        if (self.current_model) |previous| previous.deinit();
        self.current_model = model;
        self.listener.changed(self.listener.context);
    }

    const Query = union(enum) { start_range: LineRange, at: usize };

    fn items(self: *DiffEditorBreadcrumbsSource, allocator: std.mem.Allocator, query: Query) ![]feature.BreadcrumbItem {
        const model = self.current_model orelse return allocator.alloc(feature.BreadcrumbItem, 0);
        const symbols = try model.asListOfDocumentSymbols(allocator);
        defer allocator.free(symbols);
        var count: usize = 0;
        for (symbols) |symbol| {
            const include = switch (query) {
                .start_range => |range| range.contains(symbol.range.startLineNumber) and !range.contains(symbol.range.endLineNumber),
                .at => |line| LineRange.fromRange(symbol.range).contains(line),
            };
            if (!include) continue;
            symbols[count] = symbol;
            count += 1;
        }
        std.mem.sort(DocumentSymbol, symbols[0..count], {}, struct {
            fn lessThan(_: void, a: DocumentSymbol, b: DocumentSymbol) bool {
                return a.range.endLineNumber - a.range.startLineNumber > b.range.endLineNumber - b.range.startLineNumber;
            }
        }.lessThan);
        const result = try allocator.alloc(feature.BreadcrumbItem, count);
        for (result, symbols[0..count]) |*item, symbol| item.* = .{ .name = symbol.name, .kind = symbol.kind, .start_line_number = symbol.range.startLineNumber };
        return result;
    }

    fn getBreadcrumbItems(context: *anyopaque, allocator: std.mem.Allocator, range: LineRange) ![]feature.BreadcrumbItem {
        const self: *DiffEditorBreadcrumbsSource = @ptrCast(@alignCast(context));
        return self.items(allocator, .{ .start_range = range });
    }

    fn getAt(context: *anyopaque, allocator: std.mem.Allocator, line: usize) ![]feature.BreadcrumbItem {
        const self: *DiffEditorBreadcrumbsSource = @ptrCast(@alignCast(context));
        return self.items(allocator, .{ .at = line });
    }
};
