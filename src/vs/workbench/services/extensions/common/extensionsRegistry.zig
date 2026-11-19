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

pub const Grammar = struct {
    root: []const u8,
    language: []const u8,
    scope: []const u8,
    path: []const u8,
};

pub const Theme = struct {
    root: []const u8,
    id: []const u8,
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

    pub fn language(self: *const Registry, id: []const u8) ?Language {
        for (self.languages) |item| {
            if (std.mem.eql(u8, item.id, id)) return item;
        }
        return null;
    }

    pub fn grammarForLanguage(self: *const Registry, id: []const u8) ?Grammar {
        for (self.grammars) |item| {
            if (std.mem.eql(u8, item.language, id)) return item;
        }
        return null;
    }

    pub fn theme(self: *const Registry, id: []const u8) ?Theme {
        for (self.themes) |item| {
            if (std.mem.eql(u8, item.id, id)) return item;
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

/// Scans `roots`, keeping only directories that contain a `package.json`.
/// Missing roots and invalid manifests are skipped: a bundled fixture may be
/// absent in a checkout without `../vscode`.
pub fn scan(allocator: Allocator, roots: []const []const u8) !Registry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const scratch = arena.allocator();

    var extensions = std.array_list.Managed(Extension).init(scratch);
    var languages = std.array_list.Managed(Language).init(scratch);
    var grammars = std.array_list.Managed(Grammar).init(scratch);
    var themes = std.array_list.Managed(Theme).init(scratch);
    var snippets = std.array_list.Managed(Snippet).init(scratch);

    for (roots) |root| {
        const absolute = std.Io.Dir.cwd().realPathFileAlloc(time_compat.io, root, allocator) catch continue;
        defer allocator.free(absolute);
        const manifest_path = try std.fs.path.join(allocator, &.{ absolute, "package.json" });
        defer allocator.free(manifest_path);
        const text = std.Io.Dir.cwd().readFileAlloc(time_compat.io, manifest_path, allocator, .unlimited) catch continue;
        defer allocator.free(text);
        const sanitized = configuration_models.stripJsonc(allocator, text) catch continue;
        defer allocator.free(sanitized);
        const value = std.json.parseFromSliceLeaky(std.json.Value, scratch, sanitized, .{}) catch continue;
        if (value != .object) continue;
        const object = value.object;

        const name = stringField(object, "name") orelse continue;
        const version = stringField(object, "version") orelse continue;
        if (!hasEngines(object)) continue;
        const publisher = stringField(object, "publisher") orelse "undefined_publisher";
        const identifier = try std.fmt.allocPrint(scratch, "{s}.{s}@{s}", .{ publisher, name, version });
        const root_copy = try scratch.dupe(u8, absolute);
        try extensions.append(.{ .root = root_copy, .identifier = identifier, .is_builtin = true });

        const contributes = object.get("contributes") orelse continue;
        if (contributes != .object) continue;
        const points = contributes.object;

        if (points.get("languages")) |items| {
            if (items == .array) {
                for (items.array.items) |item| {
                    if (item != .object) continue;
                    const language = item.object;
                    const id = stringField(language, "id") orelse continue;
                    try languages.append(.{
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
                    const language = stringField(grammar, "language") orelse continue;
                    const scope = stringField(grammar, "scopeName") orelse continue;
                    const path = stringField(grammar, "path") orelse continue;
                    try grammars.append(.{
                        .root = root_copy,
                        .language = try scratch.dupe(u8, language),
                        .scope = try scratch.dupe(u8, scope),
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
                    try themes.append(.{
                        .root = root_copy,
                        .id = try scratch.dupe(u8, stringField(theme, "id") orelse path),
                        .label = try scratch.dupe(u8, stringField(theme, "label") orelse ""),
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
                    try snippets.append(.{
                        .root = root_copy,
                        .language = try scratch.dupe(u8, language),
                        .path = try scratch.dupe(u8, path),
                    });
                }
            }
        }
    }

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
        "../vscode/extensions/markdown-basics",
        "../vscode/extensions/theme-defaults",
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
