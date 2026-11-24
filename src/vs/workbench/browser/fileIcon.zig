// Terminal file icons for the Explorer, editor tabs and the breadcrumb row.
//
// VS Code renders file icon themes (`workbench.iconTheme`, Seti by default) as
// SVG images. The terminal has no image layer, so this module is the terminal
// adaptation documented in `README.md`: Nerd Font glyphs in the private-use
// area, chosen by file name/extension and painted with the icon's dominant
// color. A Nerd Font must be configured in the terminal; without one the
// private-use cells render blank or as a fallback box.
//
// The glyph table follows the Nerd Fonts / Seti codepoints used by common
// terminal file managers. Folder icons match VS Code's folder/file icon
// distinction; the Explorer still paints its own twistie before the icon. The
// editor tab header and the breadcrumb file segment call the same table, so
// one file shows the same glyph and color in all three places.

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

const registry = @import("../services/extensions/common/extensionsRegistry.zig");
const glyphs = @import("setiGlyphs.zig").byName;
const Color = @import("../../base/common/color.zig").Color;

pub const Appearance = struct {
    catalog: ?*const registry.Registry = null,
    theme: ?std.json.Value = null,
    variant: []const u8 = "",
    foreground: ui.Color = default_file_color,
    disabled: bool = false,

    pub fn init(catalog: ?*const registry.Registry, id: ?[]const u8, variant: []const u8, foreground: ui.Color) Appearance {
        const selected = id orelse return .{ .disabled = true };
        const available = catalog orelse return .{};
        var index = available.icon_themes.len;
        while (index > 0) {
            index -= 1;
            const theme = available.icon_themes[index];
            if (std.mem.eql(u8, selected, theme.id)) return .{ .catalog = available, .theme = theme.data, .variant = variant, .foreground = foreground };
        }
        return .{};
    }

    fn association(self: Appearance, group: []const u8, key: ?[]const u8) ?[]const u8 {
        const theme = self.theme orelse return null;
        if (field(theme, self.variant)) |variant| {
            if (associationIn(variant, group, key)) |match| return match;
        }
        return associationIn(theme, group, key);
    }

    fn definition(self: Appearance, id: []const u8, fallback: Icon) Icon {
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

    pub fn forFile(self: Appearance, name: []const u8, language_id: ?[]const u8) Icon {
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

    fn languageForName(self: Appearance, name: []const u8) ?[]const u8 {
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

    pub fn forFolder(self: Appearance, name: []const u8, expanded: bool) Icon {
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
    const io = @import("../../base/common/timeCompat.zig").io;
    std.Io.Dir.cwd().access(io, "vscode/extensions/theme-modern-icons/package.json", .{}) catch return error.SkipZigTest;
    var catalog = try registry.scan(allocator, &.{
        "vscode/extensions/theme-seti", "vscode/extensions/theme-modern-icons", "vscode/extensions/javascript",
    });
    defer catalog.deinit();
    const seti = Appearance.init(&catalog, "vs-seti", "", default_file_color);
    const modern = Appearance.init(&catalog, "vscode-modern-icons", "", default_file_color);
    const light = Appearance.init(&catalog, "vs-seti", "light", default_file_color);
    const icon = seti.forFile("README.md", "markdown");
    try std.testing.expectEqual(@as(u21, 0xE66A), icon.glyph);
    try std.testing.expectEqual(ui.Color{ .r = 0x51, .g = 0x9A, .b = 0xBA }, icon.color);
    try std.testing.expectEqual(ui.Color{ .r = 0x49, .g = 0x8B, .b = 0xA7 }, light.forFile("README.md", "markdown").color);
    try std.testing.expectEqual(@as(u21, 0xE60C), seti.forFile("client.js", null).glyph);
    try std.testing.expectEqual(icon.glyph, modern.forFile("README.md", null).glyph);
    try std.testing.expectEqual(default_file_color, modern.forFile("README.md", null).color);
    try std.testing.expect(Appearance.init(&catalog, null, "", default_file_color).disabled);
}
