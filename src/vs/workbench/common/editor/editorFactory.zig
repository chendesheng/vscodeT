// Port of the editor factory registry portion of
// `src/vs/workbench/common/editor.ts`.
//
// Upstream the registry is a global `Registry` contribution whose serializers
// are constructed with the instantiation service. The terminal workbench owns
// the registry explicitly, and each serializer carries its own context (the
// TUI file serializer needs the allocator and editor size to recreate an
// `Editor`). This keeps the group model independent of global state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const EditorInput = @import("editorInput.zig").EditorInput;

/// Mirrors upstream `IEditorSerializer`.
pub const IEditorSerializer = struct {
    context: *anyopaque,

    /// Whether the input can be represented by this serializer.
    canSerialize: *const fn (context: *anyopaque, input: *EditorInput) bool,

    /// Returns the serialized form, or null when the input cannot currently be
    /// serialized (for example a working copy that is not ready). The returned
    /// string is owned by the caller.
    serialize: *const fn (context: *anyopaque, input: *EditorInput, allocator: Allocator) anyerror!?[]const u8,

    /// Recreates an input from a serialized form. Null means the input could
    /// not be restored.
    deserialize: *const fn (context: *anyopaque, data: []const u8) anyerror!?*EditorInput,
};

/// Mirrors upstream `EditorFactoryRegistry` for editor inputs and serializers.
/// File-editor factories and editor pane descriptors are not ported yet.
pub const EditorFactoryRegistry = struct {
    allocator: Allocator,
    serializers: std.StringHashMap(IEditorSerializer),

    pub fn init(allocator: Allocator) EditorFactoryRegistry {
        return .{
            .allocator = allocator,
            .serializers = std.StringHashMap(IEditorSerializer).init(allocator),
        };
    }

    pub fn deinit(self: *EditorFactoryRegistry) void {
        self.serializers.deinit();
    }

    /// Upstream rejects duplicate type ids; the terminal registry does the
    /// same instead of silently replacing a serializer.
    pub fn registerEditorSerializer(self: *EditorFactoryRegistry, type_id: []const u8, serializer: IEditorSerializer) !void {
        if (self.serializers.contains(type_id)) return error.AlreadyRegistered;
        try self.serializers.put(type_id, serializer);
    }

    pub fn getEditorSerializer(self: *EditorFactoryRegistry, input: *EditorInput) ?IEditorSerializer {
        return self.getEditorSerializerByType(input.type_id);
    }

    pub fn getEditorSerializerByType(self: *EditorFactoryRegistry, type_id: []const u8) ?IEditorSerializer {
        return self.serializers.get(type_id);
    }
};

test "EditorFactoryRegistry rejects duplicate serializers" {
    const allocator = std.testing.allocator;
    var registry = EditorFactoryRegistry.init(allocator);
    defer registry.deinit();

    const Serializer = struct {
        fn canSerialize(_: *anyopaque, _: *EditorInput) bool {
            return true;
        }
        fn serialize(_: *anyopaque, _: *EditorInput, _: Allocator) anyerror!?[]const u8 {
            return null;
        }
        fn deserialize(_: *anyopaque, _: []const u8) anyerror!?*EditorInput {
            return null;
        }
    };

    var context: u8 = 0;
    const serializer = IEditorSerializer{
        .context = &context,
        .canSerialize = Serializer.canSerialize,
        .serialize = Serializer.serialize,
        .deserialize = Serializer.deserialize,
    };

    try registry.registerEditorSerializer("test.input", serializer);
    try std.testing.expectError(error.AlreadyRegistered, registry.registerEditorSerializer("test.input", serializer));
    try std.testing.expect(registry.getEditorSerializerByType("test.input") != null);
}
