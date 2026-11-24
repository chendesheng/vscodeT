// Declarative extension scanner and contribution registry.
//
// Port of the data-only half of `extensionsRegistry.ts` and the subset of
// `extensionsScannerService.ts` needed by the bundled declarative extensions.
// Manifests and language configurations are JSONC; contribution values borrow
// from a registry-owned arena for the process lifetime.
const std = @import("std");
const Allocator = std.mem.Allocator;
const time_compat = @import("../../../../base/common/timeCompat.zig");
const configuration_models = @import("../../../../platform/configuration/common/configurationModels.zig");

pub const Language = struct {
    root: []const u8,
    id: []const u8,
    aliases: []const []const u8,
    extensions: []const []const u8,
    filenames: []const []const u8,
    filename_patterns: []const []const u8,
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
    snippets: *std.array_list.Managed(Snippet),
};

/// Scans `roots`.
///
/// A root that is itself an extension (its `package.json` has `name`,
/// `version` and `engines.vscode`) is scanned as one extension. A root
/// without a valid extension manifest is treated as a directory of
/// extensions, like upstream's location scan: its direct child directories
/// with a `package.json` are scanned in location order. Missing roots and
/// invalid manifests are skipped: a bundled fixture may be absent in a
/// checkout without `vscode`.
pub fn scan(allocator: Allocator, roots: []const []const u8) !Registry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const scratch = arena.allocator();

    var extensions = std.array_list.Managed(Extension).init(scratch);
    var languages = std.array_list.Managed(Language).init(scratch);
    var grammars = std.array_list.Managed(Grammar).init(scratch);
    var themes = std.array_list.Managed(Theme).init(scratch);
    var snippets = std.array_list.Managed(Snippet).init(scratch);
    const contributions: Contributions = .{
        .extensions = &extensions,
        .languages = &languages,
        .grammars = &grammars,
        .themes = &themes,
        .snippets = &snippets,
    };

    for (roots) |root| {
        const absolute = std.Io.Dir.cwd().realPathFileAlloc(time_compat.io, root, allocator) catch continue;
        defer allocator.free(absolute);
        if (try scanExtensionRoot(allocator, scratch, absolute, contributions)) continue;
        try scanExtensionDirectory(allocator, scratch, absolute, contributions);
    }

    try scopes.resolveInjections(scratch, grammars.items);
    return .{
        .allocator = allocator,
        .arena = arena,
        .extensions = try extensions.toOwnedSlice(),
        .languages = try languages.toOwnedSlice(),
        .grammars = try grammars.toOwnedSlice(),
        .themes = try themes.toOwnedSlice(),
        .snippets = try snippets.toOwnedSlice(),
    };
}

/// Scans one extension directory. Returns false when the directory does not
/// contain a usable extension manifest, so the caller can treat it as a
/// container of extensions instead (`vscode/extensions/package.json` is a
/// build manifest, not an extension).
fn scanExtensionRoot(allocator: Allocator, scratch: Allocator, absolute: []const u8, contributions: Contributions) !bool {
    const manifest_path = try std.fs.path.join(allocator, &.{ absolute, "package.json" });
    defer allocator.free(manifest_path);
    const text = std.Io.Dir.cwd().readFileAlloc(time_compat.io, manifest_path, allocator, .unlimited) catch return false;
    defer allocator.free(text);
    // Only the extracted contributions survive startup. Release each parsed
    // manifest (including large command/configuration sections) after scanning.
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const temporary = parse_arena.allocator();
    const sanitized = configuration_models.stripJsonc(temporary, text) catch return true;
    const value = std.json.parseFromSliceLeaky(std.json.Value, temporary, sanitized, .{}) catch return true;
    if (value != .object) return true;
    const object = value.object;

    const name = stringField(object, "name") orelse return false;
    const version = stringField(object, "version") orelse return false;
    if (!hasEngines(object)) return false;
    const publisher = stringField(object, "publisher") orelse "undefined_publisher";
    const identifier = try std.fmt.allocPrint(scratch, "{s}.{s}@{s}", .{ publisher, name, version });
    const root_copy = try scratch.dupe(u8, absolute);
    const extension = try contributions.extensions.addOne();
    extension.* = .{ .root = root_copy, .identifier = identifier, .is_builtin = true };

    const contributes = object.get("contributes") orelse return true;
    if (contributes != .object) return true;
    const points = contributes.object;
    if (points.get("configurationDefaults")) |defaults| {
        if (defaults == .object)
            extension.configuration_defaults = try @import("../../../../platform/configuration/common/configuration.zig").cloneValue(scratch, defaults);
    }

    // VS Code manifests store theme labels as `%nlsKey%`; resolve the default
    // `package.nls.json` so the scanner exposes the same label a user sees.
    var nls: ?std.json.ObjectMap = null;
    const nls_path = try std.fs.path.join(allocator, &.{ absolute, "package.nls.json" });
    defer allocator.free(nls_path);
    if (std.Io.Dir.cwd().readFileAlloc(time_compat.io, nls_path, temporary, .unlimited)) |nls_text| {
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

    return true;
}

/// A themes-only scan result. Installed extensions usually contribute more
/// than themes; scanning the whole extension directory for every contribution
/// would also register its languages and grammars, which is not part of the
/// theme source. This keeps only the theme records.
pub const ThemeList = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    themes: []const Theme,

    pub fn deinit(self: *ThemeList) void {
        self.arena.deinit();
    }
};

pub fn scanThemes(allocator: Allocator, roots: []const []const u8) !ThemeList {
    var registry = try scan(allocator, roots);
    defer registry.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    var themes = std.array_list.Managed(Theme).init(scratch);
    for (registry.themes) |theme| {
        try themes.append(.{
            .root = try scratch.dupe(u8, theme.root),
            .id = try scratch.dupe(u8, theme.id),
            .settings_id = try scratch.dupe(u8, theme.settings_id),
            .label = try scratch.dupe(u8, theme.label),
            .ui_theme = try scratch.dupe(u8, theme.ui_theme),
            .path = try scratch.dupe(u8, theme.path),
        });
    }
    return .{
        .allocator = allocator,
        .arena = arena,
        .themes = try themes.toOwnedSlice(),
    };
}

/// Scans the direct child directories of `absolute` that contain a
/// `package.json`, in path order.
fn scanExtensionDirectory(allocator: Allocator, scratch: Allocator, absolute: []const u8, contributions: Contributions) !void {
    var dir = std.Io.Dir.cwd().openDir(time_compat.io, absolute, .{ .iterate = true }) catch return;
    defer dir.close(time_compat.io);

    var children = std.array_list.Managed([]const u8).init(scratch);
    var iterator = dir.iterate();
    while (try iterator.next(time_compat.io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const child = try std.fs.path.join(scratch, &.{ absolute, entry.name });
        const manifest_path = try std.fs.path.join(scratch, &.{ child, "package.json" });
        std.Io.Dir.cwd().access(time_compat.io, manifest_path, .{}) catch continue;
        try children.append(child);
    }
    // Keep the scan deterministic even though directory iteration order is
    // filesystem-specific. Upstream sorts scanned extensions by location.
    std.mem.sort([]const u8, children.items, {}, lessThanPath);
    for (children.items) |child| {
        _ = try scanExtensionRoot(allocator, scratch, child, contributions);
    }
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
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

fn hasEngines(object: std.json.ObjectMap) bool {
    const engines = object.get("engines") orelse return false;
    if (engines != .object) return false;
    return engines.object.get("vscode") != null;
}

test "declarative scanner reads markdown-basics and theme-defaults" {
    const allocator = std.testing.allocator;
    var registry = try scan(allocator, &.{
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
    var registry = try scan(allocator, &.{"vscode/extensions"});
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
    const io = std.Io.Threaded.global_single_threaded.io();
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
    var registry = try scan(allocator, &.{path_buffer[0..path_len]});
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
    std.Io.Dir.cwd().access(time_compat.io, roots[0], .{}) catch return error.SkipZigTest;
    var registry = try scan(std.testing.allocator, roots);
    defer registry.deinit();
    const included = scopes.forScope(registry.grammars, "source.yaml.1.2") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), included.language.len);
    const markdown = registry.grammarForLanguage("markdown") orelse return error.TestUnexpectedResult;
    try std.testing.expect(markdown.injections.len >= 2);
    for (markdown.injections) |scope| try std.testing.expect(scopes.forScope(registry.grammars, scope) != null);
}
