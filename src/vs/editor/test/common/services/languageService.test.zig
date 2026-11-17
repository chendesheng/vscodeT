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

test "filename and first-line selections update with the registry" {
    const allocator = std.testing.allocator;
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var service = LanguageService.init(allocator, &codec);
    defer service.deinit();

    const path_selection = try service.createByFilepathOrFirstLine("test:file.testLanguageSelection", null);
    defer path_selection.deinit();
    const line_selection = try service.createByFilepathOrFirstLine("test:file", "#!testLanguageSelection");
    defer line_selection.deinit();
    try std.testing.expectEqualStrings("plaintext", path_selection.interface().languageId());
    try std.testing.expectEqualStrings("plaintext", line_selection.interface().languageId());

    try service.registerLanguage(.{
        .id = "testLanguageSelection",
        .extensions = &.{".testLanguageSelection"},
        .firstLine = "^#!testLanguageSelection",
    });
    try std.testing.expectEqualStrings("testLanguageSelection", path_selection.interface().languageId());
    try std.testing.expectEqualStrings("testLanguageSelection", line_selection.interface().languageId());
}

test "language names fall back to the id and later aliases win" {
    const allocator = std.testing.allocator;
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var service = LanguageService.init(allocator, &codec);
    defer service.deinit();

    try service.registerLanguage(.{ .id = "langId" });
    const names = try service.getSortedRegisteredLanguageNames(allocator);
    defer allocator.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("langId", names[0].languageName);
    try std.testing.expectEqualStrings("langId", service.getLanguageName("langId").?);
    try std.testing.expectEqualStrings("langId", service.getLanguageIdByLanguageName("langId").?);

    try service.registerLanguage(.{ .id = "langId", .aliases = &.{"BetterLanguageName"} });
    try std.testing.expectEqualStrings("BetterLanguageName", service.getLanguageName("langId").?);
    try service.registerLanguage(.{ .id = "langId", .aliases = &.{} });
    try std.testing.expectEqualStrings("BetterLanguageName", service.getLanguageName("langId").?);

    const unnamed = try service.getSortedRegisteredLanguageNames(allocator);
    defer allocator.free(unnamed);
    try std.testing.expectEqualStrings("BetterLanguageName", unnamed[0].languageName);
}

test "mimetypes are generated and the first one wins" {
    const allocator = std.testing.allocator;
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var service = LanguageService.init(allocator, &codec);
    defer service.deinit();

    try service.registerLanguage(.{ .id = "langId" });
    try std.testing.expectEqualStrings("text/x-langId", service.getMimeType("langId").?);
    try service.registerLanguage(.{ .id = "langId", .mimetypes = &.{"text/langId"} });
    try std.testing.expectEqualStrings("text/x-langId", service.getMimeType("langId").?);

    try service.registerLanguage(.{ .id = "other", .mimetypes = &.{ "text/other", "text/other2" } });
    try std.testing.expectEqualStrings("text/other", service.getMimeType("other").?);
}

test "extensions and filenames accumulate with the primary registration first" {
    const allocator = std.testing.allocator;
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var service = LanguageService.init(allocator, &codec);
    defer service.deinit();

    try service.registerLanguage(.{ .id = "langId", .extensions = &.{".ext1"}, .filenames = &.{"primary"} });
    try service.registerLanguage(.{ .id = "langId", .extensions = &.{".ext2"}, .filenames = &.{"secondary"} });
    const extensions = service.getExtensions("langId");
    try std.testing.expectEqual(@as(usize, 2), extensions.len);
    try std.testing.expectEqualStrings(".ext1", extensions[0]);
    try std.testing.expectEqualStrings(".ext2", extensions[1]);
    const filenames = service.getFilenames("langId");
    try std.testing.expectEqual(@as(usize, 2), filenames.len);
    try std.testing.expectEqualStrings("primary", filenames[0]);

    try service.registerLanguage(.{ .id = "guess", .extensions = &.{".guess"}, .filenames = &.{"Guessfile"} });
    try std.testing.expectEqualStrings("guess", service.guessLanguageIdByFilepathOrFirstLine("path/file.guess", null).?);
    try std.testing.expectEqualStrings("guess", service.guessLanguageIdByFilepathOrFirstLine("path/Guessfile", null).?);
}

test "filename patterns are matched when guessing" {
    const allocator = std.testing.allocator;
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var service = LanguageService.init(allocator, &codec);
    defer service.deinit();

    try service.registerLanguage(.{ .id = "patternLang", .filenamePatterns = &.{"*.testpat"} });
    try std.testing.expectEqualStrings("patternLang", service.guessLanguageIdByFilepathOrFirstLine("dir/file.testpat", null).?);
    try std.testing.expect(service.guessLanguageIdByFilepathOrFirstLine("dir/file.other", null) == null);
}

fn uriPath(uri: std.Uri) []const u8 {
    return switch (uri.path) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
}

test "configuration files and icons are registered" {
    const allocator = std.testing.allocator;
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var service = LanguageService.init(allocator, &codec);
    defer service.deinit();

    const configuration = try std.Uri.parse("file:///configs/lang.json");
    const light = try std.Uri.parse("file:///icons/lang-light.svg");
    const dark = try std.Uri.parse("file:///icons/lang-dark.svg");
    try service.registerLanguage(.{
        .id = "langId",
        .configuration = configuration,
        .icon = .{ .light = light, .dark = dark },
    });

    const files = try service.getConfigurationFiles("langId", allocator);
    defer allocator.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("/configs/lang.json", uriPath(files[0]));
    const icon = service.getIcon("langId").?;
    try std.testing.expectEqualStrings("/icons/lang-light.svg", uriPath(icon.light));
    try std.testing.expectEqualStrings("/icons/lang-dark.svg", uriPath(icon.dark));
    try std.testing.expect(service.getIcon("missing") == null);
}

test "guessing uses the association matcher priorities" {
    const allocator = std.testing.allocator;
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var service = LanguageService.init(allocator, &codec);
    defer service.deinit();

    // Extensions are matched case-insensitively.
    try service.registerLanguage(.{ .id = "typescript", .extensions = &.{".ts"} });
    try std.testing.expectEqualStrings("typescript", service.guessLanguageIdByFilepathOrFirstLine("dir/FILE.TS", null).?);

    // The longest extension wins.
    try service.registerLanguage(.{ .id = "short", .extensions = &.{".foo"} });
    try service.registerLanguage(.{ .id = "long", .extensions = &.{".foo.bar"} });
    try std.testing.expectEqualStrings("short", service.guessLanguageIdByFilepathOrFirstLine("x.foo", null).?);
    try std.testing.expectEqualStrings("long", service.guessLanguageIdByFilepathOrFirstLine("x.foo.bar", null).?);

    // An exact filename wins over an extension.
    try service.registerLanguage(.{ .id = "ext", .extensions = &.{".mk"} });
    try service.registerLanguage(.{ .id = "name", .filenames = &.{"Makefile"} });
    try std.testing.expectEqualStrings("name", service.guessLanguageIdByFilepathOrFirstLine("dir/Makefile", null).?);
    try std.testing.expectEqualStrings("ext", service.guessLanguageIdByFilepathOrFirstLine("dir/build.mk", null).?);

    // File patterns win over extensions, and later registrations win ties.
    try service.registerLanguage(.{ .id = "pattern", .filenamePatterns = &.{"*.special"} });
    try service.registerLanguage(.{ .id = "special-ext", .extensions = &.{".special"} });
    try std.testing.expectEqualStrings("pattern", service.guessLanguageIdByFilepathOrFirstLine("file.special", null).?);

    try service.registerLanguage(.{ .id = "first-pattern", .filenamePatterns = &.{"Docker*"} });
    try service.registerLanguage(.{ .id = "last-pattern", .filenamePatterns = &.{"Docker*"} });
    try std.testing.expectEqualStrings("last-pattern", service.guessLanguageIdByFilepathOrFirstLine("Dockerfile", null).?);

    // Filenames are case-insensitive too.
    try service.registerLanguage(.{ .id = "codefile", .filenames = &.{"Codefile"} });
    try std.testing.expectEqualStrings("codefile", service.guessLanguageIdByFilepathOrFirstLine("dir/codefile", null).?);
}
