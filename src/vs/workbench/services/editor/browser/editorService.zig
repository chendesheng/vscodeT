// Port of visibleEditorPanes and onDidVisibleEditorsChange in
// src/vs/workbench/services/editor/browser/editorService.ts.
// Terminal groups retain one pane per tab and expose their mounted pane.
const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const Event = @import("../../../../base/common/event.zig").Emitter(void);

pub const EditorService = struct {
    part: *EditorPart,

    pub fn activeEditorPane(self: EditorService) ?*Tab {
        const group = self.part.activeView() orelse return null;
        return group.panes.activePane();
    }

    pub fn onDidActiveEditorChange(self: EditorService) *@import("../../../../base/common/event.zig").Emitter(?*EditorInput) {
        return &self.part.service.on_did_active_editor_change;
    }

    pub fn onDidVisibleEditorsChange(self: EditorService) *Event {
        return &self.part.service.on_did_visible_editors_change;
    }

    pub fn visibleEditorPanes(self: EditorService) VisibleEditorPanes {
        return .{ .groups = self.part.group_views.items };
    }

    pub const VisibleEditorPanes = struct {
        groups: []const *GroupView,

        pub fn next(self: *VisibleEditorPanes) ?*Tab {
            while (self.groups.len > 0) {
                const group = self.groups[0];
                self.groups = self.groups[1..];
                if (group.panes.activePane()) |pane| return pane;
            }
            return null;
        }
    };
};
