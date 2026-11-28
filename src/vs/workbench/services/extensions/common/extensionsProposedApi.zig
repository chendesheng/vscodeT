// Port of ApiProposalsMarkdowneRenderer in
// `src/vs/workbench/services/extensions/common/extensionsProposedApi.ts`.
// The feature view is descriptive; it does not grant proposed API access.
const std = @import("std");
const features = @import("../../extensionManagement/common/extensionFeatures.zig");

fn shouldRender(manifest: std.json.Value) bool {
    return features.items(features.property(manifest, "originalEnabledApiProposals")).len > 0 or features.items(features.property(manifest, "enabledApiProposals")).len > 0;
}
fn render(allocator: std.mem.Allocator, manifest: std.json.Value) ![]u8 {
    const original = features.property(manifest, "originalEnabledApiProposals");
    const proposals = if (original != .null) original else features.property(manifest, "enabledApiProposals");
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    for (features.items(proposals)) |proposal| if (proposal == .string) try output.writer.print("- `{s}`\n", .{proposal.string});
    return output.toOwnedSlice();
}
pub const proposals_feature: features.Descriptor = .{ .id = "enabledApiProposals", .label = "API Proposals", .should_render = shouldRender, .render = render };
