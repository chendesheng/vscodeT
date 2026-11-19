// Port of the tab-list subset of
// `src/vs/workbench/contrib/terminal/browser/terminalGroup.ts`.
//
// Upstream groups also own a SplitView of panes. Phase 1 has one pane per
// group, so this model keeps the ordered instances and the active index; the
// split-view/DOM code is deliberately not represented.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TerminalInstance = @import("./terminalInstance.zig").TerminalInstance;

pub const TerminalGroup = struct {
    allocator: Allocator,
    instances: std.array_list.Managed(*TerminalInstance),
    active: usize = 0,

    pub fn init(allocator: Allocator) TerminalGroup {
        return .{
            .allocator = allocator,
            .instances = std.array_list.Managed(*TerminalInstance).init(allocator),
        };
    }

    pub fn deinit(self: *TerminalGroup) void {
        for (self.instances.items) |instance| instance.deinit();
        self.instances.deinit();
    }

    pub fn add(self: *TerminalGroup, instance: *TerminalInstance) !void {
        try self.instances.append(instance);
        self.active = self.instances.items.len - 1;
    }

    pub fn remove(self: *TerminalGroup, index: usize) void {
        if (index >= self.instances.items.len) return;
        const instance = self.instances.orderedRemove(index);
        instance.deinit();
        if (self.instances.items.len == 0) {
            self.active = 0;
        } else if (self.active >= self.instances.items.len) {
            self.active = self.instances.items.len - 1;
        } else if (index < self.active) {
            self.active -= 1;
        }
    }

    pub fn count(self: *const TerminalGroup) usize {
        return self.instances.items.len;
    }

    pub fn at(self: *const TerminalGroup, index: usize) ?*TerminalInstance {
        if (index >= self.instances.items.len) return null;
        return self.instances.items[index];
    }

    pub fn activeInstance(self: *const TerminalGroup) ?*TerminalInstance {
        return self.at(self.active);
    }

    pub fn setActive(self: *TerminalGroup, index: usize) bool {
        if (index >= self.instances.items.len) return false;
        self.active = index;
        return true;
    }

    pub fn next(self: *TerminalGroup) void {
        if (self.instances.items.len == 0) return;
        self.active = (self.active + 1) % self.instances.items.len;
    }

    pub fn previous(self: *TerminalGroup) void {
        if (self.instances.items.len == 0) return;
        self.active = if (self.active == 0)
            self.instances.items.len - 1
        else
            self.active - 1;
    }

    /// Keeps the active index in range after the last terminal exits.
    pub fn pruneDead(self: *TerminalGroup) void {
        var index: usize = 0;
        while (index < self.instances.items.len) {
            const instance = self.instances.items[index];
            if (instance.exit != null) {
                self.remove(index);
                continue;
            }
            index += 1;
        }
    }
};
