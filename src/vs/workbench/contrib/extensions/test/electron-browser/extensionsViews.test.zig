// Port of the local-extension query cases from
// `src/vs/workbench/contrib/extensions/test/electron-browser/extensionsViews.test.ts`.
//
// Terminal adaptation: the terminal has one combined list, so `@enabled` and
// `@disabled` report local enablement across installed and built-in entries
// (upstream's version compares against the running-extension list), and
// user-installed entries sort before built-ins. Gallery, recommendation and
// paging cases are not portable and are not ported.
const std = @import("std");
const views = @import("../../browser/extensionsViews.zig");
const model = @import("../../common/extensions.zig");
const IExtension = model.IExtension;
const testing = std.testing;

const themes_upper = [_][]const u8{"Themes"};
const themes_lower = [_][]const u8{"themes"};
const programming_upper = [_][]const u8{"Programming languages"};
const programming_lower = [_][]const u8{"programming languages"};
const random_category = [_][]const u8{"random"};
const no_categories = [_][]const u8{};

fn extension(
    identifier: []const u8,
    display_name: []const u8,
    categories: []const []const u8,
    enabled: bool,
    builtin: bool,
) IExtension {
    return .{
        .identifier = identifier,
        .name = identifier,
        .display_name = display_name,
        .description = "",
        .version = "1.0.0",
        .publisher = "pub",
        .categories = categories,
        .location = identifier,
        .is_builtin = builtin,
        .enablement_state = if (enabled) .EnabledGlobally else .DisabledGlobally,
    };
}

const local_extensions = [_]IExtension{
    extension("pub.first-enabled-extension", "first-enabled-extension", &themes_upper, true, false),
    extension("pub.second-enabled-extension", "second-enabled-extension", &programming_upper, true, false),
    extension("pub.first-disabled-extension", "first-disabled-extension", &themes_lower, false, false),
    extension("pub.second-disabled-extension", "second-disabled-extension", &programming_lower, false, false),
    extension("pub.random-enabled-extension", "random-enabled-extension", &random_category, true, false),
    extension("pub.my-theme", "my-theme", &themes_upper, true, true),
    extension("pub.my-lang", "my-lang", &programming_upper, true, true),
};

fn expectNames(query: []const u8, expected: []const []const u8) !void {
    const allocator = testing.allocator;
    const filtered = try views.filterExtensions(allocator, &local_extensions, query);
    defer allocator.free(filtered);
    try testing.expectEqual(expected.len, filtered.len);
    for (expected, filtered) |name, entry| {
        try testing.expectEqualStrings(name, entry.display_name);
    }
}

test "Test installed query results" {
    try expectNames("@installed", &.{
        "first-disabled-extension",
        "first-enabled-extension",
        "random-enabled-extension",
        "second-disabled-extension",
        "second-enabled-extension",
    });
    try expectNames("@installed first", &.{
        "first-disabled-extension",
        "first-enabled-extension",
    });
    try expectNames("@disabled", &.{
        "first-disabled-extension",
        "second-disabled-extension",
    });
    try expectNames("@enabled", &.{
        "first-enabled-extension",
        "random-enabled-extension",
        "second-enabled-extension",
        "my-lang",
        "my-theme",
    });
    try expectNames("@builtin", &.{ "my-lang", "my-theme" });
    try expectNames("@builtin my-theme", &.{"my-theme"});
    try expectNames("second", &.{ "second-disabled-extension", "second-enabled-extension" });
}

test "Test builtin category queries" {
    try expectNames("@builtin category:themes", &.{"my-theme"});
    try expectNames("@builtin category:\"programming languages\"", &.{"my-lang"});
    try expectNames("category:themes", &.{
        "first-disabled-extension",
        "first-enabled-extension",
        "my-theme",
    });
}

test "Test id query" {
    try expectNames("@id:pub.second-disabled-extension", &.{"second-disabled-extension"});
    try expectNames("@id:PUB.SECOND-disabled-EXTENSION", &.{"second-disabled-extension"});
}

test "Test combined enabled and disabled query is empty" {
    try expectNames("@enabled @disabled", &.{});
    try expectNames("@installed @disabled", &.{
        "first-disabled-extension",
        "second-disabled-extension",
    });
}

test "Test unknown gallery query matches as text" {
    try expectNames("@outdated", &.{});
}

test "Test installed extensions sort before built-ins" {
    const allocator = testing.allocator;
    const entries = [_]IExtension{
        extension("pub.aaa-builtin", "aaa-builtin", &no_categories, true, true),
        extension("pub.zzz-user", "zzz-user", &no_categories, true, false),
    };
    const filtered = try views.filterExtensions(allocator, &entries, "");
    defer allocator.free(filtered);
    try testing.expectEqual(@as(usize, 2), filtered.len);
    try testing.expectEqualStrings("zzz-user", filtered[0].display_name);
    try testing.expectEqualStrings("aaa-builtin", filtered[1].display_name);
}

test "Sort token keeps installed display-name order and built-ins have a separate query" {
    // VS Code's filterInstalledExtensions excludes built-ins when a
    // sort is specified. The explicit builtin query still sorts them.
    try expectNames("@sort:name", &.{
        "first-disabled-extension",
        "first-enabled-extension",
        "random-enabled-extension",
        "second-disabled-extension",
        "second-enabled-extension",
    });
    try expectNames("@builtin @sort:name", &.{ "my-lang", "my-theme" });
}

test "Test description text matches" {
    const allocator = testing.allocator;
    var entries = [_]IExtension{
        extension("pub.one", "one", &no_categories, true, false),
    };
    entries[0].description = "Provides snippets and syntax highlighting";
    const filtered = try views.filterExtensions(allocator, &entries, "snippets");
    defer allocator.free(filtered);
    try testing.expectEqual(@as(usize, 1), filtered.len);
}

test "Sort-only query selects installed extensions by update date" {
    const allocator = testing.allocator;
    var entries = [_]IExtension{
        extension("pub.first", "First", &no_categories, true, false),
        extension("pub.second", "Second", &no_categories, true, false),
        extension("pub.builtin", "Builtin", &no_categories, true, true),
    };
    entries[0].installed_timestamp = 100;
    entries[1].installed_timestamp = 200;
    entries[2].installed_timestamp = 300;
    const filtered = try views.filterExtensions(allocator, &entries, "@sort:updateDate");
    defer allocator.free(filtered);
    try testing.expectEqual(@as(usize, 2), filtered.len);
    try testing.expectEqualStrings("pub.second", filtered[0].identifier);
    try testing.expectEqualStrings("pub.first", filtered[1].identifier);
}

test "Extension list pre-release bookmark does not replace the extension icon" {
    const ui = @import("ui");
    const list_renderer = @import("../../browser/extensionsList.zig");
    const widgets = @import("../../browser/extensionsWidgets.zig");
    var grid = try ui.CellGrid.init(testing.allocator, 24, 3);
    defer grid.deinit();
    const row: @import("../../../../../base/browser/ui/list/list.zig").Row = .{
        .grid = &grid,
        .x = 0,
        .y = 0,
        .width = 24,
        .height = 3,
        .index = 0,
        .selected = false,
        .focused = false,
        .focused_selection = false,
    };
    var entry = extension("redhat.vscode-yaml", "YAML", &no_categories, true, false);
    entry.has_pre_release = true;
    // An installed stable version with a pre-release available still uses
    // the ordinary icon and has no bookmark.
    list_renderer.renderRow(&grid, &row, &entry, list_renderer.colors(null), .{});
    try testing.expectEqual(@as(u32, list_renderer.extension_glyph), grid.cluster[0]);
    try testing.expect(grid.cluster[grid.cols] != widgets.PreReleaseBookmarkWidget.glyph);

    // The bookmark is separate for an installed pre-release version.
    grid.clear();
    entry.is_pre_release = true;
    list_renderer.renderRow(&grid, &row, &entry, list_renderer.colors(null), .{});
    try testing.expectEqual(@as(u32, list_renderer.extension_glyph), grid.cluster[0]);
    try testing.expectEqual(@as(u32, widgets.PreReleaseBookmarkWidget.glyph), grid.cluster[grid.cols]);

    // Gallery extensions advertise available pre-release versions.
    grid.clear();
    entry.state = .Uninstalled;
    entry.is_pre_release = false;
    list_renderer.renderRow(&grid, &row, &entry, list_renderer.colors(null), .{});
    try testing.expectEqual(@as(u32, list_renderer.extension_glyph), grid.cluster[0]);
    try testing.expectEqual(@as(u32, widgets.PreReleaseBookmarkWidget.glyph), grid.cluster[grid.cols]);
}
