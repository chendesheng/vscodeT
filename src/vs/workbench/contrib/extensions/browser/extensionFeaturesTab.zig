// Port of `src/vs/workbench/contrib/extensions/browser/extensionFeaturesTab.ts`.
// Terminal adaptation: registered renderers produce the shared Markdown
// document, while the feature list owns selection and renders in cell geometry.
// Feature-access telemetry and interactive Web API access controls are unported.
const std = @import("std");
const features = @import("../../../services/extensionManagement/common/extensionFeatures.zig");
pub const property = features.property;

pub const ExtensionFeaturesTab = struct {
    allocator: std.mem.Allocator,
    registry: *const features.ExtensionFeaturesRegistry,
    available: []features.Descriptor = &.{},
    selected: usize = 0,

    pub fn init(allocator: std.mem.Allocator, registry: *const features.ExtensionFeaturesRegistry) ExtensionFeaturesTab {
        return .{ .allocator = allocator, .registry = registry };
    }
    pub fn deinit(self: *ExtensionFeaturesTab) void {
        self.allocator.free(self.available);
        self.available = &.{};
    }
    fn lessThan(_: void, left: features.Descriptor, right: features.Descriptor) bool {
        return std.ascii.orderIgnoreCase(left.label, right.label) == .lt;
    }
    pub fn setManifest(self: *ExtensionFeaturesTab, manifest: std.json.Value) !void {
        const selected_id = if (self.selected < self.available.len) self.available[self.selected].id else "";
        var available: std.ArrayList(features.Descriptor) = .empty;
        errdefer available.deinit(self.allocator);
        for (self.registry.getExtensionFeatures()) |descriptor| if (descriptor.should_render(manifest)) try available.append(self.allocator, descriptor);
        std.mem.sort(features.Descriptor, available.items, {}, lessThan);
        const next = try available.toOwnedSlice(self.allocator);
        self.allocator.free(self.available);
        self.available = next;
        self.selected = 0;
        for (self.available, 0..) |descriptor, index| if (std.mem.eql(u8, descriptor.id, selected_id)) {
            self.selected = index;
            break;
        };
    }
    pub fn select(self: *ExtensionFeaturesTab, index: usize) bool {
        if (index >= self.available.len or index == self.selected) return false;
        self.selected = index;
        return true;
    }
    pub fn renderSelected(self: *const ExtensionFeaturesTab, manifest: std.json.Value) ![]u8 {
        if (self.available.len == 0) return self.allocator.dupe(u8, "No features contributed.");
        const feature = self.available[self.selected];
        const body = try feature.render(self.allocator, manifest);
        defer self.allocator.free(body);
        return std.fmt.allocPrint(self.allocator, "## {s}\n\n{s}", .{ feature.label, body });
    }
};
