const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const edit_operation = @import("../core/editOperation.zig");
const EditOperation = edit_operation.EditOperation;
const ISingleEditOperation = edit_operation.ISingleEditOperation;
const range = @import("../core/range.zig");
const Range = range.Range;
const string_edit = @import("../core/edits/stringEdit.zig");
const StringEdit = string_edit.StringEdit;
const StringReplacement = string_edit.StringReplacement;
const OffsetRange = @import("../core/ranges/offsetRange.zig").OffsetRange;
const DetailedLineRangeMapping = @import("../diff/rangeMapping.zig").DetailedLineRangeMapping;
const ModelContentChange = @import("../textModelEvents.zig").ModelContentChange;
const length_edit = @import("../core/edits/lengthEdit.zig");
const LengthEdit = length_edit.LengthEdit;
const countEOL = @import("../core/misc/eolCounter.zig").countEOL;
const TextModel = @import("textModel.zig").TextModel;

pub fn offsetEditToEditOperations(
    allocator: Allocator,
    offset_edit: *const StringEdit,
    doc: *const TextModel,
) ![]ISingleEditOperation {
    const edits = try allocator.alloc(ISingleEditOperation, offset_edit.replacements.len);
    errdefer allocator.free(edits);

    for (offset_edit.replacements, 0..) |single_edit, i| {
        const replacement_range = range.fromPositions(
            doc.getPositionAt(single_edit.replaceRange.start),
            doc.getPositionAt(single_edit.replaceRange.start + single_edit.replaceRange.length()),
        );
        edits[i] = EditOperation.replace(replacement_range, single_edit.newText);
    }
    return edits;
}

pub fn offsetEditFromContentChanges(
    allocator: Allocator,
    content_changes: []const ModelContentChange,
) !StringEdit {
    var replacements = ArrayList(StringReplacement).init(allocator);
    defer replacements.deinit();
    try replacements.ensureTotalCapacity(content_changes.len);

    // The changes are ordered from the end of the document to the beginning,
    // so reverse them to make the replacement ranges sorted.
    var i = content_changes.len;
    while (i > 0) {
        i -= 1;
        const change = content_changes[i];
        replacements.appendAssumeCapacity(StringReplacement.replace(
            OffsetRange.ofStartAndLength(change.rangeOffset, change.rangeLength),
            change.text.items(),
        ));
    }
    return StringEdit.create(allocator, replacements.items);
}

pub fn offsetEditFromLineRangeMapping(
    allocator: Allocator,
    original: *TextModel,
    modified: *TextModel,
    changes: []const DetailedLineRangeMapping,
) !StringEdit {
    var edits = ArrayList(StringReplacement).init(allocator);
    defer edits.deinit();

    // Keep the replacement texts alive until the edit has copied them.
    var text_arena = std.heap.ArenaAllocator.init(allocator);
    defer text_arena.deinit();
    const text_allocator = text_arena.allocator();

    for (changes) |change| {
        const inner_changes = change.inner_changes orelse continue;
        for (inner_changes) |inner| {
            var new_text = try modified.getValueInRange(inner.modifiedRange, null);
            defer new_text.deinit();

            const start_orig = original.getOffsetAt(inner.originalRange.getStartPosition());
            const end_ex_orig = original.getOffsetAt(inner.originalRange.getEndPosition());
            const orig_range = OffsetRange.init(start_orig, end_ex_orig);

            try edits.append(try StringReplacement.replace(orig_range, new_text.items).clone(text_allocator));
        }
    }

    return StringEdit.create(allocator, edits.items);
}

pub fn linesLengthEditFromModelContentChange(
    allocator: Allocator,
    changes: []const ModelContentChange,
) !LengthEdit {
    var edits = ArrayList(LengthEdit).init(allocator);
    defer {
        for (edits.items) |*length_edit_value| {
            length_edit_value.deinit();
        }
        edits.deinit();
    }

    var i = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        // Expand the edit range to include the entire line
        const edit_range = OffsetRange.init(change.range.startLineNumber - 1, change.range.endLineNumber);
        const replacement_length = countEOL(change.text.items()).eolCount + 1;
        try edits.append(try length_edit.replace(allocator, edit_range, replacement_length));
    }

    return length_edit.composeAll(allocator, edits.items);
}

test "offsetEditFromContentChanges: applies changes in order" {
    const allocator = std.testing.allocator;
    const strings = @import("../../../base/common/strings.zig");
    const String = strings.String;

    var changes = [_]ModelContentChange{
        .{ .range = Range.init(1, 7, 1, 12), .rangeOffset = 6, .rangeLength = 5, .text = String.initBorrowed("there") },
        .{ .range = Range.init(1, 1, 1, 6), .rangeOffset = 0, .rangeLength = 5, .text = String.initBorrowed("hi") },
    };

    var edit = try offsetEditFromContentChanges(allocator, &changes);
    defer edit.deinit();

    try std.testing.expectEqual(@as(usize, 2), edit.replacements.len);
    try std.testing.expectEqual(OffsetRange.init(0, 5), edit.replacements[0].replaceRange);
    try std.testing.expectEqual(OffsetRange.init(6, 11), edit.replacements[1].replaceRange);

    const abstract_text = @import("../core/text/abstractText.zig");
    const result = try string_edit.applyOnText(&edit, allocator, abstract_text.StringText.init("hello world"));
    defer allocator.free(result.value);
    try std.testing.expectEqualStrings("hi there", result.value);
}

test "linesLengthEditFromModelContentChange: counts EOLs" {
    const allocator = std.testing.allocator;
    const strings = @import("../../../base/common/strings.zig");
    const String = strings.String;

    var changes = [_]ModelContentChange{
        .{ .range = Range.init(2, 1, 2, 4), .rangeOffset = 4, .rangeLength = 3, .text = String.initBorrowed("x\ny") },
    };

    var edit = try linesLengthEditFromModelContentChange(allocator, &changes);
    defer edit.deinit();

    try std.testing.expectEqual(@as(usize, 1), edit.replacements.len);
    try std.testing.expectEqual(OffsetRange.init(1, 2), edit.replacements[0].replaceRange);
    try std.testing.expectEqual(@as(usize, 2), edit.replacements[0].newLength);
    try std.testing.expectEqual(@as(isize, 4), edit.getNewDataLength(3));
}

test "offsetEditToEditOperations and offsetEditFromLineRangeMapping" {
    const allocator = std.testing.allocator;
    const UndoRedoService = @import("../../../platform/undoRedo/common/undoRedoService.zig").UndoRedoService;
    const LanguageService = @import("../services/languageService.zig").LanguageService;
    const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
    const Model = @import("../model.zig");

    var undo_redo = UndoRedoService.init(allocator);
    defer undo_redo.deinit();

    const codec = try std.heap.page_allocator.create(LanguageIdCodec);
    codec.* = try LanguageIdCodec.init(std.heap.page_allocator);
    var language_service = LanguageService.init(std.heap.page_allocator, codec);

    const creation_options = Model.TextModelCreationOptions{
        .tabSize = 4,
        .indentSize = .{ .number = 4 },
        .insertSpaces = true,
        .detectIndentation = true,
        .trimAutoWhitespace = true,
        .defaultEOL = .LF,
        .isForSimpleWidget = false,
        .largeFileOptimizations = false,
        .bracketPairColorizationOptions = .{ .enabled = false, .independentColorPoolPerBracketType = false },
    };

    var original_reader = std.Io.Reader.fixed("hello\nworld");
    const original = try TextModel.init(allocator, &original_reader, "", creation_options, null, &undo_redo, &language_service);
    defer allocator.destroy(original);
    defer original.deinit();

    var modified_reader = std.Io.Reader.fixed("hello!\nworld");
    const modified = try TextModel.init(allocator, &modified_reader, "", creation_options, null, &undo_redo, &language_service);
    defer allocator.destroy(modified);
    defer modified.deinit();

    const RangeMapping = @import("../diff/rangeMapping.zig").RangeMapping;
    const inner = [_]RangeMapping{
        RangeMapping.init(Range.init(1, 1, 1, 6), Range.init(1, 1, 1, 7)),
    };
    const changes = [_]DetailedLineRangeMapping{
        DetailedLineRangeMapping.init(
            @import("../core/ranges/lineRange.zig").LineRange.init(1, 2),
            @import("../core/ranges/lineRange.zig").LineRange.init(1, 2),
            &inner,
        ),
    };

    var edit = try offsetEditFromLineRangeMapping(allocator, original, modified, &changes);
    defer edit.deinit();

    try std.testing.expectEqual(@as(usize, 1), edit.replacements.len);
    try std.testing.expectEqual(OffsetRange.init(0, 5), edit.replacements[0].replaceRange);
    try std.testing.expectEqualStrings("hello!", edit.replacements[0].newText);

    const operations = try offsetEditToEditOperations(allocator, &edit, original);
    defer allocator.free(operations);
    try std.testing.expectEqual(@as(usize, 1), operations.len);
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 6), operations[0].range);
    try std.testing.expectEqualStrings("hello!", operations[0].text.?);
}
