// Port of `src/vs/platform/theme/common/sizes/semanticSizes.ts`.
const size_utils = @import("../sizeUtils.zig");
const base = @import("./baseSizes.zig");

const corner_radius_customization = size_utils.SizeCustomization{ .minimum = 0, .maximum = 8 };
const panel_spacing_customization = size_utils.SizeCustomization{ .minimum = 0, .maximum = 16 };

pub const panelsCornerRadius = "panels.cornerRadius";
pub const agentsPanelsCornerRadius = "agentsWindow.panels.cornerRadius";
pub const toolsPanelCornerRadius = "toolsPanel.cornerRadius";
pub const primarySideBarCornerRadius = "primarySideBar.cornerRadius";
pub const secondarySideBarCornerRadius = "secondarySideBar.cornerRadius";
pub const editorAreaCornerRadius = "editorArea.cornerRadius";
pub const activityBarCornerRadius = "activityBar.cornerRadius";
pub const agentsChatPanelsCornerRadius = "agentsWindow.chatPanels.cornerRadius";
pub const agentsEditorAreaCornerRadius = "agentsWindow.editorArea.cornerRadius";
pub const agentsToolsPanelCornerRadius = "agentsWindow.toolsPanel.cornerRadius";
pub const agentsSecondarySideBarCornerRadius = "agentsWindow.secondarySideBar.cornerRadius";
pub const panelsSpacing = "panels.spacing";
pub const agentsPanelsSpacing = "agentsWindow.panels.spacing";

pub fn registerSemanticSizes(registry: *size_utils.SizeRegistry) !void {
    _ = try registry.registerSize(panelsCornerRadius, .{ .reference = base.cornerRadiusLarge }, "Shared corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(agentsPanelsCornerRadius, .{ .reference = panelsCornerRadius }, "Agents panel corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(toolsPanelCornerRadius, .{ .reference = panelsCornerRadius }, "Tools panel corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(primarySideBarCornerRadius, .{ .reference = panelsCornerRadius }, "Primary side bar corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(secondarySideBarCornerRadius, .{ .reference = panelsCornerRadius }, "Secondary side bar corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(editorAreaCornerRadius, .{ .reference = panelsCornerRadius }, "Editor area corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(activityBarCornerRadius, .{ .reference = primarySideBarCornerRadius }, "Activity bar corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(agentsChatPanelsCornerRadius, .{ .reference = agentsPanelsCornerRadius }, "Agents chat panel corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(agentsEditorAreaCornerRadius, .{ .reference = agentsPanelsCornerRadius }, "Agents editor area corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(agentsToolsPanelCornerRadius, .{ .reference = agentsPanelsCornerRadius }, "Agents tools panel corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(agentsSecondarySideBarCornerRadius, .{ .reference = agentsPanelsCornerRadius }, "Agents secondary side bar corner radius", null, corner_radius_customization);
    _ = try registry.registerSize(panelsSpacing, .{ .reference = base.spacingSize40 }, "Space between panel areas", null, panel_spacing_customization);
    _ = try registry.registerSize(agentsPanelsSpacing, .{ .reference = panelsSpacing }, "Agents panel spacing", null, panel_spacing_customization);
}
