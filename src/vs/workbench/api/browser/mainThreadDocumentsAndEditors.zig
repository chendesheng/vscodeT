// Port of the wire-shape part of
// `src/vs/workbench/api/browser/mainThreadDocumentsAndEditors.ts` and the
// document/editor delta producers it owns.
//
// Terminal adaptation: the adapter still owns the active-editor mirror and
// view state; this module builds the exact `$acceptDocumentsAndEditorsDelta`,
// `$acceptEditorTabModel`, `$acceptModelChanged` and
// `$acceptEditorPropertiesChanged` payloads, including the UTF-16 conversion of
// selections and visible ranges.
const std = @import("std");
const Allocator = std.mem.Allocator;
const TextModel = @import("../../../editor/common/model/textModel.zig").TextModel;
const Selection = @import("../../../editor/common/core/selection.zig").Selection;
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const position_converter = @import("../common/positionConverter.zig");

pub const EditorOptions = struct {
    tab_size: usize,
    indent_size: usize,
    insert_spaces: bool,
};

pub const TabSpec = struct {
    path: []const u8,
    label: []const u8,
    is_active: bool,
    is_dirty: bool,
    is_pinned: bool = true,
    is_preview: bool = false,
};

pub const ChangeSpec = struct {
    text: []const u8,
    start: struct { line: usize, column: usize },
    end: struct { line: usize, column: usize },
};

/// The delta that adds the active document and its editor. The terminal has a
/// single focused editor id (`"1"`) per active document, matching the adapter's
/// earlier wire shape.
pub fn addDocumentDelta(
    arena: Allocator,
    model: *TextModel,
    path: []const u8,
    language_id: []const u8,
    is_dirty: bool,
    options: EditorOptions,
    initial_selections: []const Selection,
) !std.json.Value {
    var docs = std.json.Array.init(arena);
    var document: std.json.ObjectMap = .empty;
    try document.put(arena, "uri", try manager.fileUri(arena, path));
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
    try document.put(arena, "EOL", .{ .string = "\n" });
    try document.put(arena, "languageId", .{ .string = try arena.dupe(u8, language_id) });
    try document.put(arena, "isDirty", .{ .bool = is_dirty });
    try document.put(arena, "encoding", .{ .string = "utf8" });
    try docs.append(.{ .object = document });

    var editors = std.json.Array.init(arena);
    var editor: std.json.ObjectMap = .empty;
    try editor.put(arena, "id", .{ .string = "1" });
    try editor.put(arena, "documentUri", try manager.fileUri(arena, path));
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
    try delta.put(arena, "addedDocuments", .{ .array = docs });
    try delta.put(arena, "addedEditors", .{ .array = editors });
    try delta.put(arena, "newActiveEditor", .{ .string = "1" });
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

pub fn tabModel(arena: Allocator, active_path: []const u8, tabs: []const TabSpec) !std.json.Value {
    var tab_array = std.json.Array.init(arena);
    for (tabs) |tab| {
        var tab_object: std.json.ObjectMap = .empty;
        try tab_object.put(arena, "id", .{ .string = try arena.dupe(u8, tab.path) });
        try tab_object.put(arena, "label", .{ .string = try arena.dupe(u8, tab.label) });
        var input: std.json.ObjectMap = .empty;
        try input.put(arena, "kind", .{ .integer = 1 });
        try input.put(arena, "uri", try manager.fileUri(arena, tab.path));
        try tab_object.put(arena, "input", .{ .object = input });
        if (std.mem.eql(u8, tab.path, active_path)) try tab_object.put(arena, "editorId", .{ .string = "1" });
        try tab_object.put(arena, "isActive", .{ .bool = tab.is_active });
        try tab_object.put(arena, "isPinned", .{ .bool = tab.is_pinned });
        try tab_object.put(arena, "isPreview", .{ .bool = tab.is_preview });
        try tab_object.put(arena, "isDirty", .{ .bool = tab.is_dirty });
        try tab_array.append(.{ .object = tab_object });
    }
    if (tab_array.items.len == 0) return .null;
    var group: std.json.ObjectMap = .empty;
    try group.put(arena, "isActive", .{ .bool = true });
    try group.put(arena, "viewColumn", .{ .integer = 1 });
    try group.put(arena, "tabs", .{ .array = tab_array });
    try group.put(arena, "groupId", .{ .integer = 1 });
    var groups = std.json.Array.init(arena);
    try groups.append(.{ .object = group });
    return .{ .array = groups };
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
    var changes = std.json.Array.init(arena);
    var item: std.json.ObjectMap = .empty;
    try item.put(arena, "rangeOffset", .{ .integer = 0 });
    try item.put(arena, "rangeLength", .{ .integer = 0 });
    try item.put(arena, "text", .{ .string = try arena.dupe(u8, change.text) });
    var range: std.json.ObjectMap = .empty;
    try range.put(arena, "startLineNumber", .{ .integer = @intCast(change.start.line) });
    try range.put(arena, "startColumn", .{ .integer = @intCast(utf16Column(model, change.start.line, change.start.column)) });
    try range.put(arena, "endLineNumber", .{ .integer = @intCast(change.end.line) });
    try range.put(arena, "endColumn", .{ .integer = @intCast(utf16Column(model, change.end.line, change.end.column)) });
    try item.put(arena, "range", .{ .object = range });
    try changes.append(.{ .object = item });

    var event: std.json.ObjectMap = .empty;
    try event.put(arena, "changes", .{ .array = changes });
    try event.put(arena, "eol", .{ .string = "\n" });
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
) !std.json.Value {
    var event: std.json.ObjectMap = .empty;
    try event.put(arena, "selections", .{ .array = try selectionsJson(arena, model, selections) });
    try event.put(arena, "source", .{ .string = try arena.dupe(u8, source) });
    var properties: std.json.ObjectMap = .empty;
    try properties.put(arena, "options", .null);
    try properties.put(arena, "selections", .{ .object = event });
    try properties.put(arena, "visibleRanges", .null);
    var args = std.json.Array.init(arena);
    try args.append(.{ .string = try arena.dupe(u8, editor_id) });
    try args.append(.{ .object = properties });
    return .{ .array = args };
}

fn utf16Column(model: *TextModel, line_number: usize, column: usize) usize {
    if (line_number < 1 or line_number > model.getLineCount()) return column;
    var line = model.getLineContent(line_number) catch return column;
    defer line.deinit();
    return position_converter.utf16OffsetForColumn(line.items, column);
}
