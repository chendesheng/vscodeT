const std = @import("std");
const Io = std.Io;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;
const UriHashMap = @import("../model.zig").UriHashMap;
const TextModel = @import("./textModel.zig").TextModel;
const UndoRedoService = @import("../../../platform/undoRedo/common/undoRedoService.zig").UndoRedoService;
const Selection = @import("../core/selection.zig").Selection;
const EOL = @import("../core/misc/eolCounter.zig").EOL;
const TextChange = @import("../core/textChange.zig").TextChange;
const String = @import("../../../base/common/strings.zig").String;
const UndoRedoGroup = @import("../../../platform/undoRedo/common/undoRedo.zig").UndoRedoGroup;
const ValidEditOperation = @import("../model.zig").ValidEditOperation;
const Disposable = @import("../../../platform/undoRedo/common/undoRedo.zig").Disposable;
const uriToString = @import("../model.zig").uriToString;
const TextModelCreationOptions = @import("../model.zig").TextModelCreationOptions;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const LanguageService = @import("../services/languageService.zig").LanguageService;
const ValidAnnotatedEditOperation = @import("../model.zig").ValidAnnotatedEditOperation;
const utils = @import("../../../base/common/utils.zig");
const Pair = utils.Pair;
const toIndexedPair = utils.toIndexedPair;
const fromIndexedPair = utils.fromIndexedPair;
const pair = utils.pair;

pub const EditStackElement = union(enum) {
    singleModel: SingleModelEditStackElement,
    multiModel: MultiModelEditStackElement,

    pub fn deinit(self: *EditStackElement) void {
        switch (self.*) {
            .singleModel => |*singleModel| singleModel.deinit(),
            .multiModel => |*multiModel| multiModel.deinit(),
        }
    }

    pub fn close(self: *EditStackElement) !void {
        switch (self.*) {
            .singleModel => |*singleModel| {
                try singleModel.close();
            },
            .multiModel => |*multiModel| {
                multiModel.close();
            },
        }
    }

    pub fn open(self: *EditStackElement) void {
        switch (self.*) {
            .singleModel => |*singleModel| {
                singleModel.open();
            },
            .multiModel => {},
        }
    }

    pub fn canAppend(self: *const EditStackElement, model: *const TextModel) bool {
        switch (self.*) {
            .singleModel => |*singleModel| {
                return singleModel.canAppend(model);
            },
            .multiModel => |*multiModel| {
                return multiModel.canAppend(model);
            },
        }
    }

    pub fn append(self: *EditStackElement, model: *const TextModel, textChanges: []const TextChange, afterEOL: EOL, afterVersionId: u32, afterCursorState: ?[]Selection) !void {
        switch (self.*) {
            .singleModel => |*singleModel| {
                try singleModel.append(textChanges, afterEOL, afterVersionId, afterCursorState);
            },
            .multiModel => |*multiModel| {
                try multiModel.append(model, textChanges, afterEOL, afterVersionId, afterCursorState);
            },
        }
    }

    pub fn setModel(self: *EditStackElement, model: TextModelOrUri) void {
        switch (self.*) {
            .singleModel => |*singleModel| {
                singleModel.setModel(model);
            },
            .multiModel => |*multiModel| {
                multiModel.setModel(model);
            },
        }
    }

    pub fn undo(self: *EditStackElement) !void {
        switch (self.*) {
            .singleModel => |*singleModel| {
                try singleModel.undo();
            },
            .multiModel => |*multiModel| {
                try multiModel.undo();
            },
        }
    }

    pub fn redo(self: *EditStackElement) !void {
        switch (self.*) {
            .singleModel => |*singleModel| {
                try singleModel.redo();
            },
            .multiModel => |*multiModel| {
                try multiModel.redo();
            },
        }
    }

    pub fn toString(self: *EditStackElement) !ArrayList(u8) {
        switch (self.*) {
            .singleModel => |*singleModel| {
                return try singleModel.toString();
            },
            .multiModel => |*multiModel| {
                return try multiModel.toString();
            },
        }
    }

    pub fn label(self: *const EditStackElement) []const u8 {
        switch (self.*) {
            .singleModel => |*singleModel| {
                return singleModel.label;
            },
            .multiModel => |*multiModel| {
                return multiModel.label;
            },
        }
    }

    pub fn getAllocator(self: *const EditStackElement) Allocator {
        switch (self.*) {
            .singleModel => |*singleModel| {
                return singleModel.allocator;
            },
            .multiModel => |*multiModel| {
                return multiModel.allocator;
            },
        }
    }

    pub fn split(self: *EditStackElement) !ArrayList(EditStackElement) {
        switch (self.*) {
            .singleModel => {
                const result = ArrayList(EditStackElement).init(self.getAllocator());
                return result;
            },
            .multiModel => |*multiModel| {
                var result = ArrayList(EditStackElement).init(self.getAllocator());
                for (multiModel.split()) |element| {
                    try result.append(EditStackElement{ .singleModel = element });
                }
                return result;
            },
        }
    }

    pub fn resource(self: *const EditStackElement) Uri {
        switch (self.*) {
            .singleModel => |*singleModel| {
                return singleModel.resource();
            },
            .multiModel => |*multiModel| {
                return multiModel.resource();
            },
        }
    }
};

pub const SingleModelEditStackData = union(enum) {
    unserialized: SingleModelEditStackDataUnserialized,
    serialized: ArrayList(u8),

    pub fn deinit(self: *SingleModelEditStackData) void {
        switch (self.*) {
            .unserialized => |*data| data.deinit(),
            .serialized => |*data| data.deinit(),
        }
    }
};

fn dupeSelections(allocator: Allocator, selections: ?[]const Selection) !?[]Selection {
    const source = selections orelse return null;
    if (source.len == 0) return null;
    return try allocator.dupe(Selection, source);
}

fn freeSelections(allocator: Allocator, selections: ?[]Selection) void {
    if (selections) |s| {
        if (s.len > 0) allocator.free(s);
    }
}

fn cloneTextChange(allocator: Allocator, change: TextChange) !TextChange {
    var old_text = ArrayList(u8).init(allocator);
    errdefer old_text.deinit();
    try old_text.appendSlice(change.oldText.items());

    var new_text = ArrayList(u8).init(allocator);
    errdefer new_text.deinit();
    try new_text.appendSlice(change.newText.items());

    return TextChange.init(
        change.oldPosition,
        String.initOwned(old_text),
        change.newPosition,
        String.initOwned(new_text),
    );
}

pub const SingleModelEditStackDataUnserialized = struct {
    beforeVersionId: u32,
    afterVersionId: u32,
    beforeEOL: EOL,
    afterEOL: EOL,
    beforeCursorState: ?[]Selection,
    afterCursorState: ?[]Selection,
    changes: ArrayList(TextChange),

    pub fn create(allocator: Allocator, alternativeVersionId: u32, eol: EOL, beforeCursorState: ?[]Selection) !SingleModelEditStackDataUnserialized {
        const before = try dupeSelections(allocator, beforeCursorState);
        errdefer freeSelections(allocator, before);
        const after = try dupeSelections(allocator, beforeCursorState);
        errdefer freeSelections(allocator, after);
        return SingleModelEditStackDataUnserialized{
            .beforeVersionId = alternativeVersionId,
            .afterVersionId = alternativeVersionId,
            .beforeEOL = eol,
            .afterEOL = eol,
            .beforeCursorState = before,
            .afterCursorState = after,
            .changes = ArrayList(TextChange).init(allocator),
        };
    }

    pub fn deinit(self: *SingleModelEditStackDataUnserialized) void {
        const allocator = self.changes.allocator;
        for (self.changes.items) |*change| {
            change.deinit();
        }
        self.changes.deinit();
        freeSelections(allocator, self.beforeCursorState);
        freeSelections(allocator, self.afterCursorState);
        self.beforeCursorState = null;
        self.afterCursorState = null;
    }

    pub fn append(self: *SingleModelEditStackDataUnserialized, textChanges: []const TextChange, afterEOL: EOL, afterVersionId: u32, afterCursorState: ?[]Selection) !void {
        for (textChanges) |change| {
            var cloned = try cloneTextChange(self.changes.allocator, change);
            errdefer cloned.deinit();
            try self.changes.append(cloned);
        }
        const newAfter = try dupeSelections(self.changes.allocator, afterCursorState);
        freeSelections(self.changes.allocator, self.afterCursorState);
        self.afterEOL = afterEOL;
        self.afterVersionId = afterVersionId;
        self.afterCursorState = newAfter;
    }

    pub fn _writeSelectionsSize(selections: ?[]const Selection) usize {
        return 4 + 4 * 4 * (if (selections) |s| s.len else 0);
    }

    pub fn _writeSelections(b: *Io.Writer, selections: ?[]Selection) !void {
        try b.writeInt(u32, if (selections) |s| @intCast(s.len) else 0, .big);
        if (selections) |s| {
            for (s) |selection| {
                try b.writeInt(u32, @intCast(selection.selectionStartLineNumber), .big);
                try b.writeInt(u32, @intCast(selection.selectionStartColumn), .big);
                try b.writeInt(u32, @intCast(selection.positionLineNumber), .big);
                try b.writeInt(u32, @intCast(selection.positionColumn), .big);
            }
        }
    }

    pub fn _readSelections(b: *Io.Reader, dest: *ArrayList(Selection)) !void {
        const count = try b.takeInt(u32, .big);
        for (0..count) |_| {
            const selectionStartLineNumber = try b.takeInt(u32, .big);
            const selectionStartColumn = try b.takeInt(u32, .big);
            const positionLineNumber = try b.takeInt(u32, .big);
            const positionColumn = try b.takeInt(u32, .big);
            try dest.append(Selection{
                .startLineNumber = 0,
                .startColumn = 0,
                .endLineNumber = 0,
                .endColumn = 0,
                .selectionStartLineNumber = selectionStartLineNumber,
                .selectionStartColumn = selectionStartColumn,
                .positionLineNumber = positionLineNumber,
                .positionColumn = positionColumn,
            });
        }
    }

    pub fn serialize(self: *const SingleModelEditStackDataUnserialized) !ArrayList(u8) {
        var necessarySize: usize = ( //
            4 // beforeVersionId
            + 4 // afterVersionId
            + 1 // beforeEOL
            + 1 // afterEOL
            + _writeSelectionsSize(self.beforeCursorState) //
            + _writeSelectionsSize(self.afterCursorState) //
            + 4 // change count
        );
        for (self.changes.items) |change| {
            necessarySize += change.writeSize();
        }

        var b = try ArrayList(u8).initCapacity(self.changes.allocator, necessarySize);
        try b.resize(necessarySize);
        var writer = Io.Writer.fixed(b.items);

        try writer.writeInt(u32, self.beforeVersionId, .big);
        try writer.writeInt(u32, self.afterVersionId, .big);
        try writer.writeInt(u8, @backingInt(self.beforeEOL), .big);
        try writer.writeInt(u8, @backingInt(self.afterEOL), .big);
        try _writeSelections(&writer, self.beforeCursorState);
        try _writeSelections(&writer, self.afterCursorState);
        try writer.writeInt(u32, @intCast(self.changes.items.len), .big);
        for (self.changes.items) |change| {
            try change.write(&writer);
        }
        return b;
    }

    pub fn deserialize(allocator: Allocator, source: []const u8) !SingleModelEditStackDataUnserialized {
        var reader = Io.Reader.fixed(source);

        const beforeVersionId = try reader.takeInt(u32, .big);
        const afterVersionId = try reader.takeInt(u32, .big);
        const beforeEOL: EOL = @fromBackingInt(@intCast(try reader.takeInt(u8, .big)));
        const afterEOL: EOL = @fromBackingInt(@intCast(try reader.takeInt(u8, .big)));
        var beforeCursorState = ArrayList(Selection).init(allocator);
        errdefer beforeCursorState.deinit();
        try _readSelections(&reader, &beforeCursorState);
        var afterCursorState = ArrayList(Selection).init(allocator);
        errdefer afterCursorState.deinit();
        try _readSelections(&reader, &afterCursorState);
        const changeCount = try reader.takeInt(u32, .big);
        var changes = ArrayList(TextChange).init(allocator);
        errdefer changes.deinit();
        for (0..changeCount) |_| {
            try TextChange.read(&reader, allocator, &changes);
        }
        const before = try beforeCursorState.toOwnedSlice();
        errdefer allocator.free(before);
        const after = try afterCursorState.toOwnedSlice();
        errdefer allocator.free(after);
        return SingleModelEditStackDataUnserialized{
            .beforeVersionId = beforeVersionId,
            .afterVersionId = afterVersionId,
            .beforeEOL = beforeEOL,
            .afterEOL = afterEOL,
            .beforeCursorState = before,
            .afterCursorState = after,
            .changes = changes,
        };
    }
};

test "SingleModelEditStackDataUnserialized" {
    const allocator = std.testing.allocator;
    var data = try SingleModelEditStackDataUnserialized.create(allocator, 1, .LF, null);
    defer data.deinit();
    try data.append(&[_]TextChange{TextChange.init(0, .initBorrowed("a"), 0, .initBorrowed("b"))}, .LF, 2, null);
    const serialized = try data.serialize();
    defer serialized.deinit();
    var deserialized = try SingleModelEditStackDataUnserialized.deserialize(allocator, serialized.items);
    defer deserialized.deinit();
    try std.testing.expectEqualStrings("a", deserialized.changes.items[0].oldText.items());
    try std.testing.expectEqualStrings("b", deserialized.changes.items[0].newText.items());
}

const TextModelOrUri = union(enum) {
    model: *TextModel,
    uri: Uri,

    pub fn getUri(self: *const TextModelOrUri) Uri {
        switch (self.*) {
            .model => |model| return model.uri(),
            .uri => |uri| return uri,
        }
    }

    pub fn eqlModel(self: *const TextModelOrUri, model: *const TextModel) bool {
        switch (self.*) {
            .model => |m| return m == model,
            .uri => {
                return false;
            },
        }
    }
};

pub const SingleModelEditStackElement = struct {
    model: TextModelOrUri,
    _data: SingleModelEditStackData,
    label: []const u8,
    code: []const u8,
    confirmBeforeUndo: ?bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, label: []const u8, code: []const u8, model: *TextModel, beforeCursorState: ?[]Selection) !SingleModelEditStackElement {
        return SingleModelEditStackElement{
            .allocator = allocator,
            .model = .{ .model = model },
            ._data = SingleModelEditStackData{
                .unserialized = try SingleModelEditStackDataUnserialized.create(
                    allocator,
                    model.getAlternativeVersionId(),
                    model.getEOL(),
                    beforeCursorState,
                ),
            },
            .label = label,
            .code = code,
            .confirmBeforeUndo = null,
        };
    }

    pub fn deinit(self: *SingleModelEditStackElement) void {
        self._data.deinit();
    }

    pub fn toString(self: *const SingleModelEditStackElement) !ArrayList(u8) {
        const allocator = self.allocator;
        var data = switch (self._data) {
            .unserialized => |data| data,
            .serialized => |data| try SingleModelEditStackDataUnserialized.deserialize(allocator, data.items),
        };
        defer {
            switch (self._data) {
                .unserialized => {},
                .serialized => data.deinit(),
            }
        }

        var result = std.array_list.Managed(u8).init(allocator);
        for (data.changes.items, 0..) |change, index| {
            const str = try change.toString(allocator);
            defer allocator.free(str);
            try result.appendSlice(str);
            if (index < data.changes.items.len - 1) {
                try result.appendSlice(", ");
            }
        }
        return result;
    }

    pub fn matchesResource(self: *const SingleModelEditStackElement, res: Uri) bool {
        const allocator = self.allocator;
        const uri = switch (self.model) {
            .model => |model| model.uri(),
            .uri => |uri| uri,
        };
        const uriStr = try uriToString(uri, allocator);
        defer uriStr.deinit();
        const resourceStr = try uriToString(res, allocator);
        defer resourceStr.deinit();
        return std.mem.eql(u8, uriStr.items, resourceStr.items);
    }

    pub fn setModel(self: *SingleModelEditStackElement, model: TextModelOrUri) void {
        self.model = model;
    }

    pub fn resource(self: *const SingleModelEditStackElement) Uri {
        return self.model.getUri();
    }

    pub fn canAppend(self: *const SingleModelEditStackElement, model: *const TextModel) bool {
        return self.model.eqlModel(model) and switch (self._data) {
            .unserialized => true,
            .serialized => false,
        };
    }

    pub fn append(self: *SingleModelEditStackElement, textChanges: []const TextChange, afterEOL: EOL, afterVersionId: u32, afterCursorState: ?[]Selection) !void {
        switch (self._data) {
            .unserialized => |*dat| {
                try dat.append(textChanges, afterEOL, afterVersionId, afterCursorState);
            },
            .serialized => {},
        }
    }

    pub fn close(self: *SingleModelEditStackElement) !void {
        var data = self._data;
        switch (data) {
            .unserialized => |*dat| {
                errdefer dat.deinit();
                const serialized = try dat.serialize();
                dat.deinit();
                self._data = .{ .serialized = serialized };
            },
            .serialized => {},
        }
    }

    pub fn open(self: *SingleModelEditStackElement) void {
        switch (self._data) {
            .serialized => |data| {
                const allocator = self.allocator;
                self._data = try SingleModelEditStackDataUnserialized.deserialize(allocator, data.items);
                allocator.free(data);
            },
            .unserialized => {},
        }
    }

    pub fn undo(self: *SingleModelEditStackElement) !void {
        switch (self.model) {
            .model => |model| {
                switch (self._data) {
                    .unserialized => |dat| {
                        var data = self._data;
                        defer data.deinit();
                        self._data = .{ .serialized = try dat.serialize() };
                    },
                    .serialized => {},
                }
                var data = try SingleModelEditStackDataUnserialized.deserialize(self.allocator, self._data.serialized.items);
                defer data.deinit();
                try model._applyUndo(data.changes, data.beforeEOL, data.beforeVersionId, data.beforeCursorState);
            },
            .uri => {
                return error.InvalidSingleModelEditStackElement;
            },
        }
    }

    pub fn redo(self: *SingleModelEditStackElement) !void {
        switch (self.model) {
            .model => |model| {
                switch (self._data) {
                    .unserialized => |*dat| {
                        var data = self._data;
                        defer data.deinit();
                        self._data = .{ .serialized = try dat.serialize() };
                    },
                    .serialized => {},
                }
                var data = try SingleModelEditStackDataUnserialized.deserialize(self.allocator, self._data.serialized.items);
                defer data.deinit();
                try model._applyRedo(data.changes, data.afterEOL, data.afterVersionId, data.afterCursorState);
            },
            .uri => {},
        }
    }

    pub fn heapSize(self: *const SingleModelEditStackElement) !usize {
        switch (self._data) {
            .unserialized => |*dat| {
                const data = try dat.serialize();
                defer self.allocator.free(data);
                return data.len + 168; // heap overhead, FIXME: is this the same in zig?
            },
            .serialized => |data| {
                return data.len + 168; // heap overhead, FIXME: is this the same in zig?
            },
        }
    }
};

test "SingleModelEditStackElement" {
    const allocator = std.testing.allocator;
    const text = "Hello, world!";
    var reader = Io.Reader.fixed(text);

    var undoRedoService = UndoRedoService.init(allocator);
    defer undoRedoService.deinit();

    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var languageService = LanguageService.init(allocator, &codec);

    var textModel = try TextModel.init(allocator, &reader, "test", TextModelCreationOptions{
        .tabSize = 4,
        .indentSize = .{ .number = 4 },
        .insertSpaces = true,
        .detectIndentation = true,
        .trimAutoWhitespace = true,
        .defaultEOL = .LF,
        .isForSimpleWidget = false,
        .largeFileOptimizations = false,
        .bracketPairColorizationOptions = .{
            .enabled = false,
            .independentColorPoolPerBracketType = false,
        },
    }, null, &undoRedoService, &languageService);
    defer allocator.destroy(textModel);
    defer textModel.deinit();

    var element = try SingleModelEditStackElement.init(allocator, "test", "test", textModel, &[_]Selection{});
    defer element.deinit();
    try std.testing.expectEqualStrings("test", element.label);
    try std.testing.expectEqualStrings("test", element.code);
    try std.testing.expectEqual(null, element.confirmBeforeUndo);
    try element.append(&[_]TextChange{TextChange.init(0, .initBorrowed("a"), 0, .initBorrowed("b"))}, .LF, 2, null);
    const str = try element.toString();
    defer str.deinit();
    try std.testing.expectEqualStrings("(replaced@0 \"a\" with \"b\")", str.items);
}

pub const MultiModelEditStackElement = struct {
    allocator: Allocator,
    label: []const u8,
    code: []const u8,

    _isOpen: bool,
    _editStackElementsArr: ArrayList(SingleModelEditStackElement),
    _editStackElementsMap: UriHashMap(SingleModelEditStackElement),
    _delegate: ?UndoRedoDelegate,

    pub fn init(allocator: Allocator, label: []const u8, code: []const u8, editStackElements: []SingleModelEditStackElement) !MultiModelEditStackElement {
        const editStackElementsMap = UriHashMap(SingleModelEditStackElement).init(allocator);
        const arr = ArrayList(SingleModelEditStackElement).init(allocator);
        try arr.appendSlice(editStackElements);
        for (arr.items) |item| {
            try editStackElementsMap.put(item.resource(), item);
        }
        return MultiModelEditStackElement{
            .allocator = allocator,
            .label = label,
            .code = code,
            ._isOpen = true,
            ._editStackElementsArr = arr,
            ._editStackElementsMap = editStackElementsMap,
            ._delegate = null,
        };
    }

    pub fn deinit(self: *MultiModelEditStackElement) void {
        self._editStackElementsMap.deinit();
        for (self._editStackElementsArr.items) |*element| {
            element.deinit();
        }
        self._editStackElementsArr.deinit();
    }

    pub fn setDelegate(self: *MultiModelEditStackElement, delegate: UndoRedoDelegate) void {
        self._delegate = delegate;
    }

    pub fn prepareUndoRedo(self: *MultiModelEditStackElement) ?Disposable {
        if (self._delegate) |delegate| {
            return delegate.prepareUndoRedo(self);
        }
        return null;
    }

    pub fn getMissingModels(self: *MultiModelEditStackElement) !ArrayList(Uri) {
        var result = ArrayList(Uri).init(self.allocator);
        for (self._editStackElementsArr.items) |editStackElement| {
            switch (editStackElement.model) {
                .model => {},
                .uri => |uri| {
                    try result.append(uri);
                },
            }
        }
        return result;
    }

    pub fn resources(self: *const MultiModelEditStackElement) !ArrayList(Uri) {
        var result = ArrayList(Uri).init(self.allocator);
        var iter = self._editStackElementsMap.valueIterator();
        while (iter.next()) |item| {
            try result.append(item.resource());
        }
        return result;
    }

    pub fn matchesResource(self: *MultiModelEditStackElement, resourceUri: Uri) bool {
        return self._editStackElementsMap.contains(resourceUri);
    }

    pub fn setModel(self: *MultiModelEditStackElement, model: TextModelOrUri) void {
        const key = model.getUri();
        if (self._editStackElementsMap.get(key)) |editStackElement| {
            editStackElement.setModel(model);
        }
    }

    pub fn canAppend(self: *const MultiModelEditStackElement, model: *const TextModel) bool {
        if (!self._isOpen) {
            return false;
        }
        if (self._editStackElementsMap.get(model.uri())) |editStackElement| {
            return editStackElement.canAppend(model);
        }
        return false;
    }

    pub fn append(self: *MultiModelEditStackElement, model: *const TextModel, textChanges: []const TextChange, afterEOL: EOL, afterVersionId: u32, afterCursorState: ?[]Selection) !void {
        if (self._editStackElementsMap.getPtr(model.uri())) |editStackElement| {
            try editStackElement.append(textChanges, afterEOL, afterVersionId, afterCursorState);
        }
    }

    pub fn close(self: *MultiModelEditStackElement) void {
        self._isOpen = false;
    }

    pub fn undo(self: *MultiModelEditStackElement) !void {
        self._isOpen = false;

        for (self._editStackElementsArr.items) |*editStackElement| {
            try editStackElement.undo();
        }
    }

    pub fn redo(self: *MultiModelEditStackElement) !void {
        for (self._editStackElementsArr.items) |*editStackElement| {
            try editStackElement.redo();
        }
    }

    pub fn heapSize(self: *const MultiModelEditStackElement, resourceUri: Uri) usize {
        if (self._editStackElementsMap.get(resourceUri)) |editStackElement| {
            return editStackElement.heapSize();
        }
        return 0;
    }

    pub fn split(self: *MultiModelEditStackElement) []SingleModelEditStackElement {
        return self._editStackElementsArr.items;
    }

    pub fn toString(self: *MultiModelEditStackElement) !ArrayList(u8) {
        const allocator = self.allocator;
        const result = ArrayList(u8).init(allocator);
        result.append('{');
        for (self._editStackElementsArr.items, 0..) |editStackElement, index| {
            const s = try editStackElement.toString();
            defer s.deinit();

            const url = try uriToString(editStackElement.resource(), allocator);
            defer url.deinit();

            try result.appendSlice(url.items);
            try result.appendSlice(": ");
            try result.appendSlice(s.items);

            if (index < self._editStackElementsArr.items.len - 1) {
                try result.appendSlice(", ");
            }
        }
        result.append('}');
        return result;
    }

    pub fn resource(self: *const MultiModelEditStackElement) Uri {
        return self._editStackElementsArr.items[0].resource();
    }
};

pub const EditStack = struct {
    _model: *anyopaque,
    _undoRedoService: *UndoRedoService,

    pub fn init(model: *TextModel, undoRedoService: *UndoRedoService) EditStack {
        return EditStack{
            ._model = model,
            ._undoRedoService = undoRedoService,
        };
    }

    pub fn textModel(self: *EditStack) *TextModel {
        return @ptrCast(@alignCast(self._model));
    }

    pub fn pushStackElement(self: *EditStack) void {
        if (self._undoRedoService.getLastElement(self.textModel().uri()) catch null) |lastElement| {
            lastElement.close() catch {};
        }
    }

    pub fn popStackElement(self: *EditStack) void {
        if (self._undoRedoService.getLastElement(self.textModel().uri()) catch null) |lastElement| {
            lastElement.open();
        }
    }

    pub fn clear(self: *EditStack) void {
        self._undoRedoService.removeElements(self.textModel().uri());
    }

    fn _getOrCreateEditStackElement(self: *EditStack, beforeCursorState: ?[]Selection, group: ?UndoRedoGroup) !*EditStackElement {
        if (try self._undoRedoService.getLastElement(self.textModel().uri())) |lastElement| {
            if (lastElement.canAppend(self.textModel())) {
                return lastElement;
            }
        }
        const allocator = self.textModel().getAllocator();
        const newElement = try SingleModelEditStackElement.init(allocator, "Typing", "undoredo.textBufferEdit", self.textModel(), beforeCursorState);
        const newEditStackElement = try allocator.create(EditStackElement);
        newEditStackElement.* = EditStackElement{ .singleModel = newElement };
        try self._undoRedoService.pushElement(newEditStackElement, group, null);
        return newEditStackElement;
    }

    pub fn pushEOL(self: *EditStack, eol: EOL) void {
        const editStackElement = self._getOrCreateEditStackElement(null, null);
        self.textModel().setEOL(eol);
        editStackElement.append(self.textModel(), &[_]TextChange{}, eol, self.textModel().getVersionId(), null);
    }

    pub fn pushEditOperation(self: *EditStack, beforeCursorState: ?[]Selection, editOperations: []ValidAnnotatedEditOperation, cursorStateComputer: ?CursorStateComputer, group: ?UndoRedoGroup) !?[]Selection {
        var editStackElement = try self._getOrCreateEditStackElement(beforeCursorState, group);
        var inverseEditOperations = (try self.textModel().applyValidatedEdits(editOperations, true)).?;
        defer {
            for (inverseEditOperations.items) |*op| op.deinit();
            inverseEditOperations.deinit();
        }
        const afterCursorState = EditStack._computeCursorState(cursorStateComputer, inverseEditOperations.items);

        var textChangesWithIndex = ArrayList(Pair(*TextChange, usize)).init(self.textModel().getAllocator());
        for (inverseEditOperations.items, 0..) |*op, i| {
            try textChangesWithIndex.append(pair(&op.textChange, i));
        }
        defer textChangesWithIndex.deinit();
        std.sort.heap(Pair(*TextChange, usize), textChangesWithIndex.items, {}, lessThanTextChangeWithIndex);
        const textChanges = try fromIndexedPair(TextChange, self.textModel().getAllocator(), textChangesWithIndex.items);
        defer textChanges.deinit();

        try editStackElement.append(self.textModel(), textChanges.items, self.textModel().getEOL(), self.textModel().getAlternativeVersionId(), afterCursorState);
        return afterCursorState;
    }

    fn _computeCursorState(cursorStateComputer: ?CursorStateComputer, inverseEditOperations: []ValidEditOperation) ?[]Selection {
        if (cursorStateComputer) |computer| {
            return computer.compute(computer.context, inverseEditOperations);
        }
        return null;
    }
};

// A callback that can compute the cursor state after applying a series of edit operations.
// A callback that can compute the resulting cursors state after some edit operations have been executed.
pub const CursorStateComputer = struct {
    context: *anyopaque,
    compute: *const fn (context: *anyopaque, inverseEditOperations: []ValidEditOperation) ?[]Selection,
};

const UndoRedoDelegate = struct {
    prepareUndoRedo: *const fn (self: *UndoRedoDelegate, element: *const MultiModelEditStackElement) ?Disposable,
};

fn lessThanTextChangeWithIndex(_: void, a: Pair(*TextChange, usize), b: Pair(*TextChange, usize)) bool {
    if (a.first.oldPosition == b.first.oldPosition) {
        return a.second - b.second < 0;
    }
    return a.first.oldPosition - b.first.oldPosition < 0;
}
