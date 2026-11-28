// Port of `src/vs/workbench/contrib/extensions/browser/extensionFeaturesTab.ts`.
// Terminal adaptation: registered renderers produce the shared Markdown
// document, while the feature list owns selection and renders in cell geometry.
// Feature-access telemetry and interactive Web API access controls are unported.
const std = @import("std");
const features = @import("../../../services/extensionManagement/common/extensionFeatures.zig");
const extension_status = @import("../../../services/extensions/common/extensions.zig");
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
    const runtime_feature: features.Descriptor = .{
        .id = "runtimeStatus",
        .label = "Runtime Status",
        .should_render = struct {
            fn render(_: std.json.Value) bool {
                return false;
            }
        }.render,
        .render = struct {
            fn render(allocator: std.mem.Allocator, _: std.json.Value) ![]u8 {
                return allocator.dupe(u8, "Not yet activated.");
            }
        }.render,
    };

    pub fn setManifest(self: *ExtensionFeaturesTab, manifest: std.json.Value) !void {
        try self.setManifestWithRuntime(manifest, false);
    }

    pub fn setManifestWithRuntime(self: *ExtensionFeaturesTab, manifest: std.json.Value, running: bool) !void {
        const selected_id = if (self.selected < self.available.len) self.available[self.selected].id else "";
        var available: std.ArrayList(features.Descriptor) = .empty;
        errdefer available.deinit(self.allocator);
        for (self.registry.getExtensionFeatures()) |descriptor| if (descriptor.should_render(manifest)) try available.append(self.allocator, descriptor);
        std.mem.sort(features.Descriptor, available.items, {}, lessThan);
        if (running) try available.insert(self.allocator, 0, runtime_feature);
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
        return self.renderSelectedWithRuntime(manifest, null);
    }

    pub fn renderSelectedWithRuntime(self: *const ExtensionFeaturesTab, manifest: std.json.Value, status: ?extension_status.IExtensionsStatus) ![]u8 {
        if (self.available.len == 0) return self.allocator.dupe(u8, "No features contributed.");
        const feature = self.available[self.selected];
        if (std.mem.eql(u8, feature.id, runtime_feature.id)) {
            if (status) |value| {
                if (value.activation_times) |times| {
                    if (times.startup) return std.fmt.allocPrint(self.allocator, "## Runtime Status\n\n### Activation\n\nActivated on Startup: `{d:.1}ms`", .{times.activate_call_time});
                    return std.fmt.allocPrint(self.allocator, "## Runtime Status\n\n### Activation\n\nActivated by `{s}` event: `{d:.1}ms`", .{ times.activation_event, times.activate_call_time });
                }
            }
            return self.allocator.dupe(u8, "## Runtime Status\n\n### Activation\n\nNot yet activated");
        }
        const body = try feature.render(self.allocator, manifest);
        defer self.allocator.free(body);
        return std.fmt.allocPrint(self.allocator, "## {s}\n\n{s}", .{ feature.label, body });
    }
};
