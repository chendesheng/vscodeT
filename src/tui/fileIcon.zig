//! Terminal file badges.
//!
//! Upstream renders editor tabs and breadcrumbs with a file icon theme
//! (`src/vs/workbench/services/themes/common/fileIconThemeData.ts`). The
//! terminal port has no icon-theme service, so the nearest cell equivalent is a
//! short language badge: two cells for known languages (the reference image
//! shows `JS` beside `http-proxy.js`) and no badge for plain text.
//!
//! This is a TUI-only helper: it is the icon boundary, not a replacement for
//! the file icon theme service. Every other tab/breadcrumb decision stays in
//! the ported layers.

const std = @import("std");
const ui = @import("ui");

/// Returns the badge text for a language id. The result is at most two cells
/// and is a static string owned by this module.
pub fn badge(language_id: []const u8) []const u8 {
    const table = .{
        .{ "javascript", "JS" },
        .{ "typescript", "TS" },
        .{ "javascriptreact", "JX" },
        .{ "typescriptreact", "TX" },
        .{ "zig", "ZG" },
        .{ "python", "PY" },
        .{ "rust", "RS" },
        .{ "go", "GO" },
        .{ "c", "C" },
        .{ "cpp", "C+" },
        .{ "java", "JV" },
        .{ "html", "HT" },
        .{ "css", "CS" },
        .{ "scss", "SC" },
        .{ "markdown", "MD" },
        .{ "yaml", "YM" },
        .{ "toml", "TM" },
        .{ "shellscript", "SH" },
        .{ "json", "{}" },
        .{ "jsonc", "{}" },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, entry[0], language_id)) return entry[1];
    }
    if (std.mem.eql(u8, language_id, "plaintext") or language_id.len == 0) return "";
    return "??";
}

/// Width of a badge in cells. Badges are ASCII, so this is the byte length.
pub fn width(text: []const u8) usize {
    return text.len;
}

/// Paints a badge's text, returning the number of cells written.
pub fn draw(grid: *ui.CellGrid, x: usize, row: usize, text: []const u8, max_cells: usize, style: ui.cell.PaintStyle) usize {
    const visible = @min(width(text), max_cells);
    var col: usize = 0;
    while (col < visible) : (col += 1) {
        grid.putCodepoint(x + col, row, text[col], 1, style);
    }
    return visible;
}

test "fileIcon: badges" {
    try std.testing.expectEqualStrings("JS", badge("javascript"));
    try std.testing.expectEqualStrings("TS", badge("typescript"));
    try std.testing.expectEqualStrings("ZG", badge("zig"));
    try std.testing.expectEqualStrings("{}", badge("json"));
    try std.testing.expectEqualStrings("", badge("plaintext"));
    try std.testing.expectEqualStrings("??", badge("a-b?"));
    try std.testing.expectEqual(@as(usize, 2), width("JS"));
}
