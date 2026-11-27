const std = @import("std");
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const EditStackElement = @import("../../../editor/common/model/editStack.zig").EditStackElement;
const UndoRedoGroup = @import("./undoRedo.zig").UndoRedoGroup;
const UndoRedoSource = @import("./undoRedo.zig").UndoRedoSource;
const UriContext = @import("../../../editor/common/model/editStack.zig").UriContext;
const PastFutureElements = @import("./undoRedo.zig").PastFutureElements;
const ResourceEditStackSnapshot = @import("./undoRedo.zig").ResourceEditStackSnapshot;
const UriComparisonKeyComputer = @import("./undoRedo.zig").UriComparisonKeyComputer;
const Disposable = @import("./undoRedo.zig").IDisposable;
const uri_util = @import("../../../base/common/stdUri.zig");
const UndoRedoSourceOrUri = @import("./undoRedo.zig").UndoRedoSourceOrUri;
const Pair = @import("../../../base/common/utils.zig").Pair;
const pair = @import("../../../base/common/utils.zig").pair;
const SingleModelEditStackElement = @import("../../../editor/common/model/editStack.zig").SingleModelEditStackElement;
const Selection = @import("../../../editor/common/core/selection.zig").Selection;
const String = @import("../../../base/common/strings.zig").String;
const INotificationService = @import("../../notification/common/notification.zig").INotificationService;

const DEBUG = false;

fn getResourceLabel(resource: Uri) []const u8 {
    switch (resource.path) {
        .raw => |raw| return raw,
        .percent_encoded => |path| return path,
    }
}

var stackElementCount: u64 = 0;

const StackElement = union(enum) {
    resourceStackElement: ResourceStackElement,
    workspaceStackElement: *WorkspaceStackElement,

    pub fn initResourceStackElement(actual_: *EditStackElement, resourceLabel: []const u8, strResource: String, groupId_: u64, groupOrder_: u64, sourceId_: u64, sourceOrder_: u64) StackElement {
        return .{ .resourceStackElement = ResourceStackElement.init(actual_, resourceLabel, strResource, groupId_, groupOrder_, sourceId_, sourceOrder_) };
    }

    pub fn deinit(self: *StackElement) void {
        switch (self.*) {
            .resourceStackElement => |*resourceStackElement| resourceStackElement.deinit(),
            .workspaceStackElement => |workspaceStackElement| workspaceStackElement.release(),
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

    pub fn strResources(self: *const StackElement, buffer: *[1]String) []const String {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| blk: {
                buffer.* = .{resourceStackElement.strResource};
                break :blk buffer[0..1];
            },
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

    pub fn resourceLabels(self: *const StackElement, buffer: *[1][]const u8) []const []const u8 {
        return switch (self.*) {
            .resourceStackElement => |resourceStackElement| blk: {
                buffer.* = .{resourceStackElement.resourceLabel};
                break :blk buffer[0..1];
            },
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
            .confirmBeforeUndo = actual.confirmBeforeUndo(),
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

    pub fn toString(self: *const ResourceStackElement) ![]u8 {
        return try std.fmt.allocPrint(self.actual.getAllocator(), "[id:{}][group:{}] [{}]{}", .{ self.id, self.groupId, if (self.isValid) "  VALID" else "INVALID", self.actual });
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
        errdefer messages.deinit();
        if (externalRemoval.items.len > 0) {
            const removal = try std.mem.join(allocator, ", ", externalRemoval.items);
            defer allocator.free(removal);
            const line = try std.fmt.allocPrint(allocator, "The following files have been closed and modified on disk: {0}.\n", .{removal});
            defer allocator.free(line);
            try messages.appendSlice(line);
        }
        if (noParallelUniverses.items.len > 0) {
            const noParallel = try std.mem.join(allocator, ", ", noParallelUniverses.items);
            defer allocator.free(noParallel);
            const line = try std.fmt.allocPrint(allocator, "The following files have been modified in an incompatible way: {0}.\n", .{noParallel});
            defer allocator.free(line);
            try messages.appendSlice(line);
        }
        return messages.toOwnedSlice();
    }

    pub fn size(self: *RemovedResources) usize {
        return self.elements.count();
    }

    pub fn has(self: *const RemovedResources, strResource: []const u8) bool {
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
    refs: usize = 1,
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
            .confirmBeforeUndo = actual.confirmBeforeUndo(),
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

    pub fn retain(self: *WorkspaceStackElement) void {
        self.refs += 1;
    }

    pub fn release(self: *WorkspaceStackElement) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const allocator = self.strResources.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    fn deinit(self: *WorkspaceStackElement) void {
        if (self.removedResources) |*removedResources| removedResources.elements.deinit();
        if (self.invalidatedResources) |*invalidatedResources| invalidatedResources.elements.deinit();
        for (self.strResources.items) |*strResource| {
            strResource.deinit();
        }
        self.strResources.deinit();
        for (self.resourceLabels.items) |label| self.resourceLabels.allocator.free(label);
        self.resourceLabels.deinit();
        const allocator = self.actual.getAllocator();
        self.actual.deinit();
        allocator.destroy(self.actual);
    }

    pub fn canSplit(self: *const WorkspaceStackElement) bool {
        return switch (self.actual.*) {
            .singleModel, .workspace => false,
            .multiModel => true,
        };
    }

    fn stableResource(self: *const WorkspaceStackElement, strResource: []const u8) ?struct { key: []const u8, label: []const u8 } {
        for (self.strResources.items, self.resourceLabels.items) |str, label| {
            if (std.mem.eql(u8, str.items(), strResource)) return .{ .key = str.items(), .label = label };
        }
        return null;
    }

    pub fn removeResource(self: *WorkspaceStackElement, _: []const u8, strResource: []const u8, reason: RemovedResourceReason) !void {
        const stable = self.stableResource(strResource) orelse return;
        if (self.removedResources == null) {
            const allocator = self.actual.getAllocator();
            self.removedResources = RemovedResources{ .elements = std.StringHashMap(ResourceReasonPair).init(allocator) };
        }
        if (self.removedResources) |*removedResources| {
            if (!removedResources.has(strResource)) {
                try removedResources.set(stable.key, ResourceReasonPair{ .resourceLabel = stable.label, .reason = reason });
            }
        }
    }

    pub fn setValid(self: *WorkspaceStackElement, _: []const u8, strResource: []const u8, isValid: bool) !void {
        const stable = self.stableResource(strResource) orelse return;
        if (self.invalidatedResources) |*invalidatedResources| {
            _ = invalidatedResources.delete(strResource);
            if (invalidatedResources.size() == 0) {
                invalidatedResources.elements.deinit();
                self.invalidatedResources = null;
            }
        }
        if (!isValid) {
            if (self.invalidatedResources == null) {
                const allocator = self.actual.getAllocator();
                self.invalidatedResources = RemovedResources{ .elements = std.StringHashMap(ResourceReasonPair).init(allocator) };
            }
            if (self.invalidatedResources) |*invalidatedResources| {
                if (!invalidatedResources.has(strResource)) {
                    try invalidatedResources.set(stable.key, ResourceReasonPair{ .resourceLabel = stable.label, .reason = RemovedResourceReason.ExternalRemoval });
                }
            }
        }
    }

    pub fn toString(self: *const WorkspaceStackElement) ![]u8 {
        return try std.fmt.allocPrint(self.actual.getAllocator(), "[id:{}] [group:{}] [{}]{}", .{ self.id, self.groupId, if (self.invalidatedResources) |_| "INVALID" else "  VALID", self.actual });
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
    owned_resource_label: ?[]u8 = null,
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
        // The map key points at this owned copy; the value owns it until the
        // stack is removed from the map.
        self.strResource.deinit();
        if (self.owned_resource_label) |label| self.getAllocator().free(label);
    }

    fn getAllocator(self: *const ResourceEditStack) Allocator {
        return self._past.allocator;
    }

    pub fn dispose(self: *ResourceEditStack) !void {
        for (self._past.items) |*element| {
            switch (element.*) {
                .workspaceStackElement => |workspaceStackElement| {
                    try workspaceStackElement.removeResource(self.resourceLabel, self.strResource.items(), RemovedResourceReason.ExternalRemoval);
                },
                .resourceStackElement => {},
            }
        }
        for (self._future.items) |*element| {
            switch (element.*) {
                .workspaceStackElement => |workspaceStackElement| {
                    try workspaceStackElement.removeResource(self.resourceLabel, self.strResource.items(), RemovedResourceReason.ExternalRemoval);
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
        try result.appendSlice(self.strResource.items());
        try result.appendSlice(":\n");
        for (self._past.items) |element| {
            try result.appendSlice("   * [UNDO] ");
            const elementString = try element.toString();
            defer self.getAllocator().free(elementString);
            try result.appendSlice(elementString);
            try result.appendSlice("\n");
        }
        for (self._future.items) |element| {
            try result.appendSlice("   * [REDO] ");
            const elementString = try element.toString();
            defer self.getAllocator().free(elementString);
            try result.appendSlice(elementString);
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
        for (self._past.items) |*element| self._setElementValidFlag(element, isValid);
        for (self._future.items) |*element| self._setElementValidFlag(element, isValid);
    }

    fn _setElementValidFlag(self: *ResourceEditStack, element: *StackElement, isValid: bool) void {
        switch (element.*) {
            .workspaceStackElement => |workspaceStackElement| {
                workspaceStackElement.setValid(self.resourceLabel, self.strResource.items(), isValid) catch {};
            },
            .resourceStackElement => |*resourceStackElement| {
                resourceStackElement.setValid(isValid);
            },
        }
    }

    pub fn setElementsValidFlag(self: *ResourceEditStack, isValid: bool, filter: *const fn (element: *const EditStackElement) bool) void {
        for (self._past.items) |*element| {
            if (filter(element.actual())) {
                self._setElementValidFlag(element, isValid);
            }
        }
        for (self._future.items) |*element| {
            if (filter(element.actual())) {
                self._setElementValidFlag(element, isValid);
            }
        }
    }

    fn preparePush(self: *ResourceEditStack) !void {
        try self._past.ensureUnusedCapacity(1);
        for (self._future.items) |*futureElement| {
            switch (futureElement.*) {
                .workspaceStackElement => try futureElement.workspaceStackElement.removeResource(self.resourceLabel, self.strResource.items(), RemovedResourceReason.NoParallelUniverses),
                .resourceStackElement => {},
            }
        }
    }

    fn pushPrepared(self: *ResourceEditStack, element: StackElement) void {
        for (self._future.items) |*futureElement| futureElement.deinit();
        self._future.clearAndFree();
        self._past.appendAssumeCapacity(element);
        self.versionId += 1;
    }

    pub fn createSnapshot(self: *const ResourceEditStack, resource: Uri) !ResourceEditStackSnapshot {
        var elements = ArrayList(u64).init(self.getAllocator());

        for (self._past.items) |element| {
            try elements.append(element.id());
        }
        var future_index = self._future.items.len;
        while (future_index > 0) {
            future_index -= 1;
            try elements.append(self._future.items[future_index].id());
        }

        return ResourceEditStackSnapshot{ .resource = resource, .elements = elements };
    }

    pub fn restoreSnapshot(self: *ResourceEditStack, snapshot: ResourceEditStackSnapshot) void {
        const snapshotLength = snapshot.elements.items.len;
        var isOK = true;
        var snapshotIndex: usize = 0;

        var removePastAfter: ?usize = null;
        for (self._past.items, 0..) |*element, i| {
            if (isOK and (snapshotIndex >= snapshotLength or element.id() != snapshot.elements.items[snapshotIndex])) {
                isOK = false;
                removePastAfter = i;
            }
            switch (element.*) {
                .workspaceStackElement => |workspaceStackElement| {
                    if (!isOK) {
                        workspaceStackElement.removeResource(self.resourceLabel, self.strResource.items(), RemovedResourceReason.ExternalRemoval) catch {};
                    }
                },
                .resourceStackElement => {},
            }
            snapshotIndex += 1;
        }

        var removeFutureBefore: ?usize = null;
        var future_index = self._future.items.len;
        while (future_index > 0) {
            future_index -= 1;
            const element = &self._future.items[future_index];
            if (isOK and (snapshotIndex >= snapshotLength or element.id() != snapshot.elements.items[snapshotIndex])) {
                isOK = false;
                removeFutureBefore = future_index;
            }
            switch (element.*) {
                .workspaceStackElement => |workspaceStackElement| {
                    if (!isOK) {
                        workspaceStackElement.removeResource(self.resourceLabel, self.strResource.items(), RemovedResourceReason.ExternalRemoval) catch {};
                    }
                },
                .resourceStackElement => {},
            }
            snapshotIndex += 1;
        }

        if (removePastAfter) |keep_len| {
            var i = self._past.items.len;
            while (i > keep_len) {
                i -= 1;
                self._past.items[i].deinit();
            }
            self._past.shrinkRetainingCapacity(keep_len);
        }
        if (removeFutureBefore) |last_removed| {
            const remove_len = last_removed + 1;
            for (self._future.items[0..remove_len]) |*element| element.deinit();
            const keep_len = self._future.items.len - remove_len;
            std.mem.copyForwards(StackElement, self._future.items[0..keep_len], self._future.items[remove_len..]);
            self._future.shrinkRetainingCapacity(keep_len);
        }
        self.versionId += 1;
    }

    pub fn getElements(self: *const ResourceEditStack) !PastFutureElements {
        var past = ArrayList(*const EditStackElement).init(self.getAllocator());
        errdefer past.deinit();
        var future = ArrayList(*const EditStackElement).init(self.getAllocator());
        errdefer future.deinit();

        for (self._past.items) |element| {
            try past.append(element.actual());
        }
        for (self._future.items) |element| {
            try future.append(element.actual());
        }

        const past_elements = try past.toOwnedSlice();
        errdefer self.getAllocator().free(past_elements);
        const future_elements = try future.toOwnedSlice();
        return PastFutureElements{
            .past = past_elements,
            .future = future_elements,
        };
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

    pub fn splitPastWorkspaceElement(self: *ResourceEditStack, toRemove: *const WorkspaceStackElement, individualMap: *std.StringHashMap(ResourceStackElement)) void {
        var j: usize = self._past.items.len;
        while (j > 0) {
            j -= 1;
            if (self._past.items[j].id() == toRemove.id) {
                if (individualMap.fetchRemove(self.strResource.items())) |individual| {
                    // gets replaced
                    self._past.items[j].deinit();
                    self._past.items[j] = .{ .resourceStackElement = individual.value };
                } else {
                    // gets deleted
                    var removed = self._past.orderedRemove(j);
                    removed.deinit();
                }
                break;
            }
        }
        self.versionId += 1;
    }

    pub fn splitFutureWorkspaceElement(self: *ResourceEditStack, toRemove: *const WorkspaceStackElement, individualMap: *std.StringHashMap(ResourceStackElement)) void {
        var j: usize = self._future.items.len;
        while (j > 0) {
            j -= 1;
            if (self._future.items[j].id() == toRemove.id) {
                if (individualMap.fetchRemove(self.strResource.items())) |individual| {
                    // gets replaced
                    self._future.items[j].deinit();
                    self._future.items[j] = .{ .resourceStackElement = individual.value };
                } else {
                    // gets deleted
                    var removed = self._future.orderedRemove(j);
                    removed.deinit();
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
    editStacks: ArrayList(*ResourceEditStack),
    _versionIds: ArrayList(u64),

    pub fn init(editStacks: ArrayList(*ResourceEditStack)) !EditStackSnapshot {
        var versionIds = ArrayList(u64).init(editStacks.allocator);
        errdefer versionIds.deinit();
        for (editStacks.items) |editStack| {
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
    _editStacks: std.StringHashMap(ResourceEditStack),
    _uriComparisonKeyComputers: ArrayList(KeyComputerPair),
    _notificationService: ?INotificationService = null,
    pending_workspace_preparations: std.AutoHashMapUnmanaged(*WorkspacePreparation, void) = .empty,

    pub fn init(allocator: Allocator) UndoRedoService {
        return UndoRedoService{
            ._editStacks = std.StringHashMap(ResourceEditStack).init(allocator),
            ._uriComparisonKeyComputers = ArrayList(KeyComputerPair).init(allocator),
        };
    }

    pub fn setNotificationService(self: *UndoRedoService, service: INotificationService) void {
        self._notificationService = service;
    }

    fn notifyWarning(self: *UndoRedoService, message: []const u8) void {
        if (self._notificationService) |service| service.warn(.{ .text = message }) else std.debug.print("WARNING: {s}\n", .{message});
    }

    pub fn deinit(self: *UndoRedoService) void {
        self.cancelPendingPreparations();
        self.pending_workspace_preparations.deinit(self._editStacks.allocator);
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
        const allocator = self._uriComparisonKeyComputers.allocator;
        return String.initOwned(ArrayList(u8).fromOwnedSlice(allocator, try uri_util.resourceKey(allocator, resource)));
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
            str.appendSlice(key.*) catch {};
            str.appendSlice("\n") catch {};
        }
        std.debug.print("{s}", .{str.items});
    }

    pub fn pushElement(self: *UndoRedoService, element: *EditStackElement, _group: ?*UndoRedoGroup, _source: ?*UndoRedoSource) !void {
        var none_group = UndoRedoGroup.None;
        var none_source = UndoRedoSource.None;
        const group = _group orelse &none_group;
        const source = _source orelse &none_source;

        switch (element.*) {
            .singleModel => |singleModel| {
                const resourceLabel = getResourceLabel(singleModel.resource());
                const strResource = try self.getUriComparisonKey(singleModel.resource());
                try self._pushElement(.{ .resourceStackElement = ResourceStackElement.init(element, resourceLabel, strResource, group.id, group.nextOrder(), source.id, source.nextOrder()) });
            },
            .multiModel => |multiModel| {
                var resources = try multiModel.resources();
                defer resources.deinit();
                try self.pushWorkspaceElement(element, resources.items, group, source);
            },
            .workspace => |workspace| try self.pushWorkspaceElement(element, workspace.resources, group, source),
        }
    }

    fn pushWorkspaceElement(self: *UndoRedoService, element: *EditStackElement, resources: []const Uri, group: *UndoRedoGroup, source: *UndoRedoSource) !void {
        const allocator = self._uriComparisonKeyComputers.allocator;
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        var resourceLabels = ArrayList([]const u8).init(allocator);
        errdefer resourceLabels.deinit();
        var strResources = ArrayList(String).init(allocator);
        errdefer {
            for (strResources.items) |*str| str.deinit();
            strResources.deinit();
        }
        for (resources) |resource| {
            var strResource = try self.getUriComparisonKey(resource);
            if (seen.contains(strResource.items())) {
                strResource.deinit();
                continue;
            }
            errdefer strResource.deinit();
            try seen.put(strResource.items(), {});
            try resourceLabels.append(getResourceLabel(resource));
            try strResources.append(strResource);
        }
        if (resourceLabels.items.len == 0) {
            resourceLabels.deinit();
            strResources.deinit();
            const a = element.getAllocator();
            element.deinit();
            a.destroy(element);
        } else if (resourceLabels.items.len == 1) {
            try self._pushElement(.{ .resourceStackElement = ResourceStackElement.init(element, resourceLabels.items[0], strResources.items[0], group.id, group.nextOrder(), source.id, source.nextOrder()) });
            resourceLabels.deinit();
            strResources.deinit();
        } else {
            var owned_labels = ArrayList([]const u8).init(allocator);
            errdefer {
                for (owned_labels.items) |label| allocator.free(label);
                owned_labels.deinit();
            }
            try owned_labels.ensureTotalCapacity(resourceLabels.items.len);
            for (resourceLabels.items) |label| owned_labels.appendAssumeCapacity(try allocator.dupe(u8, label));
            const workspace = try allocator.create(WorkspaceStackElement);
            errdefer allocator.destroy(workspace);
            workspace.* = WorkspaceStackElement.init(element, owned_labels, strResources, group.id, group.nextOrder(), source.id, source.nextOrder());
            try self._pushElement(.{ .workspaceStackElement = workspace });
            workspace.release(); // each affected stack now owns a reference
            resourceLabels.deinit();
        }
    }

    pub fn _pushElement(self: *UndoRedoService, element: StackElement) !void {
        const allocator = self._editStacks.allocator;
        var str_resources_buffer: [1]String = undefined;
        var resource_labels_buffer: [1][]const u8 = undefined;
        const str_resources = element.strResources(&str_resources_buffer);
        const resource_labels = element.resourceLabels(&resource_labels_buffer);
        for (str_resources, 0..) |strResource, i| {
            const resourceLabel = resource_labels[i];

            const res = try self._editStacks.getOrPut(strResource.items());
            if (!res.found_existing) {
                const owned_bytes = allocator.dupe(u8, strResource.items()) catch |err| {
                    _ = self._editStacks.remove(strResource.items());
                    return err;
                };
                const label = allocator.dupe(u8, resourceLabel) catch |err| {
                    allocator.free(owned_bytes);
                    _ = self._editStacks.remove(strResource.items());
                    return err;
                };
                const owned = String.initOwned(ArrayList(u8).fromOwnedSlice(allocator, owned_bytes));
                res.key_ptr.* = owned.items();
                res.value_ptr.* = ResourceEditStack.init(label, owned, allocator);
                res.value_ptr.owned_resource_label = label;
            }
            try res.value_ptr.preparePush();
        }
        for (str_resources) |strResource| {
            const stack = self._editStacks.getPtr(strResource.items()).?;
            stack.pushPrepared(element);
            if (element == .workspaceStackElement) element.workspaceStackElement.retain();
        }
    }

    pub fn getLastElement(self: *UndoRedoService, resource: Uri) !?*EditStackElement {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
        if (self._editStacks.contains(strResource.items())) {
            const editStack = self._editStacks.get(strResource.items()).?;
            if (editStack.hasFutureElements()) {
                return null;
            }
            const closestPastElement = editStack.getClosestPastElement() orelse return null;
            return closestPastElement.actual();
        }
        return null;
    }

    fn _splitPastWorkspaceElement(self: *UndoRedoService, toRemove: *WorkspaceStackElement, ignoreResources: ?RemovedResources) !void {
        var individualArr = try toRemove.actual.split();
        defer individualArr.deinit();

        var individualMap = std.StringHashMap(ResourceStackElement).init(self._uriComparisonKeyComputers.allocator);
        defer {
            var iter = individualMap.valueIterator();
            while (iter.next()) |item| item.deinit();
            individualMap.deinit();
        }
        for (individualArr.items) |*_element| {
            const resourceLabel = getResourceLabel(_element.resource());
            const strResource = try self.getUriComparisonKey(_element.resource());
            const owned = try _element.getAllocator().create(EditStackElement);
            owned.* = _element.*;
            const element = ResourceStackElement.init(owned, resourceLabel, strResource, 0, 0, 0, 0);
            try individualMap.put(element.strResource.items(), element);
        }

        for (toRemove.strResources.items) |strResource| {
            if (ignoreResources != null and ignoreResources.?.has(strResource.items())) {
                continue;
            }
            if (self._editStacks.getPtr(strResource.items())) |editStack| {
                editStack.splitPastWorkspaceElement(toRemove, &individualMap);
            }
        }
    }

    fn _splitFutureWorkspaceElement(self: *UndoRedoService, toRemove: *const WorkspaceStackElement, ignoreResources: ?RemovedResources) !void {
        var individualArr = try toRemove.actual.split();
        defer individualArr.deinit();
        var individualMap = std.StringHashMap(ResourceStackElement).init(self._uriComparisonKeyComputers.allocator);
        defer {
            var iter = individualMap.valueIterator();
            while (iter.next()) |item| item.deinit();
            individualMap.deinit();
        }
        for (individualArr.items) |*_element| {
            const resourceLabel = getResourceLabel(_element.resource());
            const strResource = try self.getUriComparisonKey(_element.resource());
            const owned = try _element.getAllocator().create(EditStackElement);
            owned.* = _element.*;
            const element = ResourceStackElement.init(owned, resourceLabel, strResource, 0, 0, 0, 0);
            try individualMap.put(element.strResource.items(), element);
        }

        for (toRemove.strResources.items) |strResource| {
            if (ignoreResources != null and ignoreResources.?.has(strResource.items())) {
                continue;
            }
            if (self._editStacks.getPtr(strResource.items())) |editStack| {
                editStack.splitFutureWorkspaceElement(toRemove, &individualMap);
            }
        }
    }

    pub fn removeElementsStr(self: *UndoRedoService, strResource: []const u8) !void {
        if (self._editStacks.fetchRemove(strResource)) |removed| {
            var editStack = removed.value;
            try editStack.dispose();
            editStack.deinit();
        }
        if (DEBUG) {
            self._print("removeElements");
        }
    }

    pub fn removeElements(self: *UndoRedoService, resource: Uri) !void {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
        try self.removeElementsStr(strResource.items());
    }

    pub fn setElementsValidFlag(self: *UndoRedoService, resource: Uri, isValid: bool, filter: *const fn (element: *const EditStackElement) bool) !void {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
        if (self._editStacks.getPtr(strResource.items())) |editStack| {
            editStack.setElementsValidFlag(isValid, filter);
        }
        if (DEBUG) {
            self._print("setElementsValidFlag");
        }
    }

    pub fn hasElements(self: *UndoRedoService, resource: Uri) !bool {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
        if (self._editStacks.get(strResource.items())) |editStack| {
            return editStack.hasPastElements() or editStack.hasFutureElements();
        }
        return false;
    }

    pub fn createSnapshot(self: *UndoRedoService, resource: Uri) !ResourceEditStackSnapshot {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
        if (self._editStacks.get(strResource.items())) |*editStack| {
            return try editStack.createSnapshot(resource);
        }
        return ResourceEditStackSnapshot{ .resource = resource, .elements = ArrayList(u64).init(self._editStacks.allocator) };
    }

    pub fn restoreSnapshot(self: *UndoRedoService, snapshot: ResourceEditStackSnapshot) !void {
        var strResource = try self.getUriComparisonKey(snapshot.resource);
        defer strResource.deinit();
        if (self._editStacks.getPtr(strResource.items())) |editStack| {
            editStack.restoreSnapshot(snapshot);

            if (!editStack.hasPastElements() and !editStack.hasFutureElements()) {
                // the edit stack is now empty, just remove it entirely
                try editStack.dispose();
                if (self._editStacks.fetchRemove(strResource.items())) |removed| {
                    var empty = removed.value;
                    empty.deinit();
                }
            }
        }
        if (DEBUG) {
            self._print("restoreSnapshot");
        }
    }

    pub fn getElements(self: *UndoRedoService, resource: Uri) !PastFutureElements {
        var strResource = try self.getUriComparisonKey(resource);
        defer strResource.deinit();
        if (self._editStacks.get(strResource.items())) |editStack| {
            return try editStack.getElements();
        }
        return PastFutureElements{
            .past = try self._editStacks.allocator.alloc(*const EditStackElement, 0),
            .future = try self._editStacks.allocator.alloc(*const EditStackElement, 0),
        };
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

    pub fn canUndo(self: *UndoRedoService, resourceOrSource: UndoRedoSourceOrUri) !bool {
        switch (resourceOrSource) {
            .source => |source| {
                if (self._findClosestUndoElementWithSource(source.id).second) |_| {
                    return true;
                }
            },
            .uri => |uri| {
                var strResource = try self.getUriComparisonKey(uri);
                defer strResource.deinit();
                if (self._editStacks.get(strResource.items())) |*editStack| {
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

    fn _onError(self: *UndoRedoService, _: anyerror, element: StackElement) void {
        // onUnexpectedError(err);
        // An error occurred while undoing or redoing => drop the undo/redo stack for all affected resources
        var str_resources_buffer: [1]String = undefined;
        for (element.strResources(&str_resources_buffer)) |strResource| {
            self.removeElementsStr(strResource.items()) catch {};
        }
    }

    fn _acquireLocks(self: *UndoRedoService, editStackSnapshot: EditStackSnapshot) bool {
        _ = self;
        // first, check if all locks can be acquired
        for (editStackSnapshot.editStacks.items) |editStack| {
            if (editStack.locked) {
                return false;
            }
        }

        // can acquire all locks
        for (editStackSnapshot.editStacks.items) |editStack| {
            editStack.locked = true;
        }
        return true;
    }

    fn _releaseWorkspaceLocks(self: *UndoRedoService, element: *const WorkspaceStackElement) void {
        // Model-edit notifications can open/close other resources, growing
        // the map during the synchronous operation as well.
        for (element.strResources.items) |resource| {
            if (self._editStacks.getPtr(resource.items())) |stack| stack.locked = false;
        }
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

    /// Preparing a workspace edit may load models on the window dispatcher.
    /// Retain the element and stack versions, never hash-map entry pointers,
    /// across that asynchronous boundary (the model resolver can add stacks).
    const WorkspacePreparation = struct {
        service: *UndoRedoService,
        element: *WorkspaceStackElement,
        resource: []u8,
        versions: []u64,
        direction: enum { undo, redo },
        undo_confirmed: bool,
        starting: bool = true,
        pending: ?Disposable = null,
        cleanup: ?Disposable = null,

        fn prepared(context: *anyopaque, cleanup: Disposable) void {
            const self: *WorkspacePreparation = @ptrCast(@alignCast(context));
            self.pending = null;
            self.cleanup = cleanup;
            if (!self.starting) {
                const service = self.service;
                self.finish() catch service.notifyWarning("Could not complete workspace undo or redo.");
            }
        }

        fn finish(self: *WorkspacePreparation) !void {
            const service = self.service;
            _ = service.pending_workspace_preparations.remove(self);
            defer self.destroy();
            var snapshot = try service._getAffectedEditStacks(self.element);
            defer snapshot.deinit();
            // The retained element owns the ordered resource keys. The fresh
            // stack lookups are compared with the versions from before await.
            @memcpy(snapshot._versionIds.items, self.versions);
            const cleanup = self.cleanup orelse Disposable.none;
            self.cleanup = null; // the execution owns cleanup from here
            switch (self.direction) {
                .undo => try service._executePreparedWorkspaceUndo(self.resource, self.element, snapshot, self.undo_confirmed, cleanup),
                .redo => try service._executePreparedWorkspaceRedo(self.resource, self.element, snapshot, cleanup),
            }
        }

        fn destroy(self: *WorkspacePreparation) void {
            const a = self.service._editStacks.allocator;
            if (self.pending) |pending| pending.dispose();
            if (self.cleanup) |cleanup| cleanup.dispose();
            self.element.release();
            a.free(self.resource);
            a.free(self.versions);
            a.destroy(self);
        }
    };

    fn _invokeWorkspacePrepare(self: *UndoRedoService, strResource: []const u8, element: *WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, direction: @FieldType(WorkspacePreparation, "direction"), undo_confirmed: bool) !bool {
        if (element.actual.* != .multiModel or !element.actual.multiModel.hasPrepareDelegate()) return false;
        const a = self._editStacks.allocator;
        const preparation = try a.create(WorkspacePreparation);
        errdefer a.destroy(preparation);
        const resource = try a.dupe(u8, strResource);
        errdefer a.free(resource);
        const versions = try a.dupe(u64, editStackSnapshot._versionIds.items);
        errdefer a.free(versions);
        preparation.* = .{ .service = self, .element = element, .resource = resource, .versions = versions, .direction = direction, .undo_confirmed = undo_confirmed };
        try self.pending_workspace_preparations.put(a, preparation, {});
        errdefer _ = self.pending_workspace_preparations.remove(preparation);
        element.retain();
        errdefer element.release();

        const pending = try element.actual.multiModel.prepareUndoRedo(.{ .context = preparation, .complete = WorkspacePreparation.prepared });
        preparation.starting = false;
        if (preparation.cleanup != null) {
            // finish owns the preparation even if verification or undo fails.
            preparation.finish() catch |err| self.notifyWarning(@errorName(err));
        } else {
            preparation.pending = pending orelse unreachable; // delegate promises one completion
        }
        return true;
    }

    pub fn cancelPendingPreparations(self: *UndoRedoService) void {
        while (self.pending_workspace_preparations.count() > 0) {
            var iterator = self.pending_workspace_preparations.keyIterator();
            const request = iterator.next().?.*;
            _ = self.pending_workspace_preparations.remove(request);
            request.destroy();
        }
    }

    /// The resolver can be disposed before externally retained models lose
    /// their undo store. Detach all delegate references to its participant.
    pub fn clearPrepareDelegate(self: *UndoRedoService, context: *anyopaque) void {
        var iterator = self._editStacks.valueIterator();
        while (iterator.next()) |stack| {
            for ([_][]const StackElement{ stack._past.items, stack._future.items }) |items| {
                for (items) |item| {
                    const actual = item.actual();
                    if (actual.* == .multiModel) actual.multiModel.clearDelegate(context);
                }
            }
        }
    }

    fn _getAffectedEditStacks(self: *UndoRedoService, element: *const WorkspaceStackElement) !EditStackSnapshot {
        var affectedEditStacks = ArrayList(*ResourceEditStack).init(self._uriComparisonKeyComputers.allocator);
        errdefer affectedEditStacks.deinit();
        for (element.strResources.items) |strResource| {
            const editStack = self._editStacks.getPtr(strResource.items()) orelse &missingEditStack;
            try affectedEditStacks.append(editStack);
        }
        return EditStackSnapshot.init(affectedEditStacks);
    }

    fn _tryToSplitAndUndo(self: *UndoRedoService, strResource: []const u8, element: *WorkspaceStackElement, ignoreResources: ?RemovedResources, message: []const u8) !WorkspaceVerificationError {
        if (element.canSplit()) {
            try self._splitPastWorkspaceElement(element, ignoreResources);
            self.notifyWarning(message);
            try self._undo(strResource, 0, true);
            return WorkspaceVerificationError{ .returnValue = null };
        } else {
            // Cannot safely split this workspace element => flush all undo/redo stacks
            for (element.strResources.items) |str| {
                try self.removeElementsStr(str.items());
            }
            self.notifyWarning(message);
            return WorkspaceVerificationError{ .returnValue = null };
        }
    }

    fn _checkWorkspaceUndo(self: *UndoRedoService, strResource: []const u8, element: *WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, checkInvalidatedResources: bool) !?WorkspaceVerificationError {
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

    fn _workspaceUndo(self: *UndoRedoService, strResource: []const u8, element: *WorkspaceStackElement, undoConfirmed: bool) !void {
        element.retain();
        defer element.release();
        var affectedEditStacks = try self._getAffectedEditStacks(element);
        defer affectedEditStacks.deinit();
        const verificationError = try self._checkWorkspaceUndo(strResource, element, affectedEditStacks, false); // invalidated resources will be checked after the prepare call
        if (verificationError != null) {
            return;
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

    fn _confirmAndExecuteWorkspaceUndo(self: *UndoRedoService, strResource: []const u8, element: *WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, undoConfirmed: bool) !void {
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
            if (verificationError1 != null) {
                return;
            }

            undoConfirmed = true;
        }

        if (try self._invokeWorkspacePrepare(strResource, element, editStackSnapshot, .undo, undoConfirmed)) return;
        try self._executePreparedWorkspaceUndo(strResource, element, editStackSnapshot, undoConfirmed, .none);
    }

    fn _executePreparedWorkspaceUndo(self: *UndoRedoService, strResource: []const u8, element: *WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, undoConfirmed: bool, cleanup: Disposable) !void {
        var cleanup_owned = true;
        defer if (cleanup_owned) cleanup.dispose();
        // Recheck invalidated resources and version/stack membership after
        // model acquisition, before mutating any one of the workspace models.
        if (try self._checkWorkspaceUndo(strResource, element, editStackSnapshot, true) != null) return;
        if (!self._acquireLocks(editStackSnapshot)) return;
        for (editStackSnapshot.editStacks.items) |editStack| {
            editStack.moveBackward(.{ .workspaceStackElement = element }) catch |err| {
                self._releaseWorkspaceLocks(element);
                return err;
            };
        }
        element.actual.undo() catch |err| {
            self._releaseWorkspaceLocks(element);
            self._onError(err, .{ .workspaceStackElement = element });
            return err;
        };
        self._releaseWorkspaceLocks(element);
        cleanup.dispose();
        cleanup_owned = false;
        try self._continueUndoInGroup(element.groupId, undoConfirmed);
    }

    fn _resourceUndo(self: *UndoRedoService, editStack: *ResourceEditStack, element: *const ResourceStackElement, undoConfirmed: bool) !void {
        if (!element.isValid) {
            // invalid element => immediately flush edit stack!
            editStack.flushAllElements();
            return;
        }
        if (editStack.locked) {
            const message = "Could not undo '{0}' because there is already an undo or redo operation running."; //, element.label
            self.notifyWarning(message);
            return;
        }
        editStack.locked = true;
        editStack.moveBackward(.{ .resourceStackElement = element.* }) catch |err| {
            editStack.locked = false;
            return err;
        };
        element.actual.undo() catch |err| {
            editStack.locked = false;
            self._onError(err, .{ .resourceStackElement = element.* });
            return err;
        };
        editStack.locked = false;
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
        var matchedStrResource: ?[]const u8 = null;

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
                try self._undo(strResource.items(), 0, false);
            },
            .str => |strResource| {
                try self._undo(strResource, 0, false);
            },
        }
    }

    fn _undo(self: *UndoRedoService, strResource: []const u8, sourceId: u64, undoConfirmed: bool) anyerror!void {
        if (self._editStacks.getPtr(strResource)) |editStack| {
            var ele = editStack.getClosestPastElement();
            if (ele) |*element| {
                if (element.groupId() != 0) {
                    // this element is a part of a group, we need to make sure undoing in a group is in order
                    const res = self._findClosestUndoElementInGroup(element.groupId());
                    const matchedElement = res.first;
                    const matchedStrResource = res.second;
                    if ((matchedElement == null or element.id() != matchedElement.?.id()) and matchedStrResource != null) {
                        // there is an element in the same group that should be undone before this one
                        return self._undo(matchedStrResource.?, sourceId, undoConfirmed);
                    }
                }

                const shouldPromptForConfirmation = (element.sourceId() != sourceId or element.confirmBeforeUndo());
                if (shouldPromptForConfirmation and !undoConfirmed) {
                    // Hit a different source or the element asks for prompt before undo, prompt for confirmation
                    return self._confirmAndContinueUndo(strResource, sourceId, element);
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
                    .workspaceStackElement => |workspaceStackElement| {
                        try self._workspaceUndo(strResource, workspaceStackElement, undoConfirmed);
                    },
                }
            }
        }
    }

    fn _confirmAndContinueUndo(self: *UndoRedoService, strResource: []const u8, sourceId: u64, element: *StackElement) !void {
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

    pub fn canRedo(self: *UndoRedoService, resourceOrSource: UndoRedoSourceOrUri) !bool {
        switch (resourceOrSource) {
            .source => |source| {
                if (self._findClosestRedoElementWithSource(source.id).second) |_| {
                    return true;
                }
            },
            .uri => |uri| {
                var strResource = try self.getUriComparisonKey(uri);
                defer strResource.deinit();
                if (self._editStacks.get(strResource.items())) |editStack| {
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
            try self._splitFutureWorkspaceElement(element, ignoreResources);
            self.notifyWarning(message);
            try self._redo(strResource);
            return WorkspaceVerificationError{ .returnValue = null };
        } else {
            // Cannot safely split this workspace element => flush all undo/redo stacks
            for (element.strResources.items) |str| {
                try self.removeElementsStr(str.items());
            }
            self.notifyWarning(message);
            return WorkspaceVerificationError{ .returnValue = null };
        }
    }

    fn _checkWorkspaceRedo(self: *UndoRedoService, strResource: []const u8, element: *const WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, checkInvalidatedResources: bool) !?WorkspaceVerificationError {
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

    fn _workspaceRedo(self: *UndoRedoService, strResource: []const u8, element: *WorkspaceStackElement) !void {
        element.retain();
        defer element.release();
        var affectedEditStacks = try self._getAffectedEditStacks(element);
        defer affectedEditStacks.deinit();
        // invalidated resources will be checked after the prepare call
        const verificationError = try self._checkWorkspaceRedo(strResource, element, affectedEditStacks, false);
        if (verificationError != null) {
            return;
        }
        try self._executeWorkspaceRedo(strResource, element, affectedEditStacks);
    }

    fn _executeWorkspaceRedo(self: *UndoRedoService, strResource: []const u8, element: *WorkspaceStackElement, editStackSnapshot: EditStackSnapshot) !void {
        if (try self._invokeWorkspacePrepare(strResource, element, editStackSnapshot, .redo, false)) return;
        try self._executePreparedWorkspaceRedo(strResource, element, editStackSnapshot, .none);
    }

    fn _executePreparedWorkspaceRedo(self: *UndoRedoService, strResource: []const u8, element: *WorkspaceStackElement, editStackSnapshot: EditStackSnapshot, cleanup: Disposable) !void {
        var cleanup_owned = true;
        defer if (cleanup_owned) cleanup.dispose();
        if (try self._checkWorkspaceRedo(strResource, element, editStackSnapshot, true) != null) return;
        if (!self._acquireLocks(editStackSnapshot)) return;
        for (editStackSnapshot.editStacks.items) |editStack| {
            editStack.moveForward(.{ .workspaceStackElement = element }) catch |err| {
                self._releaseWorkspaceLocks(element);
                return err;
            };
        }
        element.actual.redo() catch |err| {
            self._releaseWorkspaceLocks(element);
            self._onError(err, .{ .workspaceStackElement = element });
            return err;
        };
        self._releaseWorkspaceLocks(element);
        cleanup.dispose();
        cleanup_owned = false;
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
            self.notifyWarning(message);
            return;
        }
        editStack.locked = true;
        editStack.moveForward(.{ .resourceStackElement = element.* }) catch |err| {
            editStack.locked = false;
            return err;
        };
        element.actual.redo() catch |err| {
            editStack.locked = false;
            self._onError(err, .{ .resourceStackElement = element.* });
            return err;
        };
        editStack.locked = false;
        try self._continueRedoInGroup(element.groupId);

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
                try self._redo(strResource.items());
            },
            .str => |str| {
                try self._redo(str);
            },
        }
    }

    fn _redo(self: *UndoRedoService, strResource: []const u8) anyerror!void {
        if (self._editStacks.getPtr(strResource)) |editStack| {
            if (editStack.getClosestFutureElement()) |*element| {
                const groupId = element.groupId();
                if (groupId != 0) {
                    // this element is a part of a group, we need to make sure redoing in a group is in order
                    const res = self._findClosestRedoElementInGroup(groupId);
                    const matchedElement = res.first;
                    const matchedStrResource = res.second;
                    if ((matchedElement == null or element.id() != matchedElement.?.id()) and matchedStrResource != null) {
                        // there is an element in the same group that should be redone before this one
                        return self._redo(matchedStrResource.?);
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
                    .workspaceStackElement => |workspaceStackElement| {
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

test "UndoRedoService: empty-resource queries" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("file:///empty-undo-test.txt");

    var service = UndoRedoService.init(allocator);
    defer service.deinit();

    try std.testing.expect(!try service.hasElements(uri));
    try std.testing.expect(!try service.canUndo(.{ .uri = uri }));
    try std.testing.expect(!try service.canRedo(.{ .uri = uri }));

    var snapshot = try service.createSnapshot(uri);
    defer snapshot.deinit();
    try service.restoreSnapshot(snapshot);

    var elements = try service.getElements(uri);
    defer elements.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), elements.past.len);
    try std.testing.expectEqual(@as(usize, 0), elements.future.len);

    const filter = struct {
        fn keep(_: *const EditStackElement) bool {
            return true;
        }
    }.keep;
    try service.setElementsValidFlag(uri, false, filter);
    try service.removeElements(uri);

    try service.undo(.{ .uri = uri });
    try service.redo(.{ .uri = uri });
}

test "UndoRedoService: empty snapshot restore" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("file:///undo-test.txt");

    var stack = ResourceEditStack.init("test", String.initBorrowed("test"), allocator);
    defer stack.deinit();

    var snapshot = try stack.createSnapshot(uri);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), snapshot.elements.items.len);

    stack.restoreSnapshot(snapshot);
    try std.testing.expect(!stack.hasPastElements());
    try std.testing.expect(!stack.hasFutureElements());
}
