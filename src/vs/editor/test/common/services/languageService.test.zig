// Port of the language-selection cases of
// `src/vs/editor/test/common/services/languageService.test.ts`, adapted to the
// explicit terminal language registry (no model service).
const std = @import("std");
const language_service_mod = @import("../../../common/services/languageService.zig");
const languages = @import("../../../common/languages.zig");

const LanguageService = language_service_mod.LanguageService;

test "LanguageSelection falls back to plaintext and tracks registry changes" {
    const allocator = std.testing.allocator;
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var service = LanguageService.init(allocator, &codec);
    defer service.deinit();

    const selection = try service.createById("testLanguageSelection");
    defer selection.deinit();
    try std.testing.expectEqualStrings("plaintext", selection.interface().languageId());

    var events = std.array_list.Managed([]const u8).init(allocator);
    defer events.deinit();
    const Listener = struct {
        fn onChange(value: []const u8, list: *std.array_list.Managed([]const u8)) anyerror!void {
            try list.append(value);
        }
    };
    _ = try selection.emitter.listen(&events, Listener.onChange);

    try service.registerLanguage(.{
        .id = "testLanguageSelection",
        .extensions = &.{".testLanguageSelection"},
        .mimetypes = &.{"text/testLanguageSelection"},
        .firstLine = "^#!testLanguageSelection",
        .aliases = &.{"Test Language"},
    });
    try std.testing.expectEqualStrings("testLanguageSelection", selection.interface().languageId());
    try std.testing.expect(service.isRegisteredLanguageId("testLanguageSelection"));
    try std.testing.expectEqualStrings("text/testLanguageSelection", service.getMimeType("testLanguageSelection").?);
    try std.testing.expectEqualStrings("testLanguageSelection", service.getLanguageIdByMimeType("text/testLanguageSelection").?);
    try std.testing.expectEqualStrings("Test Language", service.getLanguageName("testLanguageSelection").?);
    try std.testing.expectEqual(@as(usize, 1), service.getExtensions("testLanguageSelection").len);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("testLanguageSelection", events.items[0]);

    const mime_selection = try service.createByMimeType("text/testLanguageSelection");
    defer mime_selection.deinit();
    try std.testing.expectEqualStrings("testLanguageSelection", mime_selection.interface().languageId());

    const unknown = try service.createByMimeType("text/unknown");
    defer unknown.deinit();
    try std.testing.expectEqualStrings("plaintext", unknown.interface().languageId());
}
