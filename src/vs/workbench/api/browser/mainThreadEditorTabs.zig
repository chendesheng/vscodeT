// Port of `src/vs/workbench/api/browser/mainThreadEditorTabs.ts`.
//
// Terminal adaptation: the adapter owns the tab list; this actor owns the tab
// model signature and suppresses duplicate `$acceptEditorTabModel` deliveries within editor/group event batches.
// Move/close operations are forwarded to the adapter.
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
                try object.put(arena, "viewType", .{ .string = custom.view_type });
            },
            .webview => |view_type| {
                try object.put(arena, "kind", .{ .integer = 7 });
                try object.put(arena, "viewType", .{ .string = view_type });
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
        try object.put(arena, "id", .{ .string = self.id });
        try object.put(arena, "label", .{ .string = self.label });
        try object.put(arena, "input", try self.input.dto(arena));
        if (self.editor_id) |editor_id| try object.put(arena, "editorId", .{ .string = editor_id });
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
    notify: *const fn (context: *anyopaque, model: std.json.Value) anyerror!void,
    move_tab: *const fn (context: *anyopaque, tab_id: []const u8, index: usize) anyerror!void,
    close_tab: *const fn (context: *anyopaque, tab_id: []const u8) anyerror!bool,
    close_group: *const fn (context: *anyopaque, group_id: i64) anyerror!bool,
};

pub const MainThreadEditorTabs = struct {
    allocator: Allocator,
    host: Host,
    signature: ?u64 = null,

    pub fn init(allocator: Allocator, host: Host) MainThreadEditorTabs {
        return .{ .allocator = allocator, .host = host };
    }

    pub fn deinit(self: *MainThreadEditorTabs) void {
        _ = self;
    }

    pub fn invoke(self: *MainThreadEditorTabs, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        _ = arena;
        if (std.mem.eql(u8, method, "$moveTab")) {
            if (args.len >= 2 and args[0] == .json and args[0].json == .string and args[1] == .json and args[1].json == .integer) {
                try self.host.move_tab(self.host.context, args[0].json.string, @intCast(args[1].json.integer));
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

    /// Called by editor-group and input lifecycle events. Here all wire
    /// fields (including declared multi-diff URI pairs) affect the model.
    pub fn sync(self: *MainThreadEditorTabs, arena: Allocator, groups: []const GroupSpec) !void {
        const model = try tabModel(arena, groups);
        const encoded = try std.json.Stringify.valueAlloc(arena, model, .{});
        const signature = std.hash.Wyhash.hash(0, encoded);
        if (signature == self.signature) return;
        try self.host.notify(self.host.context, model);
        self.signature = signature;
    }
};

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadEditorTabs.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

test "MainThreadEditorTabs: emits only when the tab model changes" {
    const allocator = std.testing.allocator;
    const Fake = struct {
        var notifications: usize = 0;
        fn notify(_: *anyopaque, _: std.json.Value) anyerror!void {
            notifications += 1;
        }
        fn move(_: *anyopaque, _: []const u8, _: usize) anyerror!void {}
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tabs = [_]TabSpec{.{ .id = "a", .input = .{ .text = try std.Uri.parse("file:///a.ts") }, .label = "a.ts", .is_active = true, .is_dirty = false }};
    const groups = [_]GroupSpec{.{ .id = 1, .view_column = 1, .is_active = true, .tabs = &tabs }};
    try actor.sync(arena.allocator(), &groups);
    try std.testing.expectEqual(@as(usize, 1), Fake.notifications);
    try actor.sync(arena.allocator(), &groups);
    try std.testing.expectEqual(@as(usize, 1), Fake.notifications);
    try actor.sync(arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 2), Fake.notifications);
    try actor.sync(arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 2), Fake.notifications);
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
    const model = try tabModel(arena, &.{ .{ .id = 4, .view_column = 1, .is_active = false, .tabs = &first }, .{ .id = 7, .view_column = 2, .is_active = true, .tabs = &second } });
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
    try std.testing.expectEqual(@as(i64, 2), other.get("viewColumn").?.integer);
    const diff = other.get("tabs").?.array.items[0].object;
    try std.testing.expect(diff.get("isPreview").?.bool and diff.get("isDirty").?.bool);
    try std.testing.expect(!diff.get("isPinned").?.bool);
}
