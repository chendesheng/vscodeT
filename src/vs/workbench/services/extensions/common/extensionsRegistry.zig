// Declarative extension scanner and contribution registry.
//
// Port of the data-only half of `extensionsRegistry.ts`. The platform scanner
// (`extensionsScannerService.zig`) owns the filesystem and manifest parsing;
// this registry extracts the languages, grammars, themes, icon themes,
// snippets and configuration defaults from those descriptions into a
// process-lifetime arena. Manifests and language configurations are JSONC;
// contribution values borrow from a registry-owned arena.
const std = @import("std");
const Allocator = std.mem.Allocator;
const time_compat = @import("../../../../base/common/timeCompat.zig");
const configuration_models = @import("../../../../platform/configuration/common/configurationModels.zig");
const scanner = @import("../../../../platform/extensionManagement/common/extensionsScannerService.zig");

pub const Language = struct {
    root: []const u8,
    id: []const u8,
    aliases: []const []const u8,
    extensions: []const []const u8,
    filenames: []const []const u8,
    filename_patterns: []const []const u8,
    mimetypes: []const []const u8 = &.{},
    first_line: ?[]const u8 = null,
    /// Path relative to `root`, or null.
    configuration: ?[]const u8,
};

const scopes = @import("../../textMate/common/TMScopeRegistry.zig");
pub const Grammar = scopes.Grammar;

pub const Theme = struct {
    root: []const u8,
    /// The contributed `id` (falls back to the path for unnamed themes).
    id: []const u8,
    /// `id`, else the NLS-resolved label: the value `workbench.colorTheme`
    /// stores, matching upstream `ColorThemeData.settingsId`.
    settings_id: []const u8,
    label: []const u8,
    ui_theme: []const u8,
    path: []const u8,
};

pub const IconTheme = struct {
    id: []const u8,
    data: std.json.Value,
};

pub const Snippet = struct {
    root: []const u8,
    language: []const u8,
    path: []const u8,
};

pub const Extension = struct {
    root: []const u8,
    identifier: []const u8,
    is_builtin: bool,
    configuration_defaults: ?std.json.Value = null,

    pub fn id(self: Extension) []const u8 {
        return self.identifier[0 .. std.mem.lastIndexOfScalar(u8, self.identifier, '@') orelse self.identifier.len];
    }
};

pub const ScanError = error{
    InvalidManifest,
    MissingPackageJson,
};

pub const Registry = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    extensions: []const Extension,
    languages: []const Language,
    grammars: []const Grammar,
    themes: []const Theme,
    icon_themes: []const IconTheme = &.{},
    snippets: []const Snippet,

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
    }

    /// Returns the primary contribution for `id`. VS Code merges every
    /// contribution with the same language id; the one carrying the
    /// `configuration` file is the primary definition, so it must win even
    /// when an earlier extension (for example the bundled `copilot` manifest)
    /// also contributes the same language without a configuration.
    pub fn language(self: *const Registry, id: []const u8) ?Language {
        var fallback: ?Language = null;
        for (self.languages) |item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            if (item.configuration != null) return item;
            if (fallback == null) fallback = item;
        }
        return fallback;
    }

    pub fn grammarForLanguage(self: *const Registry, id: []const u8) ?Grammar {
        for (self.grammars) |item| {
            if (std.mem.eql(u8, item.language, id)) return item;
        }
        return null;
    }

    pub fn theme(self: *const Registry, id: []const u8) ?Theme {
        for (self.themes) |item| {
            if (std.mem.eql(u8, item.id, id) or std.mem.eql(u8, item.label, id)) return item;
        }
        return null;
    }

    pub fn extensionForRoot(self: *const Registry, root: []const u8) ?Extension {
        for (self.extensions) |item| {
            if (std.mem.eql(u8, item.root, root)) return item;
        }
        return null;
    }
};

const Contributions = struct {
    extensions: *std.array_list.Managed(Extension),
    languages: *std.array_list.Managed(Language),
    grammars: *std.array_list.Managed(Grammar),
    themes: *std.array_list.Managed(Theme),
    icon_themes: *std.array_list.Managed(IconTheme),
    snippets: *std.array_list.Managed(Snippet),
};

/// Scans `roots` and extracts their declarative contributions.
///
/// A root that is itself an extension (its `package.json` has `name`,
/// `version` and `engines.vscode`) is scanned as one extension. A root
/// without a valid extension manifest is treated as a directory of
/// extensions, like upstream's location scan: its direct child directories
/// with a `package.json` are scanned in location order. Missing roots and
/// invalid manifests are skipped: a bundled fixture may be absent in a
/// checkout without `vscode`.
///
/// This is a convenience wrapper around the platform scanner for tests and
/// one-off roots. Callers that already own scanned descriptions (the
/// workbench extension service) use `scanDescriptions` so each manifest is
/// parsed once.
pub fn scan(allocator: Allocator, io: std.Io, roots: []const []const u8) !Registry {
    const extensions = try scanner.scanExtensionsFromRoots(allocator, io, roots, .system);
    defer {
        for (extensions) |*extension| extension.deinit(allocator);
        allocator.free(extensions);
    }
    const descriptions = try allocator.alloc(*const scanner.ScannedExtension, extensions.len);
    defer allocator.free(descriptions);
    for (extensions, 0..) |*extension, index| descriptions[index] = extension;
    return scanDescriptions(allocator, io, descriptions);
}

/// Extracts the declarative contributions of already-scanned extensions.
/// Contribution strings are copied into the registry arena; the descriptions
/// are only borrowed for the duration of the call. Invalid manifests are
/// already filtered by the scanner.
pub fn scanDescriptions(
    allocator: Allocator,
    io: std.Io,
    extensions: []const *const scanner.ScannedExtension,
) !Registry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const scratch = arena.allocator();

    var registry_extensions = std.array_list.Managed(Extension).init(scratch);
    var languages = std.array_list.Managed(Language).init(scratch);
    var grammars = std.array_list.Managed(Grammar).init(scratch);
    var themes = std.array_list.Managed(Theme).init(scratch);
    var icon_themes = std.array_list.Managed(IconTheme).init(scratch);
    var snippets = std.array_list.Managed(Snippet).init(scratch);
    const contributions: Contributions = .{
        .extensions = &registry_extensions,
        .languages = &languages,
        .grammars = &grammars,
        .themes = &themes,
        .icon_themes = &icon_themes,
        .snippets = &snippets,
    };

    for (extensions) |extension| try collectContributions(allocator, io, scratch, extension, contributions);

    try scopes.resolveInjections(scratch, grammars.items);
    return .{
        .allocator = allocator,
        .arena = arena,
        .extensions = try registry_extensions.toOwnedSlice(),
        .languages = try languages.toOwnedSlice(),
        .grammars = try grammars.toOwnedSlice(),
        .themes = try themes.toOwnedSlice(),
        .icon_themes = try icon_themes.toOwnedSlice(),
        .snippets = try snippets.toOwnedSlice(),
    };
}

fn collectContributions(
    allocator: Allocator,
    io: std.Io,
    scratch: Allocator,
    extension_description: *const scanner.ScannedExtension,
    contributions: Contributions,
) !void {
    const absolute = extension_description.location;
    const object = switch (extension_description.manifest.value) {
        .object => |object| object,
        else => return,
    };
    const identifier = try std.fmt.allocPrint(scratch, "{s}@{s}", .{ extension_description.identifier, extension_description.version });
    const root_copy = try scratch.dupe(u8, absolute);
    const extension = try contributions.extensions.addOne();
    extension.* = .{
        .root = root_copy,
        .identifier = identifier,
        .is_builtin = extension_description.extension_type == .system,
    };

    const contributes = object.get("contributes") orelse return;
    if (contributes != .object) return;
    const points = contributes.object;
    if (points.get("configurationDefaults")) |defaults| {
        if (defaults == .object)
            extension.configuration_defaults = try @import("../../../../platform/configuration/common/configuration.zig").cloneValue(scratch, defaults);
    }

    // Temporary strings and theme icon files live for this extension's
    // extraction only; the extracted contributions are copied to `scratch`.
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const temporary = parse_arena.allocator();

    // VS Code manifests store theme labels as `%nlsKey%`; resolve the default
    // `package.nls.json` so the scanner exposes the same label a user sees.
    var nls: ?std.json.ObjectMap = null;
    const nls_path = try std.fs.path.join(allocator, &.{ absolute, "package.nls.json" });
    defer allocator.free(nls_path);
    if (std.Io.Dir.cwd().readFileAlloc(io, nls_path, temporary, .unlimited)) |nls_text| {
        if (std.json.parseFromSliceLeaky(std.json.Value, temporary, nls_text, .{})) |nls_value| {
            if (nls_value == .object) nls = nls_value.object;
        } else |_| {}
    } else |_| {}

    if (points.get("languages")) |items| {
        if (items == .array) {
            for (items.array.items) |item| {
                if (item != .object) continue;
                const language = item.object;
                const id = stringField(language, "id") orelse continue;
                try contributions.languages.append(.{
                    .root = root_copy,
                    .id = try scratch.dupe(u8, id),
                    .aliases = try stringArray(scratch, language, "aliases"),
                    .extensions = try stringArray(scratch, language, "extensions"),
                    .filenames = try stringArray(scratch, language, "filenames"),
                    .first_line = if (stringField(language, "firstLine")) |pattern| try scratch.dupe(u8, pattern) else null,
                    .mimetypes = try stringArray(scratch, language, "mimetypes"),
                    .filename_patterns = try stringArray(scratch, language, "filenamePatterns"),
                    .configuration = if (stringField(language, "configuration")) |path| try scratch.dupe(u8, path) else null,
                });
            }
        }
    }

    if (points.get("grammars")) |items| {
        if (items == .array) {
            for (items.array.items) |item| {
                if (item != .object) continue;
                const grammar = item.object;
                const language = stringField(grammar, "language") orelse "";
                const scope = stringField(grammar, "scopeName") orelse continue;
                const path = stringField(grammar, "path") orelse continue;
                try contributions.grammars.append(.{
                    .root = root_copy,
                    .language = try scratch.dupe(u8, language),
                    .scope = try scratch.dupe(u8, scope),
                    .location = try std.fs.path.join(scratch, &.{ root_copy, path }),
                    .inject_to = try stringArray(scratch, grammar, "injectTo"),
                    .path = try scratch.dupe(u8, path),
                });
            }
        }
    }

    if (points.get("themes")) |items| {
        if (items == .array) {
            for (items.array.items) |item| {
                if (item != .object) continue;
                const theme = item.object;
                const path = stringField(theme, "path") orelse continue;
                const ui_theme = stringField(theme, "uiTheme") orelse continue;
                const contributed_id = stringField(theme, "id");
                const label = resolveNls(nls, stringField(theme, "label") orelse "");
                try contributions.themes.append(.{
                    .root = root_copy,
                    .id = try scratch.dupe(u8, contributed_id orelse path),
                    .settings_id = try scratch.dupe(u8, contributed_id orelse if (label.len > 0) label else path),
                    .label = try scratch.dupe(u8, label),
                    .ui_theme = try scratch.dupe(u8, ui_theme),
                    .path = try scratch.dupe(u8, path),
                });
            }
        }
    }

    if (points.get("iconThemes")) |items| {
        if (items == .array) for (items.array.items) |item| {
            if (item != .object) continue;
            const id = stringField(item.object, "id") orelse continue;
            const relative = stringField(item.object, "path") orelse continue;
            const path = try std.fs.path.join(temporary, &.{ root_copy, relative });
            const raw = std.Io.Dir.cwd().readFileAlloc(io, path, temporary, .limited(8 * 1024 * 1024)) catch continue;
            const json = configuration_models.stripJsonc(temporary, raw) catch continue;
            const data = std.json.parseFromSliceLeaky(std.json.Value, scratch, json, .{ .allocate = .alloc_always }) catch continue;
            if (data == .object) try contributions.icon_themes.append(.{ .id = try scratch.dupe(u8, id), .data = data });
        };
    }

    if (points.get("snippets")) |items| {
        if (items == .array) {
            for (items.array.items) |item| {
                if (item != .object) continue;
                const snippet = item.object;
                const language = stringField(snippet, "language") orelse continue;
                const path = stringField(snippet, "path") orelse continue;
                try contributions.snippets.append(.{
                    .root = root_copy,
                    .language = try scratch.dupe(u8, language),
                    .path = try scratch.dupe(u8, path),
                });
            }
        }
    }
}

fn resolveNls(nls: ?std.json.ObjectMap, raw: []const u8) []const u8 {
    if (raw.len < 3 or raw[0] != '%' or raw[raw.len - 1] != '%') return raw;
    const map = nls orelse return raw;
    const key = raw[1 .. raw.len - 1];
    const value = map.get(key) orelse return raw;
    return switch (value) {
        .string => |text| text,
        else => raw,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn stringArray(allocator: Allocator, object: std.json.ObjectMap, name: []const u8) ![]const []const u8 {
    var result = std.array_list.Managed([]const u8).init(allocator);
    const value = object.get(name) orelse return &.{};
    if (value != .array) return &.{};
    for (value.array.items) |item| {
        if (item != .string) continue;
        try result.append(try allocator.dupe(u8, item.string));
    }
    return result.toOwnedSlice();
}

test "declarative scanner reads markdown-basics and theme-defaults" {
    const allocator = std.testing.allocator;
    var registry = try scan(allocator, std.testing.io, &.{
        "vscode/extensions/markdown-basics",
        "vscode/extensions/theme-defaults",
    });
    defer registry.deinit();
    if (registry.languages.len == 0) return error.SkipZigTest;

    const markdown = registry.language("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("markdown", markdown.id);
    try std.testing.expect(markdown.configuration != null);
    try std.testing.expect(std.mem.endsWith(u8, markdown.configuration.?, "language-configuration.json"));

    const grammar = registry.grammarForLanguage("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("text.html.markdown", grammar.scope);

    const theme = registry.theme("Dark+") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("vs-dark", theme.ui_theme);
    try std.testing.expect(std.mem.endsWith(u8, theme.path, "dark_plus.json"));
}

test "declarative scanner reads a directory of bundled extensions" {
    const allocator = std.testing.allocator;
    var registry = try scan(allocator, std.testing.io, &.{"vscode/extensions"});
    defer registry.deinit();
    if (registry.extensions.len == 0) return error.SkipZigTest;

    // A full checkout also contains the `copilot` manifest, which contributes
    // `markdown` without a configuration. The scanner must still select the
    // markdown-basics contribution so the language configuration and grammar
    // keep working.
    const markdown = registry.language("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expect(markdown.configuration != null);
    try std.testing.expect(std.mem.endsWith(u8, markdown.root, "markdown-basics"));

    const grammar = registry.grammarForLanguage("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("text.html.markdown", grammar.scope);
    try std.testing.expect(std.mem.endsWith(u8, grammar.root, "markdown-basics"));

    const theme = registry.theme("Dark+") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("vs-dark", theme.ui_theme);
}

test "declarative scanner keeps duplicate language contributions and selects the configured one" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "first");
    try tmp.dir.createDirPath(io, "second");
    try tmp.dir.createDirPath(io, "third");
    try writeTestManifest(&tmp, io, "first",
        \\{
        \\  "name": "markdown-copy",
        \\  "version": "1.0.0",
        \\  "publisher": "example",
        \\  "engines": { "vscode": "*" },
        \\  "contributes": {
        \\    "languages": [
        \\      { "id": "markdown", "extensions": [".copy"] }
        \\    ]
        \\  }
        \\}
    );
    try writeTestManifest(&tmp, io, "second",
        \\{
        \\  "name": "markdown-basics",
        \\  "version": "1.0.0",
        \\  "publisher": "example",
        \\  "engines": { "vscode": "*" },
        \\  "contributes": {
        \\    "languages": [
        \\      {
        \\        "id": "markdown",
        \\        "extensions": [".md"],
        \\        "configuration": "./language-configuration.json"
        \\      }
        \\    ]
        \\  }
        \\}
    );
    try writeTestManifest(&tmp, io, "third",
        \\{
        \\  "name": "markdown-grammar",
        \\  "version": "1.0.0",
        \\  "publisher": "example",
        \\  "engines": { "vscode": "*" },
        \\  "contributes": {
        \\    "grammars": [
        \\      {
        \\        "language": "markdown",
        \\        "scopeName": "text.html.markdown",
        \\        "path": "./syntaxes/markdown.tmLanguage.json"
        \\      }
        \\    ]
        \\  }
        \\}
    );

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buffer);
    var registry = try scan(allocator, std.testing.io, &.{path_buffer[0..path_len]});
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 3), registry.extensions.len);
    try std.testing.expectEqual(@as(usize, 2), registry.languages.len);

    const markdown = registry.language("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expect(markdown.configuration != null);
    try std.testing.expect(std.mem.endsWith(u8, markdown.root, "second"));

    // The grammar comes from a third extension. Consumers must resolve its
    // path against `grammar.root`, not the language contribution's root.
    const grammar = registry.grammarForLanguage("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, grammar.root, "third"));
}

fn writeTestManifest(tmp: *std.testing.TmpDir, io: std.Io, directory: []const u8, text: []const u8) !void {
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "package.json" });
    defer std.testing.allocator.free(path);
    var file = try tmp.dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, text);
}

test "declarative scanner resolves include scopes and Markdown math injections" {
    const roots = &.{ "vscode/extensions/markdown-basics", "vscode/extensions/markdown-math", "vscode/extensions/yaml" };
    std.Io.Dir.cwd().access(std.testing.io, roots[0], .{}) catch return error.SkipZigTest;
    var registry = try scan(std.testing.allocator, std.testing.io, roots);
    defer registry.deinit();
    const included = scopes.forScope(registry.grammars, "source.yaml.1.2") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), included.language.len);
    const markdown = registry.grammarForLanguage("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expect(markdown.injections.len >= 2);
    for (markdown.injections) |scope| try std.testing.expect(scopes.forScope(registry.grammars, scope) != null);
}

test "declarative scanner marks user descriptions and extracts their contributions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "pub.user-extension-1.0.0");
    var manifest_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &manifest_path);
    const root = manifest_path[0..length];
    const extension_root = try std.fs.path.join(allocator, &.{ root, "pub.user-extension-1.0.0" });
    defer allocator.free(extension_root);
    try writeTestManifestKind(&tmp, "pub.user-extension-1.0.0",
        \\{
        \\  "name": "user-extension",
        \\  "publisher": "pub",
        \\  "version": "1.0.0",
        \\  "engines": { "vscode": "*" },
        \\  "contributes": {
        \\    "languages": [{ "id": "user-lang", "extensions": [".user"] }],
        \\    "snippets": [{ "language": "user-lang", "path": "./snippets.json" }],
        \\    "configurationDefaults": { "editor.tabSize": 3 }
        \\  }
        \\}
    );

    const scanned = try scanner.scanExtensionsFromRoots(allocator, std.testing.io, &.{extension_root}, .user);
    defer {
        for (scanned) |*extension| extension.deinit(allocator);
        allocator.free(scanned);
    }
    try std.testing.expectEqual(@as(usize, 1), scanned.len);

    const descriptions = try allocator.alloc(*const scanner.ScannedExtension, scanned.len);
    defer allocator.free(descriptions);
    for (scanned, 0..) |*extension, index| descriptions[index] = extension;

    var registry = try scanDescriptions(allocator, std.testing.io, descriptions);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 1), registry.extensions.len);
    try std.testing.expect(!registry.extensions[0].is_builtin);
    try std.testing.expectEqualStrings("pub.user-extension@1.0.0", registry.extensions[0].identifier);
    try std.testing.expect(registry.language("user-lang") != null);
    try std.testing.expectEqual(@as(usize, 1), registry.snippets.len);
    try std.testing.expect(registry.extensions[0].configuration_defaults != null);
}

fn writeTestManifestKind(tmp: *std.testing.TmpDir, directory: []const u8, text: []const u8) !void {
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "package.json" });
    defer std.testing.allocator.free(path);
    var file = try tmp.dir.createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, text);
}
