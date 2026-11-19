const std = @import("std");
const ArrayList = std.array_list.Managed;
const Uri = std.Uri;
const EditStackElement = @import("../../../editor/common/model/editStack.zig").EditStackElement;

pub const ResourceEditStackSnapshot = struct {
    resource: Uri,
    elements: ArrayList(u64),

    pub fn deinit(self: *ResourceEditStackSnapshot) void {
        self.elements.deinit();
    }
};

pub const UndoRedoGroup = struct {
    var _ID: u64 = 1;

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
        defer {
            self.order += 1;
        }
        return self.order;
    }

    pub const None = UndoRedoGroup{ .id = 0, .order = 0 };
};

pub const PastFutureElements = struct {
    past: []const *const EditStackElement,
    future: []const *const EditStackElement,

    pub fn deinit(self: *PastFutureElements, allocator: std.mem.Allocator) void {
        allocator.free(self.past);
        allocator.free(self.future);
    }
};

pub const UndoRedoSource = struct {
    var _ID: u64 = 1;

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
        const order = self.order;
        defer {
            self.order += 1;
        }
        return order;
    }

    pub const None = UndoRedoSource{ .id = 0, .order = 0 };
};

pub const UndoRedoSourceOrUri = union(enum) {
    source: UndoRedoSource,
    uri: Uri,
    str: []const u8,
};

pub const UriComparisonKeyComputer = struct {
    getComparisonKey: *const fn (self: *const UriComparisonKeyComputer, uri: Uri) []const u8,

    pub fn eql(self: *const UriComparisonKeyComputer, other: *const UriComparisonKeyComputer) bool {
        return self.getComparisonKey == other.getComparisonKey;
    }
};

pub const Disposable = struct {
    dispose: *const fn () void,
};
