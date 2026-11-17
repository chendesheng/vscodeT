// Port of `src/vs/editor/common/config/editorConfiguration.ts` (interface).
//
// Terminal adaptation: computed editor options are not ported yet, so
// `options` is an opaque pointer owned by the host; view parts read editor
// fields directly until the options object lands.
const actions = @import("../../../platform/actions/common/actions.zig");

pub const IEditorConfiguration = struct {
    is_simple_widget: bool,
    context_menu_id: actions.MenuId,
    options: ?*const anyopaque = null,
};
