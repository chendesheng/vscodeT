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

pub const GroupsOrder = enum {
    /// Groups in the order they were created.
    CREATION_TIME,
    /// Groups by most recent activation, most recent first.
    MOST_RECENTLY_ACTIVE,
};

pub const GroupDirection = enum { UP, DOWN, LEFT, RIGHT };

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

pub const SerializedEditorPart = struct {
    groups: []group_mod.SerializedEditorGroupModel,
    active_group: usize,

    pub fn deinit(self: *SerializedEditorPart, allocator: Allocator) void {
        for (self.groups) |*group| group.deinit(allocator);
        if (self.groups.len > 0) allocator.free(self.groups);
        self.* = .{ .groups = &.{}, .active_group = 0 };
    }
};

pub const EditorGroup = struct {
    id: GroupIdentifier,
    model: EditorGroupModel,
    creation_order: u64,
    activation_order: u64 = 0,

    pub fn openEditor(self: *EditorGroup, input: *EditorInput, options: EditorOpenOptions) !EditorOpenResult {
        return self.model.openEditor(input, options);
    }
};

pub const EditorGroupsService = struct {
    allocator: Allocator,
    groups: std.array_list.Managed(*EditorGroup),
    active: *EditorGroup,
    next_creation_order: u64 = 1,
    next_activation_order: u64 = 1,

    pub fn init(allocator: Allocator, config: group_mod.Configuration) !*EditorGroupsService {
        const self = try allocator.create(EditorGroupsService);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .groups = std.array_list.Managed(*EditorGroup).init(allocator),
            .active = undefined,
        };

        const group = try self.createGroup(config);
        self.active = group;
        group.activation_order = self.next_activation_order;
        self.next_activation_order += 1;
        return self;
    }

    pub fn deinit(self: *EditorGroupsService) void {
        for (self.groups.items) |group| {
            group.model.deinit();
            self.allocator.destroy(group);
        }
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
        const result = try allocator.dupe(*EditorGroup, self.groups.items);
        if (order == .MOST_RECENTLY_ACTIVE) {
            // Small N: insertion sort keeps equal activation timestamps stable
            // without pulling in a comparator context.
            var i: usize = 1;
            while (i < result.len) : (i += 1) {
                const value = result[i];
                var j = i;
                while (j > 0 and result[j - 1].activation_order < value.activation_order) : (j -= 1) {
                    result[j] = result[j - 1];
                }
                result[j] = value;
            }
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
        group.activation_order = self.next_activation_order;
        self.next_activation_order += 1;
    }

    /// Adds a group next to `location` (or after the active group). The TUI
    /// split tree decides where the new group is painted. The new group
    /// becomes active.
    pub fn addGroup(self: *EditorGroupsService, location: ?*EditorGroup, direction: GroupDirection) !*EditorGroup {
        _ = location;
        _ = direction;
        const group = try self.createGroup(.{});
        group.activation_order = self.next_activation_order;
        self.next_activation_order += 1;
        self.active = group;
        return group;
    }

    pub fn removeGroup(self: *EditorGroupsService, group: *EditorGroup) !void {
        if (self.groups.items.len <= 1) return error.LastGroup;
        const index = self.indexOf(group) orelse return error.GroupNotFound;
        if (group.model.count() > 0) return error.GroupNotEmpty;

        _ = self.groups.orderedRemove(index);
        if (self.active == group) {
            const next_index = if (index < self.groups.items.len) index else self.groups.items.len - 1;
            self.active = self.groups.items[next_index];
            self.active.activation_order = self.next_activation_order;
            self.next_activation_order += 1;
        }

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

        return .{
            .groups = groups,
            .active_group = self.indexOf(self.active) orelse 0,
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

        const first = self.groups.items[0];
        first.model.deinit();
        first.model = try group_mod.EditorGroupModel.initFromSerialized(allocator, config, data.groups[0], registry);
        first.id = first.model.id;

        var index: usize = 1;
        while (index < data.groups.len) : (index += 1) {
            const group = try self.addGroup(null, .RIGHT);
            group.model.deinit();
            group.model = try group_mod.EditorGroupModel.initFromSerialized(allocator, config, data.groups[index], registry);
            group.id = group.model.id;
        }

        if (data.active_group < self.groups.items.len) {
            self.activateGroup(self.groups.items[data.active_group]);
        }
        return self;
    }

    fn createGroup(self: *EditorGroupsService, config: group_mod.Configuration) !*EditorGroup {
        const group = try self.allocator.create(EditorGroup);
        errdefer self.allocator.destroy(group);
        group.* = .{
            .id = 0,
            .model = try EditorGroupModel.init(self.allocator, config),
            .creation_order = self.next_creation_order,
        };
        group.id = group.model.id;
        self.next_creation_order += 1;
        try self.groups.append(group);
        return group;
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
