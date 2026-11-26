// Port of `src/vs/workbench/api/browser/mainThreadEditorTabs.ts`.
//
// The actor owns the tab-group DTO model and patches it on editor model
// events. The terminal adapter supplies group/inputs and native move/close.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const std_uri = @import("../../../base/common/stdUri.zig");

/// The discriminants are TabInputKind in extHost.protocol.ts.
pub const TextDiffSpec = struct {
    original: std.Uri,
    modified: std.Uri,

    fn dto(self: TextDiffSpec, arena: Allocator) !std.json.Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "kind", .{ .integer = 2 });
        try object.put(arena, "original", try std_uri.jsonComponents(arena, self.original));
        try object.put(arena, "modified", try std_uri.jsonComponents(arena, self.modified));
        return .{ .object = object };
    }
};

pub const TabInputSpec = union(enum) {
    unknown,
    text: std.Uri,
    text_diff: TextDiffSpec,
    custom: struct { uri: std.Uri, view_type: []const u8 },
    webview: []const u8,
    terminal,
    multi_diff: []const TextDiffSpec,

    fn dto(self: TabInputSpec, arena: Allocator) !std.json.Value {
        var object: std.json.ObjectMap = .empty;
        switch (self) {
            .unknown => try object.put(arena, "kind", .{ .integer = 0 }),
            .text => |uri| {
                try object.put(arena, "kind", .{ .integer = 1 });
                try object.put(arena, "uri", try std_uri.jsonComponents(arena, uri));
            },
            .text_diff => |diff| return diff.dto(arena),
            .custom => |custom| {
                try object.put(arena, "kind", .{ .integer = 6 });
                try object.put(arena, "uri", try std_uri.jsonComponents(arena, custom.uri));
                try object.put(arena, "viewType", .{ .string = try arena.dupe(u8, custom.view_type) });
            },
            .webview => |view_type| {
                try object.put(arena, "kind", .{ .integer = 7 });
                try object.put(arena, "viewType", .{ .string = try arena.dupe(u8, view_type) });
            },
            .terminal => try object.put(arena, "kind", .{ .integer = 8 }),
            .multi_diff => |diffs| {
                try object.put(arena, "kind", .{ .integer = 11 });
                var array = std.json.Array.init(arena);
                for (diffs) |diff| try array.append(try diff.dto(arena));
                try object.put(arena, "diffEditors", .{ .array = array });
            },
        }
        return .{ .object = object };
    }
};

pub const TabSpec = struct {
    id: []const u8,
    label: []const u8,
    input: TabInputSpec,
    editor_id: ?[]const u8 = null,
    is_active: bool,
    is_dirty: bool,
    is_pinned: bool = false, // upstream DTO is the group's sticky flag
    is_preview: bool = false,

    fn dto(self: TabSpec, arena: Allocator) !std.json.Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "id", .{ .string = try arena.dupe(u8, self.id) });
        try object.put(arena, "label", .{ .string = try arena.dupe(u8, self.label) });
        try object.put(arena, "input", try self.input.dto(arena));
        if (self.editor_id) |editor_id| try object.put(arena, "editorId", .{ .string = try arena.dupe(u8, editor_id) });
        try object.put(arena, "isActive", .{ .bool = self.is_active });
        try object.put(arena, "isPinned", .{ .bool = self.is_pinned });
        try object.put(arena, "isPreview", .{ .bool = self.is_preview });
        try object.put(arena, "isDirty", .{ .bool = self.is_dirty });
        return .{ .object = object };
    }
};

pub const GroupSpec = struct {
    id: u32,
    view_column: usize,
    is_active: bool,
    tabs: []const TabSpec,

    fn dto(self: GroupSpec, arena: Allocator) !std.json.Value {
        var tabs = std.json.Array.init(arena);
        for (self.tabs) |tab| try tabs.append(try tab.dto(arena));
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "groupId", .{ .integer = self.id });
        try object.put(arena, "viewColumn", .{ .integer = @intCast(self.view_column) });
        try object.put(arena, "isActive", .{ .bool = self.is_active });
        try object.put(arena, "tabs", .{ .array = tabs });
        return .{ .object = object };
    }
};

pub fn tabModel(arena: Allocator, groups: []const GroupSpec) !std.json.Value {
    var array = std.json.Array.init(arena);
    for (groups) |group| try array.append(try group.dto(arena));
    return .{ .array = array };
}

pub const Host = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque, method: []const u8, model: std.json.Value) anyerror!void,
    move_tab: *const fn (context: *anyopaque, tab_id: []const u8, index: i64, column: i64, preserve_focus: bool) anyerror!void,
    close_tab: *const fn (context: *anyopaque, tab_id: []const u8) anyerror!bool,
    close_group: *const fn (context: *anyopaque, group_id: i64) anyerror!bool,
};

const StoredTab = struct {
    arena: std.heap.ArenaAllocator,
    dto: std.json.Value,

    fn init(allocator: Allocator, spec: TabSpec) !StoredTab {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const dto = try spec.dto(arena.allocator());
        return .{ .dto = dto, .arena = arena };
    }
    fn deinit(self: *StoredTab) void {
        self.arena.deinit();
    }
    fn id(self: StoredTab) []const u8 {
        return self.dto.object.get("id").?.string;
    }
    fn setActive(self: *StoredTab, active: bool) void {
        self.dto.object.getPtr("isActive").?.* = .{ .bool = active };
    }
};

const StoredGroup = struct {
    id: u32,
    view_column: usize,
    is_active: bool,
    tabs: std.ArrayList(StoredTab) = .empty,

    fn init(allocator: Allocator, spec: GroupSpec) !StoredGroup {
        var result: StoredGroup = .{ .id = spec.id, .view_column = spec.view_column, .is_active = spec.is_active };
        errdefer result.deinit(allocator);
        try result.tabs.ensureTotalCapacity(allocator, spec.tabs.len);
        for (spec.tabs) |tab| result.tabs.appendAssumeCapacity(try StoredTab.init(allocator, tab));
        return result;
    }
    fn deinit(self: *StoredGroup, allocator: Allocator) void {
        for (self.tabs.items) |*tab| tab.deinit();
        self.tabs.deinit(allocator);
    }
    fn dto(self: StoredGroup, arena: Allocator) !std.json.Value {
        var tabs = std.json.Array.init(arena);
        for (self.tabs.items) |tab| try tabs.append(tab.dto);
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "groupId", .{ .integer = self.id });
        try object.put(arena, "viewColumn", .{ .integer = @intCast(self.view_column) });
        try object.put(arena, "isActive", .{ .bool = self.is_active });
        try object.put(arena, "tabs", .{ .array = tabs });
        return .{ .object = object };
    }
    fn findTab(self: *StoredGroup, id: []const u8) ?usize {
        for (self.tabs.items, 0..) |tab, index| if (std.mem.eql(u8, tab.id(), id)) return index;
        return null;
    }
};

const OperationKind = enum(u8) { open, close, update, move };

pub const MainThreadEditorTabs = struct {
    allocator: Allocator,
    host: Host,
    groups: std.ArrayList(StoredGroup) = .empty,
    active_group_id: ?u32 = null,

    pub fn init(allocator: Allocator, host: Host) MainThreadEditorTabs {
        return .{ .allocator = allocator, .host = host };
    }

    pub fn deinit(self: *MainThreadEditorTabs) void {
        for (self.groups.items) |*group| group.deinit(self.allocator);
        self.groups.deinit(self.allocator);
    }

    fn findGroup(self: *MainThreadEditorTabs, id: u32) ?*StoredGroup {
        for (self.groups.items) |*group| if (group.id == id) return group;
        return null;
    }

    fn operation(self: *MainThreadEditorTabs, kind: OperationKind, group_id: u32, index: usize, tab: std.json.Value, old_index: ?usize) !void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var object: std.json.ObjectMap = .empty;
        try object.put(a, "kind", .{ .integer = @backingInt(kind) });
        try object.put(a, "groupId", .{ .integer = group_id });
        try object.put(a, "index", .{ .integer = @intCast(index) });
        try object.put(a, "tabDto", tab);
        if (old_index) |old| try object.put(a, "oldIndex", .{ .integer = @intCast(old) });
        try self.host.notify(self.host.context, "$acceptTabOperation", .{ .object = object });
    }

    pub fn open(self: *MainThreadEditorTabs, group_id: u32, index: usize, spec: TabSpec) !void {
        const group = self.findGroup(group_id) orelse return error.UnknownTabGroup;
        if (index > group.tabs.items.len or group.findTab(spec.id) != null) return error.InvalidTabModel;
        var tab = try StoredTab.init(self.allocator, spec);
        errdefer tab.deinit();
        try group.tabs.insert(self.allocator, index, tab);
        errdefer _ = group.tabs.orderedRemove(index);
        if (spec.is_active) for (group.tabs.items, 0..) |*entry, i| entry.setActive(i == index);
        try self.operation(.open, group_id, index, group.tabs.items[index].dto, null);
    }

    pub fn close(self: *MainThreadEditorTabs, group_id: u32, index: usize) !void {
        const group = self.findGroup(group_id) orelse return error.UnknownTabGroup;
        if (index >= group.tabs.items.len) return error.InvalidTabModel;
        var tab = group.tabs.orderedRemove(index);
        defer tab.deinit();
        try self.operation(.close, group_id, index, tab.dto, null);
    }

    pub fn move(self: *MainThreadEditorTabs, group_id: u32, old_index: usize, index: usize, id: []const u8) !void {
        const group = self.findGroup(group_id) orelse return error.UnknownTabGroup;
        if (old_index >= group.tabs.items.len or index >= group.tabs.items.len or !std.mem.eql(u8, group.tabs.items[old_index].id(), id)) return error.InvalidTabModel;
        if (old_index == index) return;
        const tab = group.tabs.orderedRemove(old_index);
        group.tabs.insertAssumeCapacity(index, tab);
        try self.operation(.move, group_id, index, tab.dto, old_index);
    }

    pub fn update(self: *MainThreadEditorTabs, group_id: u32, spec: TabSpec) !void {
        const group = self.findGroup(group_id) orelse return error.UnknownTabGroup;
        const index = group.findTab(spec.id) orelse return error.InvalidTabModel;
        const replacement = try StoredTab.init(self.allocator, spec);
        group.tabs.items[index].deinit();
        group.tabs.items[index] = replacement;
        if (spec.is_active) for (group.tabs.items, 0..) |*entry, i| entry.setActive(i == index);
        try self.operation(.update, group_id, index, replacement.dto, null);
    }

    pub fn activateGroup(self: *MainThreadEditorTabs, group_id: u32) !void {
        if (self.active_group_id == group_id) return;
        const group = self.findGroup(group_id) orelse return error.UnknownTabGroup;
        for (self.groups.items) |*entry| entry.is_active = entry.id == group_id;
        self.active_group_id = group_id;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        try self.host.notify(self.host.context, "$acceptTabGroupUpdate", try group.dto(scratch.allocator()));
    }

    pub fn invoke(self: *MainThreadEditorTabs, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        _ = arena;
        if (std.mem.eql(u8, method, "$moveTab")) {
            if (args.len >= 3 and args[0] == .json and args[0].json == .string and args[1] == .json and args[1].json == .integer and args[2] == .json and args[2].json == .integer) {
                const preserve_focus = args.len > 3 and args[3] == .json and args[3].json == .bool and args[3].json.bool;
                try self.host.move_tab(self.host.context, args[0].json.string, args[1].json.integer, args[2].json.integer, preserve_focus);
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$closeTab")) {
            var all_closed = true;
            if (args.len > 0 and args[0] == .json and args[0].json == .array) {
                for (args[0].json.array.items) |value| {
                    if (value == .string and !(self.host.close_tab(self.host.context, value.string) catch false)) all_closed = false;
                }
            }
            return .{ .json = .{ .bool = all_closed } };
        }
        if (std.mem.eql(u8, method, "$closeGroup")) {
            var all_closed = true;
            if (args.len > 0 and args[0] == .json and args[0].json == .array) {
                for (args[0].json.array.items) |value| {
                    if (value == .integer and !(self.host.close_group(self.host.context, value.integer) catch false)) all_closed = false;
                }
            }
            return .{ .json = .{ .bool = all_closed } };
        }
        if (methodKind(method) == .request) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }

    /// Initial delivery and structural group changes only. Ordinary tab
    /// lifecycle events patch the model through the methods above.
    pub fn sync(self: *MainThreadEditorTabs, arena: Allocator, groups: []const GroupSpec) !void {
        var next: std.ArrayList(StoredGroup) = .empty;
        errdefer {
            for (next.items) |*group| group.deinit(self.allocator);
            next.deinit(self.allocator);
        }
        try next.ensureTotalCapacity(self.allocator, groups.len);
        var active: ?u32 = null;
        for (groups) |spec| {
            next.appendAssumeCapacity(try StoredGroup.init(self.allocator, spec));
            if (spec.is_active) active = spec.id;
        }
        try self.host.notify(self.host.context, "$acceptEditorTabModel", try tabModel(arena, groups));
        self.deinit();
        self.groups = next;
        self.active_group_id = active;
    }
};

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadEditorTabs.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

test "MainThreadEditorTabs: sends the initial model and incremental tab operations" {
    const allocator = std.testing.allocator;
    const Fake = struct {
        var notifications: usize = 0;
        var last_kind: ?i64 = null;
        var is_group_update = false;
        fn notify(_: *anyopaque, method: []const u8, value: std.json.Value) anyerror!void {
            notifications += 1;
            last_kind = if (std.mem.eql(u8, method, "$acceptTabOperation")) value.object.get("kind").?.integer else null;
            is_group_update = std.mem.eql(u8, method, "$acceptTabGroupUpdate");
        }
        fn move(_: *anyopaque, _: []const u8, _: i64, _: i64, _: bool) anyerror!void {}
        fn close(_: *anyopaque, _: []const u8) anyerror!bool {
            return true;
        }
        fn closeGroup(_: *anyopaque, _: i64) anyerror!bool {
            return true;
        }
    };
    var actor = MainThreadEditorTabs.init(allocator, .{
        .context = undefined,
        .notify = Fake.notify,
        .move_tab = Fake.move,
        .close_tab = Fake.close,
        .close_group = Fake.closeGroup,
    });
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tabs = [_]TabSpec{.{ .id = "a", .input = .{ .text = try std.Uri.parse("file:///a.ts") }, .label = "a.ts", .is_active = true, .is_dirty = false }};
    const groups = [_]GroupSpec{.{ .id = 1, .view_column = 0, .is_active = true, .tabs = &tabs }};
    try actor.sync(arena.allocator(), &groups);
    try std.testing.expectEqual(@as(usize, 1), Fake.notifications);
    var changed = tabs[0];
    changed.is_dirty = true;
    try actor.update(1, changed);
    try std.testing.expectEqual(@as(usize, 2), Fake.notifications);
    try actor.close(1, 0);
    try std.testing.expectEqual(@as(usize, 3), Fake.notifications);
    try actor.open(1, 0, tabs[0]);
    try std.testing.expectEqual(@as(usize, 4), Fake.notifications);
    try std.testing.expectEqual(@as(?i64, 0), Fake.last_kind);
    var second = tabs[0];
    second.id = "b";
    try actor.open(1, 1, second);
    try actor.move(1, 1, 0, second.id);
    try std.testing.expectEqual(@as(?i64, 3), Fake.last_kind);
    try std.testing.expectEqualStrings("b", actor.groups.items[0].tabs.items[0].id());
    try std.testing.expectEqualStrings("a", actor.groups.items[0].tabs.items[1].id());
    try std.testing.expect(!actor.groups.items[0].tabs.items[1].dto.object.get("isActive").?.bool);
}

test "MainThreadEditorTabs: group columns, sticky flags and declared multi-diff URI pairs" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const original = try std.Uri.parse("git:/repo/a.json?old");
    const modified = try std.Uri.parse("file:///repo/a.json");
    const diffs = [_]TextDiffSpec{.{ .original = original, .modified = modified }};
    const first = [_]TabSpec{.{ .id = "4~multi", .label = "Changes", .editor_id = "multiDiffEditor", .input = .{ .multi_diff = &diffs }, .is_active = true, .is_dirty = false, .is_pinned = true }};
    const second = [_]TabSpec{.{ .id = "7~diff", .label = "a.json", .input = .{ .text_diff = diffs[0] }, .is_active = true, .is_dirty = true, .is_preview = true }};
    const model = try tabModel(arena, &.{ .{ .id = 4, .view_column = 0, .is_active = false, .tabs = &first }, .{ .id = 7, .view_column = 1, .is_active = true, .tabs = &second } });
    try std.testing.expectEqual(@as(usize, 2), model.array.items.len);
    const group = model.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 4), group.get("groupId").?.integer);
    try std.testing.expect(!group.get("isActive").?.bool);
    const multi = group.get("tabs").?.array.items[0].object;
    try std.testing.expect(multi.get("isPinned").?.bool);
    try std.testing.expect(multi.get("isActive").?.bool);
    const input = multi.get("input").?.object;
    try std.testing.expectEqual(@as(i64, 11), input.get("kind").?.integer);
    const child = input.get("diffEditors").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 2), child.get("kind").?.integer);
    try std.testing.expectEqualStrings("old", child.get("original").?.object.get("query").?.string);
    const other = model.array.items[1].object;
    try std.testing.expectEqual(@as(i64, 1), other.get("viewColumn").?.integer);
    const diff = other.get("tabs").?.array.items[0].object;
    try std.testing.expect(diff.get("isPreview").?.bool and diff.get("isDirty").?.bool);
    try std.testing.expect(!diff.get("isPinned").?.bool);
}
