// Port of the notebook feature table renderers in
// `src/vs/workbench/contrib/notebook/browser/notebookExtensionPoint.ts`.
// Notebook execution and browser renderer hosts are separate.
const features = @import("../../../services/extensionManagement/common/extensionFeatures.zig");

pub const notebooks_feature = features.manifestTable("notebooks", "Notebooks", &.{
    .{ .label = "ID", .key = "type" },
    .{ .label = "Name", .key = "displayName" },
}, true);
pub const renderers_feature = features.manifestTable("notebookRenderer", "Notebook Renderers", &.{
    .{ .label = "Name", .key = "displayName" },
    .{ .label = "Mimetypes", .key = "mimeTypes", .separator = "," },
}, true);
