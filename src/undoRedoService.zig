const std = @import("std");
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const EditStackElement = @import("editStack.zig").EditStackElement;
const UndoRedoGroup = @import("undoRedo.zig").UndoRedoGroup;
const UndoRedoSource = @import("undoRedo.zig").UndoRedoSource;
const UriContext = @import("editStack.zig").UriContext;
const PastFutureElements = @import("undoRedo.zig").PastFutureElements;
const ResourceEditStackSnapshot = @import("undoRedo.zig").ResourceEditStackSnapshot;
const UriComparisonKeyComputer = @import("undoRedo.zig").UriComparisonKeyComputer;
const Disposable = @import("undoRedo.zig").Disposable;
const uriToString = @import("model.zig").uriToString;
const UndoRedoSourceOrUri = @import("undoRedo.zig").UndoRedoSourceOrUri;
const Pair = @import("utils.zig").Pair;
const pair = @import("utils.zig").pair;
const SingleModelEditStackElement = @import("editStack.zig").SingleModelEditStackElement;
const Selection = @import("selection.zig").Selection;

const DEBUG = true;

fn getResourceLabel(resource: Uri) []const u8 {
    return resource.path;
}

var stackElementCount: u64 = 0;

const StackElement = union(enum) {
    resourceStackElement: *const ResourceStackElement,
    workspaceStackElement: *const WorkspaceStackElement,

    pub fn free(self: *StackElement, allocator: Allocator) void {
        switch (self.*) {
            .resourceStackElement => |resourceStackElement| allocator.free(resourceStackElement),
            .workspaceStackElement => |workspaceStackElement| allocator.free(workspaceStackElement),
        }
    }

    pub fn groupId(self: StackElement) u64 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.groupId,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.groupId,
        };
    }

    pub fn strResources(self: StackElement) []const []const u8 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.strResources,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.strResources,
        };
    }

    pub fn sourceId(self: StackElement) u64 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.sourceId,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.sourceId,
        };
    }

    pub fn sourceOrder(self: StackElement) u64 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.sourceOrder,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.sourceOrder,
        };
    }

    pub fn groupOrder(self: StackElement) u64 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.groupOrder,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.groupOrder,
        };
    }

    pub fn confirmBeforeUndo(self: StackElement) bool {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.confirmBeforeUndo,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.confirmBeforeUndo,
        };
    }

    pub fn actual(self: StackElement) *const EditStackElement {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.actual,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.actual,
        };
    }
};

const WorkspaceVerificationError = struct {
    returnValue: ?*anyopaque,
};

const ResourceStackElement = struct {
    id: u64,
    actual: *const EditStackElement,
    label: []const u8,
    confirmBeforeUndo: bool,

    resourceLabel: []const u8,
    strResource: []const u8,
    resourceLabels: []const []const u8,
    strResources: []const []const u8,
    groupId: u64,
    groupOrder: u64,
    sourceId: u64,
    sourceOrder: u64,
    isValid: bool,

    pub fn init(actual: *const EditStackElement, resourceLabel: []const u8, strResource: []const u8, groupId: u64, groupOrder: u64, sourceId: u64, sourceOrder: u64) ResourceStackElement {
        stackElementCount += 1;
        return ResourceStackElement{
            .id = stackElementCount,
            .actual = actual,
            .label = actual.label,
            .confirmBeforeUndo = actual.confirmBeforeUndo() orelse false,
            .resourceLabel = resourceLabel,
            .strResource = strResource,
            .resourceLabels = &[_][]const u8{resourceLabel},
            .strResources = &[_][]const u8{strResource},
            .groupId = groupId,
            .groupOrder = groupOrder,
            .sourceId = sourceId,
            .sourceOrder = sourceOrder,
            .isValid = true,
        };
    }

    pub fn setValid(self: *ResourceStackElement, isValid: bool) void {
        self.isValid = isValid;
    }

    pub fn toString(self: *const ResourceStackElement) ![]const u8 {
        var buf: [1024]u8 = undefined;
        return try std.fmt.bufPrint(&buf, "[id:{}][group:{}] [{}]{}", .{ self.id, self.groupId, if (self.isValid) "  VALID" else "INVALID", self.actual });
    }
};

const RemovedResourceReason = enum {
    ExternalRemoval,
    NoParallelUniverses,
};

const ResourceReasonPair = struct {
    resourceLabel: []const u8,
    reason: RemovedResourceReason,
};

const RemovedResources = struct {
    elements: std.StringHashMap(ResourceReasonPair),

    pub fn createMessage(self: *RemovedResources, allocator: Allocator) ![]const u8 {
        var externalRemoval = ArrayList([]const u8).init(allocator);
        defer externalRemoval.deinit();

        var noParallelUniverses = ArrayList([]const u8).init(allocator);
        defer noParallelUniverses.deinit();

        var iter = self.elements.valueIterator();
        while (iter.next()) |element| {
            var dest = if (element.reason == RemovedResourceReason.ExternalRemoval) &externalRemoval else &noParallelUniverses;
            try dest.append(element.resourceLabel);
        }

        var messages = ArrayList(u8).init(allocator);
        if (externalRemoval.items.len > 0) {
            const removal = try std.mem.join(allocator, ", ", externalRemoval.items);
            messages.append(try std.fmt.allocPrint(allocator, "The following files have been closed and modified on disk: {0}.\n", .{removal}));
        }
        if (noParallelUniverses.items.len > 0) {
            const noParallel = try std.mem.join(allocator, ", ", noParallelUniverses.items);
            messages.append(try std.fmt.allocPrint(allocator, "The following files have been modified in an incompatible way: {0}.\n", .{noParallel}));
        }
        return messages.toOwnedSlice();
    }

    pub fn size(self: *RemovedResources) usize {
        return self.elements.count();
    }

    pub fn has(self: *RemovedResources, strResource: []const u8) bool {
        return self.elements.contains(strResource);
    }

    pub fn set(self: *RemovedResources, strResource: []const u8, value: ResourceReasonPair) !void {
        try self.elements.put(strResource, value);
    }

    pub fn delete(self: *RemovedResources, strResource: []const u8) bool {
        return self.elements.remove(strResource);
    }
};

const WorkspaceStackElement = struct {
    id: u64,
    actual: EditStackElement,
    label: []const u8,
    confirmBeforeUndo: bool,

    resourceLabels: []const []const u8,
    strResources: []const []const u8,
    groupId: u64,
    groupOrder: u64,
    sourceId: u64,
    sourceOrder: u64,
    removedResources: ?RemovedResources,
    invalidatedResources: ?RemovedResources,

    pub fn init(actual: EditStackElement, resourceLabels: []const []const u8, strResources: []const []const u8, groupId: u64, groupOrder: u64, sourceId: u64, sourceOrder: u64) WorkspaceStackElement {
        stackElementCount += 1;
        return WorkspaceStackElement{
            .id = stackElementCount,
            .actual = actual,
            .label = actual.label,
            .confirmBeforeUndo = actual.confirmBeforeUndo() orelse false,
            .resourceLabels = resourceLabels,
            .strResources = strResources,
            .groupId = groupId,
            .groupOrder = groupOrder,
            .sourceId = sourceId,
            .sourceOrder = sourceOrder,
            .removedResources = null,
            .invalidatedResources = null,
        };
    }

    pub fn canSplit(self: *const WorkspaceStackElement) bool {
        return switch (self.actual) {
            .Resource => false,
            .Workspace => true,
        };
    }

    pub fn removeResource(self: *WorkspaceStackElement, resourceLabel: []const u8, strResource: []const u8, reason: RemovedResourceReason) void {
        if (self.removedResources) |removedResources| {
            removedResources.set(strResource, ResourceReasonPair{ .resourceLabel = resourceLabel, .reason = reason });
        } else {
            self.removedResources = RemovedResources{ .elements = std.StringHashMap(ResourceReasonPair).init(self.getAllocator()) };
        }
        if (self.removedResources) |removedResources| {
            if (!removedResources.has(strResource)) {
                removedResources.set(strResource, ResourceReasonPair{ .resourceLabel = resourceLabel, .reason = reason });
            }
        }
    }

    pub fn setValid(self: *WorkspaceStackElement, resourceLabel: []const u8, strResource: []const u8, isValid: bool) void {
        if (isValid) {
            if (self.invalidatedResources) |invalidatedResources| {
                invalidatedResources.delete(strResource);
                if (invalidatedResources.size() == 0) {
                    self.invalidatedResources = null;
                }
            }
        } else {
            if (self.invalidatedResources) |invalidatedResources| {
                invalidatedResources.delete(strResource);
                if (invalidatedResources.size() == 0) {
                    self.invalidatedResources = null;
                }
            } else {
                self.invalidatedResources = RemovedResources{ .elements = std.HashMap(Uri, ResourceReasonPair, UriContext, 0.5).init(self.getAllocator()) };
            }
            if (self.invalidatedResources) |invalidatedResources| {
                if (!invalidatedResources.has(strResource)) {
                    invalidatedResources.set(strResource, ResourceReasonPair{ .resourceLabel = resourceLabel, .reason = RemovedResourceReason.ExternalRemoval });
                }
            }
        }
    }

    pub fn toString(self: *const WorkspaceStackElement) []const u8 {
        var buf: [1024]u8 = undefined;
        return try std.fmt.bufPrint(&buf, "[id:{}] [group:{}] [{}]{}", .{ self.id, self.groupId, if (self.invalidatedResources) |_| "INVALID" else "  VALID", self.actual });
    }
};

// test "WorkspaceStackElement" {
//     const allocator = std.testing.allocator;
//     const workspaceStackElement = WorkspaceStackElement.init(
//         .{ .singleModel = &SingleModelEditStackElement.init(allocator, "test", "test", undefined, &[_]Selection{}) },
//         &[_][]const u8{"test"},
//         &[_][]const u8{"test"},
//         1,
//         1,
//         1,
//         1,
//     );
//     std.testing.expectEqualStrings("test", workspaceStackElement.label);
//     try std.testing.expectEqual(168, workspaceStackElement.actual.heapSize());
// }

var missingEditStack = ResourceEditStack.init("", "", std.heap.page_allocator);
const ResourceEditStack = struct {
    resourceLabel: []const u8,
    strResource: []const u8,
    _past: ArrayList(StackElement),
    _future: ArrayList(StackElement),
    locked: bool,
    versionId: u64,

    pub fn init(resourceLabel: []const u8, strResource: []const u8, allocator: Allocator) ResourceEditStack {
        return ResourceEditStack{
            .resourceLabel = resourceLabel,
            .strResource = strResource,
            ._past = ArrayList(StackElement).init(allocator),
            ._future = ArrayList(StackElement).init(allocator),
            .locked = false,
            .versionId = 1,
        };
    }

    fn getAllocator(self: *ResourceEditStack) Allocator {
        return self._past.allocator;
    }

    pub fn deinit(self: *ResourceEditStack) void {
        self._past.deinit();
        self._future.deinit();
    }

    pub fn dispose(self: *ResourceEditStack) void {
        for (self._past.items) |element| {
            switch (element) {
                .workspaceStackElement => |workspaceStackElement| {
                    workspaceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.ExternalRemoval);
                },
                .resourceStackElement => |resourceStackElement| {
                    resourceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.ExternalRemoval);
                },
            }
        }
        for (self._future.items) |element| {
            switch (element) {
                .workspaceStackElement => |workspaceStackElement| {
                    workspaceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.ExternalRemoval);
                },
                .resourceStackElement => |resourceStackElement| {
                    resourceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.ExternalRemoval);
                },
            }
        }
        self.versionId += 1;
    }

    pub fn toString(self: *ResourceEditStack) ![]const u8 {
        var result = ArrayList(u8).init(self.getAllocator());
        defer result.deinit();
        try result.appendSlice("* ");
        try result.appendSlice(self.strResource);
        try result.appendSlice(":\n");
        for (self._past.items) |element| {
            try result.appendSlice("   * [UNDO] ");
            try result.appendSlice(element.toString());
            try result.appendSlice("\n");
        }
        for (self._future.items) |element| {
            try result.appendSlice("   * [REDO] ");
            try result.appendSlice(element.toString());
            try result.appendSlice("\n");
        }
        return result.toOwnedSlice();
    }

    pub fn flushAllElements(self: *ResourceEditStack) void {
        self._past.clearAndFree();
        self._future.clearAndFree();
        self.versionId += 1;
    }

    pub fn setElementsIsValid(self: *ResourceEditStack, isValid: bool) void {
        for (self._past.items) |element| {
            switch (element.*) {
                .workspaceStackElement => |workspaceStackElement| {
                    workspaceStackElement.setValid(self.resourceLabel, self.strResource, isValid);
                },
                .resourceStackElement => |resourceStackElement| {
                    resourceStackElement.setValid(isValid);
                },
            }
        }
        for (self._future.items) |element| {
            switch (element.*) {
                .workspaceStackElement => |workspaceStackElement| {
                    workspaceStackElement.setValid(self.resourceLabel, self.strResource, isValid);
                },
                .resourceStackElement => |resourceStackElement| {
                    resourceStackElement.setValid(isValid);
                },
            }
        }
    }

    fn _setElementValidFlag(self: *ResourceEditStack, element: StackElement, isValid: bool) void {
        switch (element.*) {
            .workspaceStackElement => |workspaceStackElement| {
                workspaceStackElement.setValid(self.resourceLabel, self.strResource, isValid);
            },
            .resourceStackElement => |resourceStackElement| {
                resourceStackElement.setValid(isValid);
            },
        }
    }

    pub fn setElementsValidFlag(self: *ResourceEditStack, isValid: bool, filter: fn (element: EditStackElement) bool) void {
        for (self._past.items) |element| {
            if (filter(element.actual())) {
                self._setElementValidFlag(element, isValid);
            }
        }
        for (self._future.items) |element| {
            if (filter(element.actual())) {
                self._setElementValidFlag(element, isValid);
            }
        }
    }

    pub fn pushElement(self: *ResourceEditStack, element: StackElement) void {
        // remove the future
        for (self._future.items) |futureElement| {
            switch (futureElement.*) {
                .workspaceStackElement => |workspaceStackElement| {
                    workspaceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.NoParallelUniverses);
                },
                .resourceStackElement => |resourceStackElement| {
                    resourceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.NoParallelUniverses);
                },
            }
        }
        self._future.clearAndFree();
        self._past.append(element);
        self.versionId += 1;
    }

    pub fn createSnapshot(self: *ResourceEditStack, resource: Uri) ResourceEditStackSnapshot {
        var elements = ArrayList(u64).init(self.getAllocator());
        defer elements.deinit();

        for (self._past.items) |element| {
            elements.append(element.id);
        }
        for (self._future.items) |element| {
            elements.append(element.id);
        }

        return ResourceEditStackSnapshot{ .resource = resource, .elements = elements.items };
    }

    pub fn restoreSnapshot(self: *ResourceEditStack, snapshot: ResourceEditStackSnapshot) void {
        const snapshotLength = snapshot.elements.len;
        var isOK = true;
        var snapshotIndex: usize = 0;
        var removePastAfter = -1;
        var i: usize = 0;
        while (i < self._past.items.len) : (i += 1) {
            const element = self._past.items[i];
            if (isOK and (snapshotIndex >= snapshotLength or element.id != snapshot.elements[snapshotIndex])) {
                isOK = false;
                removePastAfter = 0;
            }
            switch (element.*) {
                .workspaceStackElement => |workspaceStackElement| {
                    if (!isOK) {
                        workspaceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.ExternalRemoval);
                    }
                },
                .resourceStackElement => |_| {},
            }
            snapshotIndex += 1;
        }
        var removeFutureBefore = -1;
        i = self._future.items.len - 1;
        while (i >= 0) : (i -= 1) {
            const element = self._future.items[i];
            if (isOK and (snapshotIndex >= snapshotLength or element.id != snapshot.elements[snapshotIndex])) {
                isOK = false;
                removeFutureBefore = i;
            }
            switch (element.*) {
                .workspaceStackElement => |workspaceStackElement| {
                    if (!isOK) {
                        workspaceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.ExternalRemoval);
                    }
                },
                .resourceStackElement => |_| {},
            }
            snapshotIndex += 1;
        }
        if (removePastAfter != -1) {
            self._past.items.len = removePastAfter;
        }
        if (removeFutureBefore != -1) {
            self._future.items.len = removeFutureBefore + 1;
        }
        self.versionId += 1;
    }

    pub fn getElements(self: *ResourceEditStack) PastFutureElements {
        var past = ArrayList(*const EditStackElement).init(self.getAllocator());
        defer past.deinit();
        var future = ArrayList(*const EditStackElement).init(self.getAllocator());
        defer future.deinit();

        for (self._past.items) |element| {
            past.append(element.actual());
        }
        for (self._future.items) |element| {
            future.append(element.actual());
        }

        return PastFutureElements{ .past = past.items, .future = future.items };
    }

    pub fn getClosestPastElement(self: *ResourceEditStack) ?StackElement {
        if (self._past.items.len == 0) {
            return null;
        }
        return &self._past.items[self._past.items.len - 1];
    }

    pub fn getSecondClosestPastElement(self: *ResourceEditStack) ?StackElement {
        if (self._past.items.len < 2) {
            return null;
        }
        return &self._past.items[self._past.items.len - 2];
    }

    pub fn getClosestFutureElement(self: *ResourceEditStack) ?StackElement {
        if (self._future.items.len == 0) {
            return null;
        }
        return &self._future.items[self._future.items.len - 1];
    }

    pub fn hasPastElements(self: *ResourceEditStack) bool {
        return self._past.items.len > 0;
    }

    pub fn hasFutureElements(self: *ResourceEditStack) bool {
        return self._future.items.len > 0;
    }

    pub fn splitPastWorkspaceElement(self: *ResourceEditStack, toRemove: *const WorkspaceStackElement, individualMap: *std.StringHashMap(ResourceStackElement)) void {
        var j: usize = self._past.items.len - 1;
        while (j >= 0) : (j -= 1) {
            if (self._past.items[j] == toRemove) {
                if (individualMap.get(self.strResource)) |individual| {
                    // gets replaced
                    self._past.items[j] = individual;
                } else {
                    // gets deleted
                    self._past.items.len = j;
                }
                break;
            }
        }
        self.versionId += 1;
    }

    pub fn splitFutureWorkspaceElement(self: *ResourceEditStack, toRemove: *const WorkspaceStackElement, individualMap: *std.StringHashMap(ResourceStackElement)) void {
        var j: usize = self._future.items.len - 1;
        while (j >= 0) : (j -= 1) {
            if (self._future.items[j] == toRemove) {
                if (individualMap.get(self.strResource)) |individual| {
                    // gets replaced
                    self._future.items[j] = individual;
                } else {
                    // gets deleted
                    self._future.items.len = j;
                }
                break;
            }
        }
        self.versionId += 1;
    }

    pub fn moveBackward(self: *ResourceEditStack, element: StackElement) void {
        self._past.pop();
        self._future.append(element);
        self.versionId += 1;
    }

    pub fn moveForward(self: *ResourceEditStack, element: StackElement) void {
        self._future.pop();
        self._past.append(element);
        self.versionId += 1;
    }
};

const EditStackSnapshot = struct {
    editStacks: []ResourceEditStack,
    _versionIds: ArrayList(u64),

    pub fn init(editStacks: []ResourceEditStack, allocator: Allocator) EditStackSnapshot {
        var versionIds = ArrayList(u64).init(allocator);
        for (editStacks) |editStack| {
            versionIds.append(editStack.versionId);
        }
        return EditStackSnapshot{ .editStacks = editStacks, ._versionIds = versionIds };
    }

    pub fn deinit(self: *EditStackSnapshot) void {
        self._versionIds.deinit();
    }

    pub fn isValid(self: *EditStackSnapshot) bool {
        for (self.editStacks, 0..) |editStack, i| {
            if (editStack.versionId != self._versionIds.items[i]) {
                return false;
            }
        }
        return true;
    }
};

const KeyComputerPair = struct {
    key: []const u8,
    computer: UriComparisonKeyComputer,
};

pub const UndoRedoService = struct {
    _editStacks: std.StringHashMap(ResourceEditStack),
    _uriComparisonKeyComputers: ArrayList(KeyComputerPair),

    pub fn init(allocator: Allocator) UndoRedoService {
        return UndoRedoService{
            ._editStacks = std.StringHashMap(ResourceEditStack).init(allocator),
            ._uriComparisonKeyComputers = ArrayList(KeyComputerPair).init(allocator),
        };
    }

    pub fn deinit(self: *UndoRedoService) void {
        self._editStacks.deinit();
        self._uriComparisonKeyComputers.deinit();
    }

    pub fn registerUriComparisonKeyComputer(self: *UndoRedoService, scheme: []const u8, uriComparisonKeyComputer: UriComparisonKeyComputer) !void {
        try self._uriComparisonKeyComputers.append(KeyComputerPair{ .key = scheme, .computer = uriComparisonKeyComputer });
        // return {
        // dispose: () => {
        //for (let i = 0, len = this._uriComparisonKeyComputers.length; i < len; i++) {
        //if (this._uriComparisonKeyComputers[i][1] == uriComparisonKeyComputer) {
        //this._uriComparisonKeyComputers.splice(i, 1);
        //return;
        //}
        //}
        //}
        //};
    }

    pub fn getUriComparisonKey(self: *UndoRedoService, resource: Uri) []const u8 {
        for (self._uriComparisonKeyComputers.items) |uriComparisonKeyComputer| {
            if (std.mem.eql(u8, uriComparisonKeyComputer.key, resource.scheme)) {
                return uriComparisonKeyComputer.computer.getComparisonKey(resource);
            }
        }
        return uriToString(resource, self._uriComparisonKeyComputers.allocator);
    }

    pub fn _print(self: *UndoRedoService, label: []const u8) void {
        std.debug.print("------------------------------------\n", .{});
        std.debug.print("AFTER {s}: \n", .{label});
        var str = ArrayList(u8).init(self._uriComparisonKeyComputers.allocator);
        defer str.deinit();

        try str.appendSlice("AFTER ");
        try str.appendSlice(label);
        try str.appendSlice(": ");
        var iter = self._editStacks.keyIterator();
        while (iter.next()) |key| {
            try str.appendSlice(key.*);
            try str.appendSlice("\n");
        }
        std.debug.print("{s}", .{str.items});
    }

    pub fn pushElement(self: *UndoRedoService, element: EditStackElement, group: UndoRedoGroup, source: UndoRedoSource) void {
        switch (element) {
            .resourceStackElement => |resourceStackElement| {
                const resourceLabel = getResourceLabel(resourceStackElement.resource);
                const strResource = self.getUriComparisonKey(resourceStackElement.resource);
                self._pushElement(ResourceStackElement.init(resourceStackElement, resourceLabel, strResource, group.id, group.nextOrder(), source.id, source.nextOrder()));
            },
            .workspaceStackElement => |workspaceStackElement| {
                const allocator = self._uriComparisonKeyComputers.allocator;
                var seen = std.StringHashMap(void).init(allocator);
                defer seen.deinit();
                var resourceLabels = ArrayList(Uri).init(allocator);
                defer resourceLabels.deinit();
                var strResources = ArrayList(Uri).init(allocator);
                defer strResources.deinit();
                for (workspaceStackElement.resources) |resource| {
                    const resourceLabel = getResourceLabel(resource);
                    const strResource = self.getUriComparisonKey(resource);

                    if (seen.contains(strResource)) {
                        continue;
                    }
                    try seen.put(strResource, {});
                    try resourceLabels.append(resourceLabel);
                    try strResources.append(strResource);
                }

                if (resourceLabels.items.len == 1) {
                    self._pushElement(ResourceStackElement.init(workspaceStackElement, resourceLabels.items[0], strResources.items[0], group.id, group.nextOrder(), source.id, source.nextOrder()));
                } else {
                    self._pushElement(WorkspaceStackElement.init(workspaceStackElement, resourceLabels.items, strResources.items, group.id, group.nextOrder(), source.id, source.nextOrder()));
                }
            },
        }
        if (DEBUG) {
            self._print("pushElement");
        }
    }

    pub fn _pushElement(self: *UndoRedoService, element: StackElement) void {
        for (element.strResources(), 0..) |strResource, i| {
            const resourceLabel = element.resourceLabels[i];

            const res = try self._editStacks.getOrPut(strResource);
            if (!res.found_existing) {
                res.value_ptr.* = ResourceEditStack.init(resourceLabel, strResource, self._uriComparisonKeyComputers.allocator);
            }
            res.value_ptr.pushElement(element);
        }
    }

    pub fn getLastElement(self: *UndoRedoService, resource: Uri) ?EditStackElement {
        const strResource = self.getUriComparisonKey(resource);
        if (self._editStacks.contains(strResource)) {
            const editStack = self._editStacks.get(strResource).?;
            if (editStack.hasFutureElements()) {
                return null;
            }
            const closestPastElement = editStack.getClosestPastElement() orelse return null;
            return closestPastElement.actual();
        }
        return null;
    }

    fn _splitPastWorkspaceElement(self: *UndoRedoService, toRemove: *const WorkspaceStackElement, ignoreResources: ?RemovedResources) !void {
        const individualArr = toRemove.actual.split();
        var individualMap = std.StringHashMap(ResourceStackElement).init(self._uriComparisonKeyComputers.allocator);
        defer individualMap.deinit();
        for (individualArr) |_element| {
            const resourceLabel = getResourceLabel(_element.resource);
            const strResource = self.getUriComparisonKey(_element.resource);
            const element = ResourceStackElement.init(_element, resourceLabel, strResource, 0, 0, 0, 0);
            try individualMap.put(element.strResource, element);
        }

        for (toRemove.strResources) |strResource| {
            if (ignoreResources != null and ignoreResources.contains(strResource)) {
                continue;
            }
            const editStack = self._editStacks.get(strResource).?;
            editStack.splitPastWorkspaceElement(toRemove, &individualMap);
        }
    }

    fn _splitFutureWorkspaceElement(self: *UndoRedoService, toRemove: *const WorkspaceStackElement, ignoreResources: ?RemovedResources) !void {
        const individualArr = toRemove.actual.split();
        var individualMap = std.StringHashMap(ResourceStackElement).init(self._uriComparisonKeyComputers.allocator);
        defer individualMap.deinit();
        for (individualArr) |_element| {
            const resourceLabel = getResourceLabel(_element.resource);
            const strResource = self.getUriComparisonKey(_element.resource);
            const element = ResourceStackElement.init(_element, resourceLabel, strResource, 0, 0, 0, 0, false);
            try individualMap.put(element.strResource, element);
        }

        for (toRemove.strResources) |strResource| {
            if (ignoreResources != null and ignoreResources.contains(strResource)) {
                continue;
            }
            const editStack = self._editStacks.get(strResource).?;
            editStack.splitFutureWorkspaceElement(toRemove, &individualMap);
        }
    }

    pub fn removeElements(self: *UndoRedoService, resource: Uri) void {
        const strResource = if (std.mem.eql(u8, resource.scheme, "file")) resource.path else self.getUriComparisonKey(resource);
        if (self._editStacks.get(strResource)) |editStack| {
            editStack.dispose();
            self._editStacks.remove(strResource);
        }
        if (DEBUG) {
            self._print("removeElements");
        }
    }

    pub fn setElementsValidFlag(self: *UndoRedoService, resource: Uri, isValid: bool, filter: fn (element: EditStackElement) bool) void {
        const strResource = self.getUriComparisonKey(resource);
        if (self._editStacks.get(strResource)) |editStack| {
            editStack.setElementsValidFlag(isValid, filter);
        }
        if (DEBUG) {
            self._print("setElementsValidFlag");
        }
    }

    pub fn hasElements(self: *UndoRedoService, resource: Uri) bool {
        const strResource = self.getUriComparisonKey(resource);
        if (self._editStacks.get(strResource)) |editStack| {
            return editStack.hasPastElements() or editStack.hasFutureElements();
        }
        return false;
    }

    pub fn createSnapshot(self: *UndoRedoService, resource: Uri) ResourceEditStackSnapshot {
        const strResource = self.getUriComparisonKey(resource);
        if (self._editStacks.get(strResource)) |editStack| {
            return editStack.createSnapshot(resource);
        }
        return ResourceEditStackSnapshot{ .resource = resource, .elements = &[_]u64{} };
    }

    pub fn restoreSnapshot(self: *UndoRedoService, snapshot: ResourceEditStackSnapshot) void {
        const strResource = self.getUriComparisonKey(snapshot.resource);
        if (self._editStacks.get(strResource)) |editStack| {
            editStack.restoreSnapshot(snapshot);

            if (!editStack.hasPastElements() and !editStack.hasFutureElements()) {
                // the edit stack is now empty, just remove it entirely
                editStack.dispose();
                self._editStacks.remove(strResource);
            }
        }
        if (DEBUG) {
            self._print("restoreSnapshot");
        }
    }

    pub fn getElements(self: *UndoRedoService, resource: Uri) PastFutureElements {
        const strResource = self.getUriComparisonKey(resource);
        if (self._editStacks.get(strResource)) |editStack| {
            return editStack.getElements();
        }
        return PastFutureElements{ .past = &[_]StackElement{}, .future = &[_]StackElement{} };
    }

    fn _findClosestUndoElementWithSource(self: *UndoRedoService, sourceId: u64) ResultPair {
        if (sourceId == 0) {
            return ResultPair{ .first = null, .second = null };
        }

        // find an element with the sourceId and with the highest sourceOrder ready to be undone
        var matchedElement: ?StackElement = null;
        var matchedStrResource: ?[]const u8 = null;

        var iter = self._editStacks.iterator();
        while (iter.next()) |entry| {
            const strResource = entry.key_ptr;
            const editStack = entry.value_ptr;
            if (editStack.getClosestPastElement()) |candidate| {
                if (candidate.sourceId() == sourceId) {
                    if (matchedElement == null or candidate.sourceOrder() > matchedElement.?.sourceOrder()) {
                        matchedElement = candidate;
                        matchedStrResource = strResource.*;
                    }
                }
            }
        }

        return ResultPair{ .first = matchedElement, .second = matchedStrResource };
    }

    pub fn canUndo(self: *UndoRedoService, resourceOrSource: UndoRedoSourceOrUri) bool {
        switch (resourceOrSource) {
            .source => |source| {
                if (self._findClosestUndoElementWithSource(source.id).second) |_| {
                    return true;
                }
            },
            .uri => |uri| {
                const strResource = self.getUriComparisonKey(uri);
                if (self._editStacks.get(strResource)) |editStack| {
                    return editStack.hasPastElements();
                }
            },
            .str => |strResource| {
                if (self._editStacks.get(strResource)) |editStack| {
                    return editStack.hasPastElements();
                }
            },
        }
        return false;
    }

    fn _onError(self: *UndoRedoService, err: anyerror, element: StackElement) void {
        _ = err;
        // onUnexpectedError(err);
        // An error occurred while undoing or redoing => drop the undo/redo stack for all affected resources
        for (element.strResources) |strResource| {
            self.removeElements(strResource);
        }
        //self._notificationService.error(err);
    }

    fn _acquireLocks(self: *UndoRedoService, editStackSnapshot: EditStackSnapshot) void {
        _ = self;
        // first, check if all locks can be acquired
        for (editStackSnapshot.editStacks) |editStack| {
            if (editStack.locked) {
                std.debug.print("Cannot acquire edit stack lock\n", .{});
                return;
            }
        }

        // can acquire all locks
        for (editStackSnapshot.editStacks) |editStack| {
            editStack.locked = true;
        }

        // return {
        //     // release all locks
        //     for (editStackSnapshot.editStacks) |editStack| {
        //         editStack.locked = false;
        //     }
        // }
    }

    // fn _safeInvokeWithLocks(self: *UndoRedoService, element: StackElement, invoke: fn () void, editStackSnapshot: EditStackSnapshot, cleanup: IDisposable, continuation: fn () void) void {
    //     const releaseLocks = self._acquireLocks(editStackSnapshot);

    //     var result = invoke() catch {
    //         releaseLocks();
    //         cleanup.dispose();
    //         return this._onError(err, element);
    //     }

    //     if (result) {
    //         // result is Promise<void>
    //         return result.then(
    //             () => {
    //                 releaseLocks();
    //                 cleanup.dispose();
    //                 return continuation();
    //             },
    //             (err) => {
    //                 releaseLocks();
    //                 cleanup.dispose();
    //                 return this._onError(err, element);
    //             }
    //         );
    //     } else {
    //         // result is void
    //         releaseLocks();
    //         cleanup.dispose();
    //         return continuation();
    //     }
    // }

    fn _invokeWorkspacePrepare(self: *UndoRedoService, element: *const WorkspaceStackElement) !void {
        _ = self;
        if (element.actual.prepareUndoRedo == null) {
            return;
        }
        element.actual.prepareUndoRedo();
    }

    // fn _invokeResourcePrepare(self: *UndoRedoService, element: ResourceStackElement, callback: fn (disposable: IDisposable) void) void {
    //     if (element.actual.type != UndoRedoElementType.Workspace or element.actual.prepareUndoRedo == null) {
    //         // no preparation needed
    //         return callback(IDisposable.None);
    //     }

    //     const r = element.actual.prepareUndoRedo();
    //     if (r == null) {
    //         // nothing to clean up
    //         return callback(IDisposable.None);
    //     }

    //     if (r.isDisposable()) {
    //         return callback(r);
    //     }

    //     return r.then((disposable) => {
    //         return callback(disposable);
    //     });
    // }

    fn _getAffectedEditStacks(self: *UndoRedoService, element: *const WorkspaceStackElement) !EditStackSnapshot {
        var affectedEditStacks = ArrayList(ResourceEditStack).init(self._uriComparisonKeyComputers.allocator);
        defer affectedEditStacks.deinit();
        for (element.strResources) |strResource| {
            try affectedEditStacks.append(self._editStacks.get(strResource) orelse missingEditStack);
        }
        return EditStackSnapshot{ .editStacks = affectedEditStacks };
    }

    fn _tryToSplitAndUndo(self: *UndoRedoService, strResource: []const u8, element: *const WorkspaceStackElement, ignoreResources: ?RemovedResources, message: []const u8) WorkspaceVerificationError {
        if (element.canSplit()) {
            self._splitPastWorkspaceElement(element, ignoreResources);
            self._notificationService.warn(message);
            return WorkspaceVerificationError{ .returnValue = self._undo(strResource, 0, true) };
        } else {
            // Cannot safely split this workspace element => flush all undo/redo stacks
            for (element.strResources) |str| {
                self.removeElements(str);
            }
            self._notificationService.warn(message);
            return WorkspaceVerificationError{ .returnValue = null };
        }
    }

    fn _checkWorkspaceUndo(self: *UndoRedoService, strResource: []const u8, element: *const WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, checkInvalidatedResources: bool) WorkspaceVerificationError {
        if (element.removedResources) {
            return self._tryToSplitAndUndo(strResource, element, element.removedResources, "Could not undo '{0}' across all files. {1}" //, element.label, element.removedResources.createMessage()
            );
        }
        if (checkInvalidatedResources and element.invalidatedResources) {
            return self._tryToSplitAndUndo(strResource, element, element.invalidatedResources, "Could not undo '{0}' across all files. {1}" //, element.label, element.invalidatedResources.createMessage()
            );
        }

        // this must be the last past element in all the impacted resources!
        var cannotUndoDueToResources = ArrayList([]const u8).init(std.heap.page_allocator);
        defer cannotUndoDueToResources.deinit();
        for (editStackSnapshot.editStacks) |editStack| {
            if (editStack.getClosestPastElement() != element) {
                try cannotUndoDueToResources.append(editStack.resourceLabel);
            }
        }
        if (cannotUndoDueToResources.length > 0) {
            return self._tryToSplitAndUndo(strResource, element, null, "Could not undo '{0}' across all files because changes were made to {1}" //, element.label, cannotUndoDueToResources.join(', ')
            );
        }

        var cannotLockDueToResources = ArrayList([]const u8).init(std.heap.page_allocator);
        defer cannotLockDueToResources.deinit();

        for (editStackSnapshot.editStacks) |editStack| {
            if (editStack.locked) {
                try cannotLockDueToResources.append(editStack.resourceLabel);
            }
        }
        if (cannotLockDueToResources.length > 0) {
            return self._tryToSplitAndUndo(strResource, element, null, "Could not undo '{0}' across all files because there is already an undo or redo operation running on {1}" //, element.label, cannotLockDueToResources.join(', ')
            );
        }

        // check if new stack elements were added in the meantime...
        if (!editStackSnapshot.isValid()) {
            return self._tryToSplitAndUndo(strResource, element, null, "Could not undo '{0}' across all files because an undo or redo operation occurred in the meantime" //, element.label
            );
        }

        return null;
    }

    fn _workspaceUndo(self: *UndoRedoService, strResource: []const u8, element: *const WorkspaceStackElement, undoConfirmed: bool) void {
        const affectedEditStacks = self._getAffectedEditStacks(element);
        const verificationError = self._checkWorkspaceUndo(strResource, element, affectedEditStacks, false); // invalidated resources will be checked after the prepare call
        if (verificationError) {
            return verificationError.returnValue;
        }
        return self._confirmAndExecuteWorkspaceUndo(strResource, element, affectedEditStacks, undoConfirmed);
    }

    fn _isPartOfUndoGroup(self: *UndoRedoService, element: *const WorkspaceStackElement) bool {
        if (element.groupId == 0) {
            return false;
        }
        // check that there is at least another element with the same groupId ready to be undone
        var iter = self._editStacks.valueIterator();
        while (iter.next()) |editStack| {
            if (editStack.getClosestPastElement()) |pastElement| {
                if (pastElement == element) {
                    const secondPastElement = editStack.getSecondClosestPastElement();
                    if (secondPastElement != null and secondPastElement.?.groupId == element.groupId) {
                        // there is another element with the same group id in the same stack!
                        return true;
                    }
                }
                if (pastElement.groupId == element.groupId) {
                    // there is another element with the same group id in another stack!
                    return true;
                }
            }
        }
        return false;
    }

    const UndoChoice = enum(u2) { All = 0, This = 1, Cancel = 2 };

    fn _confirmAndExecuteWorkspaceUndo(self: *UndoRedoService, strResource: []const u8, element: *const WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, undoConfirmed: bool) !void {
        if (element.canSplit() and !self._isPartOfUndoGroup(element)) {
            // this element can be split

            const result = UndoChoice.This;
            // const { result } = await self._dialogService.prompt<UndoChoice>({
            //     type: Severity.Info,
            //     message: nls.localize('confirmWorkspace', "Would you like to undo '{0}' across all files?", element.label),
            //     buttons: [
            //         {
            //             label: nls.localize({ key: "ok", comment: "{0} denotes a number that is > 1, && denotes a mnemonic" }, "&&Undo in {0} Files", editStackSnapshot.editStacks.length),
            //             run: () => UndoChoice.All
            //         },
            //         {
            //             label: nls.localize({ key: "nok", comment: "&& denotes a mnemonic" }, "Undo this &&File"),
            //             run: () => UndoChoice.This
            //         }
            //     ],
            //     cancelButton: {
            //         run: () => UndoChoice.Cancel
            //     }
            // });

            if (result == UndoChoice.Cancel) {
                // choice: cancel
                return;
            }

            if (result == UndoChoice.This) {
                // choice: undo this file
                self._splitPastWorkspaceElement(element, null);
                return self._undo(strResource, 0, true);
            }

            // choice: undo in all files

            // At this point, it is possible that the element has been made invalid in the meantime (due to the confirmation await)
            const verificationError1 = self._checkWorkspaceUndo(strResource, element, editStackSnapshot, false); // invalidated resources will be checked after the prepare call
            if (verificationError1) {
                return verificationError1.returnValue();
            }

            undoConfirmed = true;
        }

        // prepare
        var cleanup: ?Disposable = try self._invokeWorkspacePrepare(element);

        // At this point, it is possible that the element has been made invalid in the meantime (due to the prepare await)
        const verificationError2 = self._checkWorkspaceUndo(strResource, element, editStackSnapshot, true); // now also check that there are no more invalidated resources
        if (verificationError2) {
            cleanup.dispose();
            return verificationError2.returnValue;
        }

        for (editStackSnapshot.editStacks) |editStack| {
            editStack.moveBackward(element);
        }
        // return self._safeInvokeWithLocks(element, () => element.actual.undo(), editStackSnapshot, cleanup, () => self._continueUndoInGroup(element.groupId, undoConfirmed));
    }

    fn _resourceUndo(self: *UndoRedoService, editStack: *const ResourceEditStack, element: *const ResourceStackElement, undoConfirmed: bool) void {
        if (!element.isValid) {
            // invalid element => immediately flush edit stack!
            editStack.flushAllElements();
            return;
        }
        if (editStack.locked) {
            const message = "Could not undo '{0}' because there is already an undo or redo operation running."; //, element.label
            self._notificationService.warn(message);
            return;
        }
        _ = undoConfirmed;
        // return self._invokeResourcePrepare(element, (cleanup) => {
        //     editStack.moveBackward(element);
        //     // return self._safeInvokeWithLocks(element, () => element.actual.undo(), new EditStackSnapshot([editStack]), cleanup, () => self._continueUndoInGroup(element.groupId, undoConfirmed));
        // });
    }

    fn _findClosestUndoElementInGroup(self: *UndoRedoService, groupId: u64) ResultPair {
        if (groupId == 0) {
            return ResultPair{ .first = null, .second = null };
        }

        // find another element with the same groupId and with the highest groupOrder ready to be undone
        var matchedElement: ?StackElement = null;
        var matchedStrResource: ?[]const u8 = null;

        var iter = self._editStacks.iterator();
        while (iter.next()) |entry| {
            const strResource = entry.key_ptr;
            const editStack = entry.value_ptr;
            if (editStack.getClosestPastElement()) |candidate| {
                if (candidate.groupId() == groupId) {
                    if (matchedElement == null or candidate.groupOrder() > matchedElement.?.groupOrder()) {
                        matchedElement = candidate;
                        matchedStrResource = strResource;
                    }
                }
            }
        }

        return pair(matchedElement, matchedStrResource);
    }

    fn _continueUndoInGroup(self: *UndoRedoService, groupId: u64, undoConfirmed: bool) void {
        if (groupId == 0) {
            return;
        }

        const res = self._findClosestUndoElementInGroup(groupId);
        const matchedStrResource = res.second;
        if (matchedStrResource) {
            return self._undo(matchedStrResource, 0, undoConfirmed);
        }
    }

    pub fn undo(self: *UndoRedoService, resourceOrSource: UndoRedoSourceOrUri) void {
        switch (resourceOrSource) {
            .source => |source| {
                if (self._findClosestUndoElementWithSource(source.id).second) |matchedStrResource| {
                    self._undo(matchedStrResource, source.id, false);
                }
            },
            .uri => |uri| {
                self._undo(self.getUriComparisonKey(uri), 0, false);
            },
            .str => |strResource| {
                self._undo(strResource, 0, false);
            },
        }
    }

    fn _undo(self: *UndoRedoService, strResource: []const u8, sourceId: u64, undoConfirmed: bool) void {
        if (self._editStacks.get(strResource)) |editStack| {
            if (editStack.getClosestPastElement()) |element| {
                if (element.groupId() != 0) {
                    // this element is a part of a group, we need to make sure undoing in a group is in order
                    const res = self._findClosestUndoElementInGroup(element.groupId());
                    const matchedElement = res.first;
                    const matchedStrResource = res.second;
                    if ((matchedElement == null or element != matchedElement) and matchedStrResource != null) {
                        // there is an element in the same group that should be undone before this one
                        return self._undo(matchedStrResource.?, sourceId, undoConfirmed);
                    }
                }

                const shouldPromptForConfirmation = (element.sourceId() != sourceId or element.confirmBeforeUndo());
                if (shouldPromptForConfirmation and !undoConfirmed) {
                    // Hit a different source or the element asks for prompt before undo, prompt for confirmation
                    return self._confirmAndContinueUndo(strResource, sourceId, element);
                }

                if (DEBUG) {
                    self._print("undo");
                }

                switch (element.*) {
                    .resourceStackElement => |resourceStackElement| {
                        return self._resourceUndo(editStack, &resourceStackElement, undoConfirmed);
                    },
                    .workspaceStackElement => |workspaceStackElement| {
                        return self._workspaceUndo(strResource, &workspaceStackElement, undoConfirmed);
                    },
                }
            }
        }
    }

    fn _confirmAndContinueUndo(self: *UndoRedoService, strResource: []const u8, sourceId: u64, element: StackElement) !void {
        _ = element;
        // const result = await self._dialogService.confirm({
        //     message: nls.localize('confirmDifferentSource', "Would you like to undo '{0}'?", element.label),
        //     primaryButton: nls.localize({ key: 'confirmDifferentSource.yes', comment: "&& denotes a mnemonic" }, "&&Yes"),
        //     cancelButton: nls.localize('confirmDifferentSource.no', "No")
        // });

        // if (!result.confirmed) {
        //     return;
        // }

        return self._undo(strResource, sourceId, true);
    }

    fn _findClosestRedoElementWithSource(self: *UndoRedoService, sourceId: u64) ResultPair {
        if (sourceId == 0) {
            return ResultPair{ .first = null, .second = null };
        }

        // find an element with sourceId and with the lowest sourceOrder ready to be redone
        var matchedElement: ?StackElement = null;
        var matchedStrResource: ?[]const u8 = null;

        var iter = self._editStacks.iterator();
        while (iter.next()) |entry| {
            const strResource = entry.key_ptr;
            const editStack = entry.value_ptr;
            if (editStack.getClosestFutureElement()) |candidate| {
                if (candidate.sourceId() == sourceId) {
                    if (matchedElement == null or candidate.sourceOrder() < matchedElement.?.sourceOrder()) {
                        matchedElement = candidate;
                        matchedStrResource = strResource.*;
                    }
                }
            }
        }

        return pair(matchedElement, matchedStrResource);
    }

    pub fn canRedo(self: *UndoRedoService, resourceOrSource: UndoRedoSourceOrUri) bool {
        switch (resourceOrSource) {
            .source => |source| {
                if (self._findClosestRedoElementWithSource(source.id).second) |_| {
                    return true;
                }
            },
            .uri => |uri| {
                const strResource = self.getUriComparisonKey(uri);
                if (self._editStacks.get(strResource)) |editStack| {
                    return editStack.hasFutureElements();
                }
            },
            .str => |strResource| {
                if (self._editStacks.get(strResource)) |editStack| {
                    return editStack.hasFutureElements();
                }
            },
        }
        return false;
    }

    fn _tryToSplitAndRedo(self: *UndoRedoService, strResource: []const u8, element: *const WorkspaceStackElement, ignoreResources: ?RemovedResources, message: []const u8) !WorkspaceVerificationError {
        if (element.canSplit()) {
            self._splitFutureWorkspaceElement(element, ignoreResources);
            self._notificationService.warn(message);
            return WorkspaceVerificationError{ .returnValue = self._redo(strResource) };
        } else {
            // Cannot safely split this workspace element => flush all undo/redo stacks
            for (element.strResources) |str| {
                self.removeElements(str);
            }
            self._notificationService.warn(message);
            return WorkspaceVerificationError{ .returnValue = null };
        }
    }

    fn _checkWorkspaceRedo(self: *UndoRedoService, strResource: []const u8, element: *const WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, checkInvalidatedResources: bool) ?WorkspaceVerificationError {
        if (element.removedResources) {
            return try self._tryToSplitAndRedo(strResource, element, element.removedResources, "Could not redo '{0}' across all files. {1}" //, element.label, element.removedResources.createMessage()
            );
        }
        if (checkInvalidatedResources and element.invalidatedResources) {
            return try self._tryToSplitAndRedo(strResource, element, element.invalidatedResources, "Could not redo '{0}' across all files. {1}" //, element.label, element.invalidatedResources.createMessage()
            );
        }

        // this must be the last future element in all the impacted resources!
        var cannotRedoDueToResources = ArrayList([]const u8).init(std.heap.page_allocator);
        defer cannotRedoDueToResources.deinit();
        for (editStackSnapshot.editStacks) |editStack| {
            if (editStack.getClosestFutureElement() != element) {
                try cannotRedoDueToResources.append(editStack.resourceLabel);
            }
        }
        if (cannotRedoDueToResources.length > 0) {
            return try self._tryToSplitAndRedo(strResource, element, null, "Could not redo '{0}' across all files because changes were made to {1}" //, element.label, cannotRedoDueToResources.join(', ')
            );
        }

        var cannotLockDueToResources = ArrayList([]const u8).init(std.heap.page_allocator);
        defer cannotLockDueToResources.deinit();
        for (editStackSnapshot.editStacks) |editStack| {
            if (editStack.locked) {
                try cannotLockDueToResources.append(editStack.resourceLabel);
            }
        }
        if (cannotLockDueToResources.length > 0) {
            return try self._tryToSplitAndRedo(strResource, element, null, "Could not redo '{0}' across all files because there is already an undo or redo operation running on {1}" //, element.label, cannotLockDueToResources.join(', ')
            );
        }

        // check if new stack elements were added in the meantime...
        if (!editStackSnapshot.isValid()) {
            return try self._tryToSplitAndRedo(strResource, element, null, "Could not redo '{0}' across all files because an undo or redo operation occurred in the meantime" //, element.label
            );
        }

        return null;
    }

    fn _workspaceRedo(self: *UndoRedoService, strResource: []const u8, element: *const WorkspaceStackElement) !void {
        const affectedEditStacks = self._getAffectedEditStacks(element);
        // invalidated resources will be checked after the prepare call
        if (self._checkWorkspaceRedo(strResource, element, affectedEditStacks, false)) |verificationError| {
            return verificationError.returnValue;
        }
        return try self._executeWorkspaceRedo(strResource, element, affectedEditStacks);
    }

    fn _executeWorkspaceRedo(self: *UndoRedoService, strResource: []const u8, element: *const WorkspaceStackElement, editStackSnapshot: EditStackSnapshot) !void {
        // prepare
        var cleanup: ?Disposable = try self._invokeWorkspacePrepare(element);

        // At this point, it is possible that the element has been made invalid in the meantime (due to the prepare await)
        // now also check that there are no more invalidated resources
        if (self._checkWorkspaceRedo(strResource, element, editStackSnapshot, true)) |verificationError| {
            cleanup.dispose();
            return verificationError.returnValue;
        }

        for (editStackSnapshot.editStacks) |editStack| {
            editStack.moveForward(element);
        }
        // return self._safeInvokeWithLocks(element, () => element.actual.redo(), editStackSnapshot, cleanup, () => self._continueRedoInGroup(element.groupId));
    }

    fn _resourceRedo(self: *UndoRedoService, editStack: *const ResourceEditStack, element: *const ResourceStackElement) void {
        if (!element.isValid) {
            // invalid element => immediately flush edit stack!
            editStack.flushAllElements();
            return;
        }
        if (editStack.locked) {
            const message = "Could not redo '{0}' because there is already an undo or redo operation running."; //, element.label
            self._notificationService.warn(message);
            return;
        }

        // return self._invokeResourcePrepare(element, (cleanup) => {
        //     editStack.moveForward(element);
        //     // return self._safeInvokeWithLocks(element, () => element.actual.redo(), new EditStackSnapshot([editStack]), cleanup, () => self._continueRedoInGroup(element.groupId));
        // });
    }

    const ResultPair = Pair(?StackElement, ?[]const u8);

    fn _findClosestRedoElementInGroup(self: *UndoRedoService, groupId: u64) ResultPair {
        if (groupId == 0) {
            return ResultPair{ .first = null, .second = null };
        }

        // find another element with the same groupId and with the lowest groupOrder ready to be redone
        var matchedElement: ?StackElement = null;
        var matchedStrResource: ?[]const u8 = null;

        var iter = self._editStacks.iterator();
        while (iter.next()) |entry| {
            const strResource = entry.key_ptr;
            const editStack = entry.value_ptr;
            if (editStack.getClosestFutureElement()) |candidate| {
                if (candidate.groupId() == groupId) {
                    if (matchedElement == null or candidate.groupOrder() < matchedElement.?.groupOrder()) {
                        matchedElement = candidate;
                        matchedStrResource = strResource.*;
                    }
                }
            }
        }

        return pair(matchedElement, matchedStrResource);
    }

    fn _continueRedoInGroup(self: *UndoRedoService, groupId: u64) void {
        if (groupId == 0) {
            return;
        }

        if (self._findClosestRedoElementInGroup(groupId).second) |matchedStrResource| {
            return self._redo(matchedStrResource);
        }
    }

    pub fn redo(self: *UndoRedoService, resourceOrSource: UndoRedoSourceOrUri) void {
        switch (resourceOrSource) {
            .source => |source| {
                if (self._findClosestRedoElementWithSource(source.id).second) |matchedStrResource| {
                    self._redo(matchedStrResource);
                }
            },
            .uri => |uri| {
                self._redo(self.getUriComparisonKey(uri));
            },
            .str => |str| {
                self._redo(str);
            },
        }
    }

    fn _redo(self: *UndoRedoService, strResource: []const u8) void {
        if (!self._editStacks.contains(strResource)) {
            return;
        }

        const editStack = self._editStacks.get(strResource).?;
        if (editStack.getClosestFutureElement()) |element| {
            const groupId = element.groupId();
            if (groupId != 0) {
                // this element is a part of a group, we need to make sure redoing in a group is in order
                const res = self._findClosestRedoElementInGroup(groupId);
                if (res.first) |matchedElement| {
                    if (res.second) |matchedStrResource| {
                        if (element != matchedElement and matchedStrResource) {
                            // there is an element in the same group that should be redone before this one
                            return self._redo(matchedStrResource);
                        }
                    }
                } else {
                    if (res.second) |matchedStrResource| {
                        return self._redo(matchedStrResource);
                    }
                }
            }

            if (DEBUG) {
                self._print("redo");
            }

            switch (element) {
                .resourceStackElement => |resourceStackElement| {
                    return self._resourceRedo(editStack, resourceStackElement);
                },
                .workspaceStackElement => |workspaceStackElement| {
                    return self._workspaceRedo(strResource, workspaceStackElement);
                },
            }
        }
    }
};

test "UndoRedoService.init" {
    const allocator = std.testing.allocator;
    var undoRedoService = UndoRedoService.init(allocator);
    defer undoRedoService.deinit();
}
