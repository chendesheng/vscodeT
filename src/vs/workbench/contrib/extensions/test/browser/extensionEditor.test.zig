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

test "ExtensionEditor: contribution tables preserve upstream columns and grouped view locations" {
    const allocator = std.testing.allocator;
    const features = @import("../../../../services/extensionManagement/common/extensionFeatures.zig");
    var registry = features.ExtensionFeaturesRegistry.init(allocator);
    defer registry.deinit();
    try @import("../../../../workbench.common.main.zig").registerExtensionFeatures(&registry);
    var manifest = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"activationEvents":["onCommand:pub.run"],"originalEnabledApiProposals":["oldProposal"],"enabledApiProposals":["newProposal"],"contributes":{"jsonValidation":[{"fileMatch":["a.json","b.json"],"url":"./schema.json"}],"debuggers":[{"label":"Example Debugger","type":"example"}],"colors":[{"id":"example.fg","description":"Example foreground","defaults":{"dark":"#abc","light":"editor.foreground","highContrast":"#fff"}}],"customEditors":[{"viewType":"example.editor","priority":{"textEditor":"default","diffEditor":"option"},"selector":[{"filenamePattern":"*.example"}]}],"viewsContainers":{"activitybar":[{"id":"example.container","title":"Example"}]},"views":{"example.container":[{"id":"example.view","name":"Example View"}]},"localizations":[{"languageId":"fr","languageName":"French","localizedLanguageName":"Français"}],"authentication":[{"label":"Example Login","id":"example","authorizationServerGlobs":["https://example.test/*"]}],"notebooks":[{"type":"example-notebook","displayName":"Example Notebook"}],"notebookRenderer":[{"displayName":"Example Renderer","mimeTypes":["application/example","text/plain"]}]}}
    , .{});
    defer manifest.deinit();
    const cases = [_]struct { id: []const u8, matches: []const []const u8 }{
        .{ .id = "jsonValidation", .matches = &.{ "File Match", "a.json, b.json", "./schema.json" } },
        .{ .id = "debuggers", .matches = &.{ "Name", "Type", "Example Debugger", "example" } },
        .{ .id = "colors", .matches = &.{ "High Contrast Default", "example.fg", "#abc", "editor.foreground", "#fff" } },
        .{ .id = "customEditors", .matches = &.{ "View Type", "example.editor", "textEditor: default, diffEditor: option", "*.example" } },
        .{ .id = "viewsContainers", .matches = &.{ "Where", "example.container", "activitybar" } },
        .{ .id = "views", .matches = &.{ "Example View", "example.view", "example.container" } },
        .{ .id = "localizations", .matches = &.{ "Language Name (Localized)", "French", "Français" } },
        .{ .id = "authentication", .matches = &.{ "MCP Authorization Servers", "Example Login", "https://example.test/*" } },
        .{ .id = "notebooks", .matches = &.{ "example-notebook", "Example Notebook" } },
        .{ .id = "notebookRenderer", .matches = &.{ "Mimetypes", "application/example,text/plain", "Example Renderer" } },
        .{ .id = "activationEvents", .matches = &.{"onCommand:pub.run"} },
        .{ .id = "enabledApiProposals", .matches = &.{"oldProposal"} },
    };
    for (cases) |item| {
        const descriptor = registry.getExtensionFeature(item.id) orelse return error.FeatureNotRegistered;
        try std.testing.expect(descriptor.should_render(manifest.value));
        const rendered = try descriptor.render(allocator, manifest.value);
        defer allocator.free(rendered);
        for (item.matches) |part| try std.testing.expect(std.mem.indexOf(u8, rendered, part) != null);
        if (std.mem.eql(u8, item.id, "enabledApiProposals")) try std.testing.expect(std.mem.indexOf(u8, rendered, "newProposal") == null);
    }
}
