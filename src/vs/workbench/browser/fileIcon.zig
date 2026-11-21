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
