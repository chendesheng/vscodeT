// Port of the diff-editor verbosity settings in
// `src/vs/workbench/contrib/accessibility/browser/accessibilityConfiguration.ts`.
pub const AccessibilityVerbositySettingId = struct {
    pub const DiffEditor = "accessibility.verbosity.diffEditor";
    pub const MultiDiffEditorFileList = "accessibility.verbosity.multiDiffEditorFileList";
    pub const DiffEditorActive = "accessibility.verbosity.diffEditorActive";
};
pub const defaults_json =
    \\{
    \\  "accessibility.verbosity.diffEditor": true,
    \\  "accessibility.verbosity.diffEditorActive": true,
    \\  "accessibility.verbosity.multiDiffEditorFileList": true
    \\}
;
