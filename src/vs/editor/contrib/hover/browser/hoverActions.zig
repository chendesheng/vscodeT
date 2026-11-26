// Port of `src/vs/editor/contrib/hover/browser/hoverActions.ts`.
// Native wrapping replaces browser horizontal scroll geometry.
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const EditorCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const ContentHoverController = @import("contentHoverController.zig").ContentHoverController;
const Range = @import("../../../common/core/range.zig").Range;
const HoverStartMode = @import("hoverOperation.zig").HoverStartMode;
const HoverStartSource = @import("hoverTypes.zig").HoverStartSource;

pub const HoverFocusBehavior = enum { NoAutoFocus, FocusIfVisible, AutoFocusImmediately };

const ids = @import("hoverActionIds.zig");
const codes = @import("../../../../base/common/keyCodes.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const keybindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const hover_focused = contextkey.Expr{ .Defined = "hoverFocused" };
const editor_text_focus = contextkey.Expr{ .Defined = "editorTextFocus" };

pub const show_or_focus_hover_action = blk: {
    var action = EditorCommand.action(.{
        .id = ids.SHOW_OR_FOCUS_HOVER_ACTION_ID,
        .title = "Show or Focus Hover",
        .tooltip = "Show or focus the editor hover which shows documentation, references, and other content for a symbol at the current cursor position.",
    }, false, run);
    action.keybindings = &.{.{
        .id = ids.SHOW_OR_FOCUS_HOVER_ACTION_ID,
        .weight = @backingInt(keybindings.KeybindingWeight.EditorContrib),
        .when = &editor_text_focus,
        .bindings = .{ .primary = codes.KeyChord(codes.KeyMod.CtrlCmd | @backingInt(codes.KeyCode.KeyK), codes.KeyMod.CtrlCmd | @backingInt(codes.KeyCode.KeyI)) },
    }};
    break :blk action;
};

pub const hide_hover_action = EditorCommand.action(.{ .id = ids.HIDE_HOVER_ACTION_ID, .title = "Hide Hover" }, false, hide);
pub const scroll_actions = [_]actions.Action2{
    scrollAction(ids.SCROLL_UP_HOVER_ACTION_ID, "Scroll Up Hover", "Scroll up the editor hover.", .UpArrow, null, .scrollUp),
    scrollAction(ids.SCROLL_DOWN_HOVER_ACTION_ID, "Scroll Down Hover", "Scroll down the editor hover.", .DownArrow, null, .scrollDown),
    scrollAction(ids.SCROLL_LEFT_HOVER_ACTION_ID, "Scroll Left Hover", "Scroll left the editor hover.", .LeftArrow, null, .scrollLeft),
    scrollAction(ids.SCROLL_RIGHT_HOVER_ACTION_ID, "Scroll Right Hover", "Scroll right the editor hover.", .RightArrow, null, .scrollRight),
    scrollAction(ids.PAGE_UP_HOVER_ACTION_ID, "Page Up Hover", "Page up the editor hover.", .PageUp, codes.KeyMod.Alt | @backingInt(codes.KeyCode.UpArrow), .pageUp),
    scrollAction(ids.PAGE_DOWN_HOVER_ACTION_ID, "Page Down Hover", "Page down the editor hover.", .PageDown, codes.KeyMod.Alt | @backingInt(codes.KeyCode.DownArrow), .pageDown),
    scrollAction(ids.GO_TO_TOP_HOVER_ACTION_ID, "Go To Top Hover", "Go to the top of the editor hover.", .Home, codes.KeyMod.CtrlCmd | @backingInt(codes.KeyCode.UpArrow), .goToTop),
    scrollAction(ids.GO_TO_BOTTOM_HOVER_ACTION_ID, "Go To Bottom Hover", "Go to the bottom of the editor hover.", .End, codes.KeyMod.CtrlCmd | @backingInt(codes.KeyCode.DownArrow), .goToBottom),
};
const Scroll = enum { scrollUp, scrollDown, scrollLeft, scrollRight, pageUp, pageDown, goToTop, goToBottom };

fn scrollAction(comptime id: []const u8, comptime title: []const u8, comptime tooltip: []const u8, comptime primary: codes.KeyCode, comptime secondary: ?u32, comptime scroll: Scroll) actions.Action2 {
    var action = EditorCommand.action(.{ .id = id, .title = title, .tooltip = tooltip, .precondition = &hover_focused }, false, struct {
        fn execute(editor: *Editor) !void {
            const controller = editor.getContribution(ContentHoverController) orelse return;
            if (!controller.isVisible()) return;
            const widget = controller.widget().widget;
            @field(@TypeOf(widget.*), @tagName(scroll))(widget);
        }
    }.execute);
    action.keybindings = &.{.{ .id = id, .weight = @backingInt(keybindings.KeybindingWeight.EditorContrib), .when = &hover_focused, .bindings = .{ .primary = @backingInt(primary), .secondary = if (secondary) |value| &.{value} else null } }};
    return action;
}

fn hide(editor: *Editor) !void {
    if (editor.getContribution(ContentHoverController)) |controller| controller.hideContentHover();
}

pub fn showOrFocusHover(editor: *Editor, focus: HoverFocusBehavior) bool {
    const controller = editor.getContribution(ContentHoverController) orelse return false;
    if (controller.isVisible() and focus != .NoAutoFocus) {
        controller.widget().focus();
    } else {
        const position = editor.modelCursorPosition();
        controller.showContentHover(
            Range.init(position.lineNumber, position.column, position.lineNumber, position.column),
            HoverStartMode.immediate,
            HoverStartSource.keyboard,
            focus == .AutoFocusImmediately,
        );
    }
    return true;
}

fn run(editor: *Editor) !void {
    _ = showOrFocusHover(editor, .FocusIfVisible);
}
