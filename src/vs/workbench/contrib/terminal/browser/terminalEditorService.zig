// Port of terminalEditorService.ts instance registration and detachment.
// Editor groups supply placement. The local PTY remains alive across moves.

const std = @import("std");
const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const EditorViewFactory = @import("../../../browser/parts/editor/editorPane.zig").EditorViewFactory;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
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

    /// The terminal resource is represented by TerminalEditorInput. The
    /// caller chooses the editor group (equivalent to the upstream viewColumn).
    pub fn openEditor(self: *TerminalEditorService, allocator: std.mem.Allocator, io: std.Io, factory: EditorViewFactory, pane: *GroupView, instance: *TerminalInstance) !*Tab {
        const tab = try Tab.initTerminal(factory, allocator, io, instance);
        errdefer tab.deinit();
        try pane.tabs.ensureUnusedCapacity(1);
        try self.instances.ensureUnusedCapacity(1);
        _ = try pane.group.model.openEditor(tab.input, .{ .pinned = true, .active = true });
        try pane.addTab(tab);
        tab.terminal_input.?.registerInstance(self);
        pane.group.service.activateGroup(pane.group);
        return tab;
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
