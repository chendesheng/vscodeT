const std = @import("std");
const io = std.io;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;
const UriHashMap = @import("model.zig").UriHashMap;
const TextModel = @import("textModel.zig").TextModel;
const UndoRedoService = @import("undoRedoService.zig").UndoRedoService;
const Selection = @import("selection.zig").Selection;
const EOL = @import("model.zig").EOL;
const TextChange = @import("textChange.zig").TextChange;
const compressConsecutiveTextChanges = @import("textChange.zig").compressConsecutiveTextChanges;
const UndoRedoGroup = @import("undoRedo.zig").UndoRedoGroup;
const SingleEditOperation = @import("editOperation.zig").SingleEditOperation;
const ValidEditOperation = @import("model.zig").ValidEditOperation;
const Disposable = @import("undoRedo.zig").Disposable;
const uriToString = @import("model.zig").uriToString;

pub const EditStackElement = union(enum) {
    singleModel: SingleModelEditStackElement,
    multiModel: MultiModelEditStackElement,

    pub fn close(self: *EditStackElement) !void {
        switch (self.*) {
            .singleModel => |singleModel| {
                try singleModel.close();
            },
            .multiModel => |multiModel| {
                multiModel.close();
            },
        }
    }

    pub fn open(self: *EditStackElement) void {
        switch (self.*) {
            .singleModel => |singleModel| {
                singleModel.open();
            },
            .multiModel => {},
        }
    }

    pub fn canAppend(self: *EditStackElement, model: TextModel) bool {
        switch (self.*) {
            .singleModel => |singleModel| {
                return singleModel.canAppend(model);
            },
            .multiModel => |multiModel| {
                return multiModel.canAppend(model);
            },
        }
    }

    pub fn append(self: *EditStackElement, model: TextModel, textChanges: []TextChange, afterEOL: EOL, afterVersionId: i64, afterCursorState: ?[]Selection) void {
        switch (self.*) {
            .singleModel => |singleModel| {
                singleModel.append(model, textChanges, afterEOL, afterVersionId, afterCursorState);
            },
            .multiModel => |multiModel| {
                multiModel.append(model, textChanges, afterEOL, afterVersionId, afterCursorState);
            },
        }
    }

    pub fn setModel(self: *EditStackElement, model: TextModelOrUri) void {
        switch (self.*) {
            .singleModel => |singleModel| {
                singleModel.setModel(model);
            },
            .multiModel => |multiModel| {
                multiModel.setModel(model);
            },
        }
    }

    pub fn undo(self: *EditStackElement) void {
        switch (self.*) {
            .singleModel => |singleModel| {
                singleModel.undo();
            },
            .multiModel => |multiModel| {
                multiModel.undo();
            },
        }
    }

    pub fn redo(self: *EditStackElement) void {
        switch (self.*) {
            .singleModel => |singleModel| {
                singleModel.redo();
            },
            .multiModel => |multiModel| {
                multiModel.redo();
            },
        }
    }

    pub fn toString(self: *EditStackElement) !ArrayList(u8) {
        switch (self.*) {
            .singleModel => |singleModel| {
                return try singleModel.toString();
            },
            .multiModel => |multiModel| {
                return try multiModel.toString();
            },
        }
    }
};

pub const SingleModelEditStackData = union(enum) {
    unserialized: SingleModelEditStackDataUnserialized,
    serialized: []const u8,
};

pub const SingleModelEditStackDataUnserialized = struct {
    beforeVersionId: i64,
    afterVersionId: i64,
    beforeEOL: EOL,
    afterEOL: EOL,
    beforeCursorState: ?[]Selection,
    afterCursorState: ?[]Selection,
    changes: ArrayList(TextChange),

    pub fn create(model: TextModel, beforeCursorState: ?[]Selection) SingleModelEditStackDataUnserialized {
        const alternativeVersionId = model.getAlternativeVersionId();
        const eol = model.getEOL();
        return SingleModelEditStackDataUnserialized{
            .model = model,
            .beforeVersionId = alternativeVersionId,
            .afterVersionId = alternativeVersionId,
            .beforeEOL = eol,
            .afterEOL = eol,
            .beforeCursorState = beforeCursorState,
            .afterCursorState = beforeCursorState,
            .changes = ArrayList(TextChange).init(model.getAllocator()),
        };
    }

    pub fn deinit(self: *SingleModelEditStackDataUnserialized) void {
        self.changes.deinit();
    }

    pub fn append(self: *SingleModelEditStackDataUnserialized, model: TextModel, textChanges: []TextChange, afterEOL: EOL, afterVersionId: i64, afterCursorState: ?[]Selection) !void {
        _ = model;

        if (textChanges.len > 0) {
            self.changes = try compressConsecutiveTextChanges(self.changes.allocator, self.changes.items, textChanges);
        }
        self.afterEOL = afterEOL;
        self.afterVersionId = afterVersionId;
        self.afterCursorState = afterCursorState;
    }

    pub fn _writeSelectionsSize(selections: ?[]const Selection) usize {
        return 4 + 4 * 4 * (if (selections) |s| s.len else 0);
    }

    pub fn _writeSelections(b: io.AnyWriter, selections: ?[]Selection) !void {
        try b.writeInt(u32, if (selections) |s| s.len else 0, .big);
        if (selections) |s| {
            for (s) |selection| {
                try b.writeInt(u32, selection.selectionStartLineNumber, .big);
                try b.writeInt(u32, selection.selectionStartColumn, .big);
                try b.writeInt(u32, selection.positionLineNumber, .big);
                try b.writeInt(u32, selection.positionColumn, .big);
            }
        }
    }

    pub fn _readSelections(b: io.AnyReader, dest: *ArrayList(Selection)) !void {
        const count = try b.readInt(u32, .big);
        for (0..count) |_| {
            const selectionStartLineNumber = try b.readInt(u32, .big);
            const selectionStartColumn = try b.readInt(u32, .big);
            const positionLineNumber = try b.readInt(u32, .big);
            const positionColumn = try b.readInt(u32, .big);
            try dest.append(Selection{
                .selectionStartLineNumber = selectionStartLineNumber,
                .selectionStartColumn = selectionStartColumn,
                .positionLineNumber = positionLineNumber,
                .positionColumn = positionColumn,
            });
        }
    }

    pub fn serialize(self: *const SingleModelEditStackDataUnserialized) ![]const u8 {
        var necessarySize: usize = (4 // beforeVersionId
            + 4 // afterVersionId
            + 1 // beforeEOL
            + 1 // afterEOL
            + _writeSelectionsSize(self.beforeCursorState) + _writeSelectionsSize(self.afterCursorState) + 4 // change count
        );
        for (self.changes.items) |change| {
            necessarySize += change.writeSize();
        }

        const b = try self.changes.allocator.alloc(u8, necessarySize);
        const stream = io.fixedBufferStream(b);
        const writer = stream.writer().any();

        try writer.writeInt(u32, self.beforeVersionId, .big);
        try writer.writeInt(u32, self.afterVersionId, .big);
        try writer.writeInt(u8, self.beforeEOL, .big);
        try writer.writeInt(u8, self.afterEOL, .big);
        try _writeSelections(writer, self.beforeCursorState);
        try _writeSelections(writer, self.afterCursorState);
        try writer.writeInt(u32, self.changes.len, .big);
        for (self.changes.items) |change| {
            try change.write(writer);
        }
        return b;
    }

    pub fn deserialize(allocator: Allocator, source: []const u8) !SingleModelEditStackDataUnserialized {
        const stream = io.fixedBufferStream(source);
        const reader = stream.reader().any();

        const beforeVersionId = try reader.readInt(u32, .big);
        const afterVersionId = try reader.readInt(u32, .big);
        const beforeEOL = try reader.readInt(u8, .big);
        const afterEOL = try reader.readInt(u8, .big);
        const beforeCursorState = ArrayList(Selection).init(allocator);
        try _readSelections(reader, &beforeCursorState);
        const afterCursorState = ArrayList(Selection).init(allocator);
        try _readSelections(reader, &afterCursorState);
        const changeCount = try reader.readInt(u32, .big);
        const changes = ArrayList(TextChange).init(allocator);
        for (0..changeCount) |_| {
            try TextChange.read(reader, changes);
        }
        return SingleModelEditStackDataUnserialized{
            beforeVersionId,
            afterVersionId,
            beforeEOL,
            afterEOL,
            beforeCursorState,
            afterCursorState,
            changes.items,
        };
    }
};

const TextModelOrUri = union(enum) {
    model: TextModel,
    uri: Uri,

    pub fn getUri(self: *TextModelOrUri) Uri {
        switch (self.*) {
            .model => |model| return model.uri(),
            .uri => |uri| return uri,
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

    pub fn init(allocator: Allocator, label: []const u8, code: []const u8, model: TextModelOrUri, beforeCursorState: []Selection) SingleModelEditStackElement {
        return SingleModelEditStackElement{
            .allocator = allocator,
            .model = model,
            ._data = SingleModelEditStackData{ .unserialized = SingleModelEditStackDataUnserialized.create(model, beforeCursorState) },
            .label = label,
            .code = code,
            .confirmBeforeUndo = null,
        };
    }

    pub fn toString(self: *const SingleModelEditStackElement) !ArrayList(u8) {
        const allocator = self.allocator;
        const data = switch (self._data) {
            .unserialized => |data| data,
            .serialized => |data| try SingleModelEditStackDataUnserialized.deserialize(allocator, data),
        };
        defer {
            switch (self._data) {
                .unserialized => {},
                .serialized => data.deinit(),
            }
        }

        var result = std.ArrayList(u8).init(allocator);
        for (data.changes.items) |change| {
            try result.appendSlice(try change.toString(allocator));
            try result.appendSlice(", ");
        }
        return result;
    }

    pub fn matchesResource(self: *const SingleModelEditStackElement, res: Uri) bool {
        // TODO
        _ = self;
        _ = res;
        return false;
    }

    pub fn setModel(self: *SingleModelEditStackElement, model: TextModelOrUri) void {
        self.model = model;
    }

    pub fn resource(self: *const SingleModelEditStackElement) Uri {
        return self.model.getUri();
    }

    pub fn canAppend(self: *const SingleModelEditStackElement, model: TextModel) bool {
        return self.model == model and switch (self._data) {
            .serialized => true,
            .unserialized => false,
        };
    }

    pub fn append(self: *SingleModelEditStackElement, model: TextModel, textChanges: []TextChange, afterEOL: EOL, afterVersionId: i64, afterCursorState: ?[]Selection) !void {
        switch (self._data) {
            .unserialized => |dat| {
                try dat.append(model, textChanges, afterEOL, afterVersionId, afterCursorState);
            },
            .serialized => {},
        }
    }

    pub fn close(self: *SingleModelEditStackElement) !void {
        switch (self._data) {
            .unserialized => |dat| {
                defer dat.deinit();
                self._data = .{ .unserialized = try dat.serialize() };
            },
            .serialized => {},
        }
    }

    pub fn open(self: *SingleModelEditStackElement) void {
        switch (self._data) {
            .serialized => |data| {
                const allocator = self.allocator;
                self._data = try SingleModelEditStackDataUnserialized.deserialize(allocator, data);
                allocator.free(data);
            },
            .unserialized => {},
        }
    }

    pub fn undo(self: *SingleModelEditStackElement) void {
        switch (self._data) {
            .unserialized => |dat| {
                self._data = .{ .serialized = try dat.serialize() };
                dat.deinit();
            },
        }
        const data = try SingleModelEditStackDataUnserialized.deserialize(self.allocator, self._data.serialized);
        defer data.deinit();
        self.model._applyUndo(data.changes, data.beforeEOL, data.beforeVersionId, data.beforeCursorState);
    }

    pub fn redo(self: *SingleModelEditStackElement) void {
        switch (self._data) {
            .unserialized => |dat| {
                self._data = .{ .serialized = try dat.serialize() };
                dat.deinit();
            },
        }
        const data = try SingleModelEditStackDataUnserialized.deserialize(self.allocator, self._data.serialized);
        defer data.deinit();
        self.model._applyRedo(data.changes, data.afterEOL, data.afterVersionId, data.afterCursorState);
    }

    pub fn heapSize(self: *const SingleModelEditStackElement) usize {
        switch (self._data) {
            .unserialized => |dat| {
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
        self._editStackElementsArr.deinit();
        self._editStackElementsMap.deinit();
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

    pub fn resources(self: *MultiModelEditStackElement) !ArrayList(Uri) {
        var result = ArrayList(Uri).init(self.allocator);
        var iter = self._editStackElementsMap.valueIterator();
        while (iter.next()) |item| {
            try result.append(item.resource());
        }
        return result;
    }

    pub fn matchesResource(self: *MultiModelEditStackElement, resource: Uri) bool {
        return self._editStackElementsMap.contains(resource);
    }

    pub fn setModel(self: *MultiModelEditStackElement, model: TextModelOrUri) void {
        const key = model.getUri();
        if (self._editStackElementsMap.contains(key)) {
            self._editStackElementsMap.get(key).?.setModel(model);
        }
    }

    pub fn canAppend(self: *MultiModelEditStackElement, model: TextModel) bool {
        if (!self._isOpen) {
            return false;
        }
        if (self._editStackElementsMap.get(model.uri())) |editStackElement| {
            return editStackElement.canAppend(model);
        }
        return false;
    }

    pub fn append(self: *MultiModelEditStackElement, model: TextModel, textChanges: []TextChange, afterEOL: EOL, afterVersionId: i64, afterCursorState: ?[]Selection) void {
        const editStackElement = self._editStackElementsMap.get(model.uri()) orelse return;
        editStackElement.append(model, textChanges, afterEOL, afterVersionId, afterCursorState);
    }

    pub fn close(self: *MultiModelEditStackElement) void {
        self._isOpen = false;
    }

    pub fn undo(self: *MultiModelEditStackElement) void {
        self._isOpen = false;

        for (self._editStackElementsArr.items) |editStackElement| {
            editStackElement.undo();
        }
    }

    pub fn redo(self: *MultiModelEditStackElement) void {
        for (self._editStackElementsArr.items) |editStackElement| {
            editStackElement.redo();
        }
    }

    pub fn heapSize(self: *const MultiModelEditStackElement, resource: Uri) usize {
        if (self._editStackElementsMap.get(resource)) |item| {
            return item.heapSize();
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
            defer allocator.free(url);

            try result.appendSlice(url);
            try result.appendSlice(": ");
            try result.appendSlice(s.items);

            if (index < self._editStackElementsArr.items.len - 1) {
                try result.appendSlice(", ");
            }
        }
        result.append('}');
        return result;
    }
};

pub const EditStack = struct {
    _model: TextModel,
    _undoRedoService: UndoRedoService,

    pub fn init(model: TextModel, undoRedoService: UndoRedoService) EditStack {
        return EditStack{
            ._model = model,
            ._undoRedoService = undoRedoService,
        };
    }

    pub fn pushStackElement(self: *EditStack) void {
        const lastElement = self._undoRedoService.getLastElement(self._model.uri());
        lastElement.close();
    }

    pub fn popStackElement(self: *EditStack) EditStackElement {
        const lastElement = self._undoRedoService.getLastElement(self._model.uri());
        lastElement.open();
    }

    pub fn clear(self: *EditStack) void {
        self._undoRedoService.removeElements(self._model.uri());
    }

    fn _getOrCreateEditStackElement(self: *EditStack, beforeCursorState: ?[]Selection, group: ?UndoRedoGroup) EditStackElement {
        const lastElement = self._undoRedoService.getLastElement(self._model.uri());
        if (lastElement.canAppend(self._model)) {
            return lastElement;
        }
        const newElement = SingleModelEditStackElement.init("Typing", "undoredo.textBufferEdit", self._model, beforeCursorState);
        self._undoRedoService.pushElement(newElement, group);
        return newElement;
    }

    pub fn pushEOL(self: *EditStack, eol: EOL) void {
        const editStackElement = self._getOrCreateEditStackElement(null, null);
        self._model.setEOL(eol);
        editStackElement.append(self._model, &[_]TextChange{}, eol, self._model.getVersionId(), null);
    }

    pub fn pushEditOperation(self: *EditStack, beforeCursorState: ?[]Selection, editOperations: []SingleEditOperation, cursorStateComputer: ?[]Selection, group: ?UndoRedoGroup) ?[]Selection {
        const editStackElement = self._getOrCreateEditStackElement(beforeCursorState, group);
        const inverseEditOperations = self._model.applyEdits(editOperations, true);
        const afterCursorState = EditStack._computeCursorState(cursorStateComputer, inverseEditOperations);

        var textChangesWithIndex = ArrayList(struct { textChange: TextChange, index: usize }).init(self._model.getAllocator());
        defer textChangesWithIndex.deinit();
        for (inverseEditOperations, 0..) |op, index| {
            try textChangesWithIndex.append(.{ .textChange = op.textChange, .index = index });
        }
        std.sort.heap(struct { textChange: TextChange, index: usize }, textChangesWithIndex.items, {}, compareTextChangeWithIndex);

        var textChanges = ArrayList(TextChange).init(self._model.getAllocator());
        defer textChanges.deinit();
        for (textChangesWithIndex.items) |item| {
            try textChanges.append(item.textChange);
        }
        try editStackElement.append(self._model, textChanges.items, self._model.getEOL(), self._model.getAlternativeVersionId(), afterCursorState);
        return afterCursorState;
    }

    fn _computeCursorState(cursorStateComputer: ?CursorStateComputer, inverseEditOperations: []ValidEditOperation) ?[]Selection {
        if (cursorStateComputer) |computer| {
            return computer(inverseEditOperations);
        }
        return null;
    }
};

// A callback that can compute the cursor state after applying a series of edit operations.
// A callback that can compute the resulting cursors state after some edit operations have been executed.
const CursorStateComputer = fn (inverseEditOperations: []ValidEditOperation) ?[]Selection;

const UndoRedoDelegate = struct {
    prepareUndoRedo: fn (self: *UndoRedoDelegate, element: *const MultiModelEditStackElement) ?Disposable,
};

fn compareTextChangeWithIndex(a: struct { textChange: TextChange, index: usize }, b: struct { textChange: TextChange, index: usize }) bool {
    if (a.textChange.oldPosition == b.textChange.oldPosition) {
        return a.index - b.index < 0;
    }
    return a.textChange.oldPosition - b.textChange.oldPosition < 0;
}
