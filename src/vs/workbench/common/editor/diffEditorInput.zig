// Port of the identity/label subset of
// `src/vs/workbench/common/editor/diffEditorInput.ts`. Diff models, saving and
// serialization are handled by the terminal editor services later.
const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_input = @import("editorInput.zig");
const editor = @import("../editor.zig");
const factory_mod = @import("editorFactory.zig");
const EditorInput = editor_input.EditorInput;

pub const ID = "workbench.editors.diffEditorInput";

pub const DiffEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    original: *EditorInput,
    modified: *EditorInput,
    force_description: bool,
    owned_name: ?[]u8 = null,

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
        base.matches_fn = matches;
        base.matches_untyped_fn = matchesUntyped;
        base.capabilities = modified.capabilities | editor.EditorInputCapabilities.MultipleEditors;
        base.description = preferred_description;
        self.* = .{
            .allocator = allocator,
            .base = base,
            .original = original,
            .modified = modified,
            .force_description = std.mem.eql(u8, original_name, modified_name),
        };
        if (self.force_description) self.base.capabilities |= editor.EditorInputCapabilities.ForceDescription;
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
        return self;
    }

    pub fn destroy(self: *DiffEditorInput) void {
        if (self.owned_name) |name| self.allocator.free(name);
        self.base.deinit();
        self.allocator.destroy(self);
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
        };
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
        const modified = (try modified_serializer.deserialize(modified_serializer.context, modified_data)) orelse return null;
        const diff = try DiffEditorInput.init(self.allocator, null, null, original, modified);
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
