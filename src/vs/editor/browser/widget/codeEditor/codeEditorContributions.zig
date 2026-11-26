// Port of `src/vs/editor/browser/widget/codeEditor/codeEditorContributions.ts`.
// Native contribution instances use typed factories at the composition boundary.
// Borrowed registrations permit migration of existing view-bound adapters; owned
// instances are disposed by the CodeEditorWidget, independently of its model.
const std = @import("std");
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

pub const CodeEditorContributions = struct {
    instances: std.StringHashMapUnmanaged(Instance) = .empty,

    const Instance = struct {
        value: *anyopaque,
        lifetime: IDisposable = .none,
    };

    pub fn register(self: *CodeEditorContributions, allocator: std.mem.Allocator, comptime T: type, value: *T, lifetime: IDisposable) !void {
        if (self.instances.contains(T.ID)) return error.DuplicateEditorContribution;
        try self.instances.put(allocator, T.ID, .{ .value = value, .lifetime = lifetime });
    }

    pub fn get(self: *const CodeEditorContributions, comptime T: type) ?*T {
        const instance = self.instances.get(T.ID) orelse return null;
        return @ptrCast(@alignCast(instance.value));
    }

    /// Existing native adapters remove borrowed registrations before releasing
    /// their models. Owned instances remain until the widget is disposed.
    pub fn unregister(self: *CodeEditorContributions, comptime T: type, value: *T) void {
        const instance = self.instances.get(T.ID) orelse return;
        if (instance.value == @as(*anyopaque, @ptrCast(value)) and instance.lifetime.isNone()) _ = self.instances.remove(T.ID);
    }

    pub fn deinit(self: *CodeEditorContributions, allocator: std.mem.Allocator) void {
        // Remove first: disposal can synchronously access the editor registry.
        while (self.instances.count() != 0) {
            var iterator = self.instances.iterator();
            const entry = iterator.next().?;
            const instance = self.instances.fetchRemove(entry.key_ptr.*).?.value;
            instance.lifetime.dispose();
        }
        self.instances.deinit(allocator);
    }
};
