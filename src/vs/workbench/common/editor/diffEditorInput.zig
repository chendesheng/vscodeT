// Port of the identity/label subset of
// `src/vs/workbench/common/editor/diffEditorInput.ts`. Diff models, saving and
// serialization are handled by the terminal editor services later.
const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_input = @import("editorInput.zig");
const editor = @import("../editor.zig");
const factory_mod = @import("editorFactory.zig");
const EditorInput = editor_input.EditorInput;
const SignalSubscription = @import("../../../base/common/event.zig").SignalSubscription;

pub const ID = "workbench.editors.diffEditorInput";

pub const DiffEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    original: *EditorInput,
    modified: *EditorInput,
    force_description: bool,
    owned_name: ?[]u8 = null,
    owned_description: ?[]u8 = null,
    subscriptions: [7]?SignalSubscription = @splat(null),

    pub fn init(
        allocator: Allocator,
        preferred_name: ?[]const u8,
        preferred_description: ?[]const u8,
        original: *EditorInput,
        modified: *EditorInput,
    ) !*DiffEditorInput {
        const self = try allocator.create(DiffEditorInput);
        errdefer allocator.destroy(self);
        const original_name = original.getName();
        const modified_name = modified.getName();
        var base = EditorInput.init(allocator, ID);
        base.impl = self;
        base.editor_id = commonEditorId(original, modified);
        base.matches_fn = matches;
        base.matches_untyped_fn = matchesUntyped;
        base.is_dirty_fn = isDirty;
        base.save_fn = saveHook;
        base.request_save_fn = requestSaveHook;
        base.revert_fn = revertHook;
        base.capabilities = modified.capabilities | editor.EditorInputCapabilities.MultipleEditors;
        self.* = .{
            .allocator = allocator,
            .base = base,
            .original = original,
            .modified = modified,
            .force_description = std.mem.eql(u8, original_name, modified_name),
        };
        errdefer self.base.deinit();
        errdefer if (self.owned_name) |name| allocator.free(name);
        errdefer if (self.owned_description) |description| allocator.free(description);
        if (self.force_description) self.base.capabilities |= editor.EditorInputCapabilities.ForceDescription;
        if (preferred_description) |description| {
            self.owned_description = try allocator.dupe(u8, description);
            self.base.description = self.owned_description.?;
        }
        if (preferred_name) |name| {
            self.owned_name = try allocator.dupe(u8, name);
            self.base.name = self.owned_name.?;
        } else {
            self.owned_name = try std.fmt.allocPrint(allocator, "{s} ↔ {s}", .{ original_name, modified_name });
            self.base.name = self.owned_name.?;
        }
        if (preferred_description == null and self.force_description) {
            self.base.description = modified.getDescription(.LONG);
        }
        try self.registerSideListeners();
        return self;
    }

    fn commonEditorId(original: *EditorInput, modified: *EditorInput) ?[]const u8 {
        const original_id = original.editor_id orelse return null;
        const modified_id = modified.editor_id orelse return null;
        return if (std.mem.eql(u8, original_id, modified_id)) modified_id else null;
    }

    fn registerSideListeners(self: *DiffEditorInput) !void {
        errdefer self.detachSideListeners();
        self.subscriptions[0] = try self.modified.on_did_change_dirty.listenDisposable(self, onSideDirty);
        self.subscriptions[1] = try self.original.on_did_change_capabilities.listenDisposable(self, onSideCapabilities);
        self.subscriptions[2] = try self.modified.on_did_change_capabilities.listenDisposable(self, onSideCapabilities);
        self.subscriptions[3] = try self.original.on_did_change_label.listenDisposable(self, onSideLabel);
        self.subscriptions[4] = try self.modified.on_did_change_label.listenDisposable(self, onSideLabel);
        self.subscriptions[5] = try self.original.on_will_dispose.listenDisposable(self, onSideDisposed);
        self.subscriptions[6] = try self.modified.on_will_dispose.listenDisposable(self, onSideDisposed);
    }

    fn detachSideListeners(self: *DiffEditorInput) void {
        for (&self.subscriptions) |*subscription| {
            if (subscription.*) |value| value.dispose();
            subscription.* = null;
        }
    }

    fn onSideDirty(_: void, self: *DiffEditorInput) anyerror!void {
        try self.base.fireDirty();
    }

    fn onSideCapabilities(_: void, self: *DiffEditorInput) anyerror!void {
        try self.base.setCapabilities(self.modified.capabilities | editor.EditorInputCapabilities.MultipleEditors |
            (if (self.force_description) editor.EditorInputCapabilities.ForceDescription else @as(u32, 0)));
    }

    fn onSideLabel(_: void, self: *DiffEditorInput) anyerror!void {
        try self.base.fireLabel();
    }

    fn onSideDisposed(_: void, self: *DiffEditorInput) anyerror!void {
        self.detachSideListeners();
        self.base.dispose();
    }

    // The terminal swaps in-place rather than replacing the composite input.
    // Rebind the primary side's dirty event and capabilities with the models.
    pub fn setSides(self: *DiffEditorInput, original: *EditorInput, modified: *EditorInput) !void {
        const previous_dirty = self.base.isDirty();
        self.detachSideListeners();
        self.original = original;
        self.modified = modified;
        self.base.editor_id = commonEditorId(original, modified);
        try self.registerSideListeners();
        try onSideCapabilities({}, self);
        if (previous_dirty != self.base.isDirty()) try self.base.fireDirty();
    }

    pub fn destroy(self: *DiffEditorInput) void {
        self.detachSideListeners();
        if (self.owned_name) |name| self.allocator.free(name);
        if (self.owned_description) |description| self.allocator.free(description);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    fn isDirty(base: *const EditorInput) bool {
        const self: *const DiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        return self.modified.isDirty();
    }

    fn requestSaveHook(base: *EditorInput, group: editor.GroupIdentifier, completion: ?editor_input.SaveCompletion) !void {
        const self: *DiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        return self.modified.requestSave(group, completion);
    }

    fn saveHook(base: *EditorInput, group: editor.GroupIdentifier) anyerror!editor_input.SaveResult {
        const self: *DiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        return self.modified.save(group);
    }

    fn revertHook(base: *EditorInput, group: editor.GroupIdentifier) anyerror!void {
        const self: *DiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        return self.modified.revert(group);
    }

    fn matchesUntyped(base: *const EditorInput, other: editor.UntypedEditorInput) bool {
        const self: *const DiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        const other_primary = other.primary orelse return false;
        const other_secondary = other.secondary orelse return false;
        return self.modified.matches(.{ .untyped = other_primary.* }) and
            self.original.matches(.{ .untyped = other_secondary.* });
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        const self: *DiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        const other_diff = is(other) orelse return false;
        return self.modified.matches(.{ .input = other_diff.modified }) and
            self.original.matches(.{ .input = other_diff.original }) and
            self.force_description == other_diff.force_description;
    }
};

pub fn is(input: *EditorInput) ?*DiffEditorInput {
    if (!std.mem.eql(u8, input.type_id, ID) or input.impl == null) return null;
    return @ptrCast(@alignCast(input.impl.?));
}

pub const DiffEditorSerializer = struct {
    allocator: Allocator,
    registry: *factory_mod.EditorFactoryRegistry,

    pub fn init(allocator: Allocator, registry: *factory_mod.EditorFactoryRegistry) DiffEditorSerializer {
        return .{ .allocator = allocator, .registry = registry };
    }

    pub fn interface(self: *DiffEditorSerializer) factory_mod.IEditorSerializer {
        return .{
            .context = self,
            .canSerialize = canSerialize,
            .serialize = serialize,
            .deserialize = deserialize,
            .discard_deserialized = discardDeserialized,
        };
    }

    fn discardDeserialized(context: *anyopaque, input: *EditorInput) void {
        const self: *DiffEditorSerializer = @ptrCast(@alignCast(context));
        const diff = is(input) orelse return;
        const original = diff.original;
        const modified = diff.modified;
        diff.destroy();
        if (self.registry.getEditorSerializer(original)) |serializer| serializer.discardDeserialized(original);
        if (self.registry.getEditorSerializer(modified)) |serializer| serializer.discardDeserialized(modified);
    }

    fn canSerialize(context: *anyopaque, input: *EditorInput) bool {
        const self: *DiffEditorSerializer = @ptrCast(@alignCast(context));
        const diff = is(input) orelse return false;
        const original_serializer = self.registry.getEditorSerializer(diff.original) orelse return false;
        const modified_serializer = self.registry.getEditorSerializer(diff.modified) orelse return false;
        return original_serializer.canSerialize(original_serializer.context, diff.original) and
            modified_serializer.canSerialize(modified_serializer.context, diff.modified);
    }

    fn serialize(context: *anyopaque, input: *EditorInput, allocator: Allocator) anyerror!?[]const u8 {
        const self: *DiffEditorSerializer = @ptrCast(@alignCast(context));
        const diff = is(input) orelse return null;
        const original_serializer = self.registry.getEditorSerializer(diff.original) orelse return null;
        const modified_serializer = self.registry.getEditorSerializer(diff.modified) orelse return null;
        const original_data = (try original_serializer.serialize(original_serializer.context, diff.original, allocator)) orelse return null;
        defer allocator.free(original_data);
        const modified_data = (try modified_serializer.serialize(modified_serializer.context, diff.modified, allocator)) orelse return null;
        defer allocator.free(modified_data);

        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        var root = std.json.ObjectMap{};
        const arena = scratch.allocator();
        try root.put(arena, "originalSerialized", .{ .string = original_data });
        try root.put(arena, "modifiedSerialized", .{ .string = modified_data });
        try root.put(arena, "originalTypeId", .{ .string = diff.original.type_id });
        try root.put(arena, "modifiedTypeId", .{ .string = diff.modified.type_id });
        if (diff.owned_name) |name| try root.put(arena, "name", .{ .string = name });
        if (diff.base.description) |description| try root.put(arena, "description", .{ .string = description });
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    fn deserialize(context: *anyopaque, data: []const u8) anyerror!?*EditorInput {
        const self: *DiffEditorSerializer = @ptrCast(@alignCast(context));
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return null;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return null,
        };
        const original_type = stringField(object, "originalTypeId") orelse return null;
        const modified_type = stringField(object, "modifiedTypeId") orelse return null;
        const original_data = stringField(object, "originalSerialized") orelse return null;
        const modified_data = stringField(object, "modifiedSerialized") orelse return null;
        const original_serializer = self.registry.getEditorSerializerByType(original_type) orelse return null;
        const modified_serializer = self.registry.getEditorSerializerByType(modified_type) orelse return null;
        const original = (try original_serializer.deserialize(original_serializer.context, original_data)) orelse return null;
        var adopted = false;
        defer if (!adopted) original_serializer.discardDeserialized(original);
        const modified = (try modified_serializer.deserialize(modified_serializer.context, modified_data)) orelse return null;
        defer if (!adopted) modified_serializer.discardDeserialized(modified);
        const diff = try DiffEditorInput.init(self.allocator, stringField(object, "name"), stringField(object, "description"), original, modified);
        adopted = true;
        return &diff.base;
    }
};

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

test "DiffEditorInput: forwards primary dirty state and rebinds when swapped" {
    const testing = std.testing;
    var original = EditorInput.init(testing.allocator, "original");
    defer original.deinit();
    var modified = EditorInput.init(testing.allocator, "modified");
    defer modified.deinit();
    const input = try DiffEditorInput.init(testing.allocator, "Comparison", null, &original, &modified);
    defer input.destroy();
    const Counter = struct {
        count: usize = 0,
        fn changed(_: void, self: *@This()) !void {
            self.count += 1;
        }
    };
    var counter: Counter = .{};
    _ = try input.base.on_did_change_dirty.listen(&counter, Counter.changed);
    try original.setDirty(true);
    try testing.expect(!input.base.isDirty());
    try testing.expectEqual(@as(usize, 0), counter.count);
    try modified.setDirty(true);
    try testing.expect(input.base.isDirty());
    try testing.expectEqual(@as(usize, 1), counter.count);
    try input.setSides(&modified, &original);
    try modified.setDirty(false);
    try testing.expect(input.base.isDirty());
    try testing.expectEqual(@as(usize, 1), counter.count);
    try original.setDirty(false);
    try testing.expect(!input.base.isDirty());
    try testing.expectEqual(@as(usize, 2), counter.count);
    original.dispose();
    try testing.expect(input.base.disposed);
    try testing.expectEqual(@as(usize, 0), modified.on_did_change_capabilities.listenerCount());
}
