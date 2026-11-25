// Port of the portable core of
// `src/vs/workbench/services/editor/common/editorGroupsService.ts`.
//
// The browser `EditorPart`/`EditorGroupView` own the grid, title controls and
// editor panes. This port keeps the service-level behavior: a set of editor
// groups with an active group, creation/MRU ordering, adding/removing groups,
// and opening an input with "reveal if open" resolution across groups.
//
// Group layout (split tree), tab views and editor panes live in the TUI
// workbench, not here, mirroring upstream's separation between
// `IEditorGroupsService` and the editor part.

const std = @import("std");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const Allocator = std.mem.Allocator;
const editor_mod = @import("../../../common/editor.zig");
const editor_input = @import("../../../common/editor/editorInput.zig");
const group_mod = @import("../../../common/editor/editorGroupModel.zig");
const editor_factory = @import("../../../common/editor/editorFactory.zig");

const EditorInput = editor_input.EditorInput;
const EditorGroupModel = group_mod.EditorGroupModel;
const GroupIdentifier = editor_mod.GroupIdentifier;
const EditorOpenOptions = group_mod.EditorOpenOptions;
const EditorOpenResult = group_mod.EditorOpenResult;

/// Upstream preferredSideBySideGroupDirection.
pub fn preferredSideBySideGroupDirection(configuration: ?@import("../../../../platform/configuration/common/configuration.zig").IConfigurationService) GroupDirection {
    if (configuration) |service| {
        if (service.getValue("workbench.editor.openSideBySideDirection")) |value| {
            if (value.* == .string and std.mem.eql(u8, value.string, "down")) return .DOWN;
        }
    }
    return .RIGHT;
}

pub const GroupsOrder = enum {
    /// Groups in the order they were created.
    CREATION_TIME,
    /// Groups by most recent activation, most recent first.
    MOST_RECENTLY_ACTIVE,
};

pub const GroupDirection = enum { UP, DOWN, LEFT, RIGHT };
pub const GroupLocation = enum { first, last, next, previous };
pub const IFindGroupScope = union(enum) { direction: GroupDirection, location: GroupLocation };

pub const IEditorGroup = struct {
    context: *anyopaque,
    id: GroupIdentifier,
    focus_fn: *const fn (*anyopaque) void,
    count_fn: *const fn (*anyopaque) usize,
    active_index_fn: *const fn (*anyopaque) ?usize,
    get_editor_by_index: *const fn (*anyopaque, usize) ?*EditorInput,
    open_editor: *const fn (*anyopaque, *EditorInput) anyerror!void,

    pub fn count(self: IEditorGroup) usize {
        return self.count_fn(self.context);
    }

    pub fn activeEditorIndex(self: IEditorGroup) ?usize {
        return self.active_index_fn(self.context);
    }

    pub fn getEditorByIndex(self: IEditorGroup, index: usize) ?*EditorInput {
        return self.get_editor_by_index(self.context, index);
    }

    pub fn openEditor(self: IEditorGroup, input: *EditorInput) !void {
        try self.open_editor(self.context, input);
    }

    pub fn focus(self: IEditorGroup) void {
        self.focus_fn(self.context);
    }
};

const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
pub const editor_groups_service_id = instantiation.ServiceIdentifier(IEditorGroupsService, "editorGroupsService");

/// Portable arrangement currently supported by the binary terminal grid.
pub const GroupsArrangement = enum { EVEN, MAXIMIZE };

pub const IEditorGroupsService = struct {
    context: *anyopaque,
    active_group: *const fn (*anyopaque) ?IEditorGroup,
    arrange_groups: *const fn (*anyopaque, GroupsArrangement) void,
    find_group: *const fn (*anyopaque, IFindGroupScope, GroupIdentifier, bool) anyerror!?IEditorGroup,
    add_group: *const fn (*anyopaque, GroupIdentifier, GroupDirection) anyerror!IEditorGroup,
    activate_group: *const fn (*anyopaque, GroupIdentifier) void,
    move_group: *const fn (*anyopaque, GroupIdentifier, GroupIdentifier, GroupDirection) anyerror!IEditorGroup,

    pub fn arrangeGroups(self: IEditorGroupsService, arrangement: GroupsArrangement) void {
        self.arrange_groups(self.context, arrangement);
    }

    pub fn activeGroup(self: IEditorGroupsService) ?IEditorGroup {
        return self.active_group(self.context);
    }

    pub fn addGroup(self: IEditorGroupsService, source: IEditorGroup, direction: GroupDirection) !IEditorGroup {
        return self.add_group(self.context, source.id, direction);
    }

    pub fn activateGroup(self: IEditorGroupsService, group: IEditorGroup) void {
        self.activate_group(self.context, group.id);
    }

    pub fn moveGroup(self: IEditorGroupsService, source: IEditorGroup, target: IEditorGroup, direction: GroupDirection) !IEditorGroup {
        return self.move_group(self.context, source.id, target.id, direction);
    }

    pub fn findGroup(self: IEditorGroupsService, scope: IFindGroupScope, source: IEditorGroup, wrap: bool) !?IEditorGroup {
        return self.find_group(self.context, scope, source.id, wrap);
    }
};

pub const OpenOptions = struct {
    /// Mirrors the `workbench.editor.revealIfOpen` setting. The terminal
    /// workbench defaults to revealing across groups, matching the editor
    /// service behavior users expect when they pick an already-open file.
    reveal_if_open: bool = true,
    /// Mirrors `revealIfVisible` (only consider groups where the input is the
    /// active editor).
    reveal_if_visible: bool = false,
    open: EditorOpenOptions = .{},
};

pub const OpenResult = struct {
    group: *EditorGroup,
    result: EditorOpenResult,
};

pub const SerializedGrid = @import("../../../../base/browser/ui/grid/grid.zig").SerializedGrid(GroupIdentifier);

pub const SerializedEditorPart = struct {
    serialized_grid: ?SerializedGrid = null,
    groups: []group_mod.SerializedEditorGroupModel,
    active_group: usize,
    most_recent_active_groups: []const GroupIdentifier = &.{},

    pub fn deinit(self: *SerializedEditorPart, allocator: Allocator) void {
        if (self.serialized_grid) |saved| saved.root.deinit(allocator);
        allocator.free(self.most_recent_active_groups);
        for (self.groups) |*group| group.deinit(allocator);
        if (self.groups.len > 0) allocator.free(self.groups);
        self.* = .{ .groups = &.{}, .active_group = 0 };
    }
};

pub const EditorGroup = struct {
    service: *EditorGroupsService,
    id: GroupIdentifier,
    model: EditorGroupModel,
    creation_order: u64,

    pub fn openEditor(self: *EditorGroup, input: *EditorInput, options: EditorOpenOptions) !EditorOpenResult {
        return self.model.openEditor(input, options);
    }
};

pub const EditorGroupsService = struct {
    allocator: Allocator,
    groups: std.array_list.Managed(*EditorGroup),
    active: *EditorGroup,
    on_did_visible_editors_change: Emitter(void),
    on_did_active_editor_change: Emitter(?*EditorInput),
    // Multiplex each IEditorGroup.onDidModelChange without retaining a group
    // pointer after its model is disposed.
    on_did_change_group_model: Emitter(group_mod.GroupModelChangeEvent),
    next_creation_order: u64 = 1,
    most_recent_active_groups: std.ArrayList(*EditorGroup) = .empty,

    pub fn init(allocator: Allocator, config: group_mod.Configuration) !*EditorGroupsService {
        const self = try allocator.create(EditorGroupsService);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .groups = std.array_list.Managed(*EditorGroup).init(allocator),
            .active = undefined,
            .on_did_visible_editors_change = .init(allocator),
            .on_did_active_editor_change = Emitter(?*EditorInput).init(allocator),
            .on_did_change_group_model = .init(allocator),
        };

        errdefer self.groups.deinit();
        errdefer self.most_recent_active_groups.deinit(allocator);
        const group = try self.createGroup(config);
        self.active = group;
        self.updateMostRecentActive(group, true);
        return self;
    }

    pub fn deinit(self: *EditorGroupsService) void {
        for (self.groups.items) |group| {
            group.model.deinit();
            self.allocator.destroy(group);
        }
        self.most_recent_active_groups.deinit(self.allocator);
        self.on_did_visible_editors_change.deinit();
        self.on_did_active_editor_change.deinit();
        self.on_did_change_group_model.deinit();
        self.groups.deinit();
        self.allocator.destroy(self);
    }

    pub fn count(self: *const EditorGroupsService) usize {
        return self.groups.items.len;
    }

    pub fn activeGroup(self: *const EditorGroupsService) *EditorGroup {
        return self.active;
    }

    /// Returns an allocated slice; the caller owns it.
    pub fn getGroups(self: *EditorGroupsService, allocator: Allocator, order: GroupsOrder) ![]*EditorGroup {
        if (order == .CREATION_TIME) return allocator.dupe(*EditorGroup, self.groups.items);
        const result = try allocator.alloc(*EditorGroup, self.groups.items.len);
        const recent = self.most_recent_active_groups.items;
        @memcpy(result[0..recent.len], recent);
        var index = recent.len;
        for (self.groups.items) |group| {
            if (std.mem.indexOfScalar(*EditorGroup, recent, group) != null) continue;
            result[index] = group;
            index += 1;
        }
        return result;
    }

    pub fn getGroup(self: *EditorGroupsService, id: GroupIdentifier) ?*EditorGroup {
        for (self.groups.items) |group| {
            if (group.id == id) return group;
        }
        return null;
    }

    pub fn activateGroup(self: *EditorGroupsService, group: *EditorGroup) void {
        if (self.active == group) return;
        self.active = group;
        self.updateMostRecentActive(group, true);
        self.on_did_active_editor_change.fire(group.model.activeEditor()) catch {};
    }

    fn updateMostRecentActive(self: *EditorGroupsService, group: *EditorGroup, make_most_recent: bool) void {
        if (std.mem.indexOfScalar(*EditorGroup, self.most_recent_active_groups.items, group)) |index| {
            _ = self.most_recent_active_groups.orderedRemove(index);
        }
        if (make_most_recent) self.most_recent_active_groups.insertAssumeCapacity(0, group);
    }

    /// Adds a group next to `location` (or after the active group). The TUI
    /// split tree decides where the new group is painted. The new group
    /// becomes active.
    pub fn addGroup(self: *EditorGroupsService, location: ?*EditorGroup, direction: GroupDirection) !*EditorGroup {
        _ = location;
        _ = direction;
        const group = try self.createGroup(.{});
        self.activateGroup(group);
        return group;
    }

    pub fn removeGroup(self: *EditorGroupsService, group: *EditorGroup) !void {
        if (self.groups.items.len <= 1) return error.LastGroup;
        const index = self.indexOf(group) orelse return error.GroupNotFound;
        if (group.model.count() > 0) return error.GroupNotEmpty;

        if (self.active == group) {
            const next = for (self.most_recent_active_groups.items) |other| {
                if (other != group) break other;
            } else self.groups.items[@intFromBool(index == 0)];
            self.activateGroup(next);
        }
        self.updateMostRecentActive(group, false);
        _ = self.groups.orderedRemove(index);

        group.model.deinit();
        self.allocator.destroy(group);
    }

    /// Mirrors the editor service's `openEditor` group resolution for typed
    /// inputs: an explicit group wins; otherwise an already-open input can be
    /// revealed (across groups) before falling back to the active group.
    pub fn openEditor(
        self: *EditorGroupsService,
        input: *EditorInput,
        preferred_group: ?*EditorGroup,
        options: OpenOptions,
    ) !OpenResult {
        var target: ?*EditorGroup = null;

        if (preferred_group) |group| {
            if (self.indexOf(group) != null) target = group;
        }

        if (target == null) {
            const force_reveal = input.hasCapability(editor_mod.EditorInputCapabilities.ForceReveal) or
                input.hasCapability(editor_mod.EditorInputCapabilities.Singleton);
            if (options.reveal_if_open or options.reveal_if_visible or force_reveal) {
                const groups = try self.getGroups(self.allocator, .MOST_RECENTLY_ACTIVE);
                defer self.allocator.free(groups);

                var opened: ?*EditorGroup = null;
                for (groups) |group| {
                    if (options.reveal_if_visible) {
                        if (group.model.isActive(.{ .input = input })) {
                            target = group;
                            break;
                        }
                        continue;
                    }
                    if (group.model.contains(.{ .input = input }, .{})) {
                        if (opened == null) opened = group;
                        if (group.model.isActive(.{ .input = input })) {
                            target = group;
                            break;
                        }
                    }
                }
                if (target == null and opened != null and options.reveal_if_open) {
                    target = opened;
                }
            }
        }

        if (target == null) target = self.active;
        const group = target.?;
        self.activateGroup(group);

        const result = try group.model.openEditor(input, options.open);
        return .{ .group = group, .result = result };
    }

    /// Serializes all groups in creation order plus the active group index.
    pub fn serializePart(
        self: *EditorGroupsService,
        allocator: Allocator,
        registry: *editor_factory.EditorFactoryRegistry,
    ) !SerializedEditorPart {
        const groups = try allocator.alloc(group_mod.SerializedEditorGroupModel, self.groups.items.len);
        var initialized: usize = 0;
        errdefer {
            for (groups[0..initialized]) |*group| group.deinit(allocator);
            allocator.free(groups);
        }
        for (self.groups.items, 0..) |group, index| {
            groups[index] = try group.model.serialize(allocator, registry);
            initialized += 1;
        }

        const recent = try allocator.alloc(GroupIdentifier, self.most_recent_active_groups.items.len);
        for (recent, self.most_recent_active_groups.items) |*id, group| id.* = group.id;
        return .{
            .groups = groups,
            .active_group = self.indexOf(self.active) orelse 0,
            .most_recent_active_groups = recent,
        };
    }

    /// Restores a serialized editor part. Upstream restores the split grid
    /// separately; the TUI rebuilds the split tree when it creates panes.
    pub fn initFromSerializedPart(
        allocator: Allocator,
        data: SerializedEditorPart,
        registry: *editor_factory.EditorFactoryRegistry,
        config: group_mod.Configuration,
    ) !*EditorGroupsService {
        if (data.groups.len == 0) return error.NoGroups;

        const self = try EditorGroupsService.init(allocator, config);
        errdefer self.deinit();

        // EditorGroupModel's input listeners retain its address. Deserialize on
        // the group's final model, preserving its active-editor subscription.
        for (data.groups, 0..) |serialized, index| {
            const group = if (index == 0) self.activeGroup() else try self.createGroup(config);
            try group.model.deserialize(serialized, registry);
            group.id = group.model.id;
        }

        self.most_recent_active_groups.clearRetainingCapacity();
        var valid_mru = true;
        for (data.most_recent_active_groups) |id| {
            const group = self.getGroup(id) orelse {
                valid_mru = false;
                break;
            };
            if (std.mem.indexOfScalar(*EditorGroup, self.most_recent_active_groups.items, group) == null)
                self.most_recent_active_groups.appendAssumeCapacity(group);
        }
        self.active = if (data.active_group < self.groups.items.len) self.groups.items[data.active_group] else self.groups.items[0];
        self.updateMostRecentActive(self.active, true);
        if (!valid_mru) {
            self.most_recent_active_groups.clearRetainingCapacity();
            self.most_recent_active_groups.appendSliceAssumeCapacity(self.groups.items);
        }
        return self;
    }

    fn createGroup(self: *EditorGroupsService, config: group_mod.Configuration) !*EditorGroup {
        try self.most_recent_active_groups.ensureTotalCapacity(self.allocator, self.groups.items.len + 1);
        const group = try self.allocator.create(EditorGroup);
        errdefer self.allocator.destroy(group);
        group.* = .{
            .service = self,
            .id = 0,
            .model = try EditorGroupModel.init(self.allocator, config),
            .creation_order = self.next_creation_order,
        };
        errdefer group.model.deinit();
        _ = try group.model.on_did_model_change.listen(group, onGroupModelChange);
        group.id = group.model.id;
        self.next_creation_order += 1;
        try self.groups.append(group);
        return group;
    }

    fn onGroupModelChange(event: group_mod.GroupModelChangeEvent, group: *EditorGroup) anyerror!void {
        if (event == .EDITOR_ACTIVE and group.service.active == group) {
            try group.service.on_did_active_editor_change.fire(group.model.activeEditor());
        }
        try group.service.on_did_change_group_model.fire(event);
    }

    fn indexOf(self: *const EditorGroupsService, group: *EditorGroup) ?usize {
        for (self.groups.items, 0..) |candidate, index| {
            if (candidate == group) return index;
        }
        return null;
    }
};

fn closeAllEditors(service: *EditorGroupsService, allocator: Allocator) !void {
    for (service.groups.items) |group| {
        const editors = try group.model.getEditors(allocator, .SEQUENTIAL, false);
        defer allocator.free(editors);
        for (editors) |input| {
            _ = try group.model.closeEditor(input, .UNKNOWN, false);
        }
    }
}

test "EditorGroupsService: add, activate and remove groups" {
    const allocator = std.testing.allocator;
    const service = try EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const first = service.activeGroup();
    const second = try service.addGroup(first, .RIGHT);
    try std.testing.expectEqual(@as(usize, 2), service.count());
    try std.testing.expectEqual(second, service.activeGroup());

    service.activateGroup(first);
    try std.testing.expectEqual(first, service.activeGroup());

    const groups = try service.getGroups(allocator, .MOST_RECENTLY_ACTIVE);
    defer allocator.free(groups);
    try std.testing.expectEqual(first, groups[0]);
    try std.testing.expectEqual(second, groups[1]);

    try service.removeGroup(second);
    try std.testing.expectEqual(@as(usize, 1), service.count());
    try std.testing.expectError(error.LastGroup, service.removeGroup(first));
}

test "restoring groups preserves activation history when closing the active group" {
    const allocator = std.testing.allocator;
    const service = try EditorGroupsService.init(allocator, .{});
    defer service.deinit();
    const first = service.activeGroup();
    const second = try service.addGroup(first, .RIGHT);
    const third = try service.addGroup(second, .DOWN);
    service.activateGroup(first);
    service.activateGroup(third);

    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    var state = try service.serializePart(allocator, &registry);
    defer state.deinit(allocator);
    try std.testing.expectEqualSlices(GroupIdentifier, &.{ third.id, first.id, second.id }, state.most_recent_active_groups);

    const restored = try EditorGroupsService.initFromSerializedPart(allocator, state, &registry, .{});
    defer restored.deinit();
    try std.testing.expectEqual(third.id, restored.activeGroup().id);
    try restored.removeGroup(restored.activeGroup());
    try std.testing.expectEqual(first.id, restored.activeGroup().id);

    var stale = state;
    stale.most_recent_active_groups = &.{std.math.maxInt(GroupIdentifier)};
    const recovered = try EditorGroupsService.initFromSerializedPart(allocator, stale, &registry, .{});
    defer recovered.deinit();
    const order = try recovered.getGroups(allocator, .MOST_RECENTLY_ACTIVE);
    defer allocator.free(order);
    try std.testing.expectEqualSlices(*EditorGroup, recovered.groups.items, order);
}

const TestInput = struct {
    base: EditorInput,
    id: []const u8,

    fn create(allocator: Allocator, id: []const u8, capabilities: u32) !*TestInput {
        const input = try allocator.create(TestInput);
        input.* = .{
            .base = EditorInput.init(allocator, "test.editorInput"),
            .id = id,
        };
        input.base.impl = input;
        input.base.capabilities = capabilities;
        input.base.matches_fn = matches;
        return input;
    }

    fn deinit(self: *TestInput) void {
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        const self: *TestInput = @ptrCast(@alignCast(base.impl.?));
        const other_input: *TestInput = @ptrCast(@alignCast(other.impl.?));
        return std.mem.eql(u8, "test.editorInput", other.type_id) and std.mem.eql(u8, self.id, other_input.id);
    }
};

test "EditorGroupsService: reveals an already-open input across groups" {
    const allocator = std.testing.allocator;
    const service = try EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const group1 = service.activeGroup();
    const first = try TestInput.create(allocator, "first", 0);
    defer first.deinit();

    _ = try service.openEditor(&first.base, null, .{});
    try std.testing.expectEqual(@as(usize, 1), group1.model.count());

    const group2 = try service.addGroup(group1, .RIGHT);
    const second = try TestInput.create(allocator, "second", 0);
    defer second.deinit();

    const result = try service.openEditor(&first.base, null, .{ .reveal_if_open = true });
    try std.testing.expectEqual(group1, result.group);
    try std.testing.expect(!result.result.is_new);
    try std.testing.expectEqual(group1, service.activeGroup());
    try std.testing.expectEqual(@as(usize, 0), group2.model.count());

    const duplicate = try service.openEditor(&first.base, group2, .{ .reveal_if_open = false });
    try std.testing.expectEqual(group2, duplicate.group);
    try std.testing.expect(duplicate.result.is_new);
    try std.testing.expectEqual(@as(usize, 1), group2.model.count());
    try closeAllEditors(service, allocator);
}

test "EditorGroupsService: ForceReveal ignores revealIfOpen=false" {
    const allocator = std.testing.allocator;
    const service = try EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const group1 = service.activeGroup();
    const input = try TestInput.create(allocator, "forced", editor_mod.EditorInputCapabilities.ForceReveal);
    defer input.deinit();

    _ = try service.openEditor(&input.base, null, .{});
    const group2 = try service.addGroup(group1, .RIGHT);

    const result = try service.openEditor(&input.base, null, .{ .reveal_if_open = false });
    try std.testing.expectEqual(group1, result.group);
    try std.testing.expectEqual(@as(usize, 0), group2.model.count());
    try closeAllEditors(service, allocator);
}
