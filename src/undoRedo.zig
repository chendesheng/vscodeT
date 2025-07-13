const std = @import("std");
const Uri = std.Uri;

pub const UndoRedo = struct {
    pub fn init() UndoRedo {
        return UndoRedo{};
    }
};

pub const UndoRedoElement = union(enum) {
    Resource: ResourceUndoRedoElement,
    Workspace: WorkspaceUndoRedoElement,

    pub fn confirmBeforeUndo(self: *UndoRedoElement) ?bool {
        return switch (self.*) {
            .Resource => |resource| resource.confirmBeforeUndo,
            .Workspace => |workspace| workspace.confirmBeforeUndo,
        };
    }
};

pub const ResourceUndoRedoElement = struct {
    // The resource impacted by this element.
    resource: Uri,
    // A user presentable label. May be localized.
    label: []const u8,
    // A code describing the operation. Will not be localized.
    code: []const u8,
    // Show a message to the user confirming when trying to undo this element
    confirmBeforeUndo: ?bool,
};

pub const WorkspaceUndoRedoElement = struct {
    // The resources impacted by this element.
    resources: []const Uri,
    // A user presentable label. May be localized.
    label: []const u8,
    // A code describing the operation. Will not be localized.
    code: []const u8,
    // Show a message to the user confirming when trying to undo this element
    confirmBeforeUndo: ?bool,
};

pub const ResourceEditStackSnapshot = struct {
    resource: Uri,
    elements: []const u64,
};

pub const UndoRedoGroup = struct {
    var _ID: u64 = 0;

    id: u64,
    order: u64,

    pub fn init() UndoRedoGroup {
        const group = UndoRedoGroup{
            .id = _ID,
            .order = 1,
        };
        _ID += 1;
        return group;
    }

    pub fn nextOrder(self: *UndoRedoGroup) u64 {
        if (self.id == 0) {
            return 0;
        }
        self.order += 1;
        return self.order;
    }

    pub const None = UndoRedoGroup.init();
};

pub const PastFutureElements = struct {
    past: []const UndoRedoElement,
    future: []const UndoRedoElement,
};

pub const UndoRedoSource = struct {
    var _ID: u64 = 0;

    id: u64,
    order: u64,

    pub fn init() UndoRedoSource {
        const source = UndoRedoSource{
            .id = _ID,
            .order = 1,
        };
        _ID += 1;
        return source;
    }

    pub fn nextOrder(self: *UndoRedoSource) u64 {
        if (self.id == 0) {
            return 0;
        }
        self.order += 1;
        return self.order;
    }

    pub const None = UndoRedoSource.init();
};

const UriComparisonKeyComputer = struct {
    getComparisonKey: *const fn (self: *const UriComparisonKeyComputer, uri: Uri) []const u8,

    pub fn eql(self: *const UriComparisonKeyComputer, other: *const UriComparisonKeyComputer) bool {
        return self.getComparisonKey == other.getComparisonKey;
    }
};

const Disposable = struct {
    dispose: *const fn (self: *Disposable) void,
};
