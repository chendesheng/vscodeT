const std = @import("std");
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const StringHashMap = @import("../basics/strings.zig").StringHashMap;
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
const Pair = @import("../basics/utils.zig").Pair;
const pair = @import("../basics/utils.zig").pair;
const SingleModelEditStackElement = @import("editStack.zig").SingleModelEditStackElement;
const Selection = @import("../basics/selection.zig").Selection;
const String = @import("../basics/strings.zig").String;
const NotificationService = @import("notificationService.zig").NotificationService;

const DEBUG = true;

fn getResourceLabel(resource: Uri) []const u8 {
    switch (resource.path) {
        .raw => |raw| return raw,
        .percent_encoded => |path| return path,
    }
}

var stackElementCount: u64 = 0;

const StackElement = union(enum) {
    resourceStackElement: ResourceStackElement,
    workspaceStackElement: WorkspaceStackElement,

    pub fn initResourceStackElement(actual_: *EditStackElement, resourceLabel: []const u8, strResource: String, groupId_: u64, groupOrder_: u64, sourceId_: u64, sourceOrder_: u64) StackElement {
        return .{ .resourceStackElement = ResourceStackElement.init(actual_, resourceLabel, strResource, groupId_, groupOrder_, sourceId_, sourceOrder_) };
    }

    pub fn initWorkspaceStackElement(actual_: *EditStackElement, resourceLabels_: ArrayList([]const u8), strResources_: ArrayList(String), groupId_: u64, groupOrder_: u64, sourceId_: u64, sourceOrder_: u64) StackElement {
        return .{ .workspaceStackElement = WorkspaceStackElement.init(actual_, resourceLabels_, strResources_, groupId_, groupOrder_, sourceId_, sourceOrder_) };
    }

    pub fn deinit(self: *StackElement) void {
        switch (self.*) {
            .resourceStackElement => |*resourceStackElement| resourceStackElement.deinit(),
            .workspaceStackElement => |*workspaceStackElement| workspaceStackElement.deinit(),
        }
    }

    pub fn id(self: *const StackElement) u64 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.id,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.id,
        };
    }

    pub fn groupId(self: *const StackElement) u64 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.groupId,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.groupId,
        };
    }

    pub fn strResources(self: *const StackElement) []const String {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| &[_]String{resourceStackElement.strResource},
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.strResources.items,
        };
    }

    pub fn sourceId(self: *const StackElement) u64 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.sourceId,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.sourceId,
        };
    }

    pub fn sourceOrder(self: *const StackElement) u64 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.sourceOrder,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.sourceOrder,
        };
    }

    pub fn groupOrder(self: *const StackElement) u64 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.groupOrder,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.groupOrder,
        };
    }

    pub fn confirmBeforeUndo(self: *const StackElement) bool {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.confirmBeforeUndo,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.confirmBeforeUndo,
        };
    }

    pub fn actual(self: *const StackElement) *EditStackElement {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| resourceStackElement.actual,
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.actual,
        };
    }

    pub fn resourceLabels(self: *const StackElement) []const []const u8 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| &[_][]const u8{resourceStackElement.resourceLabel},
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.resourceLabels.items,
        };
    }
};

const WorkspaceVerificationError = struct {
    returnValue: ?*anyopaque,
};

const ResourceStackElement = struct {
    id: u64,
    actual: *EditStackElement,
    label: []const u8,
    confirmBeforeUndo: bool,

    resourceLabel: []const u8,
    strResource: String,
    groupId: u64,
    groupOrder: u64,
    sourceId: u64,
    sourceOrder: u64,
    isValid: bool,

    pub fn init(actual: *EditStackElement, resourceLabel: []const u8, strResource: String, groupId: u64, groupOrder: u64, sourceId: u64, sourceOrder: u64) ResourceStackElement {
        stackElementCount += 1;
        return ResourceStackElement{
            .id = stackElementCount,
            .actual = actual,
            .label = actual.label(),
            .confirmBeforeUndo = false,
            .resourceLabel = resourceLabel,
            .strResource = strResource,
            .groupId = groupId,
            .groupOrder = groupOrder,
            .sourceId = sourceId,
            .sourceOrder = sourceOrder,
            .isValid = true,
        };
    }

    pub fn deinit(self: *ResourceStackElement) void {
        self.strResource.deinit();
        self.actual.deinit();
        const allocator = self.actual.getAllocator();
        allocator.destroy(self.actual);
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
    elements: StringHashMap(ResourceReasonPair),

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

    pub fn has(self: *const RemovedResources, strResource: String) bool {
        return self.elements.contains(strResource);
    }

    pub fn set(self: *RemovedResources, strResource: String, value: ResourceReasonPair) !void {
        try self.elements.put(strResource, value);
    }

    pub fn delete(self: *RemovedResources, strResource: String) bool {
        return self.elements.remove(strResource);
    }
};

const WorkspaceStackElement = struct {
    id: u64,
    actual: *EditStackElement,
    label: []const u8,
    confirmBeforeUndo: bool,

    resourceLabels: ArrayList([]const u8),
    strResources: ArrayList(String),
    groupId: u64,
    groupOrder: u64,
    sourceId: u64,
    sourceOrder: u64,
    removedResources: ?RemovedResources,
    invalidatedResources: ?RemovedResources,

    pub fn init(actual: *EditStackElement, resourceLabels: ArrayList([]const u8), strResources: ArrayList(String), groupId: u64, groupOrder: u64, sourceId: u64, sourceOrder: u64) WorkspaceStackElement {
        stackElementCount += 1;
        return WorkspaceStackElement{
            .id = stackElementCount,
            .actual = actual,
            .label = actual.label(),
            .confirmBeforeUndo = false,
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

    pub fn deinit(self: *WorkspaceStackElement) void {
        for (self.strResources.items) |*strResource| {
            strResource.deinit();
        }
        self.strResources.deinit();
    }

    pub fn canSplit(self: *const WorkspaceStackElement) bool {
        return switch (self.actual.*) {
            .singleModel => false,
            .multiModel => true,
        };
    }

    pub fn removeResource(self: *WorkspaceStackElement, resourceLabel: []const u8, strResource: String, reason: RemovedResourceReason) !void {
        if (self.removedResources) |*removedResources| {
            try removedResources.set(strResource, ResourceReasonPair{ .resourceLabel = resourceLabel, .reason = reason });
        } else {
            const allocator = self.actual.getAllocator();
            self.removedResources = RemovedResources{ .elements = StringHashMap(ResourceReasonPair).init(allocator) };
        }
        if (self.removedResources) |*removedResources| {
            if (!removedResources.has(strResource)) {
                try removedResources.set(strResource, ResourceReasonPair{ .resourceLabel = resourceLabel, .reason = reason });
            }
        }
    }

    pub fn setValid(self: *WorkspaceStackElement, resourceLabel: []const u8, strResource: String, isValid: bool) !void {
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
                const allocator = self.actual.getAllocator();
                self.invalidatedResources = RemovedResources{ .elements = std.HashMap(Uri, ResourceReasonPair, UriContext, 0.5).init(allocator) };
            }
            if (self.invalidatedResources) |invalidatedResources| {
                if (!invalidatedResources.has(strResource)) {
                    try invalidatedResources.set(strResource, ResourceReasonPair{ .resourceLabel = resourceLabel, .reason = RemovedResourceReason.ExternalRemoval });
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

var missingEditStack = ResourceEditStack.init("", String.Empty, std.heap.page_allocator);
const ResourceEditStack = struct {
    resourceLabel: []const u8,
    strResource: String,
    _past: ArrayList(StackElement),
    _future: ArrayList(StackElement),
    locked: bool,
    versionId: u64,

    pub fn init(resourceLabel: []const u8, strResource: String, allocator: Allocator) ResourceEditStack {
        return ResourceEditStack{
            .resourceLabel = resourceLabel,
            .strResource = strResource,
            ._past = ArrayList(StackElement).init(allocator),
            ._future = ArrayList(StackElement).init(allocator),
            .locked = false,
            .versionId = 1,
        };
    }

    pub fn deinit(self: *ResourceEditStack) void {
        for (self._past.items) |*element| {
            element.deinit();
        }
        self._past.deinit();
        for (self._future.items) |*element| {
            element.deinit();
        }
        self._future.deinit();
    }

    fn getAllocator(self: *const ResourceEditStack) Allocator {
        return self._past.allocator;
    }

    pub fn dispose(self: *ResourceEditStack) !void {
        for (self._past.items) |*element| {
            switch (element.*) {
                .workspaceStackElement => |*workspaceStackElement| {
                    try workspaceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.ExternalRemoval);
                },
                .resourceStackElement => {},
            }
        }
        for (self._future.items) |*element| {
            switch (element.*) {
                .workspaceStackElement => |*workspaceStackElement| {
                    try workspaceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.ExternalRemoval);
                },
                .resourceStackElement => {},
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
        for (self._past.items) |*element| {
            element.deinit();
        }
        self._past.clearAndFree();
        for (self._future.items) |*element| {
            element.deinit();
        }
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

    pub fn pushElement(self: *ResourceEditStack, element: StackElement) !void {
        // remove the future
        for (self._future.items) |*futureElement| {
            switch (futureElement.*) {
                .workspaceStackElement => {
                    try futureElement.workspaceStackElement.removeResource(self.resourceLabel, self.strResource, RemovedResourceReason.NoParallelUniverses);
                },
                .resourceStackElement => {},
            }
        }
        self._future.clearAndFree();
        try self._past.append(element);
        self.versionId += 1;
    }

    pub fn createSnapshot(self: *const ResourceEditStack, resource: Uri) !ResourceEditStackSnapshot {
        var elements = ArrayList(u64).init(self.getAllocator());

        for (self._past.items) |element| {
            try elements.append(element.id());
        }
        for (self._future.items) |element| {
            try elements.append(element.id());
        }

        return ResourceEditStackSnapshot{ .resource = resource, .elements = elements };
    }

    pub fn restoreSnapshot(self: *ResourceEditStack, snapshot: ResourceEditStackSnapshot) void {
        const snapshotLength = snapshot.elements.len;
        var isOK = true;
        var snapshotIndex: usize = 0;
        var removePastAfter = -1;
        var i: usize = 0;
        while (i < self._past.items.len) : (i += 1) {
            const element = self._past.items[i];
            if (isOK and (snapshotIndex >= snapshotLength or element.id() != snapshot.elements[snapshotIndex])) {
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
            if (isOK and (snapshotIndex >= snapshotLength or element.id() != snapshot.elements[snapshotIndex])) {
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

    pub fn getElements(self: *const ResourceEditStack) PastFutureElements {
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

    pub fn getClosestPastElement(self: *const ResourceEditStack) ?StackElement {
        if (self._past.items.len == 0) {
            return null;
        }
        return self._past.items[self._past.items.len - 1];
    }

    pub fn getSecondClosestPastElement(self: *const ResourceEditStack) ?StackElement {
        if (self._past.items.len < 2) {
            return null;
        }
        return self._past.items[self._past.items.len - 2];
    }

    pub fn getClosestFutureElement(self: *const ResourceEditStack) ?StackElement {
        if (self._future.items.len == 0) {
            return null;
        }
        return self._future.items[self._future.items.len - 1];
    }

    pub fn hasPastElements(self: *const ResourceEditStack) bool {
        return self._past.items.len > 0;
    }

    pub fn hasFutureElements(self: *const ResourceEditStack) bool {
        return self._future.items.len > 0;
    }

    pub fn splitPastWorkspaceElement(self: *ResourceEditStack, toRemove: *const WorkspaceStackElement, individualMap: *StringHashMap(ResourceStackElement)) void {
        var j: usize = self._past.items.len - 1;
        while (j >= 0) : (j -= 1) {
            if (self._past.items[j].id() == toRemove.id) {
                if (individualMap.get(self.strResource)) |individual| {
                    // gets replaced
                    self._past.items[j] = .{ .resourceStackElement = individual };
                } else {
                    // gets deleted
                    self._past.items.len = j;
                }
                break;
            }
        }
        self.versionId += 1;
    }

    pub fn splitFutureWorkspaceElement(self: *ResourceEditStack, toRemove: *const WorkspaceStackElement, individualMap: *StringHashMap(ResourceStackElement)) void {
        var j: usize = self._future.items.len - 1;
        while (j >= 0) : (j -= 1) {
            if (self._future.items[j].id() == toRemove.id) {
                if (individualMap.get(self.strResource)) |individual| {
                    // gets replaced
                    self._future.items[j] = .{ .resourceStackElement = individual };
                } else {
                    // gets deleted
                    self._future.items.len = j;
                }
                break;
            }
        }
        self.versionId += 1;
    }

    pub fn moveBackward(self: *ResourceEditStack, element: StackElement) !void {
        _ = self._past.pop();
        try self._future.append(element);
        self.versionId += 1;
    }

    pub fn moveForward(self: *ResourceEditStack, element: StackElement) !void {
        _ = self._future.pop();
        try self._past.append(element);
        self.versionId += 1;
    }
};

const EditStackSnapshot = struct {
    editStacks: ArrayList(ResourceEditStack),
    _versionIds: ArrayList(u64),

    pub fn init(editStacks: ArrayList(ResourceEditStack)) !EditStackSnapshot {
        var versionIds = ArrayList(u64).init(editStacks.allocator);
        for (editStacks.items) |*editStack| {
            try versionIds.append(editStack.versionId);
        }
        return EditStackSnapshot{ .editStacks = editStacks, ._versionIds = versionIds };
    }

    pub fn deinit(self: *EditStackSnapshot) void {
        self.editStacks.deinit();
        self._versionIds.deinit();
    }

    pub fn isValid(self: *const EditStackSnapshot) bool {
        for (self.editStacks.items, 0..) |editStack, i| {
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
    _editStacks: StringHashMap(ResourceEditStack),
    _uriComparisonKeyComputers: ArrayList(KeyComputerPair),
    _notificationService: NotificationService,

    pub fn init(allocator: Allocator) UndoRedoService {
        return UndoRedoService{
            ._editStacks = StringHashMap(ResourceEditStack).init(allocator),
            ._uriComparisonKeyComputers = ArrayList(KeyComputerPair).init(allocator),
            ._notificationService = NotificationService{},
        };
    }

    pub fn create(allocator: Allocator) !*UndoRedoService {
        var self = try allocator.create(UndoRedoService);
        self._editStacks = StringHashMap(ResourceEditStack).init(allocator);
        self._uriComparisonKeyComputers = ArrayList(KeyComputerPair).init(allocator);
        self._notificationService = NotificationService{};
        return self;
    }

    pub fn deinit(self: *UndoRedoService) void {
        var valueIter = self._editStacks.valueIterator();
        while (valueIter.next()) |value| {
            value.deinit();
        }
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

    pub fn getUriComparisonKey(self: *UndoRedoService, resource: Uri) !String {
        for (self._uriComparisonKeyComputers.items) |uriComparisonKeyComputer| {
            if (std.mem.eql(u8, uriComparisonKeyComputer.key, resource.scheme)) {
                return String.initBorrowed(uriComparisonKeyComputer.computer.getComparisonKey(&uriComparisonKeyComputer.computer, resource));
            }
        }
        return String.initOwned(try uriToString(resource, self._uriComparisonKeyComputers.allocator));
    }

    pub fn _print(self: *UndoRedoService, label: []const u8) void {
        self._doprint(label) catch {};
    }

    fn _doprint(self: *UndoRedoService, label: []const u8) !void {
        std.debug.print("------------------------------------\n", .{});
        std.debug.print("AFTER {s}: \n", .{label});
        var str = ArrayList(u8).init(self._uriComparisonKeyComputers.allocator);
        defer str.deinit();

        try str.appendSlice("AFTER ");
        try str.appendSlice(label);
        try str.appendSlice(": ");
        var iter = self._editStacks.keyIterator();
        while (iter.next()) |key| {
            try key.fillItems(&str);
            try str.appendSlice("\n");
        }
        std.debug.print("{s}\n", .{str.items});
    }

    pub fn pushElement(self: *UndoRedoService, element: *EditStackElement, _group: ?UndoRedoGroup, _source: ?UndoRedoSource) !void {
        var group = _group orelse UndoRedoGroup.None;
        var source = _source orelse UndoRedoSource.None;

        switch (element.*) {
            .singleModel => |singleModel| {
                const resourceLabel = getResourceLabel(singleModel.resource());
                const strResource = try self.getUriComparisonKey(singleModel.resource());
                try self._pushElement(.{ .resourceStackElement = ResourceStackElement.init(element, resourceLabel, strResource, group.id, group.nextOrder(), source.id, source.nextOrder()) });
            },
            .multiModel => |multiModel| {
                const allocator = self._uriComparisonKeyComputers.allocator;
                var seen = StringHashMap(void).init(allocator);
                defer seen.deinit();
                var resourceLabels = ArrayList([]const u8).init(allocator);
                var strResources = ArrayList(String).init(allocator);
                for ((try multiModel.resources()).items) |resource| {
                    const resourceLabel = getResourceLabel(resource);
                    const strResource = try self.getUriComparisonKey(resource);

                    if (seen.contains(strResource)) {
                        continue;
                    }
                    try seen.put(strResource, {});
                    try resourceLabels.append(resourceLabel);
                    try strResources.append(strResource);
                }

                if (resourceLabels.items.len == 1) {
                    defer resourceLabels.deinit();
                    defer strResources.deinit();
                    try self._pushElement(.{ .resourceStackElement = ResourceStackElement.init(element, resourceLabels.items[0], strResources.items[0], group.id, group.nextOrder(), source.id, source.nextOrder()) });
                } else {
                    try self._pushElement(.{ .workspaceStackElement = WorkspaceStackElement.init(element, resourceLabels, strResources, group.id, group.nextOrder(), source.id, source.nextOrder()) });
                }
            },
        }
    }

    pub fn _pushElement(self: *UndoRedoService, element: StackElement) !void {
        const allocator = self._editStacks.allocator;
        for (element.strResources(), 0..) |strResource, i| {
            const resourceLabel = element.resourceLabels()[i];

            const res = try self._editStacks.getOrPut(strResource);
            if (!res.found_existing) {
                res.value_ptr.* = ResourceEditStack.init(resourceLabel, strResource, allocator);
            }
            try res.value_ptr.pushElement(element);
        }
    }

    pub fn getLastElement(self: *UndoRedoService, resource: Uri) !?*EditStackElement {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
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

    fn _splitPastWorkspaceElement(self: *UndoRedoService, toRemove: *WorkspaceStackElement, ignoreResources: ?RemovedResources) Allocator.Error!void {
        const individualArr = try toRemove.actual.split();
        defer individualArr.deinit();

        var individualMap = StringHashMap(ResourceStackElement).init(self._uriComparisonKeyComputers.allocator);
        defer individualMap.deinit();
        for (individualArr.items) |*_element| {
            const resourceLabel = getResourceLabel(_element.resource());
            const strResource = try self.getUriComparisonKey(_element.resource());
            const element = ResourceStackElement.init(_element, resourceLabel, strResource, 0, 0, 0, 0);
            try individualMap.put(element.strResource, element);
        }

        for (toRemove.strResources.items) |strResource| {
            if (ignoreResources != null and ignoreResources.?.has(strResource)) {
                continue;
            }
            if (self._editStacks.getPtr(strResource)) |editStack| {
                editStack.splitPastWorkspaceElement(toRemove, &individualMap);
            }
        }
    }

    fn _splitFutureWorkspaceElement(self: *UndoRedoService, toRemove: *const WorkspaceStackElement, ignoreResources: ?RemovedResources) !void {
        const individualArr = try toRemove.actual.split();
        var individualMap = StringHashMap(ResourceStackElement).init(self._uriComparisonKeyComputers.allocator);
        defer individualMap.deinit();
        for (individualArr.items) |*_element| {
            const resourceLabel = getResourceLabel(_element.resource());
            const strResource = try self.getUriComparisonKey(_element.resource());
            const element = ResourceStackElement.init(_element, resourceLabel, strResource, 0, 0, 0, 0);
            try individualMap.put(element.strResource, element);
        }

        for (toRemove.strResources.items) |strResource| {
            if (ignoreResources != null and ignoreResources.?.has(strResource)) {
                continue;
            }
            if (self._editStacks.getPtr(strResource)) |editStack| {
                editStack.splitFutureWorkspaceElement(toRemove, &individualMap);
            }
        }
    }

    pub fn removeElementsStr(self: *UndoRedoService, strResource: String) !void {
        if (self._editStacks.getPtr(strResource)) |editStack| {
            try editStack.dispose();
            _ = self._editStacks.remove(strResource);
        }
        if (DEBUG) {
            self._print("removeElements");
        }
    }

    pub fn removeElements(self: *UndoRedoService, resource: Uri) !void {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
        try self.removeElementsStr(strResource);
    }

    pub fn setElementsValidFlag(self: *UndoRedoService, resource: Uri, isValid: bool, filter: fn (element: EditStackElement) bool) !void {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
        if (self._editStacks.get(strResource)) |editStack| {
            editStack.setElementsValidFlag(isValid, filter);
        }
        if (DEBUG) {
            self._print("setElementsValidFlag");
        }
    }

    pub fn hasElements(self: *UndoRedoService, resource: Uri) !bool {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
        if (self._editStacks.get(strResource)) |editStack| {
            return editStack.hasPastElements() or editStack.hasFutureElements();
        }
        return false;
    }

    pub fn createSnapshot(self: *UndoRedoService, resource: Uri) !ResourceEditStackSnapshot {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
        if (self._editStacks.get(strResource)) |*editStack| {
            return try editStack.createSnapshot(resource);
        }
        return ResourceEditStackSnapshot{ .resource = resource, .elements = ArrayList(u64).init(self._editStacks.allocator) };
    }

    pub fn restoreSnapshot(self: *UndoRedoService, snapshot: ResourceEditStackSnapshot) void {
        var strResource = try self.getUriComparisonKey(snapshot.resource);
        defer strResource.deinit();
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
        const strResource = try self.getUriComparisonKey(resource);
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
        var matchedStrResource: ?String = null;

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

    pub fn canUndo(self: *UndoRedoService, resourceOrSource: UndoRedoSourceOrUri) !bool {
        switch (resourceOrSource) {
            .source => |source| {
                if (self._findClosestUndoElementWithSource(source.id).second) |_| {
                    return true;
                }
            },
            .uri => |uri| {
                const strResource = try self.getUriComparisonKey(uri);
                if (self._editStacks.get(strResource)) |*editStack| {
                    return editStack.hasPastElements();
                }
            },
            .str => |strResource| {
                if (self._editStacks.get(strResource)) |*editStack| {
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
        for (element.strResources()) |strResource| {
            self.removeElementsStr(strResource);
        }
        //self._notificationService.error(err);
    }

    fn _acquireLocks(self: *UndoRedoService, editStackSnapshot: EditStackSnapshot) (*const fn () void) {
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

        return &struct {
            fn releaseLocks() void {
                for (editStackSnapshot.editStacks) |editStack| {
                    editStack.locked = false;
                }
            }
        }.releaseLocks;
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

    fn _invokeWorkspacePrepare(self: *UndoRedoService, element: *const WorkspaceStackElement) ?Disposable {
        _ = self;
        _ = element;
        return null;

        // if (element.actual.prepareUndoRedo == null) {
        //     return;
        // }
        // element.actual.prepareUndoRedo();
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
        for (element.strResources.items) |strResource| {
            try affectedEditStacks.append(self._editStacks.get(strResource) orelse missingEditStack);
        }
        return EditStackSnapshot.init(affectedEditStacks);
    }

    fn _tryToSplitAndUndo(self: *UndoRedoService, strResource: String, element: *WorkspaceStackElement, ignoreResources: ?RemovedResources, message: []const u8) !WorkspaceVerificationError {
        if (element.canSplit()) {
            try self._splitPastWorkspaceElement(element, ignoreResources);
            self._notificationService.warn(message);
            try self._undo(strResource, 0, true);
            return WorkspaceVerificationError{ .returnValue = null };
        } else {
            // Cannot safely split this workspace element => flush all undo/redo stacks
            for (element.strResources.items) |str| {
                try self.removeElementsStr(str);
            }
            self._notificationService.warn(message);
            return WorkspaceVerificationError{ .returnValue = null };
        }
    }

    fn _checkWorkspaceUndo(self: *UndoRedoService, strResource: String, element: *WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, checkInvalidatedResources: bool) !?WorkspaceVerificationError {
        if (element.removedResources) |removedResources| {
            return try self._tryToSplitAndUndo(strResource, element, removedResources, "Could not undo '{0}' across all files. {1}" //, element.label, element.removedResources.createMessage()
            );
        }
        if (checkInvalidatedResources and element.invalidatedResources != null) {
            return try self._tryToSplitAndUndo(strResource, element, element.invalidatedResources, "Could not undo '{0}' across all files. {1}" //, element.label, element.invalidatedResources.createMessage()
            );
        }

        // this must be the last past element in all the impacted resources!
        var cannotUndoDueToResources = ArrayList([]const u8).init(std.heap.page_allocator);
        defer cannotUndoDueToResources.deinit();
        for (editStackSnapshot.editStacks.items) |editStack| {
            var ele = editStack.getClosestPastElement();
            if (ele == null or ele.?.id() != element.id) {
                try cannotUndoDueToResources.append(editStack.resourceLabel);
            }
        }
        if (cannotUndoDueToResources.items.len > 0) {
            return try self._tryToSplitAndUndo(strResource, element, null, "Could not undo '{0}' across all files because changes were made to {1}" //, element.label, cannotUndoDueToResources.join(', ')
            );
        }

        var cannotLockDueToResources = ArrayList([]const u8).init(std.heap.page_allocator);
        defer cannotLockDueToResources.deinit();

        for (editStackSnapshot.editStacks.items) |editStack| {
            if (editStack.locked) {
                try cannotLockDueToResources.append(editStack.resourceLabel);
            }
        }
        if (cannotLockDueToResources.items.len > 0) {
            return try self._tryToSplitAndUndo(strResource, element, null, "Could not undo '{0}' across all files because there is already an undo or redo operation running on {1}" //, element.label, cannotLockDueToResources.join(', ')
            );
        }

        // check if new stack elements were added in the meantime...
        if (!editStackSnapshot.isValid()) {
            return try self._tryToSplitAndUndo(strResource, element, null, "Could not undo '{0}' across all files because an undo or redo operation occurred in the meantime" //, element.label
            );
        }

        return null;
    }

    fn _workspaceUndo(self: *UndoRedoService, strResource: String, element: *WorkspaceStackElement, undoConfirmed: bool) !void {
        const affectedEditStacks = try self._getAffectedEditStacks(element);
        const verificationError = try self._checkWorkspaceUndo(strResource, element, affectedEditStacks, false); // invalidated resources will be checked after the prepare call
        if (verificationError) |err| {
            _ = err;
        }
        try self._confirmAndExecuteWorkspaceUndo(strResource, element, affectedEditStacks, undoConfirmed);
    }

    fn _isPartOfUndoGroup(self: *UndoRedoService, element: *WorkspaceStackElement) bool {
        if (element.groupId == 0) {
            return false;
        }
        // check that there is at least another element with the same groupId ready to be undone
        var iter = self._editStacks.valueIterator();
        while (iter.next()) |editStack| {
            if (editStack.getClosestPastElement()) |pastElement| {
                if (pastElement.id() == element.id) {
                    const secondPastElement = editStack.getSecondClosestPastElement();
                    if (secondPastElement != null and secondPastElement.?.groupId() == element.groupId) {
                        // there is another element with the same group id in the same stack!
                        return true;
                    }
                }
                if (pastElement.groupId() == element.groupId) {
                    // there is another element with the same group id in another stack!
                    return true;
                }
            }
        }
        return false;
    }

    const UndoChoice = enum(u2) { All = 0, This = 1, Cancel = 2 };

    fn _confirmAndExecuteWorkspaceUndo(self: *UndoRedoService, strResource: String, element: *WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, undoConfirmed: bool) !void {
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
                try self._splitPastWorkspaceElement(element, null);
                try self._undo(strResource, 0, true);
                return;
            }

            // choice: undo in all files

            // At this point, it is possible that the element has been made invalid in the meantime (due to the confirmation await)
            const verificationError1 = try self._checkWorkspaceUndo(strResource, element, editStackSnapshot, false); // invalidated resources will be checked after the prepare call
            if (verificationError1) |err| {
                _ = err;
            }

            undoConfirmed = true;
        }

        // prepare
        const cleanup: ?Disposable = self._invokeWorkspacePrepare(element);

        // At this point, it is possible that the element has been made invalid in the meantime (due to the prepare await)
        const verificationError2 = try self._checkWorkspaceUndo(strResource, element, editStackSnapshot, true); // now also check that there are no more invalidated resources
        if (verificationError2) |err| {
            if (cleanup) |c| {
                c.dispose();
            }
            _ = err;
        }

        for (editStackSnapshot.editStacks.items) |*editStack| {
            try editStack.moveBackward(.{ .workspaceStackElement = element.* });
        }
        // return self._safeInvokeWithLocks(element, () => element.actual.undo(), editStackSnapshot, cleanup, () => self._continueUndoInGroup(element.groupId, undoConfirmed));
    }

    fn _resourceUndo(self: *UndoRedoService, editStack: *ResourceEditStack, element: *const ResourceStackElement, undoConfirmed: bool) !void {
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
        // _ = undoConfirmed;
        try editStack.moveBackward(.{ .resourceStackElement = element.* });
        try element.actual.undo();
        try self._continueUndoInGroup(element.groupId, undoConfirmed);

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
        var matchedStrResource: ?String = null;

        var iter = self._editStacks.iterator();
        while (iter.next()) |entry| {
            const strResource = entry.key_ptr;
            const editStack = entry.value_ptr;
            if (editStack.getClosestPastElement()) |candidate| {
                if (candidate.groupId() == groupId) {
                    if (matchedElement == null or candidate.groupOrder() > matchedElement.?.groupOrder()) {
                        matchedElement = candidate;
                        matchedStrResource = strResource.*;
                    }
                }
            }
        }

        return pair(matchedElement, matchedStrResource);
    }

    fn _continueUndoInGroup(self: *UndoRedoService, groupId: u64, undoConfirmed: bool) !void {
        if (groupId == 0) {
            return;
        }

        const res = self._findClosestUndoElementInGroup(groupId);
        const matchedStrResource = res.second;
        if (matchedStrResource) |strResource| {
            try self._undo(strResource, 0, undoConfirmed);
        }
    }

    pub fn undo(self: *UndoRedoService, resourceOrSource: UndoRedoSourceOrUri) !void {
        switch (resourceOrSource) {
            .source => |source| {
                if (self._findClosestUndoElementWithSource(source.id).second) |matchedStrResource| {
                    try self._undo(matchedStrResource, source.id, false);
                }
            },
            .uri => |uri| {
                var strResource = try self.getUriComparisonKey(uri);
                defer strResource.deinit();
                try self._undo(strResource, 0, false);
            },
            .str => |strResource| {
                try self._undo(strResource, 0, false);
            },
        }
    }

    fn _undo(self: *UndoRedoService, strResource: String, sourceId: u64, undoConfirmed: bool) anyerror!void {
        if (self._editStacks.getPtr(strResource)) |editStack| {
            var ele = editStack.getClosestPastElement();
            if (ele) |*element| {
                if (element.groupId() != 0) {
                    // this element is a part of a group, we need to make sure undoing in a group is in order
                    const res = self._findClosestUndoElementInGroup(element.groupId());
                    const matchedElement = res.first;
                    const matchedStrResource = res.second;
                    std.debug.print("\nmatchedElement: {d}, element: {d}\n", .{ matchedElement.?.id(), element.id() });
                    if ((matchedElement == null or element.id() != matchedElement.?.id()) and matchedStrResource != null) {
                        // there is an element in the same group that should be undone before this one
                        try self._undo(matchedStrResource.?, sourceId, undoConfirmed);
                    }
                }

                const shouldPromptForConfirmation = (element.sourceId() != sourceId or element.confirmBeforeUndo());
                if (shouldPromptForConfirmation and !undoConfirmed) {
                    // Hit a different source or the element asks for prompt before undo, prompt for confirmation
                    try self._confirmAndContinueUndo(strResource, sourceId, element);
                }

                defer {
                    if (DEBUG) {
                        self._print("undo");
                    }
                }

                switch (element.*) {
                    .resourceStackElement => |*resourceStackElement| {
                        try self._resourceUndo(editStack, resourceStackElement, undoConfirmed);
                    },
                    .workspaceStackElement => |*workspaceStackElement| {
                        try self._workspaceUndo(strResource, workspaceStackElement, undoConfirmed);
                    },
                }
            }
        }
    }

    fn _confirmAndContinueUndo(self: *UndoRedoService, strResource: String, sourceId: u64, element: *StackElement) !void {
        _ = element;
        // const result = await self._dialogService.confirm({
        //     message: nls.localize('confirmDifferentSource', "Would you like to undo '{0}'?", element.label),
        //     primaryButton: nls.localize({ key: 'confirmDifferentSource.yes', comment: "&& denotes a mnemonic" }, "&&Yes"),
        //     cancelButton: nls.localize('confirmDifferentSource.no', "No")
        // });

        // if (!result.confirmed) {
        //     return;
        // }

        try self._undo(strResource, sourceId, true);
    }

    fn _findClosestRedoElementWithSource(self: *UndoRedoService, sourceId: u64) ResultPair {
        if (sourceId == 0) {
            return ResultPair{ .first = null, .second = null };
        }

        // find an element with sourceId and with the lowest sourceOrder ready to be redone
        var matchedElement: ?StackElement = null;
        var matchedStrResource: ?String = null;

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
                var strResource = try self.getUriComparisonKey(uri);
                defer strResource.deinit();
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

    fn _tryToSplitAndRedo(self: *UndoRedoService, strResource: String, element: *const WorkspaceStackElement, ignoreResources: ?RemovedResources, message: []const u8) !WorkspaceVerificationError {
        if (element.canSplit()) {
            try self._splitFutureWorkspaceElement(element, ignoreResources);
            self._notificationService.warn(message);
            try self._redo(strResource);
            return WorkspaceVerificationError{ .returnValue = null };
        } else {
            // Cannot safely split this workspace element => flush all undo/redo stacks
            for (element.strResources.items) |str| {
                try self.removeElementsStr(str);
            }
            self._notificationService.warn(message);
            return WorkspaceVerificationError{ .returnValue = null };
        }
    }

    fn _checkWorkspaceRedo(self: *UndoRedoService, strResource: String, element: *const WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, checkInvalidatedResources: bool) !?WorkspaceVerificationError {
        if (element.removedResources) |removedResources| {
            return try self._tryToSplitAndRedo(strResource, element, removedResources, "Could not redo '{0}' across all files. {1}" //, element.label, element.removedResources.createMessage()
            );
        }
        if (checkInvalidatedResources and element.invalidatedResources != null) {
            return try self._tryToSplitAndRedo(strResource, element, element.invalidatedResources, "Could not redo '{0}' across all files. {1}" //, element.label, element.invalidatedResources.createMessage()
            );
        }

        // this must be the last future element in all the impacted resources!
        var cannotRedoDueToResources = ArrayList([]const u8).init(std.heap.page_allocator);
        defer cannotRedoDueToResources.deinit();
        for (editStackSnapshot.editStacks.items) |editStack| {
            var ele = editStack.getClosestFutureElement();
            if (ele == null or ele.?.id() != element.id) {
                try cannotRedoDueToResources.append(editStack.resourceLabel);
            }
        }
        if (cannotRedoDueToResources.items.len > 0) {
            return try self._tryToSplitAndRedo(strResource, element, null, "Could not redo '{0}' across all files because changes were made to {1}" //, element.label, cannotRedoDueToResources.join(', ')
            );
        }

        var cannotLockDueToResources = ArrayList([]const u8).init(std.heap.page_allocator);
        defer cannotLockDueToResources.deinit();
        for (editStackSnapshot.editStacks.items) |editStack| {
            if (editStack.locked) {
                try cannotLockDueToResources.append(editStack.resourceLabel);
            }
        }
        if (cannotLockDueToResources.items.len > 0) {
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

    fn _workspaceRedo(self: *UndoRedoService, strResource: String, element: *const WorkspaceStackElement) !void {
        const affectedEditStacks = try self._getAffectedEditStacks(element);
        // invalidated resources will be checked after the prepare call
        const verificationError = try self._checkWorkspaceRedo(strResource, element, affectedEditStacks, false);
        if (verificationError) |err| {
            _ = err;
        }
        try self._executeWorkspaceRedo(strResource, element, affectedEditStacks);
    }

    fn _executeWorkspaceRedo(self: *UndoRedoService, strResource: String, element: *const WorkspaceStackElement, editStackSnapshot: EditStackSnapshot) !void {
        // prepare
        const cleanup = self._invokeWorkspacePrepare(element);

        // At this point, it is possible that the element has been made invalid in the meantime (due to the prepare await)
        // now also check that there are no more invalidated resources
        const verificationError = try self._checkWorkspaceRedo(strResource, element, editStackSnapshot, true);
        if (verificationError) |err| {
            if (cleanup) |c| {
                c.dispose();
            }
            _ = err;
            return;
        }

        for (editStackSnapshot.editStacks.items) |*editStack| {
            try editStack.moveForward(.{ .workspaceStackElement = element.* });
        }
        try element.actual.redo();
        try self._continueRedoInGroup(element.groupId);
        // return self._safeInvokeWithLocks(element, () => element.actual.redo(), editStackSnapshot, cleanup, () => self._continueRedoInGroup(element.groupId));
    }

    fn _resourceRedo(self: *UndoRedoService, editStack: *ResourceEditStack, element: *const ResourceStackElement) !void {
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
        try editStack.moveForward(.{ .resourceStackElement = element.* });
        try element.actual.redo();
        try self._continueRedoInGroup(element.groupId);

        // return self._invokeResourcePrepare(element, (cleanup) => {
        //     editStack.moveForward(element);
        //     // return self._safeInvokeWithLocks(element, () => element.actual.redo(), new EditStackSnapshot([editStack]), cleanup, () => self._continueRedoInGroup(element.groupId));
        // });
    }

    const ResultPair = Pair(?StackElement, ?String);

    fn _findClosestRedoElementInGroup(self: *UndoRedoService, groupId: u64) ResultPair {
        if (groupId == 0) {
            return ResultPair{ .first = null, .second = null };
        }

        // find another element with the same groupId and with the lowest groupOrder ready to be redone
        var matchedElement: ?StackElement = null;
        var matchedStrResource: ?String = null;

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

    fn _continueRedoInGroup(self: *UndoRedoService, groupId: u64) !void {
        if (groupId == 0) {
            return;
        }

        if (self._findClosestRedoElementInGroup(groupId).second) |matchedStrResource| {
            try self._redo(matchedStrResource);
        }
    }

    pub fn redo(self: *UndoRedoService, resourceOrSource: UndoRedoSourceOrUri) !void {
        switch (resourceOrSource) {
            .source => |source| {
                if (self._findClosestRedoElementWithSource(source.id).second) |matchedStrResource| {
                    try self._redo(matchedStrResource);
                }
            },
            .uri => |uri| {
                var strResource = try self.getUriComparisonKey(uri);
                defer strResource.deinit();
                try self._redo(strResource);
            },
            .str => |str| {
                try self._redo(str);
            },
        }
    }

    fn _redo(self: *UndoRedoService, strResource: String) anyerror!void {
        if (self._editStacks.getPtr(strResource)) |editStack| {
            if (editStack.getClosestFutureElement()) |*element| {
                const groupId = element.groupId();
                if (groupId != 0) {
                    // this element is a part of a group, we need to make sure redoing in a group is in order
                    const res = self._findClosestRedoElementInGroup(groupId);
                    const matchedElement = res.first;
                    const matchedStrResource = res.second;
                    std.debug.print("matchedElement: {d}, element: {d}\n", .{ matchedElement.?.id(), element.id() });
                    if ((matchedElement == null or element.id() != matchedElement.?.id()) and matchedStrResource != null) {
                        // there is an element in the same group that should be redone before this one
                        try self._redo(matchedStrResource.?);
                    }
                }

                defer {
                    if (DEBUG) {
                        self._print("redo");
                    }
                }

                switch (element.*) {
                    .resourceStackElement => |*resourceStackElement| {
                        return try self._resourceRedo(editStack, resourceStackElement);
                    },
                    .workspaceStackElement => |*workspaceStackElement| {
                        return try self._workspaceRedo(strResource, workspaceStackElement);
                    },
                }
            }
        }
    }
};

test "UndoRedoService.init" {
    const allocator = std.testing.allocator;
    var undoRedoService = UndoRedoService.init(allocator);
    defer undoRedoService.deinit();
}
