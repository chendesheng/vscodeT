// Port of `src/vs/workbench/services/workingCopy/common/workingCopyEditorService.ts`.
//
// Terminal adaptation: the editor service is not injected; callers pass the
// currently open editors to `findEditor`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const working_copy = @import("./workingCopy.zig");
const IWorkingCopy = working_copy.IWorkingCopy;
const WorkingCopyIdentifier = working_copy.WorkingCopyIdentifier;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const WorkingCopyEditorHandler = struct {
    context: *anyopaque,
    handles: *const fn (context: *anyopaque, working_copy_id: WorkingCopyIdentifier) bool,
    is_open: *const fn (context: *anyopaque, working_copy_id: WorkingCopyIdentifier, editor: *EditorInput) bool,
    create_editor: *const fn (context: *anyopaque, working_copy_id: WorkingCopyIdentifier) ?*EditorInput,
};

pub const WorkingCopyEditorService = struct {
    allocator: Allocator,
    handlers: std.array_list.Managed(*const WorkingCopyEditorHandler),
    on_did_register_handler: Emitter(*const WorkingCopyEditorHandler),

    pub fn init(allocator: Allocator) WorkingCopyEditorService {
        return .{
            .allocator = allocator,
            .handlers = std.array_list.Managed(*const WorkingCopyEditorHandler).init(allocator),
            .on_did_register_handler = Emitter(*const WorkingCopyEditorHandler).init(allocator),
        };
    }

    pub fn deinit(self: *WorkingCopyEditorService) void {
        self.handlers.deinit();
        self.on_did_register_handler.deinit();
    }

    pub fn registerHandler(self: *WorkingCopyEditorService, handler: *const WorkingCopyEditorHandler) !void {
        try self.handlers.append(handler);
        try self.on_did_register_handler.fire(handler);
    }

    pub fn unregisterHandler(self: *WorkingCopyEditorService, handler: *const WorkingCopyEditorHandler) void {
        var index: usize = 0;
        while (index < self.handlers.items.len) : (index += 1) {
            if (self.handlers.items[index] == handler) {
                _ = self.handlers.orderedRemove(index);
                return;
            }
        }
    }

    /// Returns the first editor that a registered handler reports as open for
    /// the working copy.
    pub fn findEditor(self: *const WorkingCopyEditorService, copy: IWorkingCopy, editors: []const *EditorInput) ?*EditorInput {
        const identifier = WorkingCopyIdentifier{
            .resource = copy.getResource(),
            .type_id = copy.getTypeId(),
        };
        for (editors) |editor| {
            for (self.handlers.items) |handler| {
                if (handler.is_open(handler.context, identifier, editor)) return editor;
            }
        }
        return null;
    }
};
