// Port of `src/vs/editor/contrib/codeAction/browser/codeActionCommands.ts`.
const std = @import("std");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const EditorCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const Controller = @import("codeActionController.zig").CodeActionController;
const codeAction = @import("codeAction.zig");
const types = @import("../common/types.zig");
const Kind = @import("../../../../base/common/hierarchicalKind.zig").HierarchicalKind;
const actions = @import("../../../../platform/actions/common/actions.zig");
const context = @import("../../../../platform/contextkey/common/contextkey.zig");
const keys = @import("../../../../base/common/keyCodes.zig");
const weight = @backingInt(@import("../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingWeight.EditorContrib);
const Accessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const CommandArgument = @import("../../../../platform/commands/common/commands.zig").CommandArgument;
const writable = EditorCommand.writable;
const provider = context.Expr{ .Defined = "editorHasCodeActionsProvider" };
const writable_provider = context.Expr{ .And = @constCast(&[_]*const context.Expr{ &writable, &provider }) };
const text_input_focus = context.Expr{ .Defined = "textInputFocus" };
const refactor_kind = supported("refactor");
const source_kind = supported("source");
const organize_kind = supported("source\\.organizeImports");
const fix_all_kind = supported("source\\.fixAll");
const quickfix_kind = supported("quickfix");
const can_refactor = conjunction(&refactor_kind);
const can_source = conjunction(&source_kind);
const can_organize = conjunction(&organize_kind);
const can_fix_all = conjunction(&fix_all_kind);
const can_auto_fix = conjunction(&quickfix_kind);

fn supported(comptime kind: []const u8) context.Expr {
    return .{ .Regex = .{ .key = "supportedCodeAction", .source = "(\\s|^)" ++ kind ++ "\\b", .flags = "" } };
}
fn conjunction(comptime kind: *const context.Expr) context.Expr {
    return .{ .And = @constCast(&[_]*const context.Expr{ &writable, kind }) };
}
const Mode = enum { quickfix, generic, refactor, source, organize, fix_all, auto_fix };

pub const editor_actions = [_]actions.Action2{
    make(.quickfix, codeAction.quickFixCommandId, "Quick Fix...", &writable_provider, keys.KeyMod.CtrlCmd | @backingInt(keys.KeyCode.Period), null, &.{.{ .id = actions.menu_ids.InlineChatEditorAffordance, .group = "1_quickfix", .order = 0, .when = &writable_provider }}, true, null),
    make(.refactor, codeAction.refactorCommandId, "Refactor...", &writable_provider, keys.KeyMod.CtrlCmd | keys.KeyMod.Shift | @backingInt(keys.KeyCode.KeyR), keys.KeyMod.WinCtrl | keys.KeyMod.Shift | @backingInt(keys.KeyCode.KeyR), &.{.{ .id = actions.menu_ids.EditorContext, .group = "1_modification", .order = 2, .when = &can_refactor }}, true, "Refactor..."),
    make(.source, codeAction.sourceActionCommandId, "Source Action...", &writable_provider, null, null, &.{.{ .id = actions.menu_ids.EditorContext, .group = "1_modification", .order = 2.1, .when = &can_source }}, true, "Source Action..."),
    make(.organize, codeAction.organizeImportsCommandId, "Organize Imports", &can_organize, keys.KeyMod.Shift | keys.KeyMod.Alt | @backingInt(keys.KeyCode.KeyO), null, &.{}, true, "Organize imports in the current file. Also called 'Optimize Imports' by some tools"),
    make(.auto_fix, codeAction.autoFixCommandId, "Auto Fix...", &can_auto_fix, keys.KeyMod.Alt | keys.KeyMod.Shift | @backingInt(keys.KeyCode.Period), keys.KeyMod.CtrlCmd | keys.KeyMod.Alt | @backingInt(keys.KeyCode.Period), &.{}, true, null),
    make(.fix_all, codeAction.fixAllCommandId, "Fix All", &can_fix_all, null, null, &.{}, true, null),
    make(.generic, codeAction.codeActionCommandId, "Trigger a code action", &writable_provider, null, null, &.{}, false, "Trigger a code action"),
};

fn make(comptime mode: Mode, comptime id: []const u8, comptime title: []const u8, comptime precondition: *const context.Expr, comptime key: ?u32, comptime mac_key: ?u32, comptime menus: []const actions.MenuRegistration, comptime f1: bool, comptime description: ?[]const u8) actions.Action2 {
    var action = EditorCommand.action(.{ .id = id, .title = title, .precondition = precondition, .tooltip = description orelse "" }, true, struct {
        fn run(editor: *Editor) !void {
            try trigger(editor, mode, null);
        }
    }.run);
    action.f1 = f1;
    action.menus = menus;
    if (key) |primary| action.keybindings = &.{.{ .id = id, .weight = weight, .when = &text_input_focus, .bindings = .{ .primary = primary, .mac = if (mac_key) |mac| .{ .primary = mac } else null } }};
    action.run_with_argument_fn = struct {
        fn run(_: *anyopaque, accessor: Accessor, arg: CommandArgument) !void {
            const service = try accessor.get(@import("../../../browser/services/codeEditorService.zig").code_editor_service_id);
            const editor = service.getFocusedCodeEditor() orelse service.getActiveCodeEditor() orelse return;
            if (editor.isReadOnly()) return;
            const raw = arg.as(std.json.Value) orelse return error.InvalidArgument;
            const value = if (raw.* == .array and raw.array.items.len > 0) raw.array.items[0] else raw.*;
            try trigger(editor, mode, value);
        }
    }.run;
    return action;
}

fn trigger(editor: *Editor, mode: Mode, user_args: ?std.json.Value) !void {
    const controller = editor.getContribution(Controller) orelse return;
    switch (mode) {
        .quickfix => controller.manualTriggerAtCurrentPosition("No code actions available", .QuickFix, .{}, null),
        .organize => controller.manualTriggerAtCurrentPosition("No organize imports action available", .OrganizeImports, .{ .include = types.CodeActionKind.SourceOrganizeImports, .include_source_actions = true }, .IfSingle),
        .fix_all => controller.manualTriggerAtCurrentPosition("No fix all action available", .FixAll, .{ .include = types.CodeActionKind.SourceFixAll, .include_source_actions = true }, .IfSingle),
        .auto_fix => controller.manualTriggerAtCurrentPosition("No auto fixes available", .AutoFix, .{ .include = types.CodeActionKind.QuickFix, .only_include_preferred_actions = true }, .IfSingle),
        .generic, .refactor, .source => {
            const default_kind = switch (mode) {
                .generic => Kind.Empty,
                .refactor => types.CodeActionKind.Refactor,
                .source => types.CodeActionKind.Source,
                else => unreachable,
            };
            const args = types.CodeActionCommandArgs.fromUser(user_args, .{ .kind = default_kind, .apply = if (mode == .generic) .IfSingle else .Never });
            const kind = if (default_kind.contains(args.kind)) args.kind else Kind.None;
            const noun = switch (mode) {
                .generic => "code actions",
                .refactor => "refactorings",
                .source => "source actions",
                else => unreachable,
            };
            const named = if (user_args) |value| value == .object and (if (value.object.get("kind")) |field| field == .string else false) else false;
            const message = if (named) try std.fmt.allocPrint(editor.allocator, "No {s}{s} for '{s}' available", .{ if (args.preferred) "preferred " else "", noun, args.kind.value }) else try std.fmt.allocPrint(editor.allocator, "No {s}{s} available", .{ if (args.preferred) "preferred " else "", noun });
            defer editor.allocator.free(message);
            controller.manualTriggerAtCurrentPosition(message, switch (mode) {
                .generic => .Default,
                .refactor => .Refactor,
                .source => .SourceAction,
                else => unreachable,
            }, .{ .include = kind, .include_source_actions = mode != .refactor, .only_include_preferred_actions = args.preferred }, args.apply);
        },
    }
}
