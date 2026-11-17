// Port of `src/vs/editor/common/viewModel/viewContext.zig`
// (upstream `viewContext.ts`).
const std = @import("std");
const view_model = @import("../viewModel.zig");
const editor_theme = @import("../editorTheme.zig");
const theme_service = @import("../../../platform/theme/common/themeService.zig");
const editor_configuration = @import("../config/editorConfiguration.zig");
const viewEventHandler = @import("../viewEventHandler.zig");

const IViewModel = view_model.IViewModel;
const IViewLayout = view_model.IViewLayout;
const IColorTheme = theme_service.IColorTheme;
const EditorTheme = editor_theme.EditorTheme;
const IEditorConfiguration = editor_configuration.IEditorConfiguration;
const ViewEventHandler = viewEventHandler.ViewEventHandler;

pub const ViewContext = struct {
    configuration: *const IEditorConfiguration,
    view_model: IViewModel,
    view_layout: IViewLayout,
    theme: EditorTheme,

    pub fn init(configuration: *const IEditorConfiguration, theme: IColorTheme, model: IViewModel) ViewContext {
        return .{
            .configuration = configuration,
            .view_model = model,
            .view_layout = model.view_layout,
            .theme = EditorTheme.init(theme),
        };
    }

    pub fn addEventHandler(self: *ViewContext, event_handler: *ViewEventHandler) void {
        if (self.view_model.add_view_event_handler) |add| add(self.view_model.context, event_handler);
    }

    pub fn removeEventHandler(self: *ViewContext, event_handler: *ViewEventHandler) void {
        if (self.view_model.remove_view_event_handler) |remove| remove(self.view_model.context, event_handler);
    }
};
