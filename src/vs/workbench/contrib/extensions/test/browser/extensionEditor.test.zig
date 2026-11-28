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
