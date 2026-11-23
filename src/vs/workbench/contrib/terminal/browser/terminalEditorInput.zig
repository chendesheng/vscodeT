// Port of terminalEditorInput.ts's resource, label and instance lifetime.
// Local terminal sessions have no persistent process to serialize.

const std = @import("std");
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const TerminalInstance = @import("./terminalInstance.zig").TerminalInstance;
const TerminalEditorService = @import("./terminalEditorService.zig").TerminalEditorService;

pub const TerminalEditorInput = struct {
    pub const ID = "workbench.editors.terminal";

    base: EditorInput,
    allocator: std.mem.Allocator,
    resource: []u8,
    instance: *TerminalInstance,
    host: ?*TerminalEditorService = null,

    pub fn init(allocator: std.mem.Allocator, instance: *TerminalInstance) !*TerminalEditorInput {
        const self = try allocator.create(TerminalEditorInput);
        errdefer allocator.destroy(self);
        const resource = try std.fmt.allocPrint(allocator, "vscode-terminal:/{d}", .{instance.id});
        self.* = .{
            .base = EditorInput.init(allocator, ID),
            .allocator = allocator,
            .resource = resource,
            .instance = instance,
        };
        self.base.impl = self;
        self.base.editor_id = "terminalEditor";
        self.base.resource = resource;
        self.base.get_name_fn = getName;
        self.base.get_description_fn = getDescription;
        self.base.can_reopen_fn = canReopen;
        return self;
    }

    pub fn interface(self: *TerminalEditorInput) *EditorInput {
        return &self.base;
    }

    pub fn deinit(self: *TerminalEditorInput) void {
        self.base.dispose();
        self.base.deinit();
        if (self.host) |host| host.disposeInstance(self.instance);
        self.allocator.free(self.resource);
        self.allocator.destroy(self);
    }

    pub fn registerInstance(self: *TerminalEditorInput, host: *TerminalEditorService) void {
        host.instances.appendAssumeCapacity(self.instance);
        self.host = host;
    }

    pub fn detachInstance(self: *TerminalEditorInput) *TerminalInstance {
        if (self.host) |host| host.detachInstance(self.instance);
        self.host = null;
        return self.instance;
    }

    fn fromBase(base: *const EditorInput) *const TerminalEditorInput {
        return @ptrCast(@alignCast(base.impl.?));
    }

    fn getName(base: *const EditorInput) []const u8 {
        return fromBase(base).instance.displayTitle();
    }

    fn getDescription(base: *const EditorInput) ?[]const u8 {
        const description = fromBase(base).instance.labels.description;
        return if (description.len > 0) description else null;
    }

    fn canReopen(_: *const EditorInput) bool {
        return false;
    }
};
