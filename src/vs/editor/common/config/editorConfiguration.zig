// Port of `src/vs/editor/common/config/editorConfiguration.ts` (interface).
//
// Terminal adaptation: upstream owns a concrete `ComputedEditorOptions` in
// `editor/browser/config/editorConfiguration.ts`; the common interface only
// sees its `IComputedEditorOptions` shape.
const actions = @import("../../../platform/actions/common/actions.zig");
const editorOptions = @import("./editorOptions.zig");

pub const IEditorConfiguration = struct {
    is_simple_widget: bool,
    context_menu_id: actions.MenuId,
    /// `null` until the host attaches the ported `ComputedEditorOptions`.
    options: ?editorOptions.IComputedEditorOptions = null,
};
