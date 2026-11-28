// Port of `src/vs/workbench/contrib/extensions/common/extensionsInput.ts`.
// The input owns its identifier and label: scanned inventory records are replaced
// on refresh. The terminal resource is a serialized extension URI.
const std = @import("std");
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const capabilities = @import("../../../common/editor.zig").EditorInputCapabilities;
const IExtension = @import("extensions.zig").IExtension;

pub const ExtensionsInput = struct {
    allocator: std.mem.Allocator,
    base: EditorInput,
    identifier: []u8,
    resource: []u8,
    label: []u8,
    arena: std.heap.ArenaAllocator,
    snapshot: IExtension,

    pub const ID = "workbench.extensions.input2";
    pub const editor_id = "workbench.editor.extension";

    pub fn init(allocator: std.mem.Allocator, extension: *const IExtension) !*ExtensionsInput {
        const self = try allocator.create(ExtensionsInput);
        errdefer allocator.destroy(self);
        const identifier = try std.ascii.allocLowerString(allocator, extension.identifier);
        errdefer allocator.free(identifier);
        const resource = try std.fmt.allocPrint(allocator, "extension:/{s}/extension", .{identifier});
        errdefer allocator.free(resource);
        const label = try std.fmt.allocPrint(allocator, "Extension: {s}", .{extension.display_name});
        errdefer allocator.free(label);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const snapshot = try extension.clone(arena.allocator());
        self.* = .{ .allocator = allocator, .base = EditorInput.init(allocator, ID), .identifier = identifier, .resource = resource, .label = label, .arena = arena, .snapshot = snapshot };
        self.base.impl = self;
        self.base.editor_id = editor_id;
        self.base.resource = resource;
        self.base.name = label;
        self.base.capabilities = capabilities.Readonly | capabilities.Singleton;
        self.base.matches_fn = matches;
        return self;
    }

    pub fn interface(self: *ExtensionsInput) *EditorInput {
        return &self.base;
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        if (base == other) return true;
        if (!std.mem.eql(u8, other.type_id, ID)) return false;
        const left: *ExtensionsInput = @ptrCast(@alignCast(base.impl.?));
        const right: *ExtensionsInput = @ptrCast(@alignCast(other.impl.?));
        return std.ascii.eqlIgnoreCase(left.identifier, right.identifier);
    }

    pub fn deinit(self: *ExtensionsInput) void {
        self.base.dispose();
        self.base.deinit();
        self.arena.deinit();
        self.allocator.free(self.label);
        self.allocator.free(self.resource);
        self.allocator.free(self.identifier);
        self.allocator.destroy(self);
    }
};
