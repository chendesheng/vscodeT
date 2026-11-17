// Port of the `IColorScheme` subset of
// `src/vs/platform/window/common/window.ts`.
//
// Terminal adaptation: only the color-scheme shape used by the theme service is
// ported; the window configuration, menu bar and title-bar parts are browser
// specific and not ported.
pub const IColorScheme = struct {
    dark: bool,
    highContrast: bool,
};
