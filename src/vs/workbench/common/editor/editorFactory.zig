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
const ServicesAccessor = @import("../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const instantiation_mod = @import("../../../platform/instantiation/common/instantiationService.zig");

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
    /// Zig allocation ownership for a deserialized input that could not be
    /// adopted by its composite. Upstream GC needs no separate release hook.
    discard_deserialized: ?*const fn (*anyopaque, *EditorInput) void = null,

    pub fn discardDeserialized(self: IEditorSerializer, input: *EditorInput) void {
        if (self.discard_deserialized) |discard| discard(self.context, input) else input.dispose();
    }
};

/// Zig equivalent of IConstructorSignature<IEditorSerializer>. A native
/// serializer can also be supplied as an already-bound, borrowed instance.
pub const SerializerFactory = struct {
    context: *anyopaque,
    create: *const fn (*anyopaque, ServicesAccessor) anyerror!IEditorSerializer,

    pub fn bound(comptime Serializer: type, serializer: *Serializer) SerializerFactory {
        return .{ .context = serializer, .create = struct {
            fn create(context: *anyopaque, _: ServicesAccessor) !IEditorSerializer {
                const value: *Serializer = @ptrCast(@alignCast(context));
                return value.interface();
            }
        }.create };
    }
};

/// Mirrors upstream `EditorFactoryRegistry` for editor inputs and serializers.
/// File-editor factories and editor pane descriptors are not ported yet.
pub const EditorFactoryRegistry = struct {
    allocator: Allocator,
    serializers: std.StringHashMap(IEditorSerializer),
    constructors: std.array_list.Managed(Pending),
    instantiation_service: ?*instantiation_mod.InstantiationService = null,

    const Pending = struct { id: []const u8, factory: SerializerFactory };

    pub fn init(allocator: Allocator) EditorFactoryRegistry {
        return .{
            .allocator = allocator,
            .serializers = std.StringHashMap(IEditorSerializer).init(allocator),
            .constructors = std.array_list.Managed(Pending).init(allocator),
        };
    }

    pub fn deinit(self: *EditorFactoryRegistry) void {
        self.constructors.deinit();
        self.serializers.deinit();
    }

    pub fn start(self: *EditorFactoryRegistry, accessor: ServicesAccessor) !void {
        self.instantiation_service = try accessor.get(instantiation_mod.instantiation_service_id);
        while (self.constructors.items.len != 0) {
            const pending = self.constructors.items[0];
            try self.createEditorSerializer(pending.id, pending.factory, accessor);
            _ = self.constructors.orderedRemove(0);
        }
    }

    /// Unlike upstream's process-wide registry, the native registry can be
    /// borrowed by successive terminal windows. Never retain a dead accessor.
    pub fn stop(self: *EditorFactoryRegistry, instantiation: *instantiation_mod.InstantiationService) void {
        if (self.instantiation_service == instantiation) self.instantiation_service = null;
    }

    fn hasRegistration(self: *const EditorFactoryRegistry, id: []const u8) bool {
        if (self.serializers.contains(id)) return true;
        for (self.constructors.items) |entry| {
            if (std.mem.eql(u8, id, entry.id)) return true;
        }
        return false;
    }

    fn createEditorSerializer(self: *EditorFactoryRegistry, id: []const u8, factory: SerializerFactory, accessor: ServicesAccessor) !void {
        const serializer = try factory.create(factory.context, accessor);
        try self.serializers.put(id, serializer);
    }

    fn createWithAccessor(accessor: ServicesAccessor, self: *EditorFactoryRegistry, id: []const u8, factory: SerializerFactory) !void {
        try self.createEditorSerializer(id, factory, accessor);
    }

    pub fn registerEditorSerializerFactory(self: *EditorFactoryRegistry, id: []const u8, factory: SerializerFactory) !void {
        if (self.hasRegistration(id)) return error.AlreadyRegistered;
        if (self.instantiation_service) |instantiation| {
            try instantiation.invokeFunction(createWithAccessor, .{ self, id, factory });
        } else try self.constructors.append(.{ .id = id, .factory = factory });
    }

    /// Upstream rejects duplicate type ids; the terminal registry does the
    /// same instead of silently replacing a serializer.
    pub fn registerEditorSerializer(self: *EditorFactoryRegistry, type_id: []const u8, serializer: IEditorSerializer) !void {
        if (self.hasRegistration(type_id)) return error.AlreadyRegistered;
        try self.serializers.put(type_id, serializer);
    }

    pub fn getEditorSerializer(self: *EditorFactoryRegistry, input: *EditorInput) ?IEditorSerializer {
        return self.getEditorSerializerByType(input.type_id);
    }

    pub fn getEditorSerializerByType(self: *EditorFactoryRegistry, type_id: []const u8) ?IEditorSerializer {
        return self.serializers.get(type_id);
    }
};
