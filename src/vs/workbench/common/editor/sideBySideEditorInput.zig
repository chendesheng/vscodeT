// Port of the composite identity/label subset of
// `src/vs/workbench/common/editor/sideBySideEditorInput.ts`. Rendering,
// save/revert forwarding and serialization are handled by the terminal editor
// services and are not part of this identity model.
const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_input = @import("editorInput.zig");
const editor = @import("../editor.zig");
const factory_mod = @import("editorFactory.zig");
const IEditorSerializer = factory_mod.IEditorSerializer;
const EditorInput = editor_input.EditorInput;

pub const ID = "workbench.editorinputs.sidebysideEditorInput";

pub const SideBySideEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    primary: *EditorInput,
    secondary: *EditorInput,
    has_identical_sides: bool,
    owned_name: ?[]u8 = null,
    owned_description: ?[]u8 = null,

    pub fn init(
        allocator: Allocator,
        preferred_name: ?[]const u8,
        preferred_description: ?[]const u8,
        secondary: *EditorInput,
        primary: *EditorInput,
    ) !*SideBySideEditorInput {
        const self = try allocator.create(SideBySideEditorInput);
        errdefer allocator.destroy(self);
        var base = EditorInput.init(allocator, ID);
        base.impl = self;
        base.matches_fn = matches;
        base.matches_untyped_fn = matchesUntyped;
        base.capabilities = primary.capabilities | editor.EditorInputCapabilities.MultipleEditors;
        self.* = .{
            .allocator = allocator,
            .base = base,
            .primary = primary,
            .secondary = secondary,
            .has_identical_sides = primary.matches(.{ .input = secondary }),
        };
        self.base.resource = if (self.has_identical_sides) primary.resource else null;
        if (preferred_name) |name| {
            self.owned_name = try allocator.dupe(u8, name);
            self.base.name = self.owned_name.?;
        } else if (self.has_identical_sides) {
            self.base.name = primary.getName();
        } else {
            self.owned_name = try std.fmt.allocPrint(allocator, "{s} - {s}", .{ secondary.getName(), primary.getName() });
            self.base.name = self.owned_name.?;
        }
        if (preferred_description) |description| {
            self.owned_description = try allocator.dupe(u8, description);
            self.base.description = self.owned_description.?;
        } else if (self.has_identical_sides) {
            self.base.description = primary.getDescription(.LONG);
        }
        return self;
    }

    pub fn destroy(self: *SideBySideEditorInput) void {
        if (self.owned_name) |name| self.allocator.free(name);
        if (self.owned_description) |description| self.allocator.free(description);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn getPreferredName(self: *const SideBySideEditorInput) ?[]const u8 {
        if (self.owned_name) |name| return name;
        return null;
    }

    pub fn getPreferredDescription(self: *const SideBySideEditorInput) ?[]const u8 {
        return self.owned_description;
    }

    fn matchesUntyped(base: *const EditorInput, other: editor.UntypedEditorInput) bool {
        const self: *const SideBySideEditorInput = @ptrCast(@alignCast(base.impl.?));
        const other_primary = other.primary orelse return false;
        const other_secondary = other.secondary orelse return false;
        return self.primary.matches(.{ .untyped = other_primary.* }) and
            self.secondary.matches(.{ .untyped = other_secondary.* });
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        const self: *SideBySideEditorInput = @ptrCast(@alignCast(base.impl.?));
        const other_side_by_side = is(other) orelse return false;
        return self.primary.matches(.{ .input = other_side_by_side.primary }) and
            self.secondary.matches(.{ .input = other_side_by_side.secondary });
    }
};

pub fn is(input: *EditorInput) ?*SideBySideEditorInput {
    if (!std.mem.eql(u8, input.type_id, ID) or input.impl == null) return null;
    return @ptrCast(@alignCast(input.impl.?));
}

pub const SideBySideEditorSerializer = struct {
    allocator: Allocator,
    registry: *factory_mod.EditorFactoryRegistry,

    pub fn init(allocator: Allocator, registry: *factory_mod.EditorFactoryRegistry) SideBySideEditorSerializer {
        return .{ .allocator = allocator, .registry = registry };
    }

    pub fn interface(self: *SideBySideEditorSerializer) IEditorSerializer {
        return .{
            .context = self,
            .canSerialize = canSerialize,
            .serialize = serialize,
            .deserialize = deserialize,
        };
    }

    fn canSerialize(context: *anyopaque, input: *EditorInput) bool {
        const self: *SideBySideEditorSerializer = @ptrCast(@alignCast(context));
        const composite = is(input) orelse return false;
        const primary_serializer = self.registry.getEditorSerializer(composite.primary) orelse return false;
        const secondary_serializer = self.registry.getEditorSerializer(composite.secondary) orelse return false;
        return primary_serializer.canSerialize(primary_serializer.context, composite.primary) and
            secondary_serializer.canSerialize(secondary_serializer.context, composite.secondary);
    }

    fn serialize(context: *anyopaque, input: *EditorInput, allocator: Allocator) anyerror!?[]const u8 {
        const self: *SideBySideEditorSerializer = @ptrCast(@alignCast(context));
        const composite = is(input) orelse return null;
        const primary_serializer = self.registry.getEditorSerializer(composite.primary) orelse return null;
        const secondary_serializer = self.registry.getEditorSerializer(composite.secondary) orelse return null;
        const primary_data = (try primary_serializer.serialize(primary_serializer.context, composite.primary, allocator)) orelse return null;
        defer allocator.free(primary_data);
        const secondary_data = (try secondary_serializer.serialize(secondary_serializer.context, composite.secondary, allocator)) orelse return null;
        defer allocator.free(secondary_data);

        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        var root = std.json.ObjectMap{};
        const arena = scratch.allocator();
        try root.put(arena, "primarySerialized", .{ .string = primary_data });
        try root.put(arena, "secondarySerialized", .{ .string = secondary_data });
        try root.put(arena, "primaryTypeId", .{ .string = composite.primary.type_id });
        try root.put(arena, "secondaryTypeId", .{ .string = composite.secondary.type_id });
        if (composite.owned_name) |name| try root.put(arena, "name", .{ .string = name });
        if (composite.owned_description) |description| try root.put(arena, "description", .{ .string = description });
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    fn deserialize(context: *anyopaque, data: []const u8) anyerror!?*EditorInput {
        const self: *SideBySideEditorSerializer = @ptrCast(@alignCast(context));
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return null;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return null,
        };
        const primary_type = stringField(object, "primaryTypeId") orelse return null;
        const secondary_type = stringField(object, "secondaryTypeId") orelse return null;
        const primary_data = stringField(object, "primarySerialized") orelse return null;
        const secondary_data = stringField(object, "secondarySerialized") orelse return null;
        const primary_serializer = self.registry.getEditorSerializerByType(primary_type) orelse return null;
        const secondary_serializer = self.registry.getEditorSerializerByType(secondary_type) orelse return null;
        const primary = (try primary_serializer.deserialize(primary_serializer.context, primary_data)) orelse return null;
        const secondary = (try secondary_serializer.deserialize(secondary_serializer.context, secondary_data)) orelse return null;
        const composite = try SideBySideEditorInput.init(self.allocator, stringField(object, "name"), stringField(object, "description"), secondary, primary);
        return &composite.base;
    }
};

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}
