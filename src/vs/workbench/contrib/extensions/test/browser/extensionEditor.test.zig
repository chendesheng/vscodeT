// Terminal input identity regression for
// `src/vs/workbench/contrib/extensions/test/browser/extensionEditor.test.ts`.
const std = @import("std");
const Input = @import("../../common/extensionsInput.zig").ExtensionsInput;
const IExtension = @import("../../common/extensions.zig").IExtension;

test "ExtensionsInput: owns gallery identity across result replacement" {
    const allocator = std.testing.allocator;
    const first_id = try allocator.dupe(u8, "Pub.Example");
    const extension: IExtension = .{ .identifier = first_id, .name = "example", .display_name = "Example", .description = "Description", .version = "1.0.0", .publisher = "Pub", .categories = &.{}, .location = "", .is_builtin = false, .state = .Uninstalled, .readme_url = "https://example.test/readme" };
    const first = try Input.init(allocator, &extension);
    allocator.free(first_id);
    defer first.deinit();
    var other = extension;
    other.identifier = "pub.example";
    const second = try Input.init(allocator, &other);
    defer second.deinit();
    try std.testing.expect(first.base.matches(.{ .input = &second.base }));
    try std.testing.expectEqualStrings("Extension: Example", first.base.getName());
    try std.testing.expectEqualStrings("extension:/pub.example/extension", first.resource);
    try std.testing.expectEqualStrings("https://example.test/readme", first.snapshot.readme_url.?);
}

test "ExtensionEditor: additional details include installation, category and resources" {
    const allocator = std.testing.allocator;
    const editor = @import("../../browser/extensionEditor.zig");
    var manifest = try std.json.parseFromSlice(std.json.Value, allocator, "{\"repository\":{\"url\":\"https://example.test/repo\"},\"bugs\":{\"url\":\"https://example.test/issues\"}}", .{});
    defer manifest.deinit();
    const extension: IExtension = .{ .identifier = "pub.example", .name = "example", .display_name = "Example", .description = "", .version = "1.2.3", .publisher = "Pub", .categories = &.{"Programming Languages"}, .location = "/extensions/pub.example", .is_builtin = false, .installed_timestamp = 951782400000, .source = "vsix" };
    const output = try editor.renderAdditionalDetails(allocator, extension, null, manifest.value, "https://open-vsx.org/vscode/gallery");
    defer allocator.free(output);
    for ([_][]const u8{ "Installation", "pub.example", "1.2.3", "2000-02-29", "VSIX", "Programming Languages", "https://example.test/repo", "https://example.test/issues", "https://open-vsx.org/extension/pub/example" }) |value| try std.testing.expect(std.mem.indexOf(u8, output, value) != null);
}

test "ExtensionEditor: registered feature renderers preserve command and language table data" {
    const allocator = std.testing.allocator;
    const features = @import("../../../../services/extensionManagement/common/extensionFeatures.zig");
    const tab_mod = @import("../../browser/extensionFeaturesTab.zig");
    var registry = features.ExtensionFeaturesRegistry.init(allocator);
    defer registry.deinit();
    try @import("../../../../workbench.common.main.zig").registerExtensionFeatures(&registry);
    var manifest = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"contributes":{"commands":[{"command":"pub.run","title":"Run Example"}],"keybindings":[{"command":"pub.run","key":"ctrl+r"}],"menus":{"editor/context":[{"command":"pub.run"}]},"languages":[{"id":"example","aliases":["Example"],"extensions":[".ex"]}],"grammars":[{"language":"example","scopeName":"source.example"}],"snippets":[{"language":"example","path":"snippets.json"}],"configuration":{"properties":{"pub.enabled":{"type":"boolean","default":true,"description":"Enable it"}}}}}
    , .{});
    defer manifest.deinit();
    var tab = tab_mod.ExtensionFeaturesTab.init(allocator, &registry);
    defer tab.deinit();
    try tab.setManifest(manifest.value);
    try std.testing.expectEqual(@as(usize, 3), tab.available.len);
    try std.testing.expectEqualStrings("Commands", tab.available[0].label);
    const commands = try tab.renderSelected(manifest.value);
    defer allocator.free(commands);
    for ([_][]const u8{ "pub.run", "Run Example", "ctrl+r", "editor/context", "commandPalette" }) |value| try std.testing.expect(std.mem.indexOf(u8, commands, value) != null);
    try std.testing.expect(tab.select(1));
    const languages = try tab.renderSelected(manifest.value);
    defer allocator.free(languages);
    for ([_][]const u8{ "Programming Languages", "example", ".ex", "Grammar", "Snippets", "✓" }) |value| try std.testing.expect(std.mem.indexOf(u8, languages, value) != null);
    try tab.setManifest(manifest.value);
    try std.testing.expectEqualStrings("languages", tab.available[tab.selected].id);
    try std.testing.expect(tab.select(2));
    const settings = try tab.renderSelected(manifest.value);
    defer allocator.free(settings);
    for ([_][]const u8{ "pub.enabled", "Enable it", "true" }) |value| try std.testing.expect(std.mem.indexOf(u8, settings, value) != null);
}

test "ExtensionEditor: runtime feature reports activation and replaces status" {
    const allocator = std.testing.allocator;
    const features = @import("../../../../services/extensionManagement/common/extensionFeatures.zig");
    var registry = features.ExtensionFeaturesRegistry.init(allocator);
    defer registry.deinit();
    var tab = @import("../../browser/extensionFeaturesTab.zig").ExtensionFeaturesTab.init(allocator, &registry);
    defer tab.deinit();
    try tab.setManifestWithRuntime(.null, true);
    try std.testing.expectEqualStrings("runtimeStatus", tab.available[0].id);
    const pending = try tab.renderSelectedWithRuntime(.null, .{});
    defer allocator.free(pending);
    try std.testing.expect(std.mem.indexOf(u8, pending, "Not yet activated") != null);
    const active = try tab.renderSelectedWithRuntime(.null, .{ .activation_started = true, .activation_times = .{ .code_loading_time = 1, .activate_call_time = 2, .activate_resolved_time = 3, .startup = false, .activation_event = "onCommand:example.run" } });
    defer allocator.free(active);
    try std.testing.expect(std.mem.indexOf(u8, active, "onCommand:example.run") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "2.0ms") != null);
    try tab.setManifestWithRuntime(.null, false);
    try std.testing.expectEqual(@as(usize, 0), tab.available.len);
}
