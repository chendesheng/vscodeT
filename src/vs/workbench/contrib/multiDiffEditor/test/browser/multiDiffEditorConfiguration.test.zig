// Port of `src/vs/workbench/contrib/multiDiffEditor/test/browser/multiDiffEditorConfiguration.test.ts`.
const std = @import("std");
const testing = std.testing;
const config = @import("../../../../../platform/configuration/common/configuration.zig");
const registry_mod = @import("../../../../../platform/configuration/common/configurationRegistry.zig");
const storage = @import("../../../../../platform/storage/common/storage.zig");
const Emitter = @import("../../../../../base/common/event.zig").Emitter;
const common = @import("../../common/multiDiffEditor.zig");
const editor_schema = @import("../../../../../editor/common/config/editorConfigurationSchema.zig");

fn createRegistry() !*registry_mod.ConfigurationRegistry {
    const registry = try registry_mod.ConfigurationRegistry.init(testing.allocator);
    errdefer registry.deinit();
    try registry.registerConfiguration("multiDiffEditor", &common.properties);
    try registry.registerConfiguration("diffEditor", &editor_schema.diff_editor_properties);
    return registry;
}

test "MultiDiffEditorConfiguration: registers the experimental variant setting" {
    const registry = try createRegistry();
    defer registry.deinit();
    const property = registry.getConfigurationProperties().get(common.multiDiffEditorExperimentalVariantSetting).?;
    try testing.expectEqualStrings("string", property.value_type);
    try testing.expectEqual(@as(usize, 2), property.enum_values.?.len);
    try testing.expectEqualStrings("cards", property.enum_values.?[0]);
    try testing.expectEqualStrings("noCards", property.enum_values.?[1]);
    try testing.expectEqualStrings("Use the compact card-based variant.", property.enum_descriptions.?[0]);
    try testing.expectEqualStrings("Use the compact variant without cards.", property.enum_descriptions.?[1]);
    try testing.expectEqualStrings("noCards", property.default.string);
    try testing.expectEqualStrings("cards", property.agents_window_default.?.string);
    try testing.expectEqual(config.ConfigurationScope.WINDOW, property.scope);
    try testing.expectEqualStrings("experimental", property.tags.?[0]);
    try testing.expectEqualStrings("auto", property.experiment_mode.?);
    try testing.expectEqual(common.MultiDiffEditorVariant.noCards, common.defaultMultiDiffEditorExperimentalVariant);
}

test "MultiDiffEditorConfiguration: registers the experimental file list setting as opt-in" {
    const registry = try createRegistry();
    defer registry.deinit();
    const property = registry.getConfigurationProperties().get(common.multiDiffEditorExperimentalFileListSetting).?;
    try testing.expectEqualStrings("boolean", property.value_type);
    try testing.expect(!property.default.bool);
    try testing.expect(property.agents_window_default.?.bool);
    try testing.expectEqual(config.ConfigurationScope.WINDOW, property.scope);
    try testing.expectEqualStrings("experimental", property.tags.?[0]);
}

test "MultiDiffEditorConfiguration: registers original line number visibility as an inheritable setting" {
    const registry = try createRegistry();
    defer registry.deinit();
    const property = registry.getConfigurationProperties().get("diffEditor.hideOriginalLineNumbers").?;
    try testing.expectEqual(@as(usize, 2), property.value_types.?.len);
    try testing.expectEqualStrings("boolean", property.value_types.?[0]);
    try testing.expectEqualStrings("null", property.value_types.?[1]);
    try testing.expect(property.default == .null);
    try testing.expectEqual(config.ConfigurationScope.LANGUAGE_OVERRIDABLE, property.scope);
    try testing.expect(property.policy == null);
}

test "MultiDiffEditorConfiguration: maps setting values to compact variants" {
    try testing.expectEqual(common.MultiDiffEditorVariant.cards, common.getWorkbenchMultiDiffEditorVariant("cards"));
    try testing.expectEqual(common.MultiDiffEditorVariant.noCards, common.getWorkbenchMultiDiffEditorVariant("noCards"));
    try testing.expectEqual(common.MultiDiffEditorVariant.noCards, common.getWorkbenchMultiDiffEditorVariant(null));
}

const MockConfig = struct {
    variant: std.json.Value = .{ .string = "cards" },
    enabled: std.json.Value = .{ .bool = true },
    changed: Emitter(config.Change),

    fn interface(self: *MockConfig) config.IConfigurationService {
        return .{ .context = self, .get_value = get, .on_did_change_configuration = &self.changed };
    }
    fn get(context: *anyopaque, key: []const u8) ?*const std.json.Value {
        const self: *MockConfig = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, key, common.multiDiffEditorExperimentalVariantSetting)) return &self.variant;
        if (std.mem.eql(u8, key, common.multiDiffEditorExperimentalFileListSetting)) return &self.enabled;
        return null;
    }
    fn setVariant(self: *MockConfig, value: []const u8) !void {
        self.variant = .{ .string = value };
        try self.changed.fire(.{ .source = .USER, .keys = &.{common.multiDiffEditorExperimentalVariantSetting} });
    }
    fn setEnabled(self: *MockConfig, value: bool) !void {
        self.enabled = .{ .bool = value };
        try self.changed.fire(.{ .source = .USER, .keys = &.{common.multiDiffEditorExperimentalFileListSetting} });
    }
};
const Capture = struct {
    values: std.ArrayList(common.Preferences.State) = .empty,
    fn capture(value: common.Preferences.State, self: *Capture) !void {
        try self.values.append(testing.allocator, value);
    }
    fn attach(self: *Capture, preferences: *common.Preferences) !void {
        try capture(preferences.state, self);
        _ = try preferences.changed.listen(self, capture);
    }
    fn deinit(self: *Capture) void {
        self.values.deinit(testing.allocator);
    }
};

test "MultiDiffEditorConfiguration: updates the resolved variant when configuration changes" {
    var cfg: MockConfig = .{ .changed = .init(testing.allocator) };
    defer cfg.changed.deinit();
    var store = storage.InMemoryStorageService.init(testing.allocator);
    defer store.deinit();
    const prefs = try common.Preferences.create(testing.allocator, cfg.interface(), store.interface());
    defer prefs.dispose();
    var captured: Capture = .{};
    defer captured.deinit();
    try captured.attach(prefs);
    try cfg.setVariant("noCards");
    try testing.expectEqual(@as(usize, 2), captured.values.items.len);
    try testing.expectEqual(common.MultiDiffEditorVariant.cards, captured.values.items[0].variant);
    try testing.expectEqual(common.MultiDiffEditorVariant.noCards, captured.values.items[1].variant);
}

test "MultiDiffEditorConfiguration: shows the file list while enabled and the shared toggle has not hidden it" {
    var cfg: MockConfig = .{ .changed = .init(testing.allocator) };
    defer cfg.changed.deinit();
    var store = storage.InMemoryStorageService.init(testing.allocator);
    defer store.deinit();
    const first = try common.Preferences.create(testing.allocator, cfg.interface(), store.interface());
    defer first.dispose();
    const second = try common.Preferences.create(testing.allocator, cfg.interface(), store.interface());
    defer second.dispose();
    var a: Capture = .{};
    defer a.deinit();
    var b: Capture = .{};
    defer b.deinit();
    try a.attach(first);
    try b.attach(second);
    try common.toggleMultiDiffEditorFileList(store.interface());
    try common.toggleMultiDiffEditorFileList(store.interface());
    try cfg.setEnabled(false);
    try common.toggleMultiDiffEditorFileList(store.interface());
    try common.toggleMultiDiffEditorFileList(store.interface());
    const expected = [_]bool{ true, false, true, false };
    for ([_]Capture{ a, b }) |capture| {
        try testing.expectEqual(expected.len, capture.values.items.len);
        for (expected, capture.values.items) |want, actual| try testing.expectEqual(want, actual.enabled);
    }
}

test "MultiDiffEditorConfiguration: shares the file list view mode between editors and defaults to a list" {
    var cfg: MockConfig = .{ .changed = .init(testing.allocator) };
    defer cfg.changed.deinit();
    var store = storage.InMemoryStorageService.init(testing.allocator);
    defer store.deinit();
    const first = try common.Preferences.create(testing.allocator, cfg.interface(), store.interface());
    defer first.dispose();
    const second = try common.Preferences.create(testing.allocator, cfg.interface(), store.interface());
    defer second.dispose();
    var a: Capture = .{};
    defer a.deinit();
    var b: Capture = .{};
    defer b.deinit();
    try a.attach(first);
    try b.attach(second);
    try common.setMultiDiffEditorFileListViewMode(store.interface(), .tree);
    try common.setMultiDiffEditorFileListViewMode(store.interface(), .tree);
    try common.setMultiDiffEditorFileListViewMode(store.interface(), .list);
    const expected = [_]common.MultiDiffEditorFileListViewMode{ .list, .tree, .list };
    for ([_]Capture{ a, b }) |capture| {
        try testing.expectEqual(expected.len, capture.values.items.len);
        for (expected, capture.values.items) |want, actual| try testing.expectEqual(want, actual.view_mode);
    }
}

test "MultiDiffEditorConfiguration: shares and remembers file list position, defaulting to the right" {
    var cfg: MockConfig = .{ .changed = .init(testing.allocator) };
    defer cfg.changed.deinit();
    var store = storage.InMemoryStorageService.init(testing.allocator);
    defer store.deinit();
    const first = try common.Preferences.create(testing.allocator, cfg.interface(), store.interface());
    defer first.dispose();
    const second = try common.Preferences.create(testing.allocator, cfg.interface(), store.interface());
    defer second.dispose();
    var a: Capture = .{};
    defer a.deinit();
    var b: Capture = .{};
    defer b.deinit();
    try a.attach(first);
    try b.attach(second);
    try common.setMultiDiffEditorFileListPosition(store.interface(), .left);
    try common.setMultiDiffEditorFileListPosition(store.interface(), .left);
    const restored = try common.Preferences.create(testing.allocator, cfg.interface(), store.interface());
    defer restored.dispose();
    try testing.expectEqual(common.MultiDiffEditorFileListPosition.left, restored.state.position);
    try common.setMultiDiffEditorFileListPosition(store.interface(), .right);
    const expected = [_]common.MultiDiffEditorFileListPosition{ .right, .left, .right };
    for ([_]Capture{ a, b }) |capture| {
        try testing.expectEqual(expected.len, capture.values.items.len);
        for (expected, capture.values.items) |want, actual| try testing.expectEqual(want, actual.position);
    }
}
