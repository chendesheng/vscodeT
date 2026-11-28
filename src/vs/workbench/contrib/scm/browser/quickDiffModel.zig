// Port of `src/vs/workbench/contrib/scm/browser/quickDiffModel.ts`.
//
// Terminal adaptations:
// - The URI text-model resolver owns original resource references and their
//   asynchronous acquisition. The worker receives immutable snapshots from
//   those resolved models; it never accesses live models or providers.
// - Each model uses a window deadline for its 200 ms ThrottledDelayer.
//   Worker replies wake the window to apply decorations on the UI thread.
// - The embedded peek obtains the real original document from the owned
//   resolver reference and shares the working document with the outer editor.
// - Suppressed secondary changes stay in
//   `all_changes` (the API-visible list) while `changes` contains the visible
//   primary/contributed and non-overlapping secondary changes, matching the
//   upstream split.
const std = @import("std");
const Allocator = std.mem.Allocator;

const worker_service = @import("../../../../editor/browser/services/editorWorkerService.zig");
const quick_diff = @import("../common/quickDiff.zig");
const doc_diff = @import("../../../../editor/common/diff/documentDiffProvider.zig");
const text_model = @import("../../../../editor/common/model/textModel.zig");
const range_mapping = @import("../../../../editor/common/diff/rangeMapping.zig");
const line_range = @import("../../../../editor/common/core/ranges/lineRange.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const model_resolver = @import("../../../../editor/common/services/resolverService.zig");
const EditorDocument = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const TextModelResolverService = @import("../../../services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService;
const time = @import("../../../../base/common/timeCompat.zig");

pub const QuickDiff = quick_diff.QuickDiff;
pub const QuickDiffProviderKind = quick_diff.QuickDiffProviderKind;
pub const IChange = quick_diff.IChange;
pub const ChangeType = quick_diff.ChangeType;
pub const QuickDiffResult = quick_diff.QuickDiffResult;
pub const IQuickDiffService = quick_diff.IQuickDiffService;
pub const DiffAlgorithmName = doc_diff.DiffAlgorithmName;
pub const DetailedLineRangeMapping = range_mapping.DetailedLineRangeMapping;
pub const LineRangeMapping = range_mapping.LineRangeMapping;
pub const LineRange = line_range.LineRange;
pub const RangeMapping = range_mapping.RangeMapping;
pub const TextModel = text_model.TextModel;

pub const QuickDiffModelOptions = struct {
    algorithm: DiffAlgorithmName = .advanced,
    max_computation_time_ms: ?i64 = 1000,
};

pub const DiffEditorModel = struct {
    original_document: *EditorDocument,
    ref_label: []const u8,
    resource_uri: []const u8,
};

/// A terminal quick-diff change. `change2` owns its inner-change array; the
/// provider and URI slices are borrowed from the published model state.
pub const QuickDiffChange = struct {
    provider_id: []const u8,
    original: std.Uri,
    modified: std.Uri,
    change: IChange,
    change2: DetailedLineRangeMapping,

    pub fn deinit(self: *QuickDiffChange, allocator: Allocator) void {
        self.change2.deinit(allocator);
        self.* = undefined;
    }
};

// The terminal equivalent of editorWorkerService.computeDiff. Workers own
// their input and never access the editor, provider registry or decorations.
const DiffRequest = struct {
    io: std.Io,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    originals: []QuickDiff,
    original_texts: [][]const u8,
    modified: std.array_list.Managed(u8),
    original_lines: [][][]const u8 = &.{},
    diffs: []?doc_diff.IDocumentDiff = &.{},
    options: QuickDiffModelOptions,
    ignore_trim_whitespace: bool,
    version: u32,
    message: worker_service.Request = .{ .compute = run, .reply = onReply },
    // Only the UI thread accesses this reference. Disposal detaches the reply.
    owner: ?*QuickDiffModel,
    succeeded: bool = false,

    fn run(message: *worker_service.Request) void {
        const self: *DiffRequest = @fieldParentPtr("message", message);
        self.compute() catch return;
        self.succeeded = true;
    }

    fn onReply(message: *worker_service.Request) bool {
        const self: *DiffRequest = @fieldParentPtr("message", message);
        defer self.destroy();
        const owner = self.owner orelse return false;
        owner.pending = null;
        owner.scheduler.schedule(owner.due_at);
        if (!self.succeeded) return false;
        owner.applyDiff(self) catch return false;
        return true;
    }

    fn compute(self: *DiffRequest) !void {
        const arena = self.arena.allocator();
        const modified = try splitLines(arena, self.modified.items);
        self.original_lines = try arena.alloc([][]const u8, self.originals.len);
        self.diffs = try arena.alloc(?doc_diff.IDocumentDiff, self.originals.len);
        @memset(self.diffs, null);
        var provider = doc_diff.LineDiffProvider.init(self.options.algorithm);
        for (self.original_texts, 0..) |original, i| {
            self.original_lines[i] = try splitLines(arena, original);
            self.diffs[i] = provider.computeDiffFromLines(self.allocator, self.original_lines[i], modified, .{
                .ignoreTrimWhitespace = self.ignore_trim_whitespace,
                .io = self.io,
                .maxComputationTimeMs = self.options.max_computation_time_ms orelse std.math.maxInt(i64),
                .computeMoves = false,
            }) catch null;
        }
    }

    fn destroy(self: *DiffRequest) void {
        for (self.diffs) |*result| if (result.*) |*diff| doc_diff.deinitDiff(self.allocator, diff);
        self.modified.deinit();
        freeQuickDiffsArray(self.allocator, self.originals);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

/// SCM has its own default. Only the explicit inherit setting reads the diff editor option.
pub fn ignoreTrimWhitespace(service: *@import("../../../services/configuration/browser/configurationService.zig").ConfigurationService) bool {
    const value = service.getValue("scm.diffDecorationsIgnoreTrimWhitespace", .{}) orelse return false;
    return switch (value.*) {
        .bool => value.bool, // Legacy terminal settings accepted booleans.
        .string => if (std.mem.eql(u8, value.string, "inherit"))
            service.getBool("diffEditor.ignoreTrimWhitespace", true)
        else
            !std.mem.eql(u8, value.string, "false"),
        else => false,
    };
}

/// Upstream IQuickDiffModelService: only already-resolved text-file models
/// can acquire an independent reference. The options are part of the key.
pub const IQuickDiffModelService = struct {
    context: *anyopaque,
    acquire: *const fn (*anyopaque, std.Uri, QuickDiffModelOptions) anyerror!?QuickDiffModelReference,
    pub fn createQuickDiffModelReference(self: IQuickDiffModelService, resource: std.Uri, options: QuickDiffModelOptions) !?QuickDiffModelReference {
        return self.acquire(self.context, resource, options);
    }
};
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
pub const quick_diff_model_service_id = instantiation.ServiceIdentifier(IQuickDiffModelService, "quickDiffModelService");

pub const QuickDiffModelReference = struct {
    object: *QuickDiffModel,
    entry: ?*QuickDiffModelService.Entry,

    pub fn dispose(self: *QuickDiffModelReference) void {
        const entry = self.entry orelse return;
        self.entry = null;
        entry.owner.release(entry);
    }
};

/// Window-owned reference collection, corresponding to
/// QuickDiffModelReferenceCollection and QuickDiffModelService in upstream.
/// A split editor, the change peek and API consumers share one computation
/// and one original-reference set for a canonical resource/options pair.
pub const QuickDiffModelService = struct {
    allocator: Allocator,
    service: IQuickDiffService,
    window: *@import("../../../../base/common/windowDispatch.zig").Queue,
    resolver: model_resolver.ITextModelService,
    worker: worker_service.EditorWorkerService,
    references: std.StringHashMapUnmanaged(*Entry) = .empty,
    resources_changed: ?*Emitter(void) = null,
    ignore_trim_whitespace: bool = false,

    const Entry = struct {
        owner: *QuickDiffModelService,
        key: []u8,
        document: *EditorDocument,
        document_reference: model_resolver.ModelReference,
        model: QuickDiffModel,
        refs: usize = 1,

        fn destroy(self: *Entry) void {
            const a = self.owner.allocator;
            self.model.deinit();
            self.document_reference.dispose();
            a.free(self.key);
            a.destroy(self);
        }
    };

    pub fn init(allocator: Allocator, service: IQuickDiffService, window: *@import("../../../../base/common/windowDispatch.zig").Queue, resolver: model_resolver.ITextModelService) QuickDiffModelService {
        return .{ .allocator = allocator, .service = service, .window = window, .resolver = resolver, .worker = .init() };
    }

    pub fn interface(self: *QuickDiffModelService) IQuickDiffModelService {
        return .{ .context = self, .acquire = acquireResource };
    }

    fn acquireResource(context: *anyopaque, resource: std.Uri, options: QuickDiffModelOptions) !?QuickDiffModelReference {
        const self: *QuickDiffModelService = @ptrCast(@alignCast(context));
        return self.createQuickDiffModelReference(resource, options);
    }

    pub fn createQuickDiffModelReference(self: *QuickDiffModelService, resource: std.Uri, options: QuickDiffModelOptions) !?QuickDiffModelReference {
        if (!std.mem.eql(u8, resource.scheme, "file")) return null;
        var reference = self.resolver.acquireModelReference(resource) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        errdefer reference.dispose();
        const document = TextModelResolverService.documentOf(reference);
        const a = self.allocator;
        const canonical = try @import("../../../../base/common/stdUri.zig").resourceKey(a, document.model.uri());
        defer a.free(canonical);
        const key = try std.fmt.allocPrint(a, "{s}\x00{s}:{?d}", .{ canonical, @tagName(options.algorithm), options.max_computation_time_ms });
        errdefer a.free(key);
        if (self.references.get(key)) |entry| {
            if (entry.document != document) return error.QuickDiffModelMismatch;
            a.free(key);
            reference.dispose();
            entry.refs += 1;
            return .{ .object = &entry.model, .entry = entry };
        }
        const entry = try a.create(Entry);
        errdefer a.destroy(entry);
        entry.* = .{
            .owner = self,
            .key = key,
            .document = document,
            .document_reference = reference,
            .model = QuickDiffModel.init(a, document.model, self.service, self.resolver, options),
        };
        errdefer entry.model.deinit();
        if (self.worker.replies_ready.queue == null) self.worker.attachWindow(self.window);
        entry.model.attachWindow(self.window, &self.worker);
        entry.model.setIgnoreTrimWhitespace(self.ignore_trim_whitespace);
        try entry.model.startListening(self.resources_changed);
        try self.references.put(a, key, entry);
        entry.model.triggerDiff(time.milliTimestamp(self.window.io));
        return .{ .object = &entry.model, .entry = entry };
    }

    fn release(self: *QuickDiffModelService, entry: *Entry) void {
        std.debug.assert(entry.refs > 0);
        entry.refs -= 1;
        if (entry.refs != 0) return;
        _ = self.references.remove(entry.key);
        entry.destroy();
        if (self.references.count() == 0) self.worker.stopWorker();
    }

    pub fn setRepositoryResources(self: *QuickDiffModelService, source: ?*Emitter(void)) !void {
        if (self.resources_changed == source) return;
        self.resources_changed = source;
        var entries = self.references.valueIterator();
        while (entries.next()) |entry| try entry.*.model.setRepositoryResources(source);
    }

    pub fn setIgnoreTrimWhitespace(self: *QuickDiffModelService, ignore: bool) void {
        if (self.ignore_trim_whitespace == ignore) return;
        self.ignore_trim_whitespace = ignore;
        var entries = self.references.valueIterator();
        while (entries.next()) |entry| entry.*.model.setIgnoreTrimWhitespace(ignore);
    }

    pub fn deinit(self: *QuickDiffModelService) void {
        var entries = self.references.valueIterator();
        while (entries.next()) |entry| entry.*.destroy();
        self.references.deinit(self.allocator);
        self.worker.deinit();
    }
};

pub const QuickDiffModel = struct {
    allocator: Allocator,
    model: *TextModel,
    service: IQuickDiffService,
    options: QuickDiffModelOptions,
    pending: ?*DiffRequest = null,
    resolver: model_resolver.ITextModelService,
    resolving: ?*PendingOriginals = null,
    provider_query: ?@import("../../../../base/common/lifecycle.zig").IDisposable = null,
    query_worker: ?*worker_service.EditorWorkerService = null,
    query_now_ms: i64 = 0,
    original_models: std.StringHashMapUnmanaged(*OriginalModel) = .empty,
    ignore_trim_whitespace: bool = true,

    quick_diffs: []QuickDiff = &.{},
    all_changes: std.array_list.Managed(QuickDiffChange),
    changes: std.array_list.Managed(QuickDiffChange),
    /// Visible-change indices per provider id.
    quick_diff_changes: std.StringHashMap(std.array_list.Managed(usize)),
    changes_version_id: u32,
    on_did_change: Emitter(void),
    due_at: ?i64 = null,
    scheduler: @import("../../../../base/common/windowDispatch.zig").Task = .{},
    worker: ?*worker_service.EditorWorkerService = null,
    disposed: bool = false,
    modified_listener: ?usize = null,
    providers_listener: ?usize = null,
    repository_resources: ?*Emitter(void) = null,
    repository_listener: ?usize = null,

    const OriginalModel = struct {
        uri: []u8,
        reference: model_resolver.ModelReference,
        listener: usize,

        fn dispose(self: *OriginalModel, allocator: Allocator) void {
            self.reference.object.textEditorModel.removeDidChangeContentListener(self.listener);
            self.reference.dispose();
            allocator.free(self.uri);
            allocator.destroy(self);
        }
    };

    /// The promise barrier for the current provider URI set. The resolver
    /// deduplicates acquisitions globally; this model owns each URI reference
    /// and its content subscription until that resource leaves the result.
    const PendingOriginals = struct {
        owner: *QuickDiffModel,
        worker: *worker_service.EditorWorkerService,
        now_ms: i64,
        originals: []QuickDiff,
        slots: []Slot,
        remaining: usize = 0,
        starting: bool = true,

        const Slot = struct {
            parent: *PendingOriginals,
            resource: ?[]const u8 = null,
            request: ?model_resolver.ModelReferenceRequest = null,

            fn complete(context: *anyopaque, result: model_resolver.ModelReferenceResult) void {
                const self: *Slot = @ptrCast(@alignCast(context));
                const parent = self.parent;
                self.request = null;
                if (result == .resolved) {
                    var reference = result.resolved;
                    if (self.resource) |uri| {
                        parent.owner.adoptOriginalModel(uri, reference) catch reference.dispose();
                    } else reference.dispose();
                }
                parent.remaining -= 1;
                if (!parent.starting and parent.remaining == 0) _ = parent.finish();
            }
        };

        fn create(owner: *QuickDiffModel, originals: []QuickDiff, worker: *worker_service.EditorWorkerService, now_ms: i64) !*PendingOriginals {
            const a = owner.allocator;
            const self = try a.create(PendingOriginals);
            errdefer a.destroy(self);
            const slots = try a.alloc(Slot, originals.len);
            for (slots) |*slot| slot.* = .{ .parent = self };
            self.* = .{ .owner = owner, .worker = worker, .now_ms = now_ms, .originals = originals, .slots = slots };
            return self;
        }

        fn start(self: *PendingOriginals) bool {
            const owner = self.owner;
            const api = owner.resolver;
            for (self.originals, self.slots) |quick, *slot| {
                const resource = quick.original.resource_uri;
                if (owner.original_models.contains(resource)) continue;
                const uri = std.Uri.parse(resource) catch continue;
                slot.resource = resource;
                self.remaining += 1;
                slot.request = api.createModelReference(uri, .{ .context = slot, .complete = Slot.complete }) catch blk: {
                    self.remaining -= 1;
                    break :blk null;
                };
            }
            self.starting = false;
            return if (self.remaining == 0) self.finish() else false;
        }

        fn finish(self: *PendingOriginals) bool {
            const owner = self.owner;
            const worker = self.worker;
            const now_ms = self.now_ms;
            owner.resolving = null;
            const originals = self.collectResolved() catch {
                self.destroy();
                owner.scheduler.schedule(owner.due_at);
                return false;
            };
            self.destroy();
            const request = owner.prepareDiffWithOriginals(originals) catch {
                owner.scheduler.schedule(owner.due_at);
                return false;
            };
            if (request.originals.len == 0) {
                defer request.destroy();
                owner.scheduler.schedule(owner.due_at);
                owner.applyDiff(request) catch return false;
                return true;
            }
            owner.pending = request;
            worker.computeDiff(&request.message, now_ms);
            return false;
        }

        fn collectResolved(self: *PendingOriginals) ![]QuickDiff {
            const a = self.owner.allocator;
            var result: std.array_list.Managed(QuickDiff) = .init(a);
            try result.ensureTotalCapacity(self.originals.len);
            errdefer {
                for (result.items) |*quick| quick.deinit(a);
                result.deinit();
            }
            for (self.originals) |*quick| {
                const entry = self.owner.original_models.get(quick.original.resource_uri) orelse {
                    quick.deinit(a);
                    continue;
                };
                if (entry.reference.object.textEditorModel.isTooLargeForSyncing()) {
                    quick.deinit(a);
                    continue;
                }
                result.appendAssumeCapacity(quick.*);
            }
            a.free(self.originals);
            self.originals = &.{};
            return result.toOwnedSlice();
        }

        fn destroy(self: *PendingOriginals) void {
            const a = self.owner.allocator;
            for (self.slots) |slot| if (slot.request) |request| request.cancel();
            a.free(self.slots);
            freeQuickDiffsArray(a, self.originals);
            a.destroy(self);
        }
    };

    fn adoptOriginalModel(self: *QuickDiffModel, uri: []const u8, reference: model_resolver.ModelReference) !void {
        if (self.original_models.contains(uri)) {
            var duplicate = reference;
            duplicate.dispose();
            return;
        }
        const entry = try self.allocator.create(OriginalModel);
        errdefer self.allocator.destroy(entry);
        const key = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(key);
        const model = reference.object.textEditorModel;
        const listener = try model.onDidChangeContentWithContextId(self, originalContentChanged);
        errdefer model.removeDidChangeContentListener(listener);
        entry.* = .{ .uri = key, .reference = reference, .listener = listener };
        try self.original_models.put(self.allocator, key, entry);
    }

    fn originalContentChanged(_: @import("../../../../editor/common/textModelEvents.zig").InternalModelContentChangeEvent, self: *QuickDiffModel) !void {
        self.triggerDiff(time.milliTimestamp(self.model.clockIo()));
    }

    fn pruneOriginalModels(self: *QuickDiffModel) void {
        var stale = std.array_list.Managed(*OriginalModel).init(self.allocator);
        defer stale.deinit();
        var it = self.original_models.valueIterator();
        while (it.next()) |value| {
            const entry = value.*;
            for (self.quick_diffs) |quick| {
                if (std.mem.eql(u8, quick.original.resource_uri, entry.uri)) break;
            } else stale.append(entry) catch return;
        }
        for (stale.items) |entry| {
            _ = self.original_models.remove(entry.uri);
            entry.dispose(self.allocator);
        }
    }

    pub fn init(
        allocator: Allocator,
        model: *TextModel,
        service: IQuickDiffService,
        resolver: model_resolver.ITextModelService,
        options: QuickDiffModelOptions,
    ) QuickDiffModel {
        var self = QuickDiffModel{
            .allocator = allocator,
            .model = model,
            .service = service,
            .resolver = resolver,
            .options = options,
            .all_changes = std.array_list.Managed(QuickDiffChange).init(allocator),
            .changes = std.array_list.Managed(QuickDiffChange).init(allocator),
            .quick_diff_changes = std.StringHashMap(std.array_list.Managed(usize)).init(allocator),
            .changes_version_id = model.getVersionId(),
            .on_did_change = Emitter(void).init(allocator),
        };
        self.triggerDiff(0);
        return self;
    }

    /// Model-owned listeners are independent of the decorator and the peek.
    fn startListening(self: *QuickDiffModel, repository_resources: ?*Emitter(void)) !void {
        self.modified_listener = try self.model.onDidChangeContentWithContextId(self, originalContentChanged);
        self.providers_listener = try self.service.on_did_change_providers.listen(self, onResourcesChanged);
        try self.setRepositoryResources(repository_resources);
    }

    fn onResourcesChanged(_: void, self: *QuickDiffModel) !void {
        self.triggerDiff(time.milliTimestamp(self.model.clockIo()));
    }

    fn setRepositoryResources(self: *QuickDiffModel, source: ?*Emitter(void)) !void {
        if (self.repository_listener) |id| self.repository_resources.?.unlisten(id);
        self.repository_listener = null;
        self.repository_resources = source;
        if (source) |events| self.repository_listener = try events.listen(self, onResourcesChanged);
        self.triggerDiff(time.milliTimestamp(self.model.clockIo()));
    }

    pub fn deinit(self: *QuickDiffModel) void {
        self.scheduler.schedule(null);
        self.disposed = true;
        if (self.modified_listener) |id| self.model.removeDidChangeContentListener(id);
        if (self.providers_listener) |id| self.service.on_did_change_providers.unlisten(id);
        if (self.repository_listener) |id| self.repository_resources.?.unlisten(id);
        if (self.pending) |request| request.owner = null;
        if (self.provider_query) |request| request.dispose();
        self.provider_query = null;
        if (self.resolving) |pending| pending.destroy();
        self.resolving = null;
        var original_iterator = self.original_models.valueIterator();
        while (original_iterator.next()) |value| value.*.dispose(self.allocator);
        self.original_models.deinit(self.allocator);
        self.clearChanges();
        self.all_changes.deinit();
        self.changes.deinit();
        var iterator = self.quick_diff_changes.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit();
        self.quick_diff_changes.deinit();
        self.freeQuickDiffs();
        self.on_did_change.deinit();
        self.* = undefined;
    }

    pub fn setIgnoreTrimWhitespace(self: *QuickDiffModel, ignore: bool) void {
        if (self.ignore_trim_whitespace == ignore) return;
        self.ignore_trim_whitespace = ignore;
        self.triggerDiff(time.milliTimestamp(self.model.clockIo()));
    }

    /// Debounced recompute trigger (upstream `ThrottledDelayer(200)`).
    pub fn triggerDiff(self: *QuickDiffModel, now_ms: i64) void {
        if (self.disposed) return;
        self.due_at = now_ms + 200;
        if (self.pending == null and self.resolving == null and self.provider_query == null) self.scheduler.schedule(self.due_at);
    }

    pub fn attachWindow(self: *QuickDiffModel, window: *@import("../../../../base/common/windowDispatch.zig").Queue, worker: *worker_service.EditorWorkerService) void {
        self.worker = worker;
        self.scheduler = .{ .queue = window, .context = self, .run = onDeadline };
    }

    fn onDeadline(context: *anyopaque, now: i64, _: bool) bool {
        const self: *QuickDiffModel = @ptrCast(@alignCast(context));
        return self.runScheduledDiff(self.worker.?, now);
    }

    pub fn runScheduledDiff(self: *QuickDiffModel, worker: *worker_service.EditorWorkerService, now_ms: i64) bool {
        const due = self.due_at orelse return false;
        if (now_ms < due or self.pending != null or self.resolving != null or self.provider_query != null) return false;
        self.due_at = null;
        if (self.model.isTooLargeForSyncing()) return self.startOriginals(&.{}, worker, now_ms);
        const query = self.service.requestQuickDiffs(self.allocator, self.model.uri(), self.model.getLanguageId(), true, .{ .context = self, .complete = providerQueryComplete }) catch return false;
        switch (query) {
            .ready => |originals| return self.startOriginals(originals, worker, now_ms),
            .pending => |request| {
                self.provider_query = request;
                self.query_worker = worker;
                self.query_now_ms = now_ms;
                return false;
            },
        }
    }

    fn providerQueryComplete(context: *anyopaque, result: quick_diff.QuickDiffQueryResult) void {
        const self: *QuickDiffModel = @ptrCast(@alignCast(context));
        self.provider_query = null;
        const worker = self.query_worker.?;
        self.query_worker = null;
        switch (result) {
            .resolved => |originals| _ = self.startOriginals(originals, worker, self.query_now_ms),
            .failure => self.scheduler.schedule(self.due_at),
        }
    }

    fn startOriginals(self: *QuickDiffModel, originals: []QuickDiff, worker: *worker_service.EditorWorkerService, now_ms: i64) bool {
        const pending = PendingOriginals.create(self, originals, worker, now_ms) catch {
            freeQuickDiffsArray(self.allocator, originals);
            return false;
        };
        self.resolving = pending;
        return pending.start();
    }

    pub fn quickDiffs(self: *const QuickDiffModel) []const QuickDiff {
        return self.quick_diffs;
    }

    pub fn getQuickDiffResults(self: *QuickDiffModel, allocator: Allocator) ![]QuickDiffResult {
        var results = std.array_list.Managed(QuickDiffResult).init(allocator);
        errdefer {
            for (results.items) |*result| freeResult(allocator, result);
            results.deinit();
        }
        for (self.quick_diffs) |quick| {
            var changes = std.array_list.Managed(IChange).init(allocator);
            defer changes.deinit();
            var changes2 = std.array_list.Managed(LineRangeMapping).init(allocator);
            defer changes2.deinit();
            for (self.all_changes.items) |change| {
                if (!std.mem.eql(u8, change.provider_id, quick.id)) continue;
                try changes.append(change.change);
                try changes2.append(change.change2.toLineRangeMapping());
            }
            try results.append(.{
                .provider_id = quick.id,
                .provider_kind = quick.kind,
                .original = try std.Uri.parse(quick.original.resource_uri),
                .modified = self.model.uri(),
                .changes = try changes.toOwnedSlice(),
                .changes2 = try changes2.toOwnedSlice(),
            });
        }
        return results.toOwnedSlice();
    }

    pub fn freeQuickDiffResults(allocator: Allocator, results: []QuickDiffResult) void {
        for (results) |*result| freeResult(allocator, result);
        allocator.free(results);
    }

    fn freeResult(allocator: Allocator, result: *QuickDiffResult) void {
        allocator.free(result.changes);
        allocator.free(result.changes2);
    }

    pub fn getDiffEditorModel(self: *const QuickDiffModel, provider_id: []const u8) ?DiffEditorModel {
        for (self.quick_diffs) |quick| {
            if (!std.mem.eql(u8, quick.id, provider_id)) continue;
            return .{
                .original_document = TextModelResolverService.documentOf((self.original_models.get(quick.original.resource_uri) orelse return null).reference),
                .ref_label = quick.original.ref_label,
                .resource_uri = quick.original.resource_uri,
            };
        }
        return null;
    }

    pub fn findNextClosestChange(self: *const QuickDiffModel, line_number: usize, inclusive: bool, provider_id: ?[]const u8) usize {
        for (self.changes.items, 0..) |change, index| {
            if (provider_id) |id| {
                if (!std.mem.eql(u8, change.provider_id, id)) continue;
            }
            if (!self.service.isQuickDiffProviderVisible(change.provider_id)) continue;
            if (inclusive) {
                if (quick_diff.getModifiedEndLineNumber(change.change) >= line_number) return index;
            } else if (change.change.modifiedStartLineNumber > line_number) {
                return index;
            }
        }
        return 0;
    }

    pub fn findPreviousClosestChange(self: *const QuickDiffModel, line_number: usize, inclusive: bool, provider_id: ?[]const u8) usize {
        var index = self.changes.items.len;
        while (index > 0) {
            index -= 1;
            const change = self.changes.items[index];
            if (provider_id) |id| {
                if (!std.mem.eql(u8, change.provider_id, id)) continue;
            }
            if (!self.service.isQuickDiffProviderVisible(change.provider_id)) continue;
            if (inclusive) {
                if (change.change.modifiedStartLineNumber <= line_number) return index;
            } else if (quick_diff.getModifiedEndLineNumber(change.change) < line_number) {
                return index;
            }
        }
        return if (self.changes.items.len == 0) 0 else self.changes.items.len - 1;
    }

    fn clearChanges(self: *QuickDiffModel) void {
        for (self.all_changes.items) |*change| change.deinit(self.allocator);
        self.all_changes.clearRetainingCapacity();
        for (self.changes.items) |*change| change.deinit(self.allocator);
        self.changes.clearRetainingCapacity();
        var iterator = self.quick_diff_changes.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit();
        self.quick_diff_changes.clearRetainingCapacity();
    }

    fn freeQuickDiffs(self: *QuickDiffModel) void {
        for (self.quick_diffs) |*quick| {
            quick.deinit(self.allocator);
        }
        if (self.quick_diffs.len > 0) self.allocator.free(self.quick_diffs);
        self.quick_diffs = &.{};
    }

    /// Transfer the provider descriptors and capture immutable worker input
    /// from the same live model references that the change peek uses.
    fn prepareDiffWithOriginals(self: *QuickDiffModel, originals: []QuickDiff) !*DiffRequest {
        errdefer freeQuickDiffsArray(self.allocator, originals);
        const request = try self.allocator.create(DiffRequest);
        errdefer self.allocator.destroy(request);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const snapshots = try a.alloc([]const u8, originals.len);
        for (originals, snapshots) |quick, *snapshot| {
            const model = (self.original_models.get(quick.original.resource_uri) orelse return error.OriginalUnavailable).reference.object.textEditorModel;
            var content = try model.getValue(.LF, false);
            defer content.deinit();
            snapshot.* = try a.dupe(u8, content.items);
        }
        request.* = .{
            .io = if (self.worker) |worker| worker.io_state.io() else self.model.clockIo(),
            .allocator = self.allocator,
            .owner = self,
            .arena = arena,
            .originals = originals,
            .original_texts = snapshots,
            .modified = if (originals.len == 0) std.array_list.Managed(u8).init(self.allocator) else try self.model.getValue(.LF, false),
            .options = self.options,
            .ignore_trim_whitespace = self.ignore_trim_whitespace,
            .version = self.model.getVersionId(),
        };
        return request;
    }

    fn applyDiff(self: *QuickDiffModel, request: *DiffRequest) !void {
        const new_quick_diffs = request.originals;
        var all_changes = std.array_list.Managed(QuickDiffChange).init(self.allocator);
        errdefer {
            for (all_changes.items) |*change| change.deinit(self.allocator);
            all_changes.deinit();
        }
        var visible_changes = std.array_list.Managed(QuickDiffChange).init(self.allocator);
        errdefer {
            for (visible_changes.items) |*change| change.deinit(self.allocator);
            visible_changes.deinit();
        }

        for (new_quick_diffs, 0..) |quick, quick_index| {
            const diff = request.diffs[quick_index] orelse continue;
            const original = try std.Uri.parse(quick.original.resource_uri);

            for (diff.changes) |mapping| {
                try all_changes.ensureUnusedCapacity(1);
                all_changes.appendAssumeCapacity(try self.convertMapping(quick, original, mapping));
                if (quick.kind == .secondary and
                    self.overlapsPrimary(visible_changes.items, new_quick_diffs, request.original_lines, quick_index, mapping)) continue;
                try visible_changes.ensureUnusedCapacity(1);
                visible_changes.appendAssumeCapacity(try self.convertMapping(quick, original, mapping));
            }
        }

        // Sort both lists by the visible change order used upstream.
        std.mem.sort(QuickDiffChange, all_changes.items, {}, changeLessThan);
        std.mem.sort(QuickDiffChange, visible_changes.items, {}, changeLessThan);

        var by_provider = std.StringHashMap(std.array_list.Managed(usize)).init(self.allocator);
        errdefer {
            var indices = by_provider.valueIterator();
            while (indices.next()) |list| list.deinit();
            by_provider.deinit();
        }
        for (visible_changes.items, 0..) |change, index| {
            const entry = try by_provider.getOrPut(change.provider_id);
            if (!entry.found_existing) entry.value_ptr.* = std.array_list.Managed(usize).init(self.allocator);
            try entry.value_ptr.append(index);
        }

        // Publish the complete result atomically after all allocations succeed.
        self.clearChanges();
        self.freeQuickDiffs();
        self.all_changes.deinit();
        self.changes.deinit();
        self.quick_diff_changes.deinit();
        self.quick_diffs = new_quick_diffs;
        request.originals = &.{};
        self.all_changes = all_changes;
        self.changes = visible_changes;
        self.quick_diff_changes = by_provider;
        self.changes_version_id = request.version;
        self.pruneOriginalModels();
        self.on_did_change.fire({}) catch {};
    }

    fn overlapsPrimary(
        self: *QuickDiffModel,
        visible: []const QuickDiffChange,
        quick_diffs: []const QuickDiff,
        original_lines: []const [][]const u8,
        secondary_index: usize,
        mapping: DetailedLineRangeMapping,
    ) bool {
        _ = self;
        for (visible) |existing| {
            if (existing.change2.modified.startLineNumber != mapping.modified.startLineNumber or
                existing.change2.modified.endLineNumberExclusive != mapping.modified.endLineNumberExclusive or
                existing.change2.original.length() != mapping.original.length())
            {
                continue;
            }
            // The primary original text must match the secondary original text.
            const primary_index = for (quick_diffs, 0..) |quick, index| {
                if (std.mem.eql(u8, quick.id, existing.provider_id)) break index;
            } else continue;
            if (lineRangeTextEquals(
                original_lines[primary_index],
                existing.change2.original,
                original_lines[secondary_index],
                mapping.original,
            )) return true;
        }
        return false;
    }

    fn convertMapping(self: *QuickDiffModel, quick: QuickDiff, original: std.Uri, mapping: DetailedLineRangeMapping) !QuickDiffChange {
        const change = quick_diff_change_from_mapping(mapping);
        const inner = if (mapping.inner_changes) |values| try self.allocator.dupe(RangeMapping, values) else null;
        return .{
            .provider_id = quick.id,
            .original = original,
            .modified = self.model.uri(),
            .change = change,
            .change2 = .{
                .original = mapping.original,
                .modified = mapping.modified,
                .inner_changes = inner,
            },
        };
    }
};

fn changeLessThan(_: void, a: QuickDiffChange, b: QuickDiffChange) bool {
    return quick_diff.compareChanges(a.change, b.change) < 0;
}

fn quick_diff_change_from_mapping(mapping: DetailedLineRangeMapping) IChange {
    var original_start = mapping.original.startLineNumber;
    var original_end: usize = 0;
    if (mapping.original.isEmpty()) {
        original_start = mapping.original.startLineNumber -| 1;
    } else {
        original_end = mapping.original.endLineNumberExclusive - 1;
    }
    var modified_start = mapping.modified.startLineNumber;
    var modified_end: usize = 0;
    if (mapping.modified.isEmpty()) {
        modified_start = mapping.modified.startLineNumber -| 1;
    } else {
        modified_end = mapping.modified.endLineNumberExclusive - 1;
    }
    return .{
        .originalStartLineNumber = original_start,
        .originalEndLineNumber = original_end,
        .modifiedStartLineNumber = modified_start,
        .modifiedEndLineNumber = modified_end,
    };
}

fn splitLines(allocator: Allocator, content: []const u8) ![][]const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    errdefer lines.deinit();
    var iterator = std.mem.splitScalar(u8, content, '\n');
    while (iterator.next()) |line| {
        // A trailing newline produces a final empty line in the model; the
        // split already yields it, so keep every element.
        try lines.append(line);
    }
    return lines.toOwnedSlice();
}

fn lineRangeTextEquals(a_lines: []const []const u8, a_range: LineRange, b_lines: []const []const u8, b_range: LineRange) bool {
    if (a_range.length() != b_range.length()) return false;
    var index: usize = 0;
    while (index < a_range.length()) : (index += 1) {
        const a_index = a_range.startLineNumber - 1 + index;
        const b_index = b_range.startLineNumber - 1 + index;
        if (a_index >= a_lines.len or b_index >= b_lines.len) return false;
        if (!std.mem.eql(u8, a_lines[a_index], b_lines[b_index])) return false;
    }
    return true;
}

fn freeQuickDiffsArray(allocator: Allocator, quick_diffs: []QuickDiff) void {
    for (quick_diffs) |*quick| quick.deinit(allocator);
    allocator.free(quick_diffs);
}
