const std = @import("std");
const io = std.io;
const String = @import("../basics/strings.zig").String;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;
const UriHashMap = @import("model.zig").UriHashMap;
const TextModel = @import("textModel.zig").TextModel;
const UndoRedoService = @import("undoRedoService.zig").UndoRedoService;
const Selection = @import("../basics/selection.zig").Selection;
const EOL = @import("../basics/eolCounter.zig").EOL;
const TextChange = @import("textChange.zig").TextChange;
const compressConsecutiveTextChanges = @import("textChange.zig").compressConsecutiveTextChanges;
const UndoRedoGroup = @import("undoRedo.zig").UndoRedoGroup;
const ValidEditOperation = @import("model.zig").ValidEditOperation;
const Disposable = @import("undoRedo.zig").Disposable;
const uriToString = @import("model.zig").uriToString;
const TextModelCreationOptions = @import("model.zig").TextModelCreationOptions;
const ValidAnnotatedEditOperation = @import("model.zig").ValidAnnotatedEditOperation;
const utils = @import("../basics/utils.zig");
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

    pub fn canAppend(self: *const EditStackElement, model: *TextModel) bool {
        switch (self.*) {
            .singleModel => |*singleModel| {
                return singleModel.canAppend(model);
            },
            .multiModel => |*multiModel| {
                return multiModel.canAppend(model);
            },
        }
    }

    pub fn append(self: *EditStackElement, model: *TextModel, textChanges: []const TextChange, afterEOL: EOL, afterVersionId: u32, afterCursorState: ?[]Selection) !void {
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

pub const SingleModelEditStackDataOrSerialized = union(enum) {
    unserialized: SingleModelEditStackData,
    serialized: []const u8,

    pub fn deinit(self: *SingleModelEditStackDataOrSerialized, allocator: Allocator) void {
        switch (self.*) {
            .unserialized => |*data| data.deinit(),
            .serialized => |data| allocator.free(data),
        }
    }
};

pub const SingleModelEditStackData = struct {
    beforeVersionId: u32,
    afterVersionId: u32,
    beforeEOL: EOL,
    afterEOL: EOL,
    // FIXME: always own the cursor states??
    beforeCursorState: ?[]const Selection,
    afterCursorState: ?[]const Selection,
    changes: ArrayList(TextChange),
    _ownBeforeCursorState: bool, // Whether the beforeCursorState is freed when deinit is called
    _ownAfterCursorState: bool, // Whether the afterCursorState is freed when deinit is called

    pub fn init(allocator: Allocator, beforeVersionId: u32, afterVersionId: u32, beforeEOL: EOL, afterEOL: EOL, beforeCursorState: ?[]const Selection, afterCursorState: ?[]const Selection, changes: []const TextChange) !SingleModelEditStackData {
        var changesList = ArrayList(TextChange).init(allocator);
        try changesList.appendSlice(changes);
        return .{
            .beforeVersionId = beforeVersionId,
            .afterVersionId = afterVersionId,
            .beforeEOL = beforeEOL,
            .afterEOL = afterEOL,
            .beforeCursorState = beforeCursorState,
            .afterCursorState = afterCursorState,
            .changes = changesList,
            ._ownBeforeCursorState = false,
            ._ownAfterCursorState = false,
        };
    }

    pub fn create(allocator: Allocator, alternativeVersionId: u32, eol: EOL, beforeCursorState: ?[]const Selection) SingleModelEditStackData {
        return SingleModelEditStackData{
            .beforeVersionId = alternativeVersionId,
            .afterVersionId = alternativeVersionId,
            .beforeEOL = eol,
            .afterEOL = eol,
            .beforeCursorState = beforeCursorState,
            .afterCursorState = beforeCursorState,
            .changes = ArrayList(TextChange).init(allocator),
            ._ownBeforeCursorState = false,
            ._ownAfterCursorState = false,
        };
    }

    fn _freeBeforeCursorState(self: *SingleModelEditStackData, allocator: Allocator) void {
        if (self._ownBeforeCursorState) {
            if (self.beforeCursorState) |selections| {
                allocator.free(selections);
            }
        }
    }

    fn _freeAfterCursorState(self: *SingleModelEditStackData, allocator: Allocator) void {
        if (self._ownAfterCursorState) {
            if (self.afterCursorState) |selections| {
                allocator.free(selections);
            }
        }
    }

    pub fn deinit(self: *SingleModelEditStackData) void {
        self._freeBeforeCursorState(self.changes.allocator);
        self._freeAfterCursorState(self.changes.allocator);
        for (self.changes.items) |*change| {
            change.deinit();
        }
        self.changes.deinit();
    }

    pub fn append(self: *SingleModelEditStackData, textChanges: []const TextChange, afterEOL: EOL, afterVersionId: u32, afterCursorState: ?[]const Selection) !void {
        if (textChanges.len > 0) {
            var changes = self.changes;
            defer changes.deinit();

            self.changes = try compressConsecutiveTextChanges(self.changes.allocator, changes.items, textChanges);
        }
        self.afterEOL = afterEOL;
        self.afterVersionId = afterVersionId;

        self._freeAfterCursorState(self.changes.allocator);
        self.afterCursorState = afterCursorState;
        self._ownAfterCursorState = false;
    }

    pub fn _writeSelectionsSize(selections: ?[]const Selection) usize {
        return 4 + 4 * 4 * (if (selections) |s| s.len else 0);
    }

    pub fn _writeSelections(b: *std.Io.Writer, selections: ?[]const Selection) !void {
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

    pub fn _readSelections(b: *std.Io.Reader, allocator: Allocator) ![]const Selection {
        const count = try utils.readInt(b, u32, .big);
        const selections = try allocator.alloc(Selection, count);
        for (selections) |*selection| {
            const selectionStartLineNumber = try utils.readInt(b, u32, .big);
            const selectionStartColumn = try utils.readInt(b, u32, .big);
            const positionLineNumber = try utils.readInt(b, u32, .big);
            const positionColumn = try utils.readInt(b, u32, .big);
            selection.* = Selection.init(
                selectionStartLineNumber,
                selectionStartColumn,
                positionLineNumber,
                positionColumn,
            );
        }
        return selections;
    }

    pub fn serialize(self: *const SingleModelEditStackData) ![]const u8 {
        const allocator = self.changes.allocator;

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

        const result = try allocator.alloc(u8, necessarySize);
        var writer = std.Io.Writer.fixed(result);

        try writer.writeInt(u32, self.beforeVersionId, .big);
        try writer.writeInt(u32, self.afterVersionId, .big);
        try writer.writeInt(u8, @intFromEnum(self.beforeEOL), .big);
        try writer.writeInt(u8, @intFromEnum(self.afterEOL), .big);
        try _writeSelections(&writer, self.beforeCursorState);
        try _writeSelections(&writer, self.afterCursorState);
        try writer.writeInt(u32, @intCast(self.changes.items.len), .big);
        for (self.changes.items) |change| {
            try change.write(&writer);
        }
        return result;
    }

    pub fn deserialize(allocator: Allocator, source: []const u8) !SingleModelEditStackData {
        var reader = std.Io.Reader.fixed(source);

        const beforeVersionId = try utils.readInt(&reader, u32, .big);
        const afterVersionId = try utils.readInt(&reader, u32, .big);
        const beforeEOL: EOL = @enumFromInt(try utils.readInt(&reader, u8, .big));
        const afterEOL: EOL = @enumFromInt(try utils.readInt(&reader, u8, .big));
        const beforeCursorState = try _readSelections(&reader, allocator);
        const afterCursorState = try _readSelections(&reader, allocator);
        const changeCount = try utils.readInt(&reader, u32, .big);
        var changes = ArrayList(TextChange).init(allocator);
        for (0..changeCount) |_| {
            try TextChange.read(&reader, allocator, &changes);
        }
        return SingleModelEditStackData{
            .beforeVersionId = beforeVersionId,
            .afterVersionId = afterVersionId,
            .beforeEOL = beforeEOL,
            .afterEOL = afterEOL,
            .beforeCursorState = beforeCursorState,
            .afterCursorState = afterCursorState,
            .changes = changes,
            ._ownBeforeCursorState = true,
            ._ownAfterCursorState = true,
        };
    }
};

test "SingleModelEditStackData" {
    const allocator = std.testing.allocator;
    var data = SingleModelEditStackData.create(allocator, 1, .LF, null);
    defer data.deinit();
    try data.append(&[_]TextChange{TextChange.init(0, .initBorrowed("a"), 0, .initBorrowed("b"))}, .LF, 2, null);
    const serialized = try data.serialize();
    defer allocator.free(serialized);
    var deserialized = try SingleModelEditStackData.deserialize(allocator, serialized);
    defer deserialized.deinit();
    defer {
        for (deserialized.changes.items) |*ch| {
            ch.deinit();
        }
    }
    try std.testing.expect(deserialized.changes.items[0].oldText.eql(.initBorrowed("a")));
    try std.testing.expect(deserialized.changes.items[0].newText.eql(.initBorrowed("b")));
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
    _data: SingleModelEditStackDataOrSerialized,
    label: []const u8,
    code: []const u8,
    confirmBeforeUndo: ?bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, label: []const u8, code: []const u8, model: *TextModel, beforeCursorState: ?[]Selection) SingleModelEditStackElement {
        return SingleModelEditStackElement{
            .allocator = allocator,
            .model = .{ .model = model },
            ._data = SingleModelEditStackDataOrSerialized{
                .unserialized = SingleModelEditStackData.create(
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
        self._data.deinit(self.allocator);
    }

    pub fn toString(self: *const SingleModelEditStackElement) !ArrayList(u8) {
        const allocator = self.allocator;
        var data = switch (self._data) {
            .unserialized => |data| data,
            .serialized => |data| try SingleModelEditStackData.deserialize(allocator, data),
        };
        defer {
            switch (self._data) {
                .unserialized => {},
                .serialized => data.deinit(),
            }
        }

        var result = ArrayList(u8).init(allocator);
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
            .serialized => false,
            .unserialized => true,
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
        switch (self._data) {
            .unserialized => |*dat| {
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
                const unserialized = try SingleModelEditStackData.deserialize(allocator, data);
                allocator.free(data);
                self._data = .{ .unserialized = unserialized };
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
                        defer data.deinit(self.allocator);
                        self._data = .{ .serialized = try dat.serialize() };
                    },
                    .serialized => {},
                }
                var data = try SingleModelEditStackData.deserialize(self.allocator, self._data.serialized);
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
                        defer data.deinit(self.allocator);
                        self._data = .{ .serialized = try dat.serialize() };
                    },
                    .serialized => {},
                }
                var data = try SingleModelEditStackData.deserialize(self.allocator, self._data.serialized);
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
    var source = std.Io.Reader.fixed(text);

    var undoRedoService = UndoRedoService.init(allocator);
    defer undoRedoService.deinit();

    var textModel = try TextModel.init(allocator, &source, TextModelCreationOptions{
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
    }, null, &undoRedoService);
    defer allocator.destroy(textModel);
    defer textModel.deinit();

    var element = SingleModelEditStackElement.init(allocator, "test", "test", textModel, &[_]Selection{});
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

    pub fn append(self: *MultiModelEditStackElement, model: *TextModel, textChanges: []const TextChange, afterEOL: EOL, afterVersionId: u32, afterCursorState: ?[]Selection) !void {
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
        var result = ArrayList(u8).init(allocator);
        try result.append('{');
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
        try result.append('}');
        return result;
    }

    pub fn resource(self: *const MultiModelEditStackElement) Uri {
        return self._editStackElementsArr.items[0].resource();
    }
};

pub const EditStack = struct {
    _model: *TextModel,
    _undoRedoService: *UndoRedoService,

    pub fn init(model: *TextModel, undoRedoService: *UndoRedoService) EditStack {
        return EditStack{
            ._model = model,
            ._undoRedoService = undoRedoService,
        };
    }

    pub fn pushStackElement(self: *EditStack) void {
        if (self._undoRedoService.getLastElement(self._model.uri())) |lastElement| {
            lastElement.close();
        }
    }

    pub fn popStackElement(self: *EditStack) EditStackElement {
        if (self._undoRedoService.getLastElement(self._model.uri())) |lastElement| {
            lastElement.open();
        }
    }

    pub fn clear(self: *EditStack) !void {
        try self._undoRedoService.removeElements(self._model.uri());
    }

    fn _getOrCreateEditStackElement(self: *EditStack, beforeCursorState: ?[]Selection, group: ?UndoRedoGroup) !*EditStackElement {
        if (try self._undoRedoService.getLastElement(self._model.uri())) |lastElement| {
            if (lastElement.canAppend(self._model)) {
                return lastElement;
            }
        }
        const allocator = self._model.getAllocator();
        const newElement = SingleModelEditStackElement.init(allocator, "Typing", "undoredo.textBufferEdit", self._model, beforeCursorState);
        const newEditStackElement = try allocator.create(EditStackElement);
        newEditStackElement.* = EditStackElement{ .singleModel = newElement };
        try self._undoRedoService.pushElement(newEditStackElement, group, null);
        return newEditStackElement;
    }

    pub fn pushEOL(self: *EditStack, eol: EOL) void {
        const editStackElement = self._getOrCreateEditStackElement(null, null);
        self._model.setEOL(eol);
        editStackElement.append(self._model, &[_]TextChange{}, eol, self._model.getVersionId(), null);
    }

    pub fn pushEditOperation(self: *EditStack, beforeCursorState: ?[]Selection, editOperations: []ValidAnnotatedEditOperation, cursorStateComputer: ?*CursorStateComputer, group: ?UndoRedoGroup) !?[]Selection {
        var editStackElement = try self._getOrCreateEditStackElement(beforeCursorState, group);
        const inverseEditOperations = (try self._model.applyValidatedEdits(editOperations, true)).?;
        defer inverseEditOperations.deinit();
        const afterCursorState = EditStack._computeCursorState(cursorStateComputer, inverseEditOperations.items);

        var textChanges = ArrayList(TextChange).init(self._model.getAllocator());
        for (inverseEditOperations.items) |*op| {
            try textChanges.append(op.textChange);
        }
        defer textChanges.deinit();
        std.sort.block(TextChange, textChanges.items, {}, textChangeLessThan);

        try editStackElement.append(self._model, textChanges.items, self._model.getEOL(), self._model.getAlternativeVersionId(), afterCursorState);
        return afterCursorState;
    }

    fn _computeCursorState(cursorStateComputer: ?*CursorStateComputer, inverseEditOperations: []ValidEditOperation) ?[]Selection {
        if (cursorStateComputer) |computer| {
            return computer(inverseEditOperations);
        }
        return null;
    }
};

// A callback that can compute the cursor state after applying a series of edit operations.
// A callback that can compute the resulting cursors state after some edit operations have been executed.
pub const CursorStateComputer = fn (inverseEditOperations: []ValidEditOperation) ?[]Selection;

const UndoRedoDelegate = struct {
    prepareUndoRedo: *const fn (self: *UndoRedoDelegate, element: *const MultiModelEditStackElement) ?Disposable,
};

fn textChangeLessThan(_: void, a: TextChange, b: TextChange) bool {
    return a.oldPosition - b.oldPosition < 0;
}
