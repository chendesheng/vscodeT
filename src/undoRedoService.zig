const std = @import("std");
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const UndoRedoElement = @import("undoRedo.zig").UndoRedoElement;
const UndoRedoGroup = @import("undoRedo.zig").UndoRedoGroup;
const UndoRedoSource = @import("undoRedo.zig").UndoRedoSource;

pub const UndoRedoService = struct {
    pub fn init() UndoRedoService {
        return UndoRedoService{};
    }

    pub fn pushElement(self: *UndoRedoService, element: UndoRedoElement, group: UndoRedoGroup, source: UndoRedoSource) void {
        _ = self;
        _ = element;
        _ = group;
        _ = source;
    }

    pub fn getLastElement(self: *UndoRedoService) UndoRedoElement {
        _ = self;
        return UndoRedoElement.None;
    }

    pub fn removeElements(self: *UndoRedoService, uri: Uri) void {
        _ = self;
        _ = uri;
    }
};
