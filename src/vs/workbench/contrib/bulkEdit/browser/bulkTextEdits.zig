// Port of `src/vs/workbench/contrib/bulkEdit/browser/bulkTextEdits.ts`.
// Model references resolve on the dispatcher; the entire text-edit group is
// validated before any model mutation. UTF-16 DTO ranges are converted only
// against their resolved models. Native editor selections are copied at entry
// instead of retaining an editor pointer across asynchronous model resolution.
const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("../../../../editor/common/languages.zig");
const model_types = @import("../../../../editor/common/model.zig");
const TextModel = @import("../../../../editor/common/model/textModel.zig").TextModel;
const range_mod = @import("../../../../editor/common/core/range.zig");
const Range = range_mod.Range;
const Selection = @import("../../../../editor/common/core/selection.zig").Selection;
const String = @import("../../../../base/common/strings.zig").String;
const UndoRedoGroup = @import("../../../../platform/undoRedo/common/undoRedo.zig").UndoRedoGroup;
const UndoRedoService = @import("../../../../platform/undoRedo/common/undoRedoService.zig").UndoRedoService;
const UndoRedoSource = @import("../../../../platform/undoRedo/common/undoRedo.zig").UndoRedoSource;
const edit_stack = @import("../../../../editor/common/model/editStack.zig");
const cancellation = @import("../../../../base/common/cancellation.zig");
const Disposable = cancellation.IDisposable;
const resolver = @import("../../../../editor/common/services/resolverService.zig");
const uri_util = @import("../../../../base/common/stdUri.zig");
const columns = @import("../../../api/common/positionConverter.zig");
const bulk = @import("../../../../editor/browser/services/bulkEditService.zig");
const SnippetParser = @import("../../../../editor/contrib/snippet/browser/snippetParser.zig");
const Edit = languages.WorkspaceTextEdit;

pub const ModelEditTask = struct {
    owner: *BulkTextEdits,
    resource: std.Uri,
    key: []const u8,
    edits: std.ArrayList(Edit) = .empty,
    reference: ?resolver.ModelReference = null,
    pending: ?resolver.ModelReferenceRequest = null,
    done: bool = false,
    operations: []model_types.IdentifiedSingleEditOperation = &.{},
    eol: ?@import("../../../../editor/common/core/misc/eolCounter.zig").EOL = null,

    fn modelReady(context: *anyopaque, result: resolver.ModelReferenceResult) void {
        const self: *ModelEditTask = @ptrCast(@alignCast(context));
        const owner = self.owner;
        self.pending = null;
        self.done = true;
        switch (result) {
            .failure => |err| owner.failure = err,
            .resolved => |reference| self.reference = reference,
        }
        owner.remaining -= 1;
        if (!owner.starting and !owner.canceled and owner.remaining == 0) owner.finish();
    }

    fn prepare(self: *ModelEditTask) !void {
        const reference = self.reference orelse return error.TextModelMissing;
        if (reference.object.isReadonly()) return error.ReadOnlyResource;
        const model = reference.object.textEditorModel;
        const a = self.owner.arena.allocator();
        var operations: std.ArrayList(model_types.IdentifiedSingleEditOperation) = .empty;
        for (self.edits.items) |edit| {
            if (edit.version_id) |version| if (model.getVersionId() != version) return error.ModelVersionMismatch;
            if (edit.eol) |eol| self.eol = eol;
            if (edit.range == null and edit.text.len == 0) continue;
            const range = if (edit.range) |value| if (edit.column_encoding == .utf16) try convertRange(model, value) else value else model.getFullModelRange();
            const normalized = model.validateRange(range);
            if (normalized.startLineNumber == normalized.endLineNumber and normalized.startColumn == normalized.endColumn and edit.text.len == 0) continue;
            const text = if (edit.insert_as_snippet) try SnippetParser.asInsertText(a, edit.text) else edit.text;
            try operations.append(a, .init(normalized, String.initBorrowed(text)));
        }
        std.mem.sort(model_types.IdentifiedSingleEditOperation, operations.items, {}, struct {
            fn less(_: void, left: model_types.IdentifiedSingleEditOperation, right: model_types.IdentifiedSingleEditOperation) bool {
                return range_mod.compareRangesUsingStarts(&left.range, &right.range) < 0;
            }
        }.less);
        for (operations.items[0..operations.items.len -| 1], operations.items[@min(operations.items.len, 1)..]) |left, right| {
            if (range_mod.areIntersecting(&left.range, &right.range)) return error.OverlappingEdits;
        }
        self.operations = operations.items;
    }

    fn getBeforeCursorState(self: *ModelEditTask) ?[]Selection {
        return if (self.owner.selection_key) |key| if (std.mem.eql(u8, key, self.key)) self.owner.before_selections else null else null;
    }

    fn isNoOp(self: *ModelEditTask) bool {
        return self.operations.len == 0 and (self.eol == null or self.eol.? == self.reference.?.object.textEditorModel.getEOL());
    }

    fn apply(self: *ModelEditTask, group: *UndoRedoGroup) !void {
        const model = self.reference.?.object.textEditorModel;
        if (self.operations.len > 0) _ = try model.pushEditOperations(self.getBeforeCursorState(), self.operations, null, group);
        if (self.eol) |eol| try model.pushEOLWithGroup(eol, group);
    }
};

pub fn convertRange(model: *TextModel, range: Range) !Range {
    const start_line = try model.getLineContent(range.startLineNumber);
    defer start_line.deinit();
    const end_line = try model.getLineContent(range.endLineNumber);
    defer end_line.deinit();
    return .init(range.startLineNumber, columns.columnForUtf16Offset(start_line.items, range.startColumn), range.endLineNumber, columns.columnForUtf16Offset(end_line.items, range.endColumn));
}

pub const SelectionSnapshot = struct {
    resource_key: []const u8,
    selections: []Selection,
};

pub const BulkTextEdits = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    resolver_service: resolver.ITextModelService,
    tasks: std.ArrayList(*ModelEditTask) = .empty,
    listener: bulk.EditListener,
    reporter: bulk.ResourceReporter,
    undo_group: *UndoRedoGroup,
    undo_service: *UndoRedoService,
    undo_source: ?*UndoRedoSource,
    label: []const u8,
    code: []const u8,
    selection_key: ?[]const u8 = null,
    before_selections: ?[]Selection = null,
    remaining: usize = 0,
    edit_count: usize = 0,
    starting: bool = true,
    canceled: bool = false,
    finished: bool = false,
    parent_listener: ?Disposable = null,
    failure: ?anyerror = null,
    cancel_notify: bool = false,
    detached: bool = false,

    pub fn start(allocator: Allocator, service: resolver.ITextModelService, undo_service: *UndoRedoService, edits: []const bulk.ResourceEdit, options: bulk.IBulkEditOptions, group: *UndoRedoGroup, selection: ?SelectionSnapshot, reporter: bulk.ResourceReporter, listener: bulk.EditListener) !?Disposable {
        try options.token.throwIfCancellationRequested();
        const self = try allocator.create(BulkTextEdits);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .resolver_service = service, .listener = listener, .reporter = reporter, .undo_group = group, .undo_service = undo_service, .undo_source = options.undo_redo_source, .label = options.label orelse "Workspace Edit", .code = options.code orelse "undoredo.workspaceEdit" };
        errdefer self.destroy();
        const a = self.arena.allocator();
        if (selection) |snapshot| {
            self.selection_key = try a.dupe(u8, snapshot.resource_key);
            self.before_selections = try a.dupe(Selection, snapshot.selections);
        }
        var groups: std.StringHashMapUnmanaged(*ModelEditTask) = .empty;
        for (edits) |resource_edit| {
            const edit = switch (resource_edit) {
                .text => |edit| edit,
                .file => return error.UnsupportedResourceEdit,
            };
            const key = try uri_util.resourceKey(a, edit.resource);
            const entry = try groups.getOrPut(a, key);
            if (!entry.found_existing) {
                const task = try a.create(ModelEditTask);
                task.* = .{ .owner = self, .key = key, .resource = try std.Uri.parse(try uri_util.encodedResource(a, edit.resource)) };
                entry.value_ptr.* = task;
                try self.tasks.append(a, task);
            }
            var owned = edit;
            owned.resource = entry.value_ptr.*.resource;
            owned.text = try a.dupe(u8, edit.text);
            try entry.value_ptr.*.edits.append(a, owned);
            self.edit_count += 1;
        }
        self.remaining = self.tasks.items.len;
        self.parent_listener = try options.token.onCancellationRequested(.{ .context = self, .callbackFn = onCanceled });
        for (self.tasks.items) |task| {
            if (self.canceled) break;
            const pending = self.resolver_service.createModelReference(task.resource, .{ .context = task, .complete = ModelEditTask.modelReady }) catch |err| {
                ModelEditTask.modelReady(task, .{ .failure = err });
                continue;
            };
            if (self.canceled) pending.cancel() else if (!task.done) task.pending = pending;
        }
        self.starting = false;
        if (self.canceled or self.remaining == 0) {
            self.finish();
            return null;
        }
        return Disposable.from(BulkTextEdits, self, dispose);
    }

    fn onCanceled(context: *anyopaque) void {
        const self: *BulkTextEdits = @ptrCast(@alignCast(context));
        self.cancel(true);
    }

    fn dispose(self: *BulkTextEdits) void {
        self.cancel(false);
    }
    fn cancel(self: *BulkTextEdits, notify: bool) void {
        if (self.finished) {
            if (!notify) self.detached = true;
            return;
        }
        if (self.canceled) return;
        self.canceled = true;
        self.cancel_notify = notify;
        for (self.tasks.items) |task| if (task.pending) |pending| {
            pending.cancel();
            task.pending = null;
        };
        if (!self.starting) self.finish();
    }

    fn execute(self: *BulkTextEdits) !bulk.IBulkEditResult {
        if (self.failure) |err| return err;
        if (self.tasks.items.len == 0) return .{ .is_applied = false };
        for (self.tasks.items) |task| try task.prepare();
        if (self.tasks.items.len == 1 and self.tasks.items[0].isNoOp()) return .{ .is_applied = true };
        const a = self.allocator;
        var singles = std.ArrayList(edit_stack.SingleModelEditStackElement).empty;
        defer singles.deinit(a);
        var singles_owned = true;
        defer if (singles_owned) for (singles.items) |*element| element.deinit();
        try singles.ensureTotalCapacity(a, self.tasks.items.len);
        for (self.tasks.items) |task| {
            const model = task.reference.?.object.textEditorModel;
            if (model.getUndoRedoService() != self.undo_service) return error.MismatchedUndoRedoService;
            model.pushStackElement();
            try model.ensureInitialUndoRedoSnapshot();
            singles.appendAssumeCapacity(try edit_stack.SingleModelEditStackElement.init(a, self.label, self.code, model, task.getBeforeCursorState()));
        }
        const element = try a.create(edit_stack.EditStackElement);
        var stack_owned = false;
        errdefer if (!stack_owned) a.destroy(element);
        if (singles.items.len == 1) {
            element.* = .{ .singleModel = singles.items[0] };
        } else {
            element.* = .{ .multiModel = try edit_stack.MultiModelEditStackElement.init(a, self.label, self.code, singles.items) };
        }
        singles_owned = false;
        self.undo_service.pushElement(element, self.undo_group, self.undo_source) catch |err| {
            element.deinit();
            return err;
        };
        stack_owned = true;
        // ModelEditTask appends to the pre-installed shared undo element;
        // close it only after every model belongs to the same operation.
        defer element.close() catch {};
        for (self.tasks.items) |task| try task.apply(self.undo_group);
        for (self.tasks.items) |task| self.reporter.report(self.reporter.context, &.{task.reference.?.object.textEditorModel.uri()});
        return .{ .is_applied = true, .edited_resources = self.tasks.items.len, .edit_count = self.edit_count };
    }

    fn finish(self: *BulkTextEdits) void {
        self.finished = true;
        const listener = self.listener;
        const result: anyerror!bulk.IBulkEditResult = if (self.canceled) error.CancellationError else self.execute();
        const notify = !self.detached and (!self.canceled or self.cancel_notify);
        self.destroy();
        if (notify) listener.complete(listener.context, result);
    }

    fn destroy(self: *BulkTextEdits) void {
        if (self.parent_listener) |listener| listener.dispose();
        for (self.tasks.items) |task| {
            if (task.pending) |pending| pending.cancel();
            if (task.reference) |*reference| reference.dispose();
        }
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};
