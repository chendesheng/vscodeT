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
