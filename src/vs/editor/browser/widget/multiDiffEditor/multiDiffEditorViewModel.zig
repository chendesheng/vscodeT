// Port of `src/vs/editor/browser/widget/multiDiffEditor/multiDiffEditorViewModel.ts`.
// Native worker events and a window deadline replace ObservablePromise.
// Model references survive template eviction; independently mounted editors
// borrow the item view model and the two real resource documents.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const model = @import("model.zig");
const diff = @import("../diffEditor/diffEditorViewModel.zig");
const Options = @import("../diffEditor/diffEditorOptions.zig").Options;
const EditorDocument = @import("../codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const Selection = @import("../../../common/core/selection.zig").Selection;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const time = @import("../../../../base/common/timeCompat.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const Worker = @import("../../services/editorWorkerService.zig").EditorWorkerService;
const Cache = @import("../diffEditor/diffProviderFactoryService.zig").Cache;

pub const WorkerServices = struct { worker: *Worker, cache: ?*Cache = null };

pub const DocumentDiffItemViewModel = struct {
    allocator: Allocator,
    owner: *MultiDiffEditorViewModel,
    documentDiffItem: *model.IDocumentDiffItem,
    refs: usize = 1,
    original: *EditorDocument,
    modified: *EditorDocument,
    diffEditorViewModel: diff.DiffEditorViewModel,
    options: Options,
    key: []u8,
    collapsed: bool = false,
    lastTemplateData: LastTemplateData,
    isFocused: bool = false,
    isReady: bool = false,
    change: Emitter(void),
    on_did_change_options: Emitter(void),
    diff_listener: ?usize = null,
    options_listener: ?usize = null,
    ready_task: dispatch.Task = .{},
    notify_task: dispatch.Task = .{},
    pub const LastTemplateData = struct {
        // The upstream starts with a 500-pixel estimate; a terminal row is
        // the line-height unit, so the initial estimate is 25 rows.
        expandedContentHeight: usize = 25,
        selections: ?[]Selection = null,
    };

    fn effectiveOptions(options: Options) Options {
        var result = options.normalize();
        result.hide_unchanged_regions = true;
        return result;
    }
    fn computationOptions(options: Options) diff.Options {
        return .{
            .ignore_trim_whitespace = options.ignore_trim_whitespace,
            .max_computation_time_ms = options.max_computation_time_ms,
            .diff_algorithm = options.diff_algorithm,
            .show_moves = options.show_moves,
        };
    }
    fn regionOptions(options: Options) diff.UnchangedRegionOptions {
        return .{ .enabled = options.hide_unchanged_regions, .minimum = options.hide_unchanged_regions_minimum_line_count, .context = options.hide_unchanged_regions_context_line_count };
    }
    fn getDocument(owner: *MultiDiffEditorViewModel, source: ?model.DiffItemSource, key: []const u8, side: []const u8) !*EditorDocument {
        if (source) |item| if (item.textModel) |document| {
            document.retain();
            return document;
        };
        // An absent side has no real URI; a distinct synthetic model is
        // retained for this item's lifetime, even while the view is unbound.
        const path = try std.fmt.allocPrint(owner.allocator, "/multiDiff/{s}/{s}", .{ side, key });
        defer owner.allocator.free(path);
        return EditorDocument.createFromText(owner.allocator, owner.io, "", "", .{ .scheme = "inmemory", .path = .{ .raw = path } });
    }
    fn makeKey(allocator: Allocator, item: *model.IDocumentDiffItem) ![]u8 {
        const a = if (item.original) |source| try std_uri.resourceKey(allocator, source.uri) else null;
        defer if (a) |value| allocator.free(value);
        const b = if (item.modified) |source| try std_uri.resourceKey(allocator, source.uri) else null;
        defer if (b) |value| allocator.free(value);
        return std.json.Stringify.valueAlloc(allocator, [2]?[]const u8{ a, b }, .{});
    }
    fn create(owner: *MultiDiffEditorViewModel, document: *model.IDocumentDiffItem) !*DocumentDiffItemViewModel {
        const allocator = owner.allocator;
        const self = try allocator.create(DocumentDiffItemViewModel);
        errdefer allocator.destroy(self);
        const key = try makeKey(allocator, document);
        errdefer allocator.free(key);
        const original = try getDocument(owner, document.original, key, "original");
        errdefer original.release();
        const modified = try getDocument(owner, document.modified, key, "modified");
        errdefer modified.release();
        const options = effectiveOptions(document.options);
        self.* = .{
            .allocator = allocator,
            .owner = owner,
            .documentDiffItem = document.retain(),
            .original = original,
            .modified = modified,
            .diffEditorViewModel = diff.DiffEditorViewModel.init(allocator, original.model, modified.model, computationOptions(options)),
            .options = options,
            .key = key,
            .lastTemplateData = .{},
            .change = .init(allocator),
            .on_did_change_options = .init(allocator),
            .ready_task = .{ .context = self, .queue = owner.queue, .run = onReadyDeadline },
            .notify_task = .{ .context = self, .queue = owner.queue, .run = onNotifyDeadline },
        };
        errdefer {
            self.ready_task.schedule(null);
            self.notify_task.schedule(null);
            self.diffEditorViewModel.deinit();
            self.documentDiffItem.release();
            self.change.deinit();
            self.on_did_change_options.deinit();
        }
        try self.diffEditorViewModel.setPersistentUnchangedRegionOptions(regionOptions(options));
        try self.diffEditorViewModel.startListening();
        if (owner.worker) |services| {
            self.diffEditorViewModel.initializeEmptyState();
            self.diffEditorViewModel.attachWorker(services.worker, services.cache, owner.queue);
            self.ready_task.schedule(time.milliTimestamp() +| 1000);
        } else {
            try self.diffEditorViewModel.compute();
            self.isReady = true;
        }
        self.diff_listener = try self.diffEditorViewModel.on_did_change.listen(self, onDiffChanged);
        errdefer self.diffEditorViewModel.on_did_change.unlisten(self.diff_listener.?);
        self.options_listener = try document.onOptionsDidChange.listen(self, onOptionsChanged);
        return self;
    }
    fn retain(self: *DocumentDiffItemViewModel) *DocumentDiffItemViewModel {
        self.refs += 1;
        return self;
    }
    fn release(self: *DocumentDiffItemViewModel) void {
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        self.ready_task.schedule(null);
        self.notify_task.schedule(null);
        if (self.diff_listener) |listener| self.diffEditorViewModel.on_did_change.unlisten(listener);
        if (self.options_listener) |listener| self.documentDiffItem.onOptionsDidChange.unlisten(listener);
        self.diffEditorViewModel.deinit();
        self.change.deinit();
        self.on_did_change_options.deinit();
        self.original.release();
        self.modified.release();
        self.documentDiffItem.release();
        if (self.lastTemplateData.selections) |selections| self.allocator.free(selections);
        self.allocator.free(self.key);
        self.allocator.destroy(self);
    }
    pub fn getKey(self: *const DocumentDiffItemViewModel) []const u8 {
        return self.key;
    }
    pub fn isBinary(self: *const DocumentDiffItemViewModel) bool {
        return (self.documentDiffItem.original != null and self.documentDiffItem.original.?.textModel == null) or (self.documentDiffItem.modified != null and self.documentDiffItem.modified.?.textModel == null);
    }
    pub fn isActive(self: *const DocumentDiffItemViewModel) bool {
        return self.owner.activeDiffItem == self;
    }
    pub fn isFirst(self: *const DocumentDiffItemViewModel) bool {
        return self.owner.items.len > 0 and self.owner.items[0] == self;
    }
    pub fn setActive(self: *DocumentDiffItemViewModel) !void {
        try self.owner.setActive(self);
    }
    pub fn setFocused(self: *DocumentDiffItemViewModel, focused: bool) !void {
        if (self.isFocused == focused) return;
        self.isFocused = focused;
        if (focused) {
            if (self.owner.focusedDiffItem) |old| old.isFocused = false;
            self.owner.focusedDiffItem = self;
            try self.owner.setActive(self);
        } else if (self.owner.focusedDiffItem == self) {
            self.owner.focusedDiffItem = null;
            try self.owner.on_did_change_active_item.fire({});
        }
    }
    pub fn setCollapsed(self: *DocumentDiffItemViewModel, collapsed: bool) !void {
        if (self.collapsed == collapsed) return;
        self.collapsed = collapsed;
        try self.change.fire({});
    }
    pub fn setLastTemplateData(self: *DocumentDiffItemViewModel, expanded_height: usize, selections: ?[]const Selection) !void {
        const owned = if (selections) |values| try self.allocator.dupe(Selection, values) else null;
        if (self.lastTemplateData.selections) |old| self.allocator.free(old);
        self.lastTemplateData = .{ .expandedContentHeight = expanded_height, .selections = owned };
    }
    fn onDiffChanged(_: void, self: *DocumentDiffItemViewModel) !void {
        // Complete on the window dispatcher, after the model emitter returns.
        // Publishing now could mount a new view and subscribe to that emitter
        // while it is delivering the worker completion.
        if (!self.isReady) self.ready_task.schedule(time.milliTimestamp());
        self.notify_task.post();
    }
    fn onReadyDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *DocumentDiffItemViewModel = @ptrCast(@alignCast(context));
        self.isReady = true;
        self.owner.publishReady() catch |err| {
            self.owner.last_error = err;
        };
        return true;
    }
    fn onNotifyDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *DocumentDiffItemViewModel = @ptrCast(@alignCast(context));
        self.change.fire({}) catch |err| {
            self.owner.last_error = err;
        };
        return true;
    }
    fn onOptionsChanged(_: void, self: *DocumentDiffItemViewModel) !void {
        const options = effectiveOptions(self.documentDiffItem.options);
        if (std.meta.eql(self.options, options)) return;
        self.options = options;
        const next = computationOptions(options);
        const changed = !std.meta.eql(next, self.diffEditorViewModel.options);
        if (self.diffEditorViewModel.mounted_view_count == 0) {
            self.diffEditorViewModel.options = next;
            self.diffEditorViewModel.provider = @import("../../../common/diff/documentDiffProvider.zig").LineDiffProvider.init(next.diff_algorithm);
            if (changed) self.diffEditorViewModel.requestRecompute(0);
        }
        try self.diffEditorViewModel.setPersistentUnchangedRegionOptions(regionOptions(options));
        try self.on_did_change_options.fire({});
    }
};

pub const MultiDiffEditorViewModel = struct {
    allocator: Allocator,
    io: Io,
    model: model.IMultiDiffEditorModel,
    queue: *dispatch.Queue,
    worker: ?WorkerServices,
    pending: []*DocumentDiffItemViewModel = &.{},
    items: []*DocumentDiffItemViewModel = &.{},
    isLoading: bool = true,
    focusedDiffItem: ?*DocumentDiffItemViewModel = null,
    activeDiffItem: ?*DocumentDiffItemViewModel = null,
    document_listener: ?usize = null,
    last_error: ?anyerror = null,
    on_did_change_items: Emitter(void),
    on_did_change_active_item: Emitter(void),
    on_did_change_loading: Emitter(void),

    pub fn create(allocator: Allocator, io: Io, source: model.IMultiDiffEditorModel, queue: *dispatch.Queue, worker: ?WorkerServices) !*MultiDiffEditorViewModel {
        const self = try allocator.create(MultiDiffEditorViewModel);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .model = source,
            .queue = queue,
            .worker = worker,
            .on_did_change_items = .init(allocator),
            .on_did_change_active_item = .init(allocator),
            .on_did_change_loading = .init(allocator),
        };
        errdefer self.destroy();
        self.document_listener = try source.on_did_change_documents.listen(self, onDocumentsChanged);
        try self.updateDocuments();
        return self;
    }
    pub fn destroy(self: *MultiDiffEditorViewModel) void {
        if (self.document_listener) |listener| self.model.on_did_change_documents.unlisten(listener);
        self.releaseItems(self.pending);
        self.releaseItems(self.items);
        self.on_did_change_items.deinit();
        self.on_did_change_active_item.deinit();
        self.on_did_change_loading.deinit();
        self.allocator.destroy(self);
    }
    fn releaseItems(self: *MultiDiffEditorViewModel, items: []*DocumentDiffItemViewModel) void {
        for (items) |item| item.release();
        self.allocator.free(items);
    }
    fn onDocumentsChanged(_: void, self: *MultiDiffEditorViewModel) !void {
        try self.updateDocuments();
    }
    fn updateDocuments(self: *MultiDiffEditorViewModel) !void {
        const docs = self.model.documents(self.model.context);
        const next = try self.allocator.alloc(*DocumentDiffItemViewModel, if (docs == .items) docs.items.len else 0);
        var count: usize = 0;
        var adopted = false;
        errdefer if (!adopted) {
            for (next[0..count]) |item| item.release();
            self.allocator.free(next);
        };
        if (docs == .items) for (docs.items, 0..) |document, i| {
            const existing = for (self.pending) |item| {
                if (item.documentDiffItem == document) break item;
            } else for (self.items) |item| {
                if (item.documentDiffItem == document) break item;
            } else null;
            next[i] = if (existing) |item| item.retain() else try DocumentDiffItemViewModel.create(self, document);
            count += 1;
        };
        self.releaseItems(self.pending);
        self.pending = next;
        adopted = true;
        try self.setLoading(docs == .loading or for (next) |item| {
            if (!item.isReady) break true;
        } else false);
        try self.publishReady();
    }
    fn setLoading(self: *MultiDiffEditorViewModel, value: bool) !void {
        if (self.isLoading == value) return;
        self.isLoading = value;
        try self.on_did_change_loading.fire({});
    }
    fn publishReady(self: *MultiDiffEditorViewModel) !void {
        for (self.pending) |item| if (!item.isReady) return;
        if (!std.mem.eql(*DocumentDiffItemViewModel, self.pending, self.items)) {
            const result = try self.allocator.alloc(*DocumentDiffItemViewModel, self.pending.len);
            for (result, self.pending) |*dst, src| dst.* = src.retain();
            const previous = self.items;
            self.items = result;
            defer self.releaseItems(previous);
            const active_removed = self.activeDiffItem != null and std.mem.indexOfScalar(*DocumentDiffItemViewModel, result, self.activeDiffItem.?) == null;
            if (self.focusedDiffItem) |item| if (std.mem.indexOfScalar(*DocumentDiffItemViewModel, result, item) == null) {
                item.isFocused = false;
                self.focusedDiffItem = null;
            };
            if (active_removed) self.activeDiffItem = null;
            // Consumers release bindings while the previous items are alive.
            try self.on_did_change_items.fire({});
            if (active_removed) try self.on_did_change_active_item.fire({});
        }
        try self.setLoading(self.model.documents(self.model.context) == .loading);
    }
    pub fn setActive(self: *MultiDiffEditorViewModel, item: ?*DocumentDiffItemViewModel) !void {
        if (item) |value| if (std.mem.indexOfScalar(*DocumentDiffItemViewModel, self.items, value) == null) return error.UnknownDiffItem;
        if (self.activeDiffItem == item) return;
        self.activeDiffItem = item;
        try self.on_did_change_active_item.fire({});
    }
    pub fn collapseAll(self: *MultiDiffEditorViewModel) !void {
        for (self.items) |item| try item.setCollapsed(true);
    }
    pub fn expandAll(self: *MultiDiffEditorViewModel) !void {
        for (self.items) |item| try item.setCollapsed(false);
    }
};
