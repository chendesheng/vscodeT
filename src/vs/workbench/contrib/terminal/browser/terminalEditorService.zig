// Port of terminalEditorService.ts instance registration and detachment.
// Editor groups supply placement. The local PTY remains alive across moves.

const std = @import("std");
const TerminalInstance = @import("./terminalInstance.zig").TerminalInstance;

pub const TerminalEditorService = struct {
    instances: std.array_list.Managed(*TerminalInstance),

    pub fn init(allocator: std.mem.Allocator) TerminalEditorService {
        return .{ .instances = .init(allocator) };
    }

    pub fn deinit(self: *TerminalEditorService) void {
        for (self.instances.items) |instance| instance.deinit();
        self.instances.deinit();
    }

    pub fn detachInstance(self: *TerminalEditorService, instance: *TerminalInstance) void {
        for (self.instances.items, 0..) |candidate, index| {
            if (candidate != instance) continue;
            _ = self.instances.orderedRemove(index);
            return;
        }
    }

    pub fn disposeInstance(self: *TerminalEditorService, instance: *TerminalInstance) void {
        self.detachInstance(instance);
        instance.deinit();
    }
};
