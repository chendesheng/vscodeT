// Port of `src/vs/workbench/services/themes/common/hostColorSchemeService.ts`
// (the interface).
//
// Terminal adaptation: upstream exposes `dark`/`highContrast` fields and an
// `onDidChangeColorScheme` event. The terminal host lets the theme service read
// the current values through the vtable; change notification is host-driven and
// no event emitter is part of this port.
const window_mod = @import("../../../../platform/window/common/window.zig");

pub const IColorScheme = window_mod.IColorScheme;

pub const IHostColorSchemeService = struct {
    context: *anyopaque,
    is_dark: *const fn (context: *anyopaque) bool,
    is_high_contrast: *const fn (context: *anyopaque) bool,

    pub fn dark(self: IHostColorSchemeService) bool {
        return self.is_dark(self.context);
    }

    pub fn highContrast(self: IHostColorSchemeService) bool {
        return self.is_high_contrast(self.context);
    }

    pub fn colorScheme(self: IHostColorSchemeService) IColorScheme {
        return .{ .dark = self.dark(), .highContrast = self.highContrast() };
    }
};
