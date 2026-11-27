// Port of the local-extension model in
// `src/vs/workbench/contrib/extensions/common/extensions.ts`.
//
// Terminal adaptation: only installed local extensions exist (no gallery,
// remote or web extension servers). `IExtension` therefore carries just the
// manifest data the terminal view and its actions consult; gallery fields
// (ratings, install counts, publisher domain, deprecation, update state) are
// not ported.
const std = @import("std");
const management = @import("../../../services/extensionManagement/common/extensionManagement.zig");

pub const EnablementState = management.EnablementState;

/// Upstream view-container id (used by the open command and by context keys).
pub const VIEWLET_ID = "workbench.view.extensions";
/// Native activity/container/view alias used by the terminal workbench.
pub const VIEW_ID = "extensions";
pub const EXTENSIONS_CATEGORY = "Extensions";
/// Upstream installed view id, kept for reference by the ported view.
pub const EXTENSIONS_VIEW_ID = "workbench.views.extensions.installed";

/// Upstream `ExtensionState`. Only `Installed` is produced by the local model.
pub const ExtensionState = enum(u8) {
    Installing = 0,
    Installed = 1,
    Uninstalling = 2,
    Uninstalled = 3,
};

/// A locally installed extension. String fields are borrowed from the
/// workbench service's scanned inventory and stay valid until `refresh`.
pub const IExtension = struct {
    identifier: []const u8,
    name: []const u8,
    display_name: []const u8,
    description: []const u8,
    version: []const u8,
    publisher: []const u8,
    categories: []const []const u8,
    location: []const u8,
    is_builtin: bool,
    state: ExtensionState = .Installed,
    enablement_state: EnablementState = .EnabledGlobally,

    pub fn isEnabled(self: IExtension) bool {
        return self.enablement_state.isEnabled();
    }

    pub fn hasCategory(self: IExtension, category: []const u8) bool {
        for (self.categories) |entry| {
            if (std.ascii.eqlIgnoreCase(entry, category)) return true;
        }
        return false;
    }
};
