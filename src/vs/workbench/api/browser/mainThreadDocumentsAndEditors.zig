// Port of the wire-shape part of
// `src/vs/workbench/api/browser/mainThreadDocumentsAndEditors.ts` and the
// document/editor delta producers it owns.
//
// Terminal adaptation: the adapter supplies editor-group lifecycle and focus;
// this module owns the real model mirrors and builds the exact `$acceptDocumentsAndEditorsDelta`,
// `$acceptModelChanged` and
// `$acceptEditorPropertiesChanged` payloads, including the UTF-16 conversion of
// selections and visible ranges.
const std = @import("std");
const Allocator = std.mem.Allocator;
const TextModel = @import("../../../editor/common/model/textModel.zig").TextModel;
const Selection = @import("../../../editor/common/core/selection.zig").Selection;
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const std_uri = @import("../../../base/common/stdUri.zig");
const position_converter = @import("../common/positionConverter.zig");

pub const EditorOptions = struct {
    tab_size: usize,
    indent_size: usize,
    insert_spaces: bool,
};

pub const ChangeSpec = struct {
    text: []const u8,
    start: struct { line: usize, column: usize },
    end: struct { line: usize, column: usize },
    /// UTF-16 wire columns, precomputed against the host's mirrored document
    /// when the model already changed. Fall back to converting against `model`
    /// when absent.
    start_utf16: ?usize = null,
    end_utf16: ?usize = null,
    range_offset: usize = 0,
    range_length: usize = 0,
};

/// The delta that adds the active document and its editor. The terminal has a
/// single focused editor id (`"1"`) per active document, matching the adapter's
/// earlier wire shape.
///
/// The document resource is the text model's URI, never the editor's path
/// spelling: upstream identifies documents by URI, and the language-feature
/// requests carry `model.uri()`. Using the raw path here made a relative
/// command-line path look like a different document to the extension host, so
/// providers never found it and navigation silently produced no result.
pub fn documentData(arena: Allocator, model: *TextModel, language_id: []const u8, is_dirty: bool) !std.json.Value {
    const document_uri = try std_uri.jsonComponents(arena, model.uri());
    var document: std.json.ObjectMap = .empty;
    try document.put(arena, "uri", document_uri);
    try document.put(arena, "versionId", .{ .integer = @intCast(model.getVersionId()) });
    var lines = std.json.Array.init(arena);
    const line_count = model.getLineCount();
    var line_number: usize = 1;
    while (line_number <= line_count) : (line_number += 1) {
        var line = try model.getLineContent(line_number);
        defer line.deinit();
        try lines.append(.{ .string = try arena.dupe(u8, line.items) });
    }
    try document.put(arena, "lines", .{ .array = lines });
    try document.put(arena, "EOL", .{ .string = if (model.getEOL() == .CRLF) "\r\n" else "\n" });
    try document.put(arena, "languageId", .{ .string = try arena.dupe(u8, language_id) });
    try document.put(arena, "isDirty", .{ .bool = is_dirty });
    try document.put(arena, "encoding", .{ .string = "utf8" });
    return .{ .object = document };
}

pub fn addedModelDelta(arena: Allocator, model: *TextModel, language_id: []const u8, is_dirty: bool) !std.json.Value {
    var documents = std.json.Array.init(arena);
    try documents.append(try documentData(arena, model, language_id, is_dirty));
    var delta = std.json.ObjectMap{};
    try delta.put(arena, "addedDocuments", .{ .array = documents });
    return .{ .object = delta };
}

pub fn addedEditorDelta(arena: Allocator, model: *TextModel, options: EditorOptions, initial_selections: []const Selection) !std.json.Value {
    const document_uri = try std_uri.jsonComponents(arena, model.uri());
    var editors = std.json.Array.init(arena);
    var editor: std.json.ObjectMap = .empty;
    try editor.put(arena, "id", .{ .string = "1" });
    try editor.put(arena, "documentUri", document_uri);
    var editor_options: std.json.ObjectMap = .empty;
    try editor_options.put(arena, "tabSize", .{ .integer = @intCast(options.tab_size) });
    try editor_options.put(arena, "indentSize", .{ .integer = @intCast(options.indent_size) });
    try editor_options.put(arena, "originalIndentSize", .{ .string = "tabSize" });
    try editor_options.put(arena, "insertSpaces", .{ .bool = options.insert_spaces });
    try editor_options.put(arena, "cursorStyle", .{ .integer = 1 });
    try editor_options.put(arena, "lineNumbers", .{ .integer = 1 });
    try editor.put(arena, "options", .{ .object = editor_options });
    try editor.put(arena, "selections", .{ .array = try selectionsJson(arena, model, initial_selections) });
    try editor.put(arena, "visibleRanges", .{ .array = try visibleRangesJson(arena, model) });
    try editor.put(arena, "editorPosition", .{ .integer = 1 });
    try editors.append(.{ .object = editor });

    var delta: std.json.ObjectMap = .empty;
    try delta.put(arena, "addedEditors", .{ .array = editors });
    try delta.put(arena, "newActiveEditor", .{ .string = "1" });
    return .{ .object = delta };
}

pub fn addDocumentDelta(arena: Allocator, model: *TextModel, language_id: []const u8, is_dirty: bool, options: EditorOptions, initial_selections: []const Selection) !std.json.Value {
    var delta = try addedEditorDelta(arena, model, options, initial_selections);
    const documents = try addedModelDelta(arena, model, language_id, is_dirty);
    try delta.object.put(arena, "addedDocuments", documents.object.get("addedDocuments").?);
    return delta;
}

pub fn removedEditorDelta(arena: Allocator) !std.json.Value {
    var delta = std.json.ObjectMap{};
    var editors = std.json.Array.init(arena);
    try editors.append(.{ .string = "1" });
    try delta.put(arena, "removedEditors", .{ .array = editors });
    try delta.put(arena, "newActiveEditor", .null);
    return .{ .object = delta };
}

pub fn removedModelDelta(arena: Allocator, model: *TextModel) !std.json.Value {
    var delta = std.json.ObjectMap{};
    var documents = std.json.Array.init(arena);
    try documents.append(try std_uri.jsonComponents(arena, model.uri()));
    try delta.put(arena, "removedDocuments", .{ .array = documents });
    return .{ .object = delta };
}

pub fn removedDocumentDelta(arena: Allocator, path: []const u8) !std.json.Value {
    var delta: std.json.ObjectMap = .empty;
    var removed_docs = std.json.Array.init(arena);
    try removed_docs.append(try manager.fileUri(arena, path));
    var removed_editors = std.json.Array.init(arena);
    try removed_editors.append(.{ .string = "1" });
    try delta.put(arena, "removedDocuments", .{ .array = removed_docs });
    try delta.put(arena, "removedEditors", .{ .array = removed_editors });
    return .{ .object = delta };
}

pub fn selectionsJson(arena: Allocator, model: *TextModel, selections: []const Selection) !std.json.Array {
    var array = std.json.Array.init(arena);
    for (selections) |selection| {
        var item: std.json.ObjectMap = .empty;
        try item.put(arena, "selectionStartLineNumber", .{ .integer = @intCast(selection.startLineNumber) });
        try item.put(arena, "selectionStartColumn", .{ .integer = @intCast(utf16Column(model, selection.startLineNumber, selection.startColumn)) });
        try item.put(arena, "positionLineNumber", .{ .integer = @intCast(selection.endLineNumber) });
        try item.put(arena, "positionColumn", .{ .integer = @intCast(utf16Column(model, selection.endLineNumber, selection.endColumn)) });
        try array.append(.{ .object = item });
    }
    return array;
}

pub fn visibleRangesJson(arena: Allocator, model: *TextModel) !std.json.Array {
    var array = std.json.Array.init(arena);
    var item: std.json.ObjectMap = .empty;
    try item.put(arena, "startLineNumber", .{ .integer = 1 });
    try item.put(arena, "startColumn", .{ .integer = 1 });
    try item.put(arena, "endLineNumber", .{ .integer = @intCast(model.getLineCount()) });
    try item.put(arena, "endColumn", .{ .integer = 1 });
    try array.append(.{ .object = item });
    return array;
}

pub fn modelChangedEvent(
    arena: Allocator,
    model: *TextModel,
    change: ChangeSpec,
    version: u32,
) !std.json.Value {
    return modelChangesEvent(arena, model, &.{change}, version);
}

/// `$acceptModelChanged` payload for a whole model event. Upstream sends all
/// change ranges from one edit batch in one event, so the extension host can
/// apply multi-range commands atomically.
pub fn modelChangesEvent(
    arena: Allocator,
    model: *TextModel,
    changes: []const ChangeSpec,
    version: u32,
) !std.json.Value {
    var change_array = std.json.Array.init(arena);
    for (changes) |change| {
        var item: std.json.ObjectMap = .empty;
        try item.put(arena, "rangeOffset", .{ .integer = @intCast(change.range_offset) });
        try item.put(arena, "rangeLength", .{ .integer = @intCast(change.range_length) });
        try item.put(arena, "text", .{ .string = try arena.dupe(u8, change.text) });
        var range: std.json.ObjectMap = .empty;
        try range.put(arena, "startLineNumber", .{ .integer = @intCast(change.start.line) });
        try range.put(arena, "startColumn", .{ .integer = @intCast(change.start_utf16 orelse utf16Column(model, change.start.line, change.start.column)) });
        try range.put(arena, "endLineNumber", .{ .integer = @intCast(change.end.line) });
        try range.put(arena, "endColumn", .{ .integer = @intCast(change.end_utf16 orelse utf16Column(model, change.end.line, change.end.column)) });
        try item.put(arena, "range", .{ .object = range });
        try change_array.append(.{ .object = item });
    }

    var event: std.json.ObjectMap = .empty;
    try event.put(arena, "changes", .{ .array = change_array });
    try event.put(arena, "eol", .{ .string = if (model.getEOL() == .CRLF) "\r\n" else "\n" });
    try event.put(arena, "versionId", .{ .integer = @intCast(version) });
    try event.put(arena, "isUndoing", .{ .bool = false });
    try event.put(arena, "isRedoing", .{ .bool = false });
    try event.put(arena, "isFlush", .{ .bool = false });
    try event.put(arena, "isEolChange", .{ .bool = false });
    try event.put(arena, "detailedReason", .null);
    return .{ .object = event };
}

pub fn editorPropertiesChanged(
    arena: Allocator,
    editor_id: []const u8,
    model: *TextModel,
    selections: []const Selection,
    source: []const u8,
    visible_range: ?@import("../../../editor/common/core/range.zig").Range,
) !std.json.Value {
    var event: std.json.ObjectMap = .empty;
    try event.put(arena, "selections", .{ .array = try selectionsJson(arena, model, selections) });
    try event.put(arena, "source", .{ .string = try arena.dupe(u8, source) });
    var properties: std.json.ObjectMap = .empty;
    try properties.put(arena, "options", .null);
    try properties.put(arena, "selections", .{ .object = event });
    if (visible_range) |range| {
        try properties.put(arena, "visibleRanges", .{ .array = try visibleRangeJson(arena, model, range) });
    } else {
        try properties.put(arena, "visibleRanges", .null);
    }
    var args = std.json.Array.init(arena);
    try args.append(.{ .string = try arena.dupe(u8, editor_id) });
    try args.append(.{ .object = properties });
    return .{ .array = args };
}

/// Properties-changed payload carrying only a viewport delta. Upstream sends
/// this from `MainThreadTextEditor` when the editor scrolls without changing
/// its selection.
pub fn editorVisibleRangesChanged(
    arena: Allocator,
    editor_id: []const u8,
    model: *TextModel,
    visible_range: @import("../../../editor/common/core/range.zig").Range,
) !std.json.Value {
    var properties: std.json.ObjectMap = .empty;
    try properties.put(arena, "options", .null);
    try properties.put(arena, "selections", .null);
    try properties.put(arena, "visibleRanges", .{ .array = try visibleRangeJson(arena, model, visible_range) });
    var args = std.json.Array.init(arena);
    try args.append(.{ .string = try arena.dupe(u8, editor_id) });
    try args.append(.{ .object = properties });
    return .{ .array = args };
}

fn visibleRangeJson(arena: Allocator, model: *TextModel, range: @import("../../../editor/common/core/range.zig").Range) !std.json.Array {
    var array = std.json.Array.init(arena);
    var item: std.json.ObjectMap = .empty;
    const start_line = @min(@max(range.startLineNumber, 1), model.getLineCount());
    const end_line = @min(@max(range.endLineNumber, start_line), model.getLineCount());
    try item.put(arena, "startLineNumber", .{ .integer = @intCast(start_line) });
    try item.put(arena, "startColumn", .{ .integer = 1 });
    try item.put(arena, "endLineNumber", .{ .integer = @intCast(end_line) });
    try item.put(arena, "endColumn", .{ .integer = @intCast(model.getLineMaxColumn(end_line)) });
    try array.append(.{ .object = item });
    return array;
}

fn utf16Column(model: *TextModel, line_number: usize, column: usize) usize {
    if (line_number < 1 or line_number > model.getLineCount()) return column;
    var line = model.getLineContent(line_number) catch return column;
    defer line.deinit();
    return position_converter.utf16OffsetForColumn(line.items, column);
}

test "documentsAndEditors: the document resource is the model URI" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // The editor's path is a relative spelling; the model resource is the
    // canonical absolute URI language-feature requests carry.
    var editor = try Editor.createFromText(allocator, io, "{\n  \"a\": 1\n}\n", "relative.json", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const delta = try addDocumentDelta(
        arena.allocator(),
        editor.model,
        "json",
        false,
        .{ .tab_size = 2, .indent_size = 2, .insert_spaces = true },
        &.{},
    );
    const document_uri = delta.object.get("addedDocuments").?.array.items[0].object.get("uri").?.object;
    const editor_uri = delta.object.get("addedEditors").?.array.items[0].object.get("documentUri").?.object;
    const document_path = document_uri.get("path").?.string;
    try std.testing.expect(std.fs.path.isAbsolute(document_path));
    // The mirror must not fall back to the editor's relative path spelling:
    // that is what the extension host could not match to `model.uri()`.
    try std.testing.expect(!std.mem.eql(u8, editor.path, document_path));
    try std.testing.expectEqualStrings(document_path, editor_uri.get("path").?.string);
    try std.testing.expectEqualStrings(try std_uri.fsPath(editor.model.uri(), arena.allocator()), document_path);
}

// MainThreadDocumentAndEditorStateComputer's model collection. The terminal
// supplies model additions/removals from editor-group lifecycle events; each
// resource owns exactly one mirror, including both models of a diff editor.
const editor_terminal = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const Editor = editor_terminal.Editor;
const EditorDocument = editor_terminal.EditorDocument;
const WorkingCopy = @import("../../services/workingCopy/common/workingCopy.zig").IWorkingCopy;
const model_events = @import("../../../editor/common/textModelEvents.zig");
const EOL = @import("../../../editor/common/core/misc/eolCounter.zig").EOL;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");

pub const ModelCollection = struct {
    allocator: Allocator,
    host: Host,
    documents: std.ArrayList(*MirroredDocument) = .empty,

    pub const Host = struct {
        context: *anyopaque,
        notify: *const fn (*anyopaque, Actor, []const u8, []const rpc.Arg) anyerror!void,
    };
    pub const Actor = enum { documents, documents_and_editors };

    pub fn init(allocator: Allocator, host: Host) ModelCollection {
        return .{ .allocator = allocator, .host = host };
    }

    pub fn deinit(self: *ModelCollection) void {
        while (self.documents.items.len > 0) self.remove(self.documents.items.len - 1) catch {
            self.documents.pop().?.deinit();
        };
        self.documents.deinit(self.allocator);
    }

    pub fn documentForResource(self: *ModelCollection, key: []const u8) ?*EditorDocument {
        for (self.documents.items) |document| if (std.mem.eql(u8, document.key, key)) return document.document;
        return null;
    }

    pub fn modelForResource(self: *ModelCollection, key: []const u8) ?*TextModel {
        return if (self.documentForResource(key)) |document| document.model else null;
    }

    pub fn writableEditorForResource(self: *ModelCollection, key: []const u8) ?*Editor {
        const document = self.documentForResource(key) orelse return null;
        if (!std.mem.eql(u8, document.model.uri().scheme, "file")) return null;
        for (document.editors.items) |editor| if (!editor.isReadOnly()) return editor;
        return null;
    }

    /// The model set is independent of mounted code-editor controls.
    /// The active document is first when two controls resolve the same URI.
    pub fn synchronize(self: *ModelCollection, editors: []const *Editor) !void {
        var documents: std.ArrayList(*EditorDocument) = .empty;
        defer documents.deinit(self.allocator);
        for (editors) |editor| try documents.append(self.allocator, editor.document);
        try self.synchronizeDocuments(documents.items);
    }

    pub fn synchronizeDocuments(self: *ModelCollection, documents: []const *EditorDocument) !void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var wanted = std.StringHashMap(*EditorDocument).init(a);
        for (documents) |document| {
            if (!document.model.shouldSynchronizeModel()) continue;
            const key = try std_uri.resourceKey(a, document.model.uri());
            const entry = try wanted.getOrPut(key);
            if (!entry.found_existing) entry.value_ptr.* = document;
        }
        var index: usize = 0;
        while (index < self.documents.items.len) {
            const mirrored = self.documents.items[index];
            const document = wanted.get(mirrored.key);
            if (!mirrored.retained) {
                // The actual model service owns this document's lifecycle;
                // removing a mounted editor is not removing the model.
                _ = wanted.remove(mirrored.key);
                index += 1;
                continue;
            }
            if (document == null or document.? != mirrored.document) {
                try self.remove(index);
            } else {
                _ = wanted.remove(mirrored.key);
                index += 1;
            }
        }
        // Preserve the caller's model ordering in addedDocuments.
        for (documents) |document| {
            if (!document.model.shouldSynchronizeModel()) continue;
            const key = try std_uri.resourceKey(a, document.model.uri());
            if (wanted.fetchRemove(key)) |entry| try self.add(entry.value, key, true);
        }
    }

    /// The model service sends a small add/remove delta for an actual model,
    /// even when no code editor displays it. Do not hold a reference which
    /// would prevent the model service's last-reference disposal event.
    pub fn addTrackedDocument(self: *ModelCollection, document: *EditorDocument) !void {
        if (!document.model.shouldSynchronizeModel()) return;
        const key = try std_uri.resourceKey(self.allocator, document.model.uri());
        defer self.allocator.free(key);
        for (self.documents.items, 0..) |mirrored, index| {
            if (!std.mem.eql(u8, mirrored.key, key)) continue;
            if (mirrored.document != document) {
                try self.remove(index);
                break;
            }
            if (mirrored.retained) {
                mirrored.retained = false;
                document.release();
            }
            return;
        }
        try self.add(document, key, false);
    }

    pub fn removeTrackedModel(self: *ModelCollection, model: *TextModel) void {
        for (self.documents.items, 0..) |mirrored, index| {
            if (mirrored.retained or mirrored.document.model != model) continue;
            self.remove(index) catch {
                // Transport failure cannot leave a callback on a dying model.
                _ = self.documents.orderedRemove(index);
                mirrored.deinit();
            };
            return;
        }
    }

    fn add(self: *ModelCollection, document: *EditorDocument, key: []const u8, retained: bool) !void {
        const mirrored = try MirroredDocument.create(self, document, key, retained);
        errdefer mirrored.deinit();
        try self.documents.ensureUnusedCapacity(self.allocator, 1);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const delta = try addedModelDelta(scratch.allocator(), document.model, document.model.getLanguageId(), document.isDirty());
        try self.host.notify(self.host.context, .documents_and_editors, "$acceptDocumentsAndEditorsDelta", &.{.{ .json = delta }});
        self.documents.appendAssumeCapacity(mirrored);
    }

    fn remove(self: *ModelCollection, index: usize) !void {
        const mirrored = self.documents.items[index];
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const delta = try removedModelDelta(scratch.allocator(), mirrored.document.model);
        try self.host.notify(self.host.context, .documents_and_editors, "$acceptDocumentsAndEditorsDelta", &.{.{ .json = delta }});
        _ = self.documents.orderedRemove(index);
        mirrored.deinit();
    }
};

const MirroredDocument = struct {
    owner: *ModelCollection,
    document: *EditorDocument,
    retained: bool,
    copy: WorkingCopy,
    key: []const u8,
    lines: std.array_list.Managed([]u8),
    eol: EOL,
    content_listener: ?usize = null,
    language_listener: ?usize = null,
    dirty_listener: bool = false,
    save_listener: bool = false,

    fn create(owner: *ModelCollection, document: *EditorDocument, key: []const u8, retained: bool) !*MirroredDocument {
        const a = owner.allocator;
        const self = try a.create(MirroredDocument);
        const owned = a.dupe(u8, key) catch |err| {
            a.destroy(self);
            return err;
        };
        self.* = .{ .owner = owner, .document = document, .retained = retained, .copy = document.interface(), .key = owned, .lines = .init(a), .eol = document.model.getEOL() };
        if (retained) self.document.retain();
        errdefer self.deinit();
        self.lines = try captureLines(a, document.model);
        self.content_listener = try document.model.onDidChangeContentWithContextId(self, onContent);
        self.language_listener = try document.model.listenDidChangeLanguage(self, onLanguage);
        self.copy.add_dirty_listener(self.copy.context, .{ .context = self, .callback = onDirty });
        self.dirty_listener = true;
        self.copy.add_save_listener(self.copy.context, .{ .context = self, .callback = onSave });
        self.save_listener = true;
        return self;
    }

    fn deinit(self: *MirroredDocument) void {
        const a = self.owner.allocator;
        const model = self.document.model;
        if (self.content_listener) |id| model.removeDidChangeContentListener(id);
        if (self.language_listener) |id| model.removeDidChangeLanguageListener(id);
        if (self.dirty_listener) self.copy.remove_dirty_listener(self.copy.context, .{ .context = self, .callback = onDirty });
        if (self.save_listener) self.copy.remove_save_listener(self.copy.context, .{ .context = self, .callback = onSave });
        freeLines(a, &self.lines);
        a.free(self.key);
        if (self.retained) self.document.release();
        a.destroy(self);
    }

    fn onContent(event: model_events.InternalModelContentChangeEvent, self: *MirroredDocument) !void {
        const model = self.document.model;
        const changes = event.contentChangedEvent;
        const a = self.owner.allocator;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var specs: std.ArrayList(ChangeSpec) = .empty;
        const eol_width: usize = if (self.eol == .CRLF) 2 else 1;
        for (changes.changes.items) |change| {
            const range = change.range;
            const start_utf16 = utf16ColumnForLines(self.lines.items, range.startLineNumber, range.startColumn);
            const end_utf16 = utf16ColumnForLines(self.lines.items, range.endLineNumber, range.endColumn);
            const offset = offsetForLines(self.lines.items, range.startLineNumber, start_utf16, eol_width);
            const end = offsetForLines(self.lines.items, range.endLineNumber, end_utf16, eol_width);
            try specs.append(arena, .{
                .text = change.text.items(),
                .start = .{ .line = range.startLineNumber, .column = range.startColumn },
                .end = .{ .line = range.endLineNumber, .column = range.endColumn },
                .start_utf16 = start_utf16,
                .end_utf16 = end_utf16,
                .range_offset = offset,
                .range_length = end -| offset,
            });
        }
        var payload = try modelChangesEvent(arena, model, specs.items, @intCast(changes.versionId));
        try payload.object.put(arena, "isUndoing", .{ .bool = changes.isUndoing });
        try payload.object.put(arena, "isRedoing", .{ .bool = changes.isRedoing });
        try payload.object.put(arena, "isFlush", .{ .bool = changes.isFlush });
        try payload.object.put(arena, "isEolChange", .{ .bool = changes.isEolChange });
        self.owner.host.notify(self.owner.host.context, .documents, "$acceptModelChanged", &.{ .{ .json = try std_uri.jsonComponents(arena, model.uri()) }, .{ .json = payload }, .{ .json = .{ .bool = self.copy.getDirty() } } }) catch {};
        self.eol = model.getEOL();
        for (changes.changes.items) |change| {
            applyLineChange(a, &self.lines, change.range, change.text.items()) catch {
                const replacement = try captureLines(a, model);
                freeLines(a, &self.lines);
                self.lines = replacement;
                break;
            };
        }
    }

    fn onLanguage(event: model_events.ModelLanguageChangedEvent, self: *MirroredDocument) !void {
        var scratch = std.heap.ArenaAllocator.init(self.owner.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        try self.owner.host.notify(self.owner.host.context, .documents, "$acceptModelLanguageChanged", &.{ .{ .json = try std_uri.jsonComponents(arena, self.document.model.uri()) }, .{ .json = .{ .string = event.newLanguage } } });
    }
    fn workingCopyEvent(self: *MirroredDocument, method: []const u8, dirty: ?bool) !void {
        var scratch = std.heap.ArenaAllocator.init(self.owner.allocator);
        defer scratch.deinit();
        const uri = try std_uri.jsonComponents(scratch.allocator(), self.document.model.uri());
        if (dirty) |value| {
            try self.owner.host.notify(self.owner.host.context, .documents, method, &.{ .{ .json = uri }, .{ .json = .{ .bool = value } } });
        } else try self.owner.host.notify(self.owner.host.context, .documents, method, &.{.{ .json = uri }});
    }
    fn onDirty(context: *anyopaque) void {
        const self: *MirroredDocument = @ptrCast(@alignCast(context));
        self.workingCopyEvent("$acceptDirtyStateChanged", self.copy.getDirty()) catch {};
    }
    fn onSave(context: *anyopaque) void {
        const self: *MirroredDocument = @ptrCast(@alignCast(context));
        self.workingCopyEvent("$acceptModelSaved", null) catch {};
    }
};

pub fn freeLines(allocator: Allocator, lines: *std.array_list.Managed([]u8)) void {
    for (lines.items) |line| allocator.free(line);
    lines.deinit();
}

pub fn captureLines(allocator: Allocator, model: *TextModel) !std.array_list.Managed([]u8) {
    var lines = std.array_list.Managed([]u8).init(allocator);
    errdefer freeLines(allocator, &lines);
    for (1..model.getLineCount() + 1) |number| {
        var content = try model.getLineContent(number);
        defer content.deinit();
        const copy = try allocator.dupe(u8, content.items);
        errdefer allocator.free(copy);
        try lines.append(copy);
    }
    return lines;
}

pub fn utf16ColumnForLines(lines: []const []u8, line: usize, column: usize) usize {
    if (line == 0 or line > lines.len) return column;
    return position_converter.utf16OffsetForColumn(lines[line - 1], column);
}

fn offsetForLines(lines: []const []u8, line: usize, utf16_column: usize, eol_width: usize) usize {
    var offset: usize = 0;
    for (lines[0..@min(line -| 1, lines.len)]) |content| offset += position_converter.utf16OffsetForColumn(content, content.len + 1) - 1 + eol_width;
    return offset + utf16_column -| 1;
}

pub fn applyLineChange(allocator: Allocator, lines: *std.array_list.Managed([]u8), range: @import("../../../editor/common/core/range.zig").Range, text: []const u8) !void {
    const start = range.startLineNumber;
    const end = range.endLineNumber;
    if (start < 1 or end < start or end > lines.items.len) return error.InvalidChange;
    const start_column = @min(@max(range.startColumn, 1), lines.items[start - 1].len + 1);
    const end_column = @min(@max(range.endColumn, 1), lines.items[end - 1].len + 1);
    var segment = std.array_list.Managed(u8).init(allocator);
    defer segment.deinit();
    try segment.appendSlice(lines.items[start - 1][0 .. start_column - 1]);
    try segment.appendSlice(text);
    try segment.appendSlice(lines.items[end - 1][end_column - 1 ..]);
    var replacement = std.array_list.Managed([]u8).init(allocator);
    errdefer freeLines(allocator, &replacement);
    var split = std.mem.splitScalar(u8, segment.items, '\n');
    while (split.next()) |line| {
        const content = if (split.peek() != null and std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
        const copy = try allocator.dupe(u8, content);
        errdefer allocator.free(copy);
        try replacement.append(copy);
    }
    const count = end - start + 1;
    const removed = try allocator.dupe([]u8, lines.items[start - 1 .. end]);
    defer allocator.free(removed);
    try lines.replaceRange(start - 1, count, replacement.items);
    for (removed) |line| allocator.free(line);
    replacement.deinit();
}

test "documentsAndEditors: diff model resources survive editor focus changes and mirror nonfocused edits" {
    const a = std.testing.allocator;
    const Range = @import("../../../editor/common/core/range.zig").Range;
    const Host = struct {
        added: usize = 0,
        removed: usize = 0,
        content: usize = 0,
        fn notify(context: *anyopaque, actor: ModelCollection.Actor, method: []const u8, args: []const rpc.Arg) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (actor == .documents_and_editors) {
                const delta = args[0].json.object;
                if (delta.get("addedDocuments")) |docs| {
                    const doc = docs.array.items[0].object;
                    const uri = doc.get("uri").?.object;
                    if (self.added == 0) {
                        try std.testing.expectEqualStrings("git", uri.get("scheme").?.string);
                        try std.testing.expectEqualStrings("HEAD", uri.get("query").?.string);
                        try std.testing.expectEqualStrings("\r\n", doc.get("EOL").?.string);
                    } else try std.testing.expectEqualStrings("file", uri.get("scheme").?.string);
                    self.added += 1;
                }
                if (delta.get("removedDocuments")) |docs| {
                    const uri = docs.array.items[0].object;
                    try std.testing.expectEqualStrings(if (self.removed == 0) "git" else "file", uri.get("scheme").?.string);
                    self.removed += 1;
                }
            } else if (std.mem.eql(u8, method, "$acceptModelChanged")) {
                const uri = args[0].json.object;
                try std.testing.expectEqualStrings("git", uri.get("scheme").?.string);
                try std.testing.expectEqualStrings("HEAD", uri.get("query").?.string);
                const event = args[1].json.object;
                const change = event.get("changes").?.array.items[0].object;
                try std.testing.expectEqual(@as(i64, 5), change.get("rangeOffset").?.integer);
                try std.testing.expectEqual(@as(i64, 1), change.get("rangeLength").?.integer);
                const range = change.get("range").?.object;
                try std.testing.expectEqual(@as(i64, 3), range.get("startColumn").?.integer);
                try std.testing.expectEqual(@as(i64, 4), range.get("endColumn").?.integer);
                self.content += 1;
            }
        }
    };
    var host: Host = .{};
    var models = ModelCollection.init(a, .{ .context = &host, .notify = Host.notify });
    defer models.deinit();
    const original_doc = try EditorDocument.createFromText(a, std.testing.io, "/diff-model.txt", "a\r\n😀x", try std.Uri.parse("git:/diff-model.txt?HEAD"));
    defer original_doc.release();
    const original = try Editor.createViewFromDocument(original_doc, 40, 8, .{});
    defer {
        original.deinit();
        a.destroy(original);
    }
    const modified = try Editor.createFromText(a, std.testing.io, "new", "/diff-model.txt", 40, 8);
    defer {
        modified.deinit();
        a.destroy(modified);
    }
    try models.synchronize(&.{ original, modified });
    try std.testing.expectEqual(@as(usize, 2), host.added);
    const key = try std_uri.resourceKey(a, original.model.uri());
    defer a.free(key);
    try std.testing.expectEqual(original.model, models.modelForResource(key).?);
    try models.synchronize(&.{ modified, original, modified });
    try std.testing.expectEqual(@as(usize, 2), host.added);
    try std.testing.expectEqual(@as(usize, 0), host.removed);
    try original.applyTextEdits(&.{.{ .range = Range.init(2, 5, 2, 6), .text = "z" }}, &.{});
    try std.testing.expectEqual(@as(usize, 1), host.content);
    try models.synchronize(&.{modified});
    try std.testing.expectEqual(@as(usize, 1), host.removed);
    try std.testing.expect(models.modelForResource(key) == null);
    try models.synchronize(&.{});
    try std.testing.expectEqual(@as(usize, 2), host.removed);
}

test "documentsAndEditors: mirrors unmounted resource documents without synthetic editor views" {
    const a = std.testing.allocator;
    const Host = struct {
        added: usize = 0,
        removed: usize = 0,
        edits: usize = 0,
        fn notify(context: *anyopaque, actor: ModelCollection.Actor, method: []const u8, args: []const rpc.Arg) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (actor == .documents_and_editors) {
                const delta = args[0].json.object;
                if (delta.get("addedDocuments")) |docs| {
                    try std.testing.expectEqualStrings("git", docs.array.items[0].object.get("uri").?.object.get("scheme").?.string);
                    self.added += 1;
                }
                if (delta.get("removedDocuments") != null) self.removed += 1;
            } else if (std.mem.eql(u8, method, "$acceptModelChanged")) self.edits += 1;
        }
    };
    var host: Host = .{};
    var collection = ModelCollection.init(a, .{ .context = &host, .notify = Host.notify });
    defer collection.deinit();
    const first = try EditorDocument.createFromText(a, std.testing.io, "/repo/a.txt", "before", try std.Uri.parse("git:/repo/a.txt?HEAD"));
    defer first.release();
    const other = try EditorDocument.createFromText(a, std.testing.io, "/repo/b.txt", "other", try std.Uri.parse("git:/repo/b.txt?HEAD"));
    defer other.release();
    try std.testing.expectEqual(@as(usize, 0), first.editors.items.len);
    try std.testing.expectEqual(@as(usize, 0), other.editors.items.len);
    try collection.synchronizeDocuments(&.{ first, other });
    try std.testing.expectEqual(@as(usize, 2), host.added);
    const key = try std_uri.resourceKey(a, other.model.uri());
    defer a.free(key);
    try std.testing.expectEqual(other.model, collection.modelForResource(key).?);
    try other.appendGeneratedContents(" changed");
    try std.testing.expectEqual(@as(usize, 1), host.edits);
    try collection.synchronizeDocuments(&.{ other, first, other });
    try std.testing.expectEqual(@as(usize, 2), host.added);
    try collection.synchronizeDocuments(&.{first});
    try std.testing.expectEqual(@as(usize, 1), host.removed);
    try std.testing.expect(collection.modelForResource(key) == null);
}
