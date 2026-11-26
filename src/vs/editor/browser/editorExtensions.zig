// Portable subset of `src/vs/editor/browser/editorExtensions.ts`.
//
// Zig has no class inheritance, so an editor action is a value carrying its
// command metadata and a type-erased `run` callback.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

pub const KeybindingWeight = enum(u8) {
    editor_core = 0,
    editor_contrib = 100,
};

pub const Keybinding = struct {
    key: []const u8,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false,
    weight: KeybindingWeight = .editor_contrib,
    when: ?[]const u8 = null,
};

pub const EditorActionOptions = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
    precondition: ?[]const u8 = null,
    keybinding: ?Keybinding = null,
    context: *anyopaque,
    run: *const fn (context: *anyopaque) anyerror!void,
};

/// Port of EditorCommand.runEditorCommand. The focused editor takes precedence
/// over the workbench's active editor. Writability belongs to the target's
/// scoped context, including the two distinct controls in a diff editor.
pub const EditorCommand = struct {
    const Editor = @import("widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
    const Accessor = @import("../../platform/instantiation/common/instantiation.zig").ServicesAccessor;

    const platform_actions = @import("../../platform/actions/common/actions.zig");
    const contextkey = @import("../../platform/contextkey/common/contextkey.zig");
    pub const writable = contextkey.Expr{ .Not = "editorReadonly" };

    /// Zig adapter for the EditorAction constructor and its runEditorCommand
    /// implementation. The declaring contribution owns the descriptor.
    pub fn action(comptime command: platform_actions.ICommandAction, comptime requires_writable: bool, comptime operation: fn (*Editor) anyerror!void) platform_actions.Action2 {
        return .{
            .command = command,
            .f1 = true,
            .context = @constCast(&{}),
            .run_fn = struct {
                fn run(_: *anyopaque, accessor: Accessor) !void {
                    try runEditorCommand(accessor, requires_writable, operation);
                }
            }.run,
        };
    }

    pub fn runEditorCommand(accessor: Accessor, requires_writable: bool, comptime run: fn (*Editor) anyerror!void) !void {
        const service = try accessor.get(@import("services/codeEditorService.zig").code_editor_service_id);
        const editor = service.getFocusedCodeEditor() orelse service.getActiveCodeEditor() orelse return;
        if (requires_writable and editor.isReadOnly()) return;
        try run(editor);
    }
};

/// Base shape shared by registered editor actions.
pub const EditorAction = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
    precondition: ?[]const u8 = null,
    keybinding: ?Keybinding = null,
    context: *anyopaque,
    run_action: *const fn (context: *anyopaque) anyerror!void,

    pub fn init(options: EditorActionOptions) EditorAction {
        return .{
            .id = options.id,
            .label = options.label,
            .description = options.description,
            .precondition = options.precondition,
            .keybinding = options.keybinding,
            .context = options.context,
            .run_action = options.run,
        };
    }

    pub fn run(self: *const EditorAction) !void {
        return self.run_action(self.context);
    }
};

pub const EditorActionRegistry = struct {
    actions: ArrayList(EditorAction),

    pub fn init(allocator: Allocator) EditorActionRegistry {
        return .{ .actions = ArrayList(EditorAction).init(allocator) };
    }

    pub fn deinit(self: *EditorActionRegistry) void {
        self.actions.deinit();
    }

    pub fn register(self: *EditorActionRegistry, action: EditorAction) !void {
        try self.actions.append(action);
    }

    pub fn get(self: *const EditorActionRegistry, id: []const u8) ?EditorAction {
        for (self.actions.items) |action| {
            if (std.mem.eql(u8, action.id, id)) return action;
        }
        return null;
    }

    pub fn run(self: *const EditorActionRegistry, id: []const u8) !bool {
        const action = self.get(id) orelse return false;
        try action.run();
        return true;
    }
};

/// `registerDiffEditorContribution`: the portable widget owns the lifetime
/// of attached contributions. The workbench supplies registered factories and
/// its service accessor at the normal editor creation boundary.
pub const DiffEditorContribution = struct {
    id: []const u8,
    context: *anyopaque,
    dispose_fn: *const fn (*anyopaque) void,

    pub fn dispose(self: DiffEditorContribution) void {
        self.dispose_fn(self.context);
    }
};

pub const DiffEditorContributionRegistration = struct {
    id: []const u8,
    create: *const fn (Allocator, @import("editorBrowser.zig").IDiffEditor, @import("../../platform/instantiation/common/instantiation.zig").ServicesAccessor) anyerror!?DiffEditorContribution,
};

test "editorExtensions: action metadata and run callback" {
    const State = struct {
        ran: bool = false,
        fn run(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ran = true;
        }
    };

    var state = State{};
    const action = EditorAction.init(.{
        .id = "test.action",
        .label = "Test Action",
        .description = "Runs the test action",
        .keybinding = .{ .key = "l", .ctrl = true, .weight = .editor_core },
        .context = &state,
        .run = State.run,
    });

    var registry = EditorActionRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(action);

    try std.testing.expectEqualStrings("Test Action", registry.get("test.action").?.label);
    try std.testing.expect(try registry.run("test.action"));
    try std.testing.expect(state.ran);
    try std.testing.expect(!try registry.run("missing.action"));
}
