// Port of `src/vs/workbench/contrib/multiDiffEditor/browser/media/multiDiffEditorWithFileList.css`.
// The shared terminal tree renderer paints a one-cell row directly, so the
// flex label/status layout is projected to a clipped label and trailing
// status cell. Browser font size and CSS selectors have no terminal equivalent.
pub const padding: usize = 1;
pub const status_gap: usize = 1;
pub const background = "multiDiffEditor.background";
pub const added_foreground = "gitDecoration.addedResourceForeground";
pub const deleted_foreground = "gitDecoration.deletedResourceForeground";
pub const modified_foreground = "gitDecoration.modifiedResourceForeground";
