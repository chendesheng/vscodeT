// File associations from `src/vs/workbench/services/themes/browser/fileIconThemeData.ts`.
// The terminal maps icon definitions to Nerd Font glyphs and cell colors.
// File names, compound extensions, language IDs, expanded folders and color
// scheme overrides share the same resolution path for Explorer, tabs and breadcrumbs.

const std = @import("std");
const ui = @import("ui");

pub const Icon = struct {
    glyph: u21,
    color: ui.Color,
};

const folder_color = ui.Color{ .r = 0xDC, .g = 0xB6, .b = 0x7A };
const default_file_color = ui.Color{ .r = 0xB0, .g = 0xB8, .b = 0xC4 };

const Entry = struct {
    extension: []const u8,
    glyph: u21,
    color: ui.Color,
};

const table = [_]Entry{
    .{ .extension = "hs", .glyph = 0xE61F, .color = .{ .r = 0xAA, .g = 0x77, .b = 0xCC } },
    .{ .extension = "zig", .glyph = 0xE6A9, .color = .{ .r = 0xF7, .g = 0xA4, .b = 0x1D } },
    .{ .extension = "js", .glyph = 0xE781, .color = .{ .r = 0xF1, .g = 0xE0, .b = 0x5A } },
    .{ .extension = "mjs", .glyph = 0xE781, .color = .{ .r = 0xF1, .g = 0xE0, .b = 0x5A } },
    .{ .extension = "cjs", .glyph = 0xE781, .color = .{ .r = 0xF1, .g = 0xE0, .b = 0x5A } },
    .{ .extension = "jsx", .glyph = 0xE781, .color = .{ .r = 0xF1, .g = 0xE0, .b = 0x5A } },
    .{ .extension = "ts", .glyph = 0xE628, .color = .{ .r = 0x31, .g = 0x78, .b = 0xC6 } },
    .{ .extension = "mts", .glyph = 0xE628, .color = .{ .r = 0x31, .g = 0x78, .b = 0xC6 } },
    .{ .extension = "cts", .glyph = 0xE628, .color = .{ .r = 0x31, .g = 0x78, .b = 0xC6 } },
    .{ .extension = "tsx", .glyph = 0xE628, .color = .{ .r = 0x31, .g = 0x78, .b = 0xC6 } },
    .{ .extension = "json", .glyph = 0xE60B, .color = .{ .r = 0xF1, .g = 0xE0, .b = 0x5A } },
    .{ .extension = "jsonc", .glyph = 0xE60B, .color = .{ .r = 0xF1, .g = 0xE0, .b = 0x5A } },
    .{ .extension = "log", .glyph = 0xF15C, .color = default_file_color },
    .{ .extension = "yaml", .glyph = 0xE6A8, .color = .{ .r = 0xA0, .g = 0x74, .b = 0xC4 } },
    .{ .extension = "yml", .glyph = 0xE6A8, .color = .{ .r = 0xA0, .g = 0x74, .b = 0xC4 } },
    .{ .extension = "md", .glyph = 0xE73E, .color = .{ .r = 0x51, .g = 0x9A, .b = 0xBA } },
    .{ .extension = "markdown", .glyph = 0xE73E, .color = .{ .r = 0x51, .g = 0x9A, .b = 0xBA } },
    .{ .extension = "html", .glyph = 0xE736, .color = .{ .r = 0xE3, .g = 0x4F, .b = 0x26 } },
    .{ .extension = "htm", .glyph = 0xE736, .color = .{ .r = 0xE3, .g = 0x4F, .b = 0x26 } },
    .{ .extension = "css", .glyph = 0xE749, .color = .{ .r = 0x42, .g = 0xA5, .b = 0xF5 } },
    .{ .extension = "scss", .glyph = 0xE749, .color = .{ .r = 0xCF, .g = 0x64, .b = 0x9A } },
    .{ .extension = "less", .glyph = 0xE749, .color = .{ .r = 0x42, .g = 0xA5, .b = 0xF5 } },
    .{ .extension = "py", .glyph = 0xE73C, .color = .{ .r = 0xFF, .g = 0xD4, .b = 0x3B } },
    .{ .extension = "rs", .glyph = 0xE7A8, .color = .{ .r = 0xDE, .g = 0xA5, .b = 0x84 } },
    .{ .extension = "go", .glyph = 0xE627, .color = .{ .r = 0x00, .g = 0xAD, .b = 0xD8 } },
    .{ .extension = "c", .glyph = 0xE61E, .color = .{ .r = 0x59, .g = 0x9E, .b = 0xFF } },
    .{ .extension = "h", .glyph = 0xE61E, .color = .{ .r = 0x59, .g = 0x9E, .b = 0xFF } },
    .{ .extension = "cc", .glyph = 0xE61D, .color = .{ .r = 0x59, .g = 0x9E, .b = 0xFF } },
    .{ .extension = "cpp", .glyph = 0xE61D, .color = .{ .r = 0x59, .g = 0x9E, .b = 0xFF } },
    .{ .extension = "cxx", .glyph = 0xE61D, .color = .{ .r = 0x59, .g = 0x9E, .b = 0xFF } },
    .{ .extension = "hpp", .glyph = 0xE61D, .color = .{ .r = 0x59, .g = 0x9E, .b = 0xFF } },
    .{ .extension = "java", .glyph = 0xE738, .color = .{ .r = 0xCC, .g = 0x3E, .b = 0x44 } },
    .{ .extension = "sh", .glyph = 0xE795, .color = .{ .r = 0x89, .g = 0xE0, .b = 0x51 } },
    .{ .extension = "bash", .glyph = 0xE795, .color = .{ .r = 0x89, .g = 0xE0, .b = 0x51 } },
    .{ .extension = "zsh", .glyph = 0xE795, .color = .{ .r = 0x89, .g = 0xE0, .b = 0x51 } },
    .{ .extension = "fish", .glyph = 0xE795, .color = .{ .r = 0x89, .g = 0xE0, .b = 0x51 } },
    .{ .extension = "lock", .glyph = 0xF023, .color = .{ .r = 0x9E, .g = 0x9E, .b = 0x9E } },
    .{ .extension = "png", .glyph = 0xF1C5, .color = .{ .r = 0xA0, .g = 0x74, .b = 0xC4 } },
    .{ .extension = "jpg", .glyph = 0xF1C5, .color = .{ .r = 0xA0, .g = 0x74, .b = 0xC4 } },
    .{ .extension = "jpeg", .glyph = 0xF1C5, .color = .{ .r = 0xA0, .g = 0x74, .b = 0xC4 } },
    .{ .extension = "gif", .glyph = 0xF1C5, .color = .{ .r = 0xA0, .g = 0x74, .b = 0xC4 } },
    .{ .extension = "svg", .glyph = 0xF1C5, .color = .{ .r = 0xFF, .g = 0xB1, .b = 0x3B } },
    .{ .extension = "pdf", .glyph = 0xF1C1, .color = .{ .r = 0xE5, .g = 0x3D, .b = 0x3D } },
    .{ .extension = "zip", .glyph = 0xF1C6, .color = .{ .r = 0xB0, .g = 0xB8, .b = 0xC4 } },
    .{ .extension = "tar", .glyph = 0xF1C6, .color = .{ .r = 0xB0, .g = 0xB8, .b = 0xC4 } },
    .{ .extension = "gz", .glyph = 0xF1C6, .color = .{ .r = 0xB0, .g = 0xB8, .b = 0xC4 } },
};

const named = [_]struct {
    name: []const u8,
    glyph: u21,
    color: ui.Color,
}{
    .{ .name = ".gitignore", .glyph = 0xE702, .color = .{ .r = 0xF1, .g = 0x4C, .b = 0x26 } },
    .{ .name = ".gitattributes", .glyph = 0xE702, .color = .{ .r = 0xF1, .g = 0x4C, .b = 0x26 } },
    .{ .name = ".gitmodules", .glyph = 0xE702, .color = .{ .r = 0xF1, .g = 0x4C, .b = 0x26 } },
    .{ .name = "Makefile", .glyph = 0xE673, .color = .{ .r = 0x99, .g = 0x99, .b = 0x99 } },
    .{ .name = "makefile", .glyph = 0xE673, .color = .{ .r = 0x99, .g = 0x99, .b = 0x99 } },
    .{ .name = "Dockerfile", .glyph = 0xF308, .color = .{ .r = 0x23, .g = 0x91, .b = 0xE3 } },
    .{ .name = "LICENSE", .glyph = 0xF02D, .color = .{ .r = 0xD0, .g = 0xBF, .b = 0x8F } },
    .{ .name = "LICENSE.md", .glyph = 0xF02D, .color = .{ .r = 0xD0, .g = 0xBF, .b = 0x8F } },
};

pub fn folder(expanded: bool) Icon {
    return .{
        .glyph = if (expanded) 0xF07C else 0xF07B,
        .color = folder_color,
    };
}

/// Picks the Nerd Font glyph for a file name. Unknown types use the generic
/// file glyph; the name match is case-sensitive only for the well-known,
/// capitalised names above.
pub fn file(name: []const u8) Icon {
    for (named) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return .{ .glyph = entry.glyph, .color = entry.color };
    }

    const extension = std.fs.path.extension(name);
    const normalized = std.mem.trimStart(u8, extension, ".");
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(normalized, entry.extension)) {
            return .{ .glyph = entry.glyph, .color = entry.color };
        }
    }
    return .{ .glyph = 0xF15B, .color = default_file_color };
}

/// Picks the icon for a path using its base name. Editor tabs and breadcrumbs
/// carry resource paths, while the Explorer table is keyed by file name.
pub fn forPath(path: []const u8) Icon {
    return file(std.fs.path.basename(path));
}

test "fileIcon: folders and common extensions use Nerd Font glyphs" {
    try std.testing.expectEqual(@as(u21, 0xF07B), folder(false).glyph);
    try std.testing.expectEqual(@as(u21, 0xF07C), folder(true).glyph);

    try std.testing.expectEqual(@as(u21, 0xE6A9), file("main.zig").glyph);
    try std.testing.expectEqual(@as(u21, 0xE781), file("app.JS").glyph);
    try std.testing.expectEqual(@as(u21, 0xE628), file("index.tsx").glyph);
    try std.testing.expectEqual(@as(u21, 0xE60B), file("settings.json").glyph);
    try std.testing.expectEqual(@as(u21, 0xE73E), file("README.md").glyph);
    try std.testing.expectEqual(@as(u21, 0xE702), file(".gitignore").glyph);
    try std.testing.expectEqual(@as(u21, 0xF023), file("Cargo.lock").glyph);
    try std.testing.expectEqual(@as(u21, 0xF15B), file("notes.unknown").glyph);
    try std.testing.expectEqual(@as(u21, 0xF15B), file("LICENSE-MIT").glyph);

    try std.testing.expectEqual(@as(u21, 0xE6A9), forPath("/repo/src/main.zig").glyph);
    try std.testing.expectEqual(@as(u21, 0xE73E), forPath("/repo/README.md").glyph);
    try std.testing.expectEqual(@as(u21, 0xF15B), forPath("/repo/notes.unknown").glyph);
}

const registry = @import("../../extensions/common/extensionsRegistry.zig");
// Seti Unicode assignments from Nerd Fonts v3.4.0 glyphnames.json.
// https://github.com/ryanoasis/nerd-fonts/blob/v3.4.0/glyphnames.json

const glyphs = std.StaticStringMap(u21).initComptime(.{
    .{ "apple", 0xE635 },
    .{ "argdown", 0xE636 },
    .{ "asm", 0xE637 },
    .{ "audio", 0xE638 },
    .{ "babel", 0xE639 },
    .{ "bazel", 0xE63A },
    .{ "bicep", 0xE63B },
    .{ "bower", 0xE61A },
    .{ "bsl", 0xE63C },
    .{ "c", 0xE649 },
    .{ "c_sharp", 0xE648 },
    .{ "cake", 0xE63E },
    .{ "cake_php", 0xE63D },
    .{ "checkbox", 0xE63F },
    .{ "checkbox_unchecked", 0xE640 },
    .{ "cjsx", 0xE61B },
    .{ "clock", 0xE641 },
    .{ "clojure", 0xE642 },
    .{ "code_climate", 0xE643 },
    .{ "code_search", 0xE644 },
    .{ "coffee", 0xE61B },
    .{ "coldfusion", 0xE645 },
    .{ "config", 0xE615 },
    .{ "cpp", 0xE646 },
    .{ "crystal", 0xE62F },
    .{ "crystal_embedded", 0xE647 },
    .{ "css", 0xE614 },
    .{ "csv", 0xE64A },
    .{ "cu", 0xE64B },
    .{ "d", 0xE651 },
    .{ "dart", 0xE64C },
    .{ "db", 0xE64D },
    .{ "default", 0xE64E },
    .{ "deprecation_cop", 0xE64F },
    .{ "docker", 0xE650 },
    .{ "editorconfig", 0xE652 },
    .{ "ejs", 0xE618 },
    .{ "elixir", 0xE62D },
    .{ "elixir_script", 0xE653 },
    .{ "elm", 0xE62C },
    .{ "error", 0xE654 },
    .{ "eslint", 0xE655 },
    .{ "ethereum", 0xE656 },
    .{ "f_sharp", 0xE65A },
    .{ "favicon", 0xE623 },
    .{ "firebase", 0xE657 },
    .{ "firefox", 0xE658 },
    .{ "folder", 0xE613 },
    .{ "font", 0xE659 },
    .{ "git", 0xE65D },
    .{ "git_folder", 0xE65D },
    .{ "git_ignore", 0xE65D },
    .{ "github", 0xE65B },
    .{ "gitlab", 0xE65C },
    .{ "go", 0xE627 },
    .{ "go2", 0xE65E },
    .{ "godot", 0xE65F },
    .{ "gradle", 0xE660 },
    .{ "grails", 0xE661 },
    .{ "graphql", 0xE662 },
    .{ "grunt", 0xE611 },
    .{ "gulp", 0xE610 },
    .{ "hacklang", 0xE663 },
    .{ "haml", 0xE664 },
    .{ "happenings", 0xE665 },
    .{ "haskell", 0xE61F },
    .{ "haxe", 0xE666 },
    .{ "heroku", 0xE607 },
    .{ "hex", 0xE667 },
    .{ "home", 0xE617 },
    .{ "html", 0xE60E },
    .{ "ignored", 0xE668 },
    .{ "illustrator", 0xE669 },
    .{ "image", 0xE60D },
    .{ "info", 0xE66A },
    .{ "ionic", 0xE66B },
    .{ "jade", 0xE66C },
    .{ "java", 0xE66D },
    .{ "javascript", 0xE60C },
    .{ "jenkins", 0xE66E },
    .{ "jinja", 0xE66F },
    .{ "json", 0xE60B },
    .{ "julia", 0xE624 },
    .{ "karma", 0xE622 },
    .{ "kotlin", 0xE634 },
    .{ "less", 0xE60B },
    .{ "license", 0xE60A },
    .{ "liquid", 0xE670 },
    .{ "livescript", 0xE671 },
    .{ "lock", 0xE672 },
    .{ "lua", 0xE620 },
    .{ "makefile", 0xE673 },
    .{ "markdown", 0xE609 },
    .{ "maven", 0xE674 },
    .{ "mdo", 0xE675 },
    .{ "mustache", 0xE60F },
    .{ "new_file", 0xE676 },
    .{ "nim", 0xE677 },
    .{ "notebook", 0xE678 },
    .{ "npm", 0xE616 },
    .{ "npm_ignored", 0xE616 },
    .{ "nunjucks", 0xE679 },
    .{ "ocaml", 0xE67A },
    .{ "odata", 0xE67B },
    .{ "pddl", 0xE67C },
    .{ "pdf", 0xE67D },
    .{ "perl", 0xE67E },
    .{ "photoshop", 0xE67F },
    .{ "php", 0xE608 },
    .{ "pipeline", 0xE680 },
    .{ "plan", 0xE681 },
    .{ "platformio", 0xE682 },
    .{ "play_arrow", 0xE602 },
    .{ "powershell", 0xE683 },
    .{ "prisma", 0xE684 },
    .{ "project", 0xE601 },
    .{ "prolog", 0xE685 },
    .{ "pug", 0xE686 },
    .{ "puppet", 0xE631 },
    .{ "purescript", 0xE630 },
    .{ "python", 0xE606 },
    .{ "r", 0xE68A },
    .{ "rails", 0xE604 },
    .{ "react", 0xE625 },
    .{ "reasonml", 0xE687 },
    .{ "rescript", 0xE688 },
    .{ "rollup", 0xE689 },
    .{ "ruby", 0xE605 },
    .{ "rust", 0xE68B },
    .{ "salesforce", 0xE68C },
    .{ "sass", 0xE603 },
    .{ "sbt", 0xE68D },
    .{ "scala", 0xE68E },
    .{ "search", 0xE68F },
    .{ "settings", 0xE690 },
    .{ "shell", 0xE691 },
    .{ "slim", 0xE692 },
    .{ "smarty", 0xE693 },
    .{ "spring", 0xE694 },
    .{ "stylelint", 0xE695 },
    .{ "stylus", 0xE600 },
    .{ "sublime", 0xE696 },
    .{ "svelte", 0xE697 },
    .{ "svg", 0xE698 },
    .{ "swift", 0xE699 },
    .{ "terraform", 0xE69A },
    .{ "tex", 0xE69B },
    .{ "text", 0xE64E },
    .{ "time_cop", 0xE641 },
    .{ "todo", 0xE69C },
    .{ "tsconfig", 0xE69D },
    .{ "twig", 0xE61C },
    .{ "typescript", 0xE628 },
    .{ "vala", 0xE69E },
    .{ "video", 0xE69F },
    .{ "vue", 0xE6A0 },
    .{ "wasm", 0xE6A1 },
    .{ "wat", 0xE6A2 },
    .{ "webpack", 0xE6A3 },
    .{ "wgt", 0xE6A4 },
    .{ "word", 0xE6A5 },
    .{ "xls", 0xE6A6 },
    .{ "xml", 0xE619 },
    .{ "yarn", 0xE6A7 },
    .{ "yml", 0xE6A8 },
    .{ "zig", 0xE6A9 },
    .{ "zip", 0xE6AA },
});
const Color = @import("../../../../base/common/color.zig").Color;

pub const FileIconThemeData = struct {
    catalog: ?*const registry.Registry = null,
    settings_id: ?[]const u8 = null,
    theme: ?std.json.Value = null,
    variant: []const u8 = "",
    foreground: ui.Color = default_file_color,
    disabled: bool = false,

    pub fn init(catalog: ?*const registry.Registry, id: ?[]const u8, variant: []const u8, foreground: ui.Color) FileIconThemeData {
        const selected = id orelse return .{ .disabled = true };
        const available = catalog orelse return .{};
        var index = available.icon_themes.len;
        while (index > 0) {
            index -= 1;
            const theme = available.icon_themes[index];
            if (std.mem.eql(u8, selected, theme.id)) return .{ .catalog = available, .settings_id = theme.id, .theme = theme.data, .variant = variant, .foreground = foreground };
        }
        return .{};
    }

    fn association(self: FileIconThemeData, group: []const u8, key: ?[]const u8) ?[]const u8 {
        const theme = self.theme orelse return null;
        if (field(theme, self.variant)) |variant| {
            if (associationIn(variant, group, key)) |match| return match;
        }
        return associationIn(theme, group, key);
    }

    fn definition(self: FileIconThemeData, id: []const u8, fallback: Icon) Icon {
        const definitions = field(self.theme.?, "iconDefinitions") orelse return fallback;
        const def = field(definitions, id) orelse return fallback;
        const hex = field(def, "fontColor");
        const color = if (hex != null and hex.? == .string) Color.fromHex(hex.?.string) catch null else null;
        var symbol = std.mem.trimStart(u8, id, "_");
        if (std.mem.endsWith(u8, symbol, "_light")) symbol = symbol[0 .. symbol.len - 6];
        if (std.mem.lastIndexOfScalar(u8, symbol, '_')) |i| {
            if (i + 1 < symbol.len and std.ascii.isDigit(symbol[i + 1])) symbol = symbol[0..i];
        }
        var buf: [128]u8 = undefined;
        const glyph = if (symbol.len <= buf.len) blk: {
            const normalized = std.ascii.lowerString(&buf, symbol);
            for (normalized) |*byte| if (byte.* == '-') {
                byte.* = '_';
            };
            break :blk glyphs.get(normalized) orelse fallback.glyph;
        } else fallback.glyph;
        return .{ .glyph = glyph, .color = if (color) |c| .{ .r = c.r, .g = c.g, .b = c.b } else self.foreground };
    }

    pub fn forFile(self: FileIconThemeData, name: []const u8, language_id: ?[]const u8) Icon {
        const fallback = file(name);
        if (self.theme == null) return fallback;
        var buf: [1024]u8 = undefined;
        if (name.len > buf.len) return fallback;
        const key = std.ascii.lowerString(&buf, name);
        if (self.association("fileNames", key)) |id| return self.definition(id, fallback);
        var suffix = key;
        while (std.mem.indexOfScalar(u8, suffix, '.')) |i| {
            suffix = suffix[i + 1 ..];
            if (self.association("fileExtensions", suffix)) |id| return self.definition(id, fallback);
        }
        const language = language_id orelse self.languageForName(name);
        if (language) |lang| {
            if (self.association("languageIds", lang)) |id| return self.definition(id, fallback);
        }
        return self.definition(self.association("file", null) orelse return fallback, file(""));
    }

    fn languageForName(self: FileIconThemeData, name: []const u8) ?[]const u8 {
        const catalog = self.catalog orelse return null;
        var language: ?[]const u8 = null;
        var length: usize = 0;
        for (catalog.languages) |contribution| {
            for (contribution.filenames) |filename| {
                if (std.ascii.eqlIgnoreCase(name, filename)) return contribution.id;
            }
            for (contribution.extensions) |ext| {
                if (ext.len > length and std.ascii.endsWithIgnoreCase(name, ext)) {
                    length = ext.len;
                    language = contribution.id;
                }
            }
        }
        return language;
    }

    pub fn forFolder(self: FileIconThemeData, name: []const u8, expanded: bool) Icon {
        const fallback = folder(expanded);
        if (self.theme == null) return fallback;
        var buf: [1024]u8 = undefined;
        if (name.len > buf.len) return fallback;
        const key = std.ascii.lowerString(&buf, name);
        const id = self.association(if (expanded) "folderNamesExpanded" else "folderNames", key) orelse
            self.association(if (expanded) "folderExpanded" else "folder", null) orelse return fallback;
        return self.definition(id, fallback);
    }
};

fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}

fn associationIn(value: std.json.Value, group: []const u8, key: ?[]const u8) ?[]const u8 {
    const map = field(value, group) orelse return null;
    const id = if (key) |k| field(map, k) orelse return null else map;
    return if (id == .string) id.string else null;
}

test "fileIcon: shipped names override language mappings and color variants" {
    const allocator = std.testing.allocator;
    const io = @import("../../../../base/common/timeCompat.zig").io;
    std.Io.Dir.cwd().access(io, "vscode/extensions/theme-modern-icons/package.json", .{}) catch return error.SkipZigTest;
    var catalog = try registry.scan(allocator, &.{
        "vscode/extensions/theme-seti", "vscode/extensions/theme-modern-icons", "vscode/extensions/javascript",
    });
    defer catalog.deinit();
    const seti = FileIconThemeData.init(&catalog, "vs-seti", "", default_file_color);
    const modern = FileIconThemeData.init(&catalog, "vscode-modern-icons", "", default_file_color);
    const light = FileIconThemeData.init(&catalog, "vs-seti", "light", default_file_color);
    const icon = seti.forFile("README.md", "markdown");
    try std.testing.expectEqual(@as(u21, 0xE66A), icon.glyph);
    try std.testing.expectEqual(ui.Color{ .r = 0x51, .g = 0x9A, .b = 0xBA }, icon.color);
    try std.testing.expectEqual(ui.Color{ .r = 0x49, .g = 0x8B, .b = 0xA7 }, light.forFile("README.md", "markdown").color);
    try std.testing.expectEqual(@as(u21, 0xE60C), seti.forFile("client.js", null).glyph);
    try std.testing.expectEqual(icon.glyph, modern.forFile("README.md", null).glyph);
    try std.testing.expectEqual(default_file_color, modern.forFile("README.md", null).color);
    try std.testing.expect(FileIconThemeData.init(&catalog, null, "", default_file_color).disabled);
}
