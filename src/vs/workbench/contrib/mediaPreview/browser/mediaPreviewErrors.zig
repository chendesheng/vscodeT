// Port of reopenInTextEditor from src/vs/workbench/contrib/mediaPreview/browser/mediaPreviewErrors.ts.
// The terminal does not implement media diff inputs. Text override replaces the
// preview through the editor service in each group sharing its input.
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const IEditorService = @import("../../../services/editor/common/editorService.zig").IEditorService;

pub fn reopenInTextEditor(input: *EditorInput, service: IEditorService) !void {
    const resource = input.resource orelse return;
    const allocator = input.allocator;
    const path = try allocator.dupe(u8, resource);
    defer allocator.free(path);
    const editors = try service.getEditors(allocator);
    defer allocator.free(editors);
    for (editors) |identifier| {
        if (identifier.editor != input) continue;
        try service.replaceEditors(&.{.{
            .editor = input,
            .resource = path,
            .options = .{ .force_text = true, .pinned = true },
        }}, identifier.group_id);
    }
}
