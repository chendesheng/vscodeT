// Portable subset of `src/vs/editor/browser/editorExtensions.ts`.
//
// Zig has no class inheritance, so an editor action is a value carrying its
// command metadata and a type-erased `run` callback.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

/// Upstream contribution registration policy. The factory is invoked on
/// demand or by the code editor's instantiation lifecycle, not at binding.
pub const EditorContributionInstantiation = enum(u8) {
    eager,
    after_first_render,
    before_first_interaction,
    eventually,
    lazy,
};

pub const IEditorContributionDescription = struct {
    id: []const u8,
    instantiation: EditorContributionInstantiation,
    context: *anyopaque,
    instantiate: *const fn (*anyopaque) anyerror!void,
};

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

/// A mounted terminal editor inherits workbench keys from the window, but
/// editor-local values must come from the owning code-editor control rather
/// than the currently active diff side. Menu snapshots query this context.
pub const EditorScopedContext = struct {
    editor: *@import("widget/codeEditor/codeEditorWidgetTerminal.zig").Editor,
    parent: @import("../../platform/contextkey/common/contextkey.zig").IContext,
    const contextkey = @import("../../platform/contextkey/common/contextkey.zig");

    pub fn interface(self: *EditorScopedContext) contextkey.IContext {
        return .{ .context = self, .get_value = get };
    }
    fn get(context: *anyopaque, key: []const u8) contextkey.ContextKeyValue {
        const self: *EditorScopedContext = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, key, "editorReadonly")) return .{ .boolean = self.editor.isReadOnly() };
        if (std.mem.eql(u8, key, "editorHasRenameProvider")) return .{ .boolean = self.editor.rename_available };
        if (std.mem.eql(u8, key, "renameInputVisible")) return .{ .boolean = self.editor.rename_input_visible };
        if (std.mem.eql(u8, key, "config.editor.rename.enablePreview")) return .{ .boolean = self.editor.rename_preview };
        if (std.mem.eql(u8, key, "editorHasSignatureHelpProvider")) return .{ .boolean = self.editor.parameter_hints_available };
        if (std.mem.eql(u8, key, "parameterHintsVisible")) return .{ .boolean = self.editor.parameter_hints_visible };
        if (std.mem.eql(u8, key, "parameterHintsMultipleSignatures")) return .{ .boolean = self.editor.parameter_hints_multiple };
        if (std.mem.eql(u8, key, "editorHasCodeActionsProvider")) return .{ .boolean = self.editor.has_code_action_provider };
        if (std.mem.eql(u8, key, "editorLangId")) return .{ .string = if (self.editor.getModel()) |model| model.getLanguageId() else "" };
        if (std.mem.eql(u8, key, "resourceScheme")) return .{ .string = if (self.editor.getModel()) |model| model.uri().scheme else "" };
        if (std.mem.eql(u8, key, "inSnippetMode")) return .{ .boolean = self.editor.snippet_state.in_snippet_mode };
        if (std.mem.eql(u8, key, "hasNextTabstop")) return .{ .boolean = self.editor.snippet_state.has_next_tabstop };
        if (std.mem.eql(u8, key, "hasPrevTabstop")) return .{ .boolean = self.editor.snippet_state.has_prev_tabstop };
        if (std.mem.eql(u8, key, "inSnippetChoice")) return .{ .boolean = self.editor.snippet_state.in_snippet_choice };
        return self.parent.getValue(key);
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
