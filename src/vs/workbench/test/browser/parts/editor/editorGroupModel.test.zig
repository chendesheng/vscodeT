// Port of `src/vs/workbench/test/browser/parts/editor/editorGroupModel.test.ts`.
//
// The browser test instantiates the model through VS Code's instantiation and
// configuration services. Here the model takes its two settings directly and
// the tests provide a `TestEditorInput` equivalent. Serialization and
// side-by-side/diff editor cases wait for the editor factory registry and the
// composite editor inputs; everything else is ported.

const std = @import("std");
const Allocator = std.mem.Allocator;

const workbench_editor = @import("../../../../common/editor.zig");
const editor_input_mod = @import("../../../../common/editor/editorInput.zig");
const group_mod = @import("../../../../common/editor/editorGroupModel.zig");

const EditorInput = editor_input_mod.EditorInput;
const EditorGroupModel = group_mod.EditorGroupModel;
const Candidate = editor_input_mod.Candidate;
const EditorsOrder = workbench_editor.EditorsOrder;
const EditorCloseContext = workbench_editor.EditorCloseContext;
const GroupIdentifier = workbench_editor.GroupIdentifier;
const MatchEditorOptions = workbench_editor.MatchEditorOptions;
const GroupModelChangeEvent = group_mod.GroupModelChangeEvent;
const EditorChange = group_mod.EditorChange;
const EditorCloseChange = group_mod.EditorCloseChange;
const EditorMoveChange = group_mod.EditorMoveChange;

const Kind = enum { serializable, non_serializable, file };

const TestEditorInput = struct {
    base: EditorInput,
    kind: Kind,
    id: []const u8,
    resource: ?[]const u8,
};

fn toTest(base: *EditorInput) *TestEditorInput {
    return @ptrCast(@alignCast(base.impl.?));
}

fn matchesFn(base: *EditorInput, other: *EditorInput) bool {
    const self = toTest(base);
    const other_input = toTest(other);
    return switch (self.kind) {
        .serializable => other_input.kind == .serializable and std.mem.eql(u8, self.id, other_input.id),
        .non_serializable => other_input.kind == .non_serializable and std.mem.eql(u8, self.id, other_input.id),
        .file => base == other or
            (other_input.kind == .file and
                std.mem.eql(u8, self.resource.?, other_input.resource.?)),
    };
}

fn newInput(allocator: Allocator, kind: Kind, id: []const u8, resource: ?[]const u8) !*EditorInput {
    const type_id = switch (kind) {
        .serializable => "testEditorInputForGroups",
        .non_serializable => "testEditorInputForGroups-nonSerializable",
        .file => "testFileEditorInputForGroups",
    };

    const input = try allocator.create(TestEditorInput);
    input.* = .{
        .base = EditorInput.init(allocator, type_id),
        .kind = kind,
        .id = id,
        .resource = resource,
    };
    input.base.impl = input;
    input.base.resource = resource;
    input.base.editor_id = if (kind == .file) id else null;
    input.base.matches_fn = matchesFn;
    return &input.base;
}

fn makeGroup(allocator: Allocator, config: group_mod.Configuration) !*EditorGroupModel {
    const group = try allocator.create(EditorGroupModel);
    group.* = try EditorGroupModel.init(allocator, config);
    return group;
}

const GroupEvents = struct {
    allocator: Allocator,
    group: *EditorGroupModel,

    locked: usize = 0,
    active: usize = 0,
    index: usize = 0,
    label: usize = 0,

    opened: std.array_list.Managed(EditorChange),
    activated: std.array_list.Managed(EditorChange),
    closed: std.array_list.Managed(EditorCloseChange),
    pinned: std.array_list.Managed(EditorChange),
    unpinned: std.array_list.Managed(EditorChange),
    sticky: std.array_list.Managed(EditorChange),
    unsticky: std.array_list.Managed(EditorChange),
    transient: std.array_list.Managed(EditorChange),
    moved: std.array_list.Managed(EditorMoveChange),
    disposed: std.array_list.Managed(EditorChange),

    fn init(allocator: Allocator, group: *EditorGroupModel) GroupEvents {
        return .{
            .allocator = allocator,
            .group = group,
            .opened = std.array_list.Managed(EditorChange).init(allocator),
            .activated = std.array_list.Managed(EditorChange).init(allocator),
            .closed = std.array_list.Managed(EditorCloseChange).init(allocator),
            .pinned = std.array_list.Managed(EditorChange).init(allocator),
            .unpinned = std.array_list.Managed(EditorChange).init(allocator),
            .sticky = std.array_list.Managed(EditorChange).init(allocator),
            .unsticky = std.array_list.Managed(EditorChange).init(allocator),
            .transient = std.array_list.Managed(EditorChange).init(allocator),
            .moved = std.array_list.Managed(EditorMoveChange).init(allocator),
            .disposed = std.array_list.Managed(EditorChange).init(allocator),
        };
    }

    fn deinit(self: *GroupEvents) void {
        self.opened.deinit();
        self.activated.deinit();
        self.closed.deinit();
        self.pinned.deinit();
        self.unpinned.deinit();
        self.sticky.deinit();
        self.unsticky.deinit();
        self.transient.deinit();
        self.moved.deinit();
        self.disposed.deinit();
    }

    fn listen(self: *GroupEvents) !void {
        _ = try self.group.on_did_model_change.listen(self, onEvent);
    }

    fn onEvent(event: GroupModelChangeEvent, self: *GroupEvents) anyerror!void {
        switch (event) {
            .GROUP_LOCKED => self.locked += 1,
            .GROUP_ACTIVE => self.active += 1,
            .GROUP_INDEX => self.index += 1,
            .GROUP_LABEL => self.label += 1,
            .EDITOR_OPEN => |change| try self.opened.append(change),
            .EDITOR_CLOSE => |change| try self.closed.append(change),
            .EDITOR_ACTIVE => |change| try self.activated.append(change),
            .EDITOR_PIN => |change| {
                if (self.group.isPinned(.{ .editor = change.editor })) {
                    try self.pinned.append(change);
                } else {
                    try self.unpinned.append(change);
                }
            },
            .EDITOR_STICKY => |change| {
                if (self.group.isSticky(.{ .editor = change.editor })) {
                    try self.sticky.append(change);
                } else {
                    try self.unsticky.append(change);
                }
            },
            .EDITOR_TRANSIENT => |change| try self.transient.append(change),
            .EDITOR_MOVE => |change| try self.moved.append(change),
            .EDITOR_WILL_DISPOSE => |change| try self.disposed.append(change),
            .EDITORS_SELECTION, .EDITOR_LABEL, .EDITOR_CAPABILITIES, .EDITOR_DIRTY => {},
        }
    }
};

fn closeAllEditors(group: *EditorGroupModel, allocator: Allocator) !void {
    const editors = try group.getEditors(allocator, .SEQUENTIAL, false);
    defer allocator.free(editors);
    for (editors) |input| {
        _ = try group.closeEditor(input, .UNKNOWN, false);
    }
}

fn assertSequential(
    group: *EditorGroupModel,
    allocator: Allocator,
    expected: []const *EditorInput,
) !void {
    const editors = try group.getEditors(allocator, .SEQUENTIAL, false);
    defer allocator.free(editors);
    try std.testing.expectEqual(expected.len, editors.len);
    for (expected, editors) |want, got| {
        try std.testing.expectEqual(want, got);
    }
}

fn assertSelection(group: *EditorGroupModel, allocator: Allocator, active: *EditorInput, expected: []const *EditorInput) !void {
    try std.testing.expectEqual(active, group.activeEditor());
    const selected = try group.selectedEditors(allocator);
    defer allocator.free(selected);
    try std.testing.expectEqual(expected.len, selected.len);
    for (expected, selected) |want, got| {
        try std.testing.expectEqual(want, got);
    }
}

test "EditorGroupModel: Clone Group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = false, .active = true });

    _ = try group.stick(input2);
    try std.testing.expect(group.isSticky(.{ .editor = input2 }));

    try std.testing.expect(!group.isLocked());
    try group.lock(true);
    try std.testing.expect(group.isLocked());

    const clone = try group.clone();
    defer clone.destroy();
    try std.testing.expect(group.id != clone.id);
    try std.testing.expectEqual(@as(usize, 3), clone.count());
    try std.testing.expect(!clone.isLocked()); // locking does not clone over

    var did_editor_label_change = false;
    _ = try clone.on_did_model_change.listen(&did_editor_label_change, struct {
        fn cb(event: GroupModelChangeEvent, flag: *bool) anyerror!void {
            if (event == .EDITOR_LABEL) flag.* = true;
        }
    }.cb);
    try input1.fireLabel();
    try std.testing.expect(did_editor_label_change);

    try std.testing.expect(clone.isPinned(.{ .editor = input1 }));
    try std.testing.expect(!clone.isActive(.{ .input = input1 }));
    try std.testing.expect(!clone.isSticky(.{ .editor = input1 }));

    try std.testing.expect(clone.isPinned(.{ .editor = input2 }));
    try std.testing.expect(!clone.isActive(.{ .input = input2 }));
    try std.testing.expect(clone.isSticky(.{ .editor = input2 }));

    try std.testing.expect(!clone.isPinned(.{ .editor = input3 }));
    try std.testing.expect(clone.isActive(.{ .input = input3 }));
    try std.testing.expect(!clone.isSticky(.{ .editor = input3 }));
}

test "EditorGroupModel: isActive - untyped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .file, "testInput", "/fake");
    const input2 = try newInput(allocator, .file, "testInput2", "/fake2");
    const untyped_input: Candidate = .{ .untyped = .{ .resource = "/fake", .editor_id = "testInput" } };
    const untyped_non_active: Candidate = .{ .untyped = .{ .resource = "/fake2", .editor_id = "testInput2" } };

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .active = false });

    try std.testing.expect(group.isActive(.{ .input = input1 }));
    try std.testing.expect(group.isActive(untyped_input));
    try std.testing.expect(!group.isActive(untyped_non_active));
}

test "EditorGroupModel: contains untyped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .file, "input1", "/input1");
    const input2 = try newInput(allocator, .file, "input2", "/input2");
    const untyped1 = Candidate{ .untyped = .{ .resource = "/input1", .editor_id = "input1" } };
    const untyped2 = Candidate{ .untyped = .{ .resource = "/input2", .editor_id = "input2" } };

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });

    try std.testing.expect(group.contains(untyped1, .{}));
    try std.testing.expect(!group.contains(untyped1, .{ .strict_equals = true }));
    try std.testing.expect(!group.contains(untyped2, .{}));

    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    try std.testing.expect(group.contains(untyped1, .{}));
    try std.testing.expect(group.contains(untyped2, .{}));

    _ = try group.closeEditor(input1, .UNKNOWN, true);
    try std.testing.expect(!group.contains(untyped1, .{}));
    try std.testing.expect(group.contains(untyped2, .{}));
}

test "EditorGroupModel: group changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    try group.lock(true);
    try group.lock(true);
    try group.lock(false);
    try std.testing.expectEqual(@as(usize, 2), events.locked);

    try group.setIndex(4);
    try std.testing.expectEqual(@as(usize, 1), events.index);

    try group.setLabel("Window 1");
    try std.testing.expectEqual(@as(usize, 1), events.label);

    _ = try group.setActive(null);
    try std.testing.expectEqual(@as(usize, 1), events.active);
}

test "EditorGroupModel: One Editor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    try std.testing.expectEqual(@as(usize, 0), group.count());
    try std.testing.expectEqual(@as(usize, 0), (try group.getEditors(allocator, .MOST_RECENTLY_ACTIVE, false)).len);

    const input1 = try newInput(allocator, .serializable, "1", null);
    const opened = try group.openEditor(input1, .{ .active = true, .pinned = true });
    try std.testing.expectEqual(input1, opened.editor);
    try std.testing.expect(opened.is_new);

    try std.testing.expectEqual(@as(usize, 1), group.count());
    try std.testing.expectEqual(input1, group.findEditor(input1, .{}).?.editor);
    try std.testing.expectEqual(input1, group.activeEditor().?);
    try std.testing.expect(group.isActive(.{ .input = input1 }));
    try std.testing.expect(group.isPinned(.{ .editor = input1 }));
    try std.testing.expect(group.isPinned(.{ .index = 0 }));
    try std.testing.expect(group.isFirst(input1));
    try std.testing.expect(group.isLast(input1));

    try std.testing.expectEqual(input1, events.opened.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events.opened.items[0].editor_index);
    try std.testing.expectEqual(input1, events.activated.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events.activated.items[0].editor_index);

    const index = group.indexOf(.{ .input = input1 }).?;
    const close_event = (try group.closeEditor(input1, .UNPIN, true)).?;
    try std.testing.expectEqual(input1, close_event.editor);
    try std.testing.expectEqual(index, close_event.editor_index);
    try std.testing.expectEqual(@as(usize, 0), group.count());
    try std.testing.expectEqual(@as(?*EditorInput, null), group.activeEditor());
    try std.testing.expect(!group.isFirst(input1));
    try std.testing.expect(!group.isLast(input1));
    try std.testing.expectEqual(input1, events.closed.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events.closed.items[0].editor_index);
    try std.testing.expectEqual(EditorCloseContext.UNPIN, events.closed.items[0].context);

    const input2 = try newInput(allocator, .serializable, "2", null);
    _ = try group.openEditor(input2, .{ .active = true, .pinned = false });
    try std.testing.expectEqual(@as(usize, 1), group.count());
    try std.testing.expectEqual(input2, group.activeEditor().?);
    try std.testing.expect(!group.isPinned(.{ .editor = input2 }));
    try std.testing.expectEqual(input2, events.opened.items[1].editor);
    try std.testing.expectEqual(@as(usize, 0), events.opened.items[1].editor_index);
    try std.testing.expectEqual(input2, events.activated.items[1].editor);

    _ = try group.closeEditor(input2, .UNKNOWN, true);
    try std.testing.expectEqual(@as(usize, 0), group.count());
    try std.testing.expectEqual(input2, events.closed.items[1].editor);

    try std.testing.expectEqual(@as(?group_mod.EditorCloseResult, null), try group.closeEditor(input2, .UNKNOWN, true));

    const input3 = try newInput(allocator, .serializable, "3", null);
    _ = try group.openEditor(input3, .{ .active = false, .pinned = true });
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expect(group.isPinned(.{ .editor = input3 }));
    try std.testing.expectEqual(input3, events.activated.items[2].editor);
}

fn assertMru(
    group: *EditorGroupModel,
    allocator: Allocator,
    expected: []const *EditorInput,
) !void {
    const editors = try group.getEditors(allocator, .MOST_RECENTLY_ACTIVE, false);
    defer allocator.free(editors);
    try std.testing.expectEqual(expected.len, editors.len);
    for (expected, editors) |want, got| {
        try std.testing.expectEqual(want, got);
    }
}

const CloseDirection = enum { left, right, others };

fn closeEditors(
    group: *EditorGroupModel,
    allocator: Allocator,
    except: *EditorInput,
    direction: CloseDirection,
) !void {
    const index = group.indexOf(.{ .input = except }) orelse return;

    switch (direction) {
        .left => {
            var i = index;
            while (i > 0) {
                i -= 1;
                const input = group.getEditorByIndex(i).?;
                _ = try group.closeEditor(input, .UNKNOWN, true);
            }
        },
        .right => {
            var i = group.count();
            while (i > index + 1) {
                i -= 1;
                const input = group.getEditorByIndex(i).?;
                _ = try group.closeEditor(input, .UNKNOWN, true);
            }
        },
        .others => {
            const editors = try group.getEditors(allocator, .MOST_RECENTLY_ACTIVE, false);
            defer allocator.free(editors);
            for (editors) |input| {
                if (input != except) {
                    _ = try group.closeEditor(input, .UNKNOWN, true);
                }
            }
        },
    }
}

test "EditorGroupModel: Multiple Editors - Pinned and Active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input1_copy = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    var opened = try group.openEditor(input1, .{ .pinned = true, .active = true });
    try std.testing.expectEqual(input1, opened.editor);
    try std.testing.expect(opened.is_new);

    opened = try group.openEditor(input1_copy, .{ .pinned = true, .active = true });
    try std.testing.expectEqual(input1, opened.editor);
    try std.testing.expect(!opened.is_new);

    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = true, .active = true });

    try std.testing.expectEqual(@as(usize, 3), group.count());
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expect(!group.isActive(.{ .input = input1 }));
    try std.testing.expect(group.isPinned(.{ .editor = input1 }));
    try std.testing.expect(!group.isActive(.{ .input = input2 }));
    try std.testing.expect(group.isPinned(.{ .editor = input2 }));
    try std.testing.expect(group.isActive(.{ .input = input3 }));
    try std.testing.expect(group.isPinned(.{ .editor = input3 }));
    try std.testing.expect(group.isFirst(input1));
    try std.testing.expect(!group.isFirst(input2));
    try std.testing.expect(!group.isFirst(input3));
    try std.testing.expect(!group.isLast(input1));
    try std.testing.expect(!group.isLast(input2));
    try std.testing.expect(group.isLast(input3));

    try std.testing.expectEqual(input1, events.opened.items[0].editor);
    try std.testing.expectEqual(input2, events.opened.items[1].editor);
    try std.testing.expectEqual(input3, events.opened.items[2].editor);

    try std.testing.expectEqual(input1, events.activated.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events.activated.items[0].editor_index);
    try std.testing.expectEqual(input2, events.activated.items[1].editor);
    try std.testing.expectEqual(@as(usize, 1), events.activated.items[1].editor_index);
    try std.testing.expectEqual(input3, events.activated.items[2].editor);
    try std.testing.expectEqual(@as(usize, 2), events.activated.items[2].editor_index);

    try assertMru(group, allocator, &.{ input3, input2, input1 });

    const same_input1 = try newInput(allocator, .serializable, "1", null);
    _ = try group.openEditor(same_input1, .{ .pinned = true, .active = true });
    try std.testing.expectEqual(input1, events.activated.items[3].editor);
    try std.testing.expectEqual(@as(usize, 0), events.activated.items[3].editor_index);

    _ = try group.unpin(same_input1);
    try std.testing.expectEqual(input1, events.unpinned.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events.unpinned.items[0].editor_index);

    _ = try group.pin(same_input1);
    try std.testing.expectEqual(input1, events.pinned.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events.pinned.items[0].editor_index);

    _ = try group.stick(same_input1);
    try std.testing.expectEqual(input1, events.sticky.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events.sticky.items[0].editor_index);

    _ = try group.unstick(same_input1);
    try std.testing.expectEqual(input1, events.unsticky.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events.unsticky.items[0].editor_index);

    _ = try group.moveEditor(same_input1, 1);
    try std.testing.expectEqual(input1, events.moved.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events.moved.items[0].old_editor_index);
    try std.testing.expectEqual(@as(usize, 1), events.moved.items[0].editor_index);

    _ = try group.closeEditor(same_input1, .UNKNOWN, true);
    try std.testing.expectEqual(input1, events.closed.items[0].editor);
    try std.testing.expectEqual(@as(usize, 1), events.closed.items[0].editor_index);

    try closeAllEditors(group, allocator);
    try std.testing.expectEqual(@as(usize, 3), events.closed.items.len);
    try std.testing.expectEqual(@as(usize, 0), group.count());
}

test "EditorGroupModel: preview editor moves to the side of the active one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{ .pinned = false, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = true, .active = true });

    try std.testing.expectEqual(input3, (try group.getEditors(allocator, .SEQUENTIAL, false))[2]);

    const input4 = try newInput(allocator, .serializable, "4", null);
    _ = try group.openEditor(input4, .{ .pinned = false, .active = true });

    try std.testing.expectEqual(input4, (try group.getEditors(allocator, .SEQUENTIAL, false))[2]);
}

test "EditorGroupModel: Pinned and Active with left positioning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{ .editor_open_positioning = .left });
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = true, .active = true });

    try assertSequential(group, allocator, &.{ input3, input2, input1 });

    try closeAllEditors(group, allocator);
    try std.testing.expectEqual(@as(usize, 3), events.closed.items.len);
    try std.testing.expectEqual(@as(usize, 0), group.count());
}

test "EditorGroupModel: Pinned and Not Active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{ .pinned = true });
    _ = try group.openEditor(input2, .{ .pinned = true });
    _ = try group.openEditor(input3, .{ .pinned = true });

    try std.testing.expectEqual(@as(usize, 3), group.count());
    try std.testing.expectEqual(input1, group.activeEditor().?);
    try std.testing.expect(group.isActive(.{ .input = input1 }));
    try std.testing.expect(!group.isActive(.{ .input = input2 }));
    try std.testing.expect(!group.isActive(.{ .input = input3 }));
    try std.testing.expect(group.isPinned(.{ .editor = input1 }));
    try std.testing.expect(group.isPinned(.{ .index = 0 }));
    try std.testing.expect(group.isPinned(.{ .editor = input2 }));
    try std.testing.expect(group.isPinned(.{ .index = 1 }));
    try std.testing.expect(group.isPinned(.{ .editor = input3 }));
    try std.testing.expect(group.isPinned(.{ .index = 2 }));

    try assertMru(group, allocator, &.{ input1, input3, input2 });
}

test "EditorGroupModel: preview gets overwritten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{});
    _ = try group.openEditor(input2, .{});
    _ = try group.openEditor(input3, .{});

    try std.testing.expectEqual(@as(usize, 1), group.count());
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expect(group.isActive(.{ .input = input3 }));
    try std.testing.expect(!group.isPinned(.{ .editor = input3 }));

    try std.testing.expectEqual(input1, events.opened.items[0].editor);
    try std.testing.expectEqual(input2, events.opened.items[1].editor);
    try std.testing.expectEqual(input3, events.opened.items[2].editor);
    try std.testing.expectEqual(input1, events.closed.items[0].editor);
    try std.testing.expectEqual(input2, events.closed.items[1].editor);
    try std.testing.expectEqual(EditorCloseContext.REPLACE, events.closed.items[0].context);
    try std.testing.expectEqual(EditorCloseContext.REPLACE, events.closed.items[1].context);

    try assertMru(group, allocator, &.{input3});
}

test "EditorGroupModel: set active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = false, .active = true });

    try std.testing.expectEqual(input3, group.activeEditor().?);
    try assertMru(group, allocator, &.{ input3, input2, input1 });

    _ = try group.setActive(input3);
    try std.testing.expectEqual(@as(usize, 3), events.activated.items.len);

    _ = try group.setActive(input1);
    try std.testing.expectEqual(input1, events.activated.items[3].editor);
    try std.testing.expectEqual(input1, group.activeEditor().?);
    try std.testing.expect(group.isActive(.{ .input = input1 }));
    try std.testing.expect(!group.isActive(.{ .input = input2 }));
    try std.testing.expect(!group.isActive(.{ .input = input3 }));

    try assertMru(group, allocator, &.{ input1, input3, input2 });
}

test "EditorGroupModel: pin and unpin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = false, .active = true });

    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 3), group.count());

    _ = try group.pin(input3);
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expect(group.isPinned(.{ .editor = input3 }));
    try std.testing.expect(group.isActive(.{ .input = input3 }));
    try std.testing.expectEqual(input3, events.pinned.items[0].editor);
    try std.testing.expectEqual(@as(usize, 3), group.count());

    _ = try group.unpin(input1);
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expect(!group.isPinned(.{ .editor = input1 }));
    try std.testing.expect(!group.isActive(.{ .input = input1 }));
    try std.testing.expectEqual(input1, events.unpinned.items[0].editor);
    try std.testing.expectEqual(@as(usize, 3), group.count());

    _ = try group.unpin(input2);
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 2), group.count());
    try assertSequential(group, allocator, &.{ input2, input3 });
    try std.testing.expectEqual(input1, events.closed.items[0].editor);

    _ = try group.unpin(input3);
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 1), group.count());
    try assertSequential(group, allocator, &.{input3});
    try std.testing.expectEqual(input2, events.closed.items[1].editor);
}

test "EditorGroupModel: closing picks next from MRU list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);
    const input4 = try newInput(allocator, .serializable, "4", null);
    const input5 = try newInput(allocator, .serializable, "5", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input4, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input5, .{ .pinned = true, .active = true });

    try std.testing.expectEqual(input5, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 5), group.count());

    _ = try group.closeEditor(input5, .UNKNOWN, true);
    try std.testing.expectEqual(input4, group.activeEditor().?);
    try std.testing.expectEqual(input4, events.activated.items[5].editor);
    try std.testing.expectEqual(@as(usize, 4), group.count());

    _ = try group.setActive(input1);
    _ = try group.setActive(input4);
    _ = try group.closeEditor(input4, .UNKNOWN, true);
    try std.testing.expectEqual(input1, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 3), group.count());

    _ = try group.closeEditor(input1, .UNKNOWN, true);
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 2), group.count());

    _ = try group.setActive(input2);
    _ = try group.closeEditor(input2, .UNKNOWN, true);
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 1), group.count());

    _ = try group.closeEditor(input3, .UNKNOWN, true);
    try std.testing.expectEqual(@as(?*EditorInput, null), group.activeEditor());
    try std.testing.expectEqual(@as(usize, 0), group.count());
}

test "EditorGroupModel: closing picks next to the right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{ .focus_recent_editor_after_close = false });
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);
    const input4 = try newInput(allocator, .serializable, "4", null);
    const input5 = try newInput(allocator, .serializable, "5", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input4, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input5, .{ .pinned = true, .active = true });

    _ = try group.closeEditor(input5, .UNKNOWN, true);
    try std.testing.expectEqual(input4, group.activeEditor().?);
    try std.testing.expectEqual(input4, events.activated.items[5].editor);

    _ = try group.setActive(input1);
    _ = try group.closeEditor(input1, .UNKNOWN, true);
    try std.testing.expectEqual(input2, group.activeEditor().?);

    _ = try group.setActive(input3);
    _ = try group.closeEditor(input3, .UNKNOWN, true);
    try std.testing.expectEqual(input4, group.activeEditor().?);

    _ = try group.closeEditor(input4, .UNKNOWN, true);
    try std.testing.expectEqual(input2, group.activeEditor().?);

    _ = try group.closeEditor(input2, .UNKNOWN, true);
    try std.testing.expectEqual(@as(?*EditorInput, null), group.activeEditor());
    try std.testing.expectEqual(@as(usize, 0), group.count());
}

test "EditorGroupModel: move editor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);
    const input4 = try newInput(allocator, .serializable, "4", null);
    const input5 = try newInput(allocator, .serializable, "5", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });

    _ = try group.moveEditor(input1, 1);
    try std.testing.expectEqual(input1, events.moved.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events.moved.items[0].old_editor_index);
    try std.testing.expectEqual(@as(usize, 1), events.moved.items[0].editor_index);
    try assertSequential(group, allocator, &.{ input2, input1 });

    _ = try group.setActive(input1);
    _ = try group.openEditor(input3, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input4, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input5, .{ .pinned = true, .active = true });

    _ = try group.moveEditor(input4, 0);
    try std.testing.expectEqual(input4, events.moved.items[1].editor);
    try std.testing.expectEqual(@as(usize, 3), events.moved.items[1].old_editor_index);
    try std.testing.expectEqual(@as(usize, 0), events.moved.items[1].editor_index);
    try assertSequential(group, allocator, &.{ input4, input2, input1, input3, input5 });

    _ = try group.moveEditor(input4, 3);
    _ = try group.moveEditor(input2, 1);
    try assertSequential(group, allocator, &.{ input1, input2, input3, input4, input5 });

    try std.testing.expectEqual(@as(usize, 4), events.moved.items.len);
    _ = try group.moveEditor(input1, 0);
    try std.testing.expectEqual(@as(usize, 4), events.moved.items.len);
    _ = try group.moveEditor(input1, -1);
    try std.testing.expectEqual(@as(usize, 4), events.moved.items.len);

    _ = try group.moveEditor(input5, 4);
    try std.testing.expectEqual(@as(usize, 4), events.moved.items.len);
    _ = try group.moveEditor(input5, 100);
    try std.testing.expectEqual(@as(usize, 4), events.moved.items.len);

    _ = try group.moveEditor(input5, -1);
    try std.testing.expectEqual(@as(usize, 5), events.moved.items.len);
    try std.testing.expectEqual(input5, (try group.getEditors(allocator, .SEQUENTIAL, false))[0]);

    _ = try group.moveEditor(input1, 100);
    try std.testing.expectEqual(@as(usize, 6), events.moved.items.len);
    try std.testing.expectEqual(input1, (try group.getEditors(allocator, .SEQUENTIAL, false))[4]);
}

test "EditorGroupModel: move editor across groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group1 = try makeGroup(allocator, .{});
    defer group1.deinit();
    const group2 = try makeGroup(allocator, .{});
    defer group2.deinit();

    const g1_input1 = try newInput(allocator, .serializable, "g1-1", null);
    const g1_input2 = try newInput(allocator, .serializable, "g1-2", null);
    const g2_input1 = try newInput(allocator, .serializable, "g2-1", null);

    _ = try group1.openEditor(g1_input1, .{ .active = true, .pinned = true });
    _ = try group1.openEditor(g1_input2, .{ .active = true, .pinned = true });
    _ = try group2.openEditor(g2_input1, .{ .active = true, .pinned = true });

    _ = try group2.closeEditor(g2_input1, .UNKNOWN, true);
    _ = try group1.openEditor(g2_input1, .{ .active = true, .pinned = true, .index = 1 });

    try std.testing.expectEqual(@as(usize, 3), group1.count());
    try assertSequential(group1, allocator, &.{ g1_input1, g2_input1, g1_input2 });
}

test "EditorGroupModel: move editor across groups when the input already exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group1 = try makeGroup(allocator, .{});
    defer group1.deinit();
    const group2 = try makeGroup(allocator, .{});
    defer group2.deinit();

    const g1_input1 = try newInput(allocator, .serializable, "g1-1", null);
    const g1_input2 = try newInput(allocator, .serializable, "g1-2", null);
    const g1_input3 = try newInput(allocator, .serializable, "g1-3", null);
    const g2_input1 = g1_input2;

    _ = try group1.openEditor(g1_input1, .{ .active = true, .pinned = true });
    _ = try group1.openEditor(g1_input2, .{ .active = true, .pinned = true });
    _ = try group1.openEditor(g1_input3, .{ .active = true, .pinned = true });
    _ = try group2.openEditor(g2_input1, .{ .active = true, .pinned = true });

    _ = try group2.closeEditor(g2_input1, .UNKNOWN, true);
    _ = try group1.openEditor(g2_input1, .{ .active = true, .pinned = true, .index = 0 });

    try std.testing.expectEqual(@as(usize, 3), group1.count());
    try assertSequential(group1, allocator, &.{ g1_input2, g1_input1, g1_input3 });
}

test "EditorGroupModel: Pinned and non-active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    _ = try group.openEditor(input1, .{});
    try std.testing.expectEqual(input1, group.activeEditor().?);
    try std.testing.expectEqual(input1, group.previewEditor().?);
    try assertSequential(group, allocator, &.{input1});

    const input2 = try newInput(allocator, .serializable, "2", null);
    _ = try group.openEditor(input2, .{ .pinned = true, .active = false });
    try std.testing.expectEqual(input1, group.activeEditor().?);
    try std.testing.expectEqual(input1, group.previewEditor().?);
    try assertSequential(group, allocator, &.{ input1, input2 });

    const input3 = try newInput(allocator, .serializable, "3", null);
    _ = try group.openEditor(input3, .{ .pinned = true, .active = false });
    try std.testing.expectEqual(input1, group.activeEditor().?);
    try std.testing.expectEqual(input1, group.previewEditor().?);
    try assertSequential(group, allocator, &.{ input1, input3, input2 });
    try std.testing.expect(!group.isPinned(.{ .editor = input1 }));
    try std.testing.expect(group.isPinned(.{ .editor = input2 }));
    try std.testing.expect(group.isPinned(.{ .editor = input3 }));
}

test "EditorGroupModel: close others, close left, close right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);
    const input4 = try newInput(allocator, .serializable, "4", null);
    const input5 = try newInput(allocator, .serializable, "5", null);

    _ = try group.openEditor(input1, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input2, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input3, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input4, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input5, .{ .active = true, .pinned = true });

    try closeEditors(group, allocator, group.activeEditor().?, .others);
    try std.testing.expectEqual(input5, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 1), group.count());

    try closeAllEditors(group, allocator);
    _ = try group.openEditor(input1, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input2, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input3, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input4, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input5, .{ .active = true, .pinned = true });
    _ = try group.setActive(input3);

    try closeEditors(group, allocator, group.activeEditor().?, .left);
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 3), group.count());
    try assertSequential(group, allocator, &.{ input3, input4, input5 });

    try closeAllEditors(group, allocator);
    _ = try group.openEditor(input1, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input2, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input3, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input4, .{ .active = true, .pinned = true });
    _ = try group.openEditor(input5, .{ .active = true, .pinned = true });
    _ = try group.setActive(input3);

    try closeEditors(group, allocator, group.activeEditor().?, .right);
    try std.testing.expectEqual(input3, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 3), group.count());
    try assertSequential(group, allocator, &.{ input1, input2, input3 });
}

test "EditorGroupModel: real user example" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const index_html = try newInput(allocator, .serializable, "index.html", null);
    var opened = try group.openEditor(index_html, .{});
    try std.testing.expectEqual(index_html, opened.editor);
    try std.testing.expectEqual(index_html, group.activeEditor().?);
    try std.testing.expectEqual(index_html, group.previewEditor().?);
    try assertSequential(group, allocator, &.{index_html});

    const same_index_html = try newInput(allocator, .serializable, "index.html", null);
    opened = try group.openEditor(same_index_html, .{});
    try std.testing.expectEqual(index_html, opened.editor);
    try std.testing.expectEqual(@as(usize, 1), group.count());

    const style_css = try newInput(allocator, .serializable, "style.css", null);
    opened = try group.openEditor(style_css, .{});
    try std.testing.expectEqual(style_css, opened.editor);
    try std.testing.expectEqual(style_css, group.previewEditor().?);

    const test_js = try newInput(allocator, .serializable, "test.js", null);
    opened = try group.openEditor(test_js, .{ .active = true, .pinned = true });
    try std.testing.expectEqual(test_js, opened.editor);
    try std.testing.expectEqual(style_css, group.previewEditor().?);
    try std.testing.expectEqual(test_js, group.activeEditor().?);
    try std.testing.expect(!group.isPinned(.{ .editor = style_css }));
    try std.testing.expect(group.isPinned(.{ .editor = test_js }));
    try assertSequential(group, allocator, &.{ style_css, test_js });

    const index_html2 = try newInput(allocator, .serializable, "index.html", null);
    _ = try group.openEditor(index_html2, .{ .active = true });
    try std.testing.expectEqual(index_html2, group.activeEditor().?);
    try std.testing.expectEqual(index_html2, group.previewEditor().?);
    try std.testing.expect(!group.isPinned(.{ .editor = index_html2 }));
    try std.testing.expect(group.isPinned(.{ .editor = test_js }));
    try assertSequential(group, allocator, &.{ test_js, index_html2 });

    const test_js2 = try newInput(allocator, .serializable, "test.js", null);
    _ = try group.setActive(test_js2);
    try std.testing.expectEqual(test_js, group.activeEditor().?);
    try std.testing.expect(group.isActive(.{ .input = test_js2 }));

    const index_html3 = try newInput(allocator, .serializable, "index.html", null);
    _ = try group.pin(index_html3);
    try std.testing.expect(group.isPinned(.{ .editor = index_html3 }));
    try std.testing.expectEqual(test_js, group.activeEditor().?);

    const file_ts = try newInput(allocator, .serializable, "file.ts", null);
    _ = try group.openEditor(file_ts, .{ .active = true, .pinned = true });
    try std.testing.expect(group.isPinned(.{ .editor = file_ts }));
    try std.testing.expectEqual(@as(usize, 3), group.count());
    try std.testing.expectEqual(file_ts, group.activeEditor().?);

    _ = try group.unpin(file_ts);
    try std.testing.expectEqual(@as(usize, 3), group.count());
    try std.testing.expect(!group.isPinned(.{ .editor = file_ts }));
    try std.testing.expectEqual(file_ts, group.activeEditor().?);

    const other_ts = try newInput(allocator, .serializable, "other.ts", null);
    _ = try group.openEditor(other_ts, .{ .active = true });
    try std.testing.expectEqual(@as(usize, 3), group.count());
    try std.testing.expectEqual(other_ts, group.activeEditor().?);
    try std.testing.expect((try group.getEditors(allocator, .SEQUENTIAL, false))[0].matches(.{ .input = test_js }));
    try std.testing.expectEqual(other_ts, (try group.getEditors(allocator, .SEQUENTIAL, false))[1]);
    try std.testing.expect((try group.getEditors(allocator, .SEQUENTIAL, false))[2].matches(.{ .input = index_html }));

    const index_html4 = try newInput(allocator, .serializable, "index.html", null);
    _ = try group.setActive(index_html4);
    try std.testing.expectEqual(index_html2, group.activeEditor().?);

    _ = try group.closeEditor(index_html, .UNKNOWN, true);
    try std.testing.expectEqual(@as(usize, 2), group.count());
    try std.testing.expectEqual(other_ts, group.activeEditor().?);
    try std.testing.expect((try group.getEditors(allocator, .SEQUENTIAL, false))[0].matches(.{ .input = test_js }));
    try std.testing.expectEqual(other_ts, (try group.getEditors(allocator, .SEQUENTIAL, false))[1]);

    _ = try group.closeEditor(other_ts, .UNKNOWN, true);
    try std.testing.expectEqual(@as(usize, 1), group.count());
    try std.testing.expectEqual(test_js, group.activeEditor().?);

    _ = try group.unpin(test_js);
    try std.testing.expectEqual(@as(usize, 1), group.count());
    try std.testing.expectEqual(test_js, group.activeEditor().?);
    try std.testing.expect(!group.isPinned(.{ .editor = test_js }));

    _ = try group.closeEditor(test_js, .UNKNOWN, true);
    try std.testing.expectEqual(@as(usize, 0), group.count());
    try std.testing.expectEqual(@as(?*EditorInput, null), group.activeEditor());
    try std.testing.expectEqual(@as(?*EditorInput, null), group.previewEditor());
}

test "EditorGroupModel: editor dispose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group1 = try makeGroup(allocator, .{});
    defer group1.deinit();
    const group2 = try makeGroup(allocator, .{});
    defer group2.deinit();

    var events1 = GroupEvents.init(allocator, group1);
    defer events1.deinit();
    try events1.listen();
    var events2 = GroupEvents.init(allocator, group2);
    defer events2.deinit();
    try events2.listen();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group1.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group1.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group1.openEditor(input3, .{ .pinned = true, .active = true });

    _ = try group2.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group2.openEditor(input2, .{ .pinned = true, .active = true });

    input1.dispose();

    try std.testing.expectEqual(@as(usize, 1), events1.disposed.items.len);
    try std.testing.expectEqual(@as(usize, 0), events1.disposed.items[0].editor_index);
    try std.testing.expectEqual(@as(usize, 1), events2.disposed.items.len);
    try std.testing.expectEqual(@as(usize, 0), events2.disposed.items[0].editor_index);
    try std.testing.expect(events1.disposed.items[0].editor.matches(.{ .input = input1 }));
    try std.testing.expect(events2.disposed.items[0].editor.matches(.{ .input = input1 }));

    input3.dispose();
    try std.testing.expectEqual(@as(usize, 2), events1.disposed.items.len);
    try std.testing.expectEqual(@as(usize, 2), events1.disposed.items[1].editor_index);
    try std.testing.expectEqual(@as(usize, 1), events2.disposed.items.len);
    try std.testing.expect(events1.disposed.items[1].editor.matches(.{ .input = input3 }));
}

test "EditorGroupModel: preview tab does not have a stable position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .active = true });
    _ = try group.setActive(input1);

    _ = try group.openEditor(input3, .{ .active = true });
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input3 }));
}

test "EditorGroupModel: editor emits dirty and label changed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group1 = try makeGroup(allocator, .{});
    defer group1.deinit();
    const group2 = try makeGroup(allocator, .{});
    defer group2.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);

    _ = try group1.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group2.openEditor(input2, .{ .pinned = true, .active = true });

    var dirty1: usize = 0;
    _ = try group1.on_did_model_change.listen(&dirty1, struct {
        fn cb(event: GroupModelChangeEvent, counter: *usize) anyerror!void {
            if (event == .EDITOR_DIRTY) counter.* += 1;
        }
    }.cb);
    var dirty2: usize = 0;
    _ = try group2.on_did_model_change.listen(&dirty2, struct {
        fn cb(event: GroupModelChangeEvent, counter: *usize) anyerror!void {
            if (event == .EDITOR_DIRTY) counter.* += 1;
        }
    }.cb);
    var label1: usize = 0;
    _ = try group1.on_did_model_change.listen(&label1, struct {
        fn cb(event: GroupModelChangeEvent, counter: *usize) anyerror!void {
            if (event == .EDITOR_LABEL) counter.* += 1;
        }
    }.cb);
    var label2: usize = 0;
    _ = try group2.on_did_model_change.listen(&label2, struct {
        fn cb(event: GroupModelChangeEvent, counter: *usize) anyerror!void {
            if (event == .EDITOR_LABEL) counter.* += 1;
        }
    }.cb);

    try input1.fireDirty();
    try input1.fireLabel();
    try std.testing.expectEqual(@as(usize, 1), dirty1);
    try std.testing.expectEqual(@as(usize, 1), label1);

    try input2.fireDirty();
    try input2.fireLabel();
    try std.testing.expectEqual(@as(usize, 1), dirty2);
    try std.testing.expectEqual(@as(usize, 1), label2);

    try closeAllEditors(group2, allocator);

    try input2.fireDirty();
    try input2.fireLabel();
    try std.testing.expectEqual(@as(usize, 1), dirty2);
    try std.testing.expectEqual(@as(usize, 1), label2);
    try std.testing.expectEqual(@as(usize, 1), dirty1);
    try std.testing.expectEqual(@as(usize, 1), label1);
}

test "EditorGroupModel: sticky editors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);
    const input4 = try newInput(allocator, .serializable, "4", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = false, .active = true });

    try std.testing.expectEqual(@as(usize, 0), group.stickyCount());
    try std.testing.expectEqual(@as(usize, 3), (try group.getEditors(allocator, .SEQUENTIAL, false)).len);
    try std.testing.expectEqual(@as(usize, 3), (try group.getEditors(allocator, .SEQUENTIAL, true)).len);
    try std.testing.expectEqual(@as(usize, 3), (try group.getEditors(allocator, .MOST_RECENTLY_ACTIVE, false)).len);
    try std.testing.expectEqual(@as(usize, 3), (try group.getEditors(allocator, .MOST_RECENTLY_ACTIVE, true)).len);

    _ = try group.stick(input3);
    try std.testing.expectEqual(@as(usize, 1), group.stickyCount());
    try std.testing.expectEqual(@as(usize, 2), (try group.getEditors(allocator, .MOST_RECENTLY_ACTIVE, true)).len);
    try std.testing.expectEqual(@as(usize, 3), (try group.getEditors(allocator, .MOST_RECENTLY_ACTIVE, false)).len);
    try std.testing.expect(!group.isSticky(.{ .editor = input1 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input2 }));
    try std.testing.expect(group.isSticky(.{ .editor = input3 }));
    try std.testing.expect(group.isPinned(.{ .editor = input3 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input3 }));

    {
        const seq_excl = try group.getEditors(allocator, .SEQUENTIAL, true);
        try std.testing.expectEqual(@as(usize, 2), seq_excl.len);
        try std.testing.expect(group.indexOfExact(input1) != null);
        try std.testing.expect(group.indexOfExact(input2) != null);
        const mru_excl = try group.getEditors(allocator, .MOST_RECENTLY_ACTIVE, true);
        try std.testing.expectEqual(@as(usize, 2), mru_excl.len);
    }

    _ = try group.stick(input3);
    try std.testing.expect(group.isSticky(.{ .editor = input3 }));

    _ = try group.stick(input2);
    try std.testing.expectEqual(@as(usize, 2), group.stickyCount());
    try std.testing.expect(!group.isSticky(.{ .editor = input1 }));
    try std.testing.expect(group.isSticky(.{ .editor = input2 }));
    try std.testing.expect(group.isSticky(.{ .editor = input3 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input3 }));

    _ = try group.stick(input1);
    try std.testing.expectEqual(@as(usize, 3), group.stickyCount());
    try std.testing.expectEqual(@as(usize, 0), (try group.getEditors(allocator, .SEQUENTIAL, true)).len);
    try std.testing.expectEqual(@as(usize, 0), (try group.getEditors(allocator, .MOST_RECENTLY_ACTIVE, true)).len);

    _ = try group.unstick(input3);
    try std.testing.expectEqual(@as(usize, 2), group.stickyCount());
    try std.testing.expect(group.isSticky(.{ .editor = input1 }));
    try std.testing.expect(group.isSticky(.{ .editor = input2 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input3 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input3 }));

    _ = try group.unstick(input1);
    _ = try group.unstick(input2);
    try std.testing.expectEqual(@as(usize, 0), group.stickyCount());
    try std.testing.expect(!group.isSticky(.{ .editor = input1 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input2 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input3 }));

    _ = try group.moveEditor(input1, 0);
    _ = try group.moveEditor(input2, 1);
    _ = try group.moveEditor(input3, 2);

    _ = try group.stick(input1);
    _ = try group.stick(input2);
    _ = try group.setActive(input1);

    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    _ = try group.openEditor(input4, .{ .pinned = true, .active = true });
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input4 }));
    _ = try group.closeEditor(input4, .UNKNOWN, true);
    try std.testing.expect(!events.closed.items[0].sticky);

    _ = try group.setActive(input2);
    _ = try group.openEditor(input4, .{ .pinned = true, .active = true });
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input4 }));
    _ = try group.closeEditor(input4, .UNKNOWN, true);
    try std.testing.expect(!events.closed.items[1].sticky);

    try std.testing.expectEqual(@as(usize, 2), group.stickyCount());
    try std.testing.expect(group.isSticky(.{ .editor = input1 }));
    try std.testing.expect(group.isSticky(.{ .editor = input2 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input3 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input3 }));

    _ = try group.moveEditor(input1, 1);
    try std.testing.expect(group.isSticky(.{ .editor = input1 }));
    try std.testing.expect(group.isSticky(.{ .editor = input2 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input3 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input3 }));

    _ = try group.moveEditor(input1, 0);
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input2 }));

    _ = try group.moveEditor(input1, 2);
    try std.testing.expect(!group.isSticky(.{ .editor = input1 }));
    try std.testing.expect(group.isSticky(.{ .editor = input2 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input3 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input3 }));

    _ = try group.moveEditor(input2, 2);
    try std.testing.expect(!group.isSticky(.{ .editor = input1 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input2 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input3 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input3 }));

    _ = try group.moveEditor(input1, 0);
    _ = try group.moveEditor(input2, 1);
    _ = try group.moveEditor(input3, 2);
    _ = try group.stick(input1);
    _ = try group.unstick(input2);
    try std.testing.expectEqual(@as(usize, 1), group.stickyCount());
    try std.testing.expect(group.isSticky(.{ .editor = input1 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input2 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input3 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input3 }));

    _ = try group.moveEditor(input3, 1);
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input3 }));

    _ = try group.moveEditor(input3, 2);
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input3 }));

    _ = try group.moveEditor(input3, 0);
    try std.testing.expect(group.isSticky(.{ .editor = input3 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input3 }));

    _ = try group.moveEditor(input2, 0);
    try std.testing.expect(group.isSticky(.{ .editor = input2 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input3 }));

    _ = try group.stick(input1);
    _ = try group.stick(input2);
    _ = try group.unstick(input3);
    try std.testing.expectEqual(@as(usize, 2), group.stickyCount());
    _ = try group.closeEditor(input1, .UNKNOWN, true);
    try std.testing.expect(events.closed.items[2].sticky);
    try std.testing.expectEqual(@as(usize, 1), group.stickyCount());
    _ = try group.closeEditor(input2, .UNKNOWN, true);
    try std.testing.expect(events.closed.items[3].sticky);
    try std.testing.expectEqual(@as(usize, 0), group.stickyCount());

    try closeAllEditors(group, allocator);
    try std.testing.expectEqual(@as(usize, 0), group.stickyCount());

    _ = try group.openEditor(input1, .{ .sticky = true });
    try std.testing.expectEqual(@as(usize, 1), group.stickyCount());
    try std.testing.expect(group.isSticky(.{ .editor = input1 }));

    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    try std.testing.expectEqual(@as(usize, 1), group.stickyCount());
    try std.testing.expect(!group.isSticky(.{ .editor = input2 }));

    _ = try group.openEditor(input2, .{ .sticky = true });
    try std.testing.expectEqual(@as(usize, 2), group.stickyCount());
    try std.testing.expect(group.isSticky(.{ .editor = input2 }));

    _ = try group.openEditor(input3, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input4, .{ .pinned = false, .active = true, .sticky = true });
    try std.testing.expectEqual(@as(usize, 3), group.stickyCount());
    try std.testing.expect(group.isSticky(.{ .editor = input1 }));
    try std.testing.expect(group.isSticky(.{ .editor = input2 }));
    try std.testing.expect(!group.isSticky(.{ .editor = input3 }));
    try std.testing.expect(group.isSticky(.{ .editor = input4 }));
    try std.testing.expect(group.isPinned(.{ .editor = input4 }));
    try std.testing.expectEqual(@as(?usize, 0), group.indexOf(.{ .input = input1 }));
    try std.testing.expectEqual(@as(?usize, 1), group.indexOf(.{ .input = input2 }));
    try std.testing.expectEqual(@as(?usize, 3), group.indexOf(.{ .input = input3 }));
    try std.testing.expectEqual(@as(?usize, 2), group.indexOf(.{ .input = input4 }));
}

test "EditorGroupModel: sticky and unsticky events send correct editor index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = false, .active = true });
    try std.testing.expectEqual(@as(usize, 0), group.stickyCount());

    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    _ = try group.stick(input3);
    try std.testing.expectEqual(@as(usize, 0), events.sticky.items[0].editor_index);
    try std.testing.expectEqual(@as(usize, 1), group.stickyCount());

    _ = try group.stick(input2);
    try std.testing.expectEqual(@as(usize, 1), events.sticky.items[1].editor_index);
    try std.testing.expectEqual(@as(usize, 2), group.stickyCount());

    _ = try group.unstick(input3);
    try std.testing.expectEqual(@as(usize, 1), events.unsticky.items[0].editor_index);
    try std.testing.expect(!group.isSticky(.{ .editor = input3 }));
    try std.testing.expect(group.isSticky(.{ .editor = input2 }));
    try std.testing.expectEqual(@as(usize, 1), group.stickyCount());
}

test "EditorGroupModel: move and open events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group1 = try makeGroup(allocator, .{});
    defer group1.deinit();
    const group2 = try makeGroup(allocator, .{});
    defer group2.deinit();

    var events1 = GroupEvents.init(allocator, group1);
    defer events1.deinit();
    try events1.listen();
    var events2 = GroupEvents.init(allocator, group2);
    defer events2.deinit();
    try events2.listen();

    const input1_group1 = try newInput(allocator, .serializable, "g1-1", null);
    const input2_group1 = try newInput(allocator, .serializable, "g1-2", null);
    const input1_group2 = try newInput(allocator, .serializable, "g2-1", null);
    const input2_group2 = try newInput(allocator, .serializable, "g2-2", null);

    _ = try group1.openEditor(input1_group1, .{ .pinned = true, .active = true, .index = 0 });
    _ = try group1.openEditor(input2_group1, .{ .pinned = true, .active = false, .index = 1 });
    _ = try group2.openEditor(input1_group2, .{ .pinned = true, .active = true, .index = 0 });
    _ = try group2.openEditor(input2_group2, .{ .pinned = true, .active = false, .index = 1 });

    try std.testing.expectEqual(@as(usize, 2), events1.opened.items.len);
    try std.testing.expectEqual(input1_group1, events1.opened.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events1.opened.items[0].editor_index);
    try std.testing.expectEqual(input2_group1, events1.opened.items[1].editor);
    try std.testing.expectEqual(@as(usize, 1), events1.opened.items[1].editor_index);

    try std.testing.expectEqual(@as(usize, 2), events2.opened.items.len);
    try std.testing.expectEqual(input1_group2, events2.opened.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events2.opened.items[0].editor_index);
    try std.testing.expectEqual(input2_group2, events2.opened.items[1].editor);
    try std.testing.expectEqual(@as(usize, 1), events2.opened.items[1].editor_index);

    _ = try group1.moveEditor(input1_group1, 1);
    try std.testing.expectEqual(input1_group1, events1.moved.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events1.moved.items[0].old_editor_index);
    try std.testing.expectEqual(@as(usize, 1), events1.moved.items[0].editor_index);

    _ = try group2.moveEditor(input1_group2, 1);
    try std.testing.expectEqual(input1_group2, events2.moved.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events2.moved.items[0].old_editor_index);
    try std.testing.expectEqual(@as(usize, 1), events2.moved.items[0].editor_index);
}

test "EditorGroupModel: moving editor sends sticky event when sticky changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group1 = try makeGroup(allocator, .{});
    defer group1.deinit();

    const input1_group1 = try newInput(allocator, .serializable, "g1-1", null);
    const input2_group1 = try newInput(allocator, .serializable, "g1-2", null);
    const input3_group1 = try newInput(allocator, .serializable, "g1-3", null);

    _ = try group1.openEditor(input1_group1, .{ .pinned = true, .active = true, .index = 0, .sticky = true });
    _ = try group1.openEditor(input2_group1, .{ .pinned = true, .active = false, .index = 1 });
    _ = try group1.openEditor(input3_group1, .{ .pinned = true, .active = false, .index = 2 });

    var events1 = GroupEvents.init(allocator, group1);
    defer events1.deinit();
    try events1.listen();

    _ = try group1.moveEditor(input2_group1, 0);
    try std.testing.expectEqual(input2_group1, events1.sticky.items[0].editor);
    try std.testing.expectEqual(@as(usize, 0), events1.sticky.items[0].editor_index);

    const group2 = try makeGroup(allocator, .{});
    defer group2.deinit();

    const input1_group2 = try newInput(allocator, .serializable, "g2-1", null);
    const input2_group2 = try newInput(allocator, .serializable, "g2-2", null);
    const input3_group2 = try newInput(allocator, .serializable, "g2-3", null);

    _ = try group2.openEditor(input1_group2, .{ .pinned = true, .active = true, .index = 0, .sticky = true });
    _ = try group2.openEditor(input2_group2, .{ .pinned = true, .active = false, .index = 1 });
    _ = try group2.openEditor(input3_group2, .{ .pinned = true, .active = false, .index = 2 });

    var events2 = GroupEvents.init(allocator, group2);
    defer events2.deinit();
    try events2.listen();

    _ = try group2.moveEditor(input1_group2, 1);
    try std.testing.expectEqual(input1_group2, events2.unsticky.items[0].editor);
    try std.testing.expectEqual(@as(usize, 1), events2.unsticky.items[0].editor_index);
}

test "EditorGroupModel: editor selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    try std.testing.expectEqual(@as(?*EditorInput, null), group.activeEditor());
    try std.testing.expectEqual(@as(usize, 0), (try group.selectedEditors(allocator)).len);

    const input1 = try newInput(allocator, .serializable, "1", null);
    _ = try group.openEditor(input1, .{ .pinned = true, .active = true, .index = 0 });
    try assertSelection(group, allocator, input1, &.{input1});

    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true, .index = 1 });
    _ = try group.openEditor(input3, .{ .pinned = true, .active = true, .index = 2 });
    try assertSelection(group, allocator, input3, &.{input3});

    try group.setSelection(input2, &.{input1});
    try assertSelection(group, allocator, input2, &.{ input1, input2 });

    _ = try group.openEditor(input2, .{ .active = true, .inactive_selection = &.{ input3, input1 } });
    try assertSelection(group, allocator, input2, &.{ input1, input2, input3 });

    _ = try group.openEditor(input1, .{ .active = true, .inactive_selection = &.{ input3, input1, input3 } });
    try assertSelection(group, allocator, input1, &.{ input1, input3 });

    const input4 = try newInput(allocator, .serializable, "4", null);
    _ = try group.openEditor(input4, .{ .pinned = true, .active = false, .inactive_selection = &.{input2}, .index = 3 });
    try assertSelection(group, allocator, input1, &.{ input1, input2 });

    const input5 = try newInput(allocator, .serializable, "5", null);
    _ = try group.openEditor(input5, .{ .pinned = true, .active = true, .inactive_selection = &.{input4}, .index = 4 });
    try assertSelection(group, allocator, input5, &.{ input4, input5 });

    try group.setSelection(input2, &.{ input3, input1 });
    _ = try group.closeEditor(input3, .UNKNOWN, true);
    try assertSelection(group, allocator, input2, &.{ input1, input2 });
}

test "EditorGroupModel: setSelection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);
    _ = try group.openEditor(input1, .{ .pinned = true, .active = true, .index = 0 });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true, .index = 1 });
    _ = try group.openEditor(input3, .{ .pinned = true, .active = true, .index = 2 });

    try group.setSelection(input2, &.{ input3, input1 });
    try assertSelection(group, allocator, input2, &.{ input1, input2, input3 });

    try group.setSelection(input3, &.{});
    try assertSelection(group, allocator, input3, &.{input3});
    try group.setSelection(input2, &.{ input1, input2, input1 });
    try assertSelection(group, allocator, input2, &.{ input1, input2 });

    try std.testing.expect(group.isSelected(.{ .editor = input1 }));
    try std.testing.expect(group.isSelected(.{ .editor = input2 }));
    try std.testing.expect(!group.isSelected(.{ .editor = input3 }));
    try std.testing.expect(group.isSelected(.{ .index = 0 }));
    try std.testing.expect(!group.isSelected(.{ .index = 2 }));
}

test "EditorGroupModel: select invalid editor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    _ = try group.openEditor(input1, .{ .pinned = true, .active = true, .index = 0 });

    try group.setSelection(input2, &.{input1});
    try std.testing.expectEqual(input1, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 1), (try group.selectedEditors(allocator)).len);
    try std.testing.expect(group.isSelected(.{ .editor = input1 }));
    try std.testing.expect(!group.isSelected(.{ .editor = input2 }));

    try group.setSelection(input1, &.{input2});
    try std.testing.expectEqual(input1, group.activeEditor().?);
    try std.testing.expectEqual(@as(usize, 1), (try group.selectedEditors(allocator)).len);
    try std.testing.expect(group.isSelected(.{ .editor = input1 }));
    try std.testing.expect(!group.isSelected(.{ .editor = input2 }));
}

test "EditorGroupModel: transient basics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });

    try std.testing.expect(!group.isTransient(.{ .editor = input1 }));
    try std.testing.expectEqual(@as(usize, 0), events.transient.items.len);

    _ = try group.openEditor(input2, .{ .pinned = true, .active = true, .transient = true });
    try std.testing.expectEqual(input2, events.transient.items[0].editor);
    try std.testing.expect(group.isTransient(.{ .editor = input2 }));

    _ = try group.setTransient(input1, true);
    try std.testing.expect(group.isTransient(.{ .editor = input1 }));
    try std.testing.expectEqual(input1, events.transient.items[1].editor);

    _ = try group.setTransient(input2, false);
    try std.testing.expect(!group.isTransient(.{ .editor = input2 }));
    try std.testing.expectEqual(input2, events.transient.items[2].editor);
}

const editor_factory = @import("../../../../common/editor/editorFactory.zig");
const TestSerializer = struct {
    allocator: Allocator,
    disable_serialize: bool = false,
    disable_deserialize: bool = false,

    fn interface(self: *TestSerializer) editor_factory.IEditorSerializer {
        return .{
            .context = self,
            .canSerialize = canSerialize,
            .serialize = serialize,
            .deserialize = deserialize,
        };
    }

    fn canSerialize(_: *anyopaque, input: *EditorInput) bool {
        return toTest(input).kind == .serializable;
    }

    fn serialize(context: *anyopaque, input: *EditorInput, allocator: Allocator) anyerror!?[]const u8 {
        const self: *TestSerializer = @ptrCast(@alignCast(context));
        if (self.disable_serialize) return null;
        return try allocator.dupe(u8, toTest(input).id);
    }

    fn deserialize(context: *anyopaque, data: []const u8) anyerror!?*EditorInput {
        const self: *TestSerializer = @ptrCast(@alignCast(context));
        if (self.disable_deserialize) return null;
        const id = try self.allocator.dupe(u8, data);
        return try newInput(self.allocator, .serializable, id, null);
    }
};

fn testRegistry(allocator: Allocator, serializer: *TestSerializer) !editor_factory.EditorFactoryRegistry {
    var registry = editor_factory.EditorFactoryRegistry.init(allocator);
    errdefer registry.deinit();
    try registry.registerEditorSerializer("testEditorInputForGroups", serializer.interface());
    return registry;
}

test "EditorGroupModel: group serialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = TestSerializer{ .allocator = allocator };
    var registry = try testRegistry(allocator, &serializer);
    defer registry.deinit();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = false, .active = true });

    {
        var data = try group.serialize(allocator, &registry);
        defer data.deinit(allocator);

        var deserialized = try EditorGroupModel.initFromSerialized(allocator, .{}, data, &registry);
        defer deserialized.deinit();

        try std.testing.expectEqual(group.id, deserialized.id);
        try std.testing.expectEqual(@as(usize, 3), deserialized.count());
        try std.testing.expect(deserialized.isPinned(.{ .editor = input1 }));
        try std.testing.expect(deserialized.isPinned(.{ .editor = input2 }));
        try std.testing.expect(!deserialized.isPinned(.{ .editor = input3 }));
        try std.testing.expect(deserialized.isActive(.{ .input = input3 }));
    }

    // Case 2: inputs cannot be serialized.
    serializer.disable_serialize = true;
    {
        var data = try group.serialize(allocator, &registry);
        defer data.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), data.editors.len);

        var deserialized = try EditorGroupModel.initFromSerialized(allocator, .{}, data, &registry);
        defer deserialized.deinit();
        try std.testing.expectEqual(group.id, deserialized.id);
        try std.testing.expectEqual(@as(usize, 0), deserialized.count());
    }

    // Case 3: inputs cannot be deserialized.
    serializer.disable_serialize = false;
    serializer.disable_deserialize = true;
    {
        var data = try group.serialize(allocator, &registry);
        defer data.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 3), data.editors.len);

        var deserialized = try EditorGroupModel.initFromSerialized(allocator, .{}, data, &registry);
        defer deserialized.deinit();
        try std.testing.expectEqual(group.id, deserialized.id);
        try std.testing.expectEqual(@as(usize, 0), deserialized.count());
    }
}

test "EditorGroupModel: group serialization (sticky editor)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = TestSerializer{ .allocator = allocator };
    var registry = try testRegistry(allocator, &serializer);
    defer registry.deinit();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const input1 = try newInput(allocator, .serializable, "1", null);
    const input2 = try newInput(allocator, .serializable, "2", null);
    const input3 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(input1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input2, .{ .pinned = true, .active = true });
    _ = try group.openEditor(input3, .{ .pinned = false, .active = true });
    _ = try group.stick(input2);

    var data = try group.serialize(allocator, &registry);
    defer data.deinit(allocator);

    var deserialized = try EditorGroupModel.initFromSerialized(allocator, .{}, data, &registry);
    defer deserialized.deinit();

    try std.testing.expectEqual(group.id, deserialized.id);
    try std.testing.expectEqual(@as(usize, 3), deserialized.count());
    try std.testing.expect(deserialized.isPinned(.{ .editor = input1 }));
    try std.testing.expect(!deserialized.isActive(.{ .input = input1 }));
    try std.testing.expect(!deserialized.isSticky(.{ .editor = input1 }));
    try std.testing.expect(deserialized.isPinned(.{ .editor = input2 }));
    try std.testing.expect(deserialized.isSticky(.{ .editor = input2 }));
    try std.testing.expect(!deserialized.isPinned(.{ .editor = input3 }));
    try std.testing.expect(deserialized.isActive(.{ .input = input3 }));
    try std.testing.expect(!deserialized.isSticky(.{ .editor = input3 }));
}

test "EditorGroupModel: group serialization (locked group)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = TestSerializer{ .allocator = allocator };
    var registry = try testRegistry(allocator, &serializer);
    defer registry.deinit();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    try group.lock(true);

    var data = try group.serialize(allocator, &registry);
    defer data.deinit(allocator);
    var deserialized = try EditorGroupModel.initFromSerialized(allocator, .{}, data, &registry);
    defer deserialized.deinit();
    try std.testing.expectEqual(group.id, deserialized.id);
    try std.testing.expect(deserialized.isLocked());
}

test "EditorGroupModel: serialization skips non-serializable editors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = TestSerializer{ .allocator = allocator };
    var registry = try testRegistry(allocator, &serializer);
    defer registry.deinit();

    const group = try makeGroup(allocator, .{});
    defer group.deinit();

    const serializable1 = try newInput(allocator, .serializable, "1", null);
    const non_serializable = try newInput(allocator, .non_serializable, "2", null);
    const serializable2 = try newInput(allocator, .serializable, "3", null);

    _ = try group.openEditor(serializable1, .{ .pinned = true, .active = true });
    _ = try group.openEditor(non_serializable, .{ .pinned = false, .active = true });
    _ = try group.openEditor(serializable2, .{ .pinned = true, .active = false });

    var data = try group.serialize(allocator, &registry);
    defer data.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), data.editors.len);

    var deserialized = try EditorGroupModel.initFromSerialized(allocator, .{}, data, &registry);
    defer deserialized.deinit();
    try std.testing.expectEqual(@as(usize, 2), deserialized.count());
    try std.testing.expect(deserialized.isPinned(.{ .editor = serializable1 }));
    try std.testing.expect(deserialized.isPinned(.{ .editor = serializable2 }));
    try std.testing.expect(deserialized.isActive(.{ .input = serializable2 }));
}

test "EditorGroupModel: index events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();
    try std.testing.expectEqual(@as(usize, 0), events.index);
    try group.setIndex(4);
    try std.testing.expectEqual(@as(usize, 1), events.index);
}

test "EditorGroupModel: label events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();
    try std.testing.expectEqual(@as(usize, 0), events.label);
    try group.setLabel("Window 1");
    try std.testing.expectEqual(@as(usize, 1), events.label);
}

test "EditorGroupModel: active events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    var events = GroupEvents.init(allocator, group);
    defer events.deinit();
    try events.listen();
    try std.testing.expectEqual(@as(usize, 0), events.active);
    _ = try group.setActive(null);
    try std.testing.expectEqual(@as(usize, 1), events.active);
}

test "EditorGroupModel: locked group serialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const group = try makeGroup(allocator, .{});
    defer group.deinit();
    const group_id = group.id;
    try group.lock(true);

    var registry = @import("../../../../common/editor/editorFactory.zig").EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    var data = try group.serialize(allocator, &registry);
    defer data.deinit(allocator);
    const deserialized = try makeGroup(allocator, .{});
    defer deserialized.deinit();
    try deserialized.deserialize(data, &registry);
    try std.testing.expectEqual(group_id, deserialized.id);
    try std.testing.expectEqual(@as(usize, 0), deserialized.count());
    try std.testing.expect(deserialized.isLocked());
}
