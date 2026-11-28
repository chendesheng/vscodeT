// Port of the extension model in
// `src/vs/workbench/contrib/extensions/common/extensions.ts`.
// The terminal model merges local and gallery metadata for the local server;
// remote/web server state and other gallery flags remain unported.
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

/// Upstream `ExtensionState`. Management operations expose transient states.
pub const ExtensionState = enum(u8) {
    Installing = 0,
    Installed = 1,
    Uninstalling = 2,
    Uninstalled = 3,
};

/// Extension view data. Service-owned strings are borrowed until the next
/// local refresh or gallery page replacement. Long-lived inputs clone them.
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
    installed_timestamp: ?i64 = null,
    updated: bool = false,
    pinned: bool = false,
    is_pre_release: bool = false,
    has_pre_release: bool = false,
    publisher_domain: ?[]const u8 = null,
    publisher_verified: bool = false,
    install_count: ?f64 = null,
    rating: ?f64 = null,
    rating_count: ?f64 = null,
    manifest_url: ?[]const u8 = null,
    readme_url: ?[]const u8 = null,
    changelog_url: ?[]const u8 = null,
    vsix_url: ?[]const u8 = null,
    target_platform: ?[]const u8 = null,
    uuid: ?[]const u8 = null,
    last_updated: ?i64 = null,
    release_date: ?i64 = null,
    source: ?[]const u8 = null,
    executes_code: ?bool = null,
    enablement_state: EnablementState = .EnabledGlobally,

    /// Copy a view model into an input-owned arena; scanner and gallery
    /// generations may be replaced while an extension editor remains open.
    pub fn clone(self: IExtension, allocator: std.mem.Allocator) !IExtension {
        var result = self;
        inline for (.{ "identifier", "name", "display_name", "description", "version", "publisher", "location" }) |key| {
            @field(result, key) = try allocator.dupe(u8, @field(self, key));
        }
        inline for (.{ "manifest_url", "readme_url", "changelog_url", "vsix_url", "publisher_domain", "target_platform", "uuid", "source" }) |key| {
            if (@field(self, key)) |value| @field(result, key) = try allocator.dupe(u8, value);
        }
        const categories = try allocator.alloc([]const u8, self.categories.len);
        for (self.categories, 0..) |category, i| categories[i] = try allocator.dupe(u8, category);
        result.categories = categories;
        return result;
    }

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
