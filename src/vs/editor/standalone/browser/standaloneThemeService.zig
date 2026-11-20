//! Loads VS Code's Dark+ token colors for TextMate tokenization.
//!
//! The primary path goes through the ported workbench theme service
//! (`initFromThemeService`): `ColorThemeData` loads `dark_plus.json` and its
//! `dark_vs.json` include through a bundled-assets resource reader, and its
//! token colors are converted into the editor `TokenTheme`. The legacy
//! `init` below remains as a fallback loader; it reads the rules from the
//! upstream checkout's
//! `theme-defaults/themes/dark_plus.json` and its `dark_vs.json` include. They
//! are resolved by the editor's `TokenTheme` (the VS Code tokenization port),
//! which keeps the scope inheritance, font styles and color map. The TUI paints
//! token colors through `TokenizationRegistry`'s color map.
//!
//! VS Code's theme files are JSONC; they are sanitized before parsing. Scope
//! selectors that combine a parent scope and a target (`a b`) or exclude a
//! scope (`a - b`) are reduced to their target scope because the ported trie
//! matches one scope at a time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assets = @import("vscode-syntax");
const tokenization = @import("../../common/languages/supports/tokenization.zig");
const TokenTheme = tokenization.TokenTheme;
const ITokenThemeRule = tokenization.ITokenThemeRule;
const stripJsonc = @import("../../../platform/configuration/common/configurationModels.zig").stripJsonc;
const TokenizationRegistry = @import("../../common/tokenizationRegistry.zig").TokenizationRegistry;
const Color = @import("../../../base/common/color.zig").Color;
const color_utils = @import("../../../platform/theme/common/colorUtils.zig");
const theme_service_mod = @import("../../../workbench/services/themes/browser/workbenchThemeService.zig");
const color_theme_mod = @import("../../../workbench/services/themes/common/colorThemeData.zig");
const theme_mod = @import("../../../platform/theme/common/theme.zig");
const time_compat = @import("../../../base/common/timeCompat.zig");

pub const SyntaxTheme = struct {
    theme: TokenTheme = undefined,

    pub fn init(self: *SyntaxTheme, allocator: Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        var rules = std.array_list.Managed(ITokenThemeRule).init(scratch);
        var colors: std.json.ObjectMap = .empty;
        try appendTheme(scratch, "dark_plus.json", &rules, &colors, 0);

        const foreground = colorString(colors, "editor.foreground") orelse "#D4D4D4";
        const background = colorString(colors, "editor.background") orelse "#1E1E1E";
        try rules.append(.{ .token = "", .foreground = foreground, .background = background });

        try self.installTheme(allocator, rules.items);
    }

    /// Builds the token theme from the ported color-theme data instead of the
    /// local JSONC walker. `TokenColor` scopes become one token rule each; the
    /// theme's `editor.foreground`/`editor.background` become the default rule.
    pub fn initFromColorThemeData(self: *SyntaxTheme, allocator: Allocator, theme_data: *color_theme_mod.ColorThemeData) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        var rules = std.array_list.Managed(ITokenThemeRule).init(scratch);
        for (theme_data.getTokenColors()) |token_color| {
            const settings = token_color.settings;
            if (token_color.scope) |scopes| {
                if (scopes.len == 0) {
                    try rules.append(.{
                        .token = "",
                        .foreground = settings.foreground,
                        .background = settings.background,
                        .fontStyle = settings.font_style,
                    });
                    continue;
                }
                for (scopes) |scope| {
                    try rules.append(.{
                        .token = scope,
                        .foreground = settings.foreground,
                        .background = settings.background,
                        .fontStyle = settings.font_style,
                    });
                }
            } else {
                try rules.append(.{
                    .token = "",
                    .foreground = settings.foreground,
                    .background = settings.background,
                    .fontStyle = settings.font_style,
                });
            }
        }

        const foreground = try colorToHex(scratch, theme_data.getColor("editor.foreground", true));
        const background = try colorToHex(scratch, theme_data.getColor("editor.background", true));
        if (foreground != null or background != null) {
            try rules.append(.{ .token = "", .foreground = foreground, .background = background });
        }

        try self.installTheme(allocator, rules.items);
    }

    /// Loads the built-in Dark+ theme through the ported workbench theme
    /// service (including the `dark_vs.json` include).
    pub fn initFromThemeService(self: *SyntaxTheme, allocator: Allocator) !void {
        var registry = color_utils.ColorRegistry.init(allocator);
        defer registry.deinit();
        const service = try theme_service_mod.ThemeService.init(allocator, &registry, null);
        defer service.deinit();
        try service.registerTheme("vs-dark", "Dark (Visual Studio)", .DARK);

        var reader = ThemeAssetReader{};
        try service.setTheme("vs-dark", ThemeAssetReader.interface(&reader), "dark_plus.json");
        try self.initFromColorThemeData(allocator, service.getActiveTheme());
    }

    /// Loads a theme contributed by a declarative extension from its real
    /// files, including `include` chains resolved relative to the extension.
    pub fn initFromThemeFiles(
        self: *SyntaxTheme,
        allocator: Allocator,
        root: []const u8,
        path: []const u8,
        ui_theme: []const u8,
    ) !void {
        var reader = FileThemeReader{ .root = root, .arena = std.heap.ArenaAllocator.init(allocator) };
        defer reader.arena.deinit();

        var registry = color_utils.ColorRegistry.init(allocator);
        defer registry.deinit();
        const service = try theme_service_mod.ThemeService.init(allocator, &registry, null);
        defer service.deinit();
        const scheme: theme_mod.ColorScheme = if (std.mem.eql(u8, ui_theme, "vs"))
            .LIGHT
        else if (std.mem.eql(u8, ui_theme, "hc-black"))
            .HIGH_CONTRAST_DARK
        else if (std.mem.eql(u8, ui_theme, "hc-light"))
            .HIGH_CONTRAST_LIGHT
        else
            .DARK;
        try service.registerTheme("extension-theme", "Extension Theme", scheme);
        try service.setTheme("extension-theme", FileThemeReader.interface(&reader), path);
        try self.initFromColorThemeData(allocator, service.getActiveTheme());
    }

    fn installTheme(self: *SyntaxTheme, allocator: Allocator, rules: []const ITokenThemeRule) !void {
        self.theme = try TokenTheme.createFromRawTokenTheme(allocator, rules, &.{});
        tokenization.setActiveTokenTheme(&self.theme);
        TokenizationRegistry.instance.setColorMap(self.theme.getColorMap());
    }

    pub fn deinit(self: *SyntaxTheme) void {
        tokenization.setActiveTokenTheme(null);
        TokenizationRegistry.instance.clearColorMap();
        self.theme.deinit();
    }
};

/// Serves the bundled VS Code theme assets to the color theme loader.
pub const ThemeAssetReader = struct {
    fn read(_: *anyopaque, path: []const u8) anyerror![]const u8 {
        const name = std.fs.path.basename(path);
        return assets.themeData(name) orelse error.FileNotFound;
    }

    pub fn interface(self: *ThemeAssetReader) color_theme_mod.ResourceReader {
        return .{ .context = self, .read = read };
    }
};

/// Reads theme files and `include` targets relative to an extension root.
const FileThemeReader = struct {
    root: []const u8,
    arena: std.heap.ArenaAllocator,

    fn read(context: *anyopaque, path: []const u8) anyerror![]const u8 {
        const self: *FileThemeReader = @ptrCast(@alignCast(context));
        const arena = self.arena.allocator();
        const full_path = try std.fs.path.join(arena, &.{ self.root, path });
        return std.Io.Dir.cwd().readFileAlloc(time_compat.io, full_path, arena, .unlimited);
    }

    fn interface(self: *FileThemeReader) color_theme_mod.ResourceReader {
        return .{ .context = self, .read = read };
    }
};

fn colorToHex(allocator: Allocator, color: ?Color) !?[]const u8 {
    const value = color orelse return null;
    return try value.toHexString(allocator);
}

fn colorString(colors: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = colors.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn appendTheme(
    allocator: Allocator,
    name: []const u8,
    rules: *std.array_list.Managed(ITokenThemeRule),
    colors: *std.json.ObjectMap,
    depth: usize,
) !void {
    if (depth > 8) return;
    const data = assets.themeData(name) orelse return;
    const sanitized = try stripJsonc(allocator, data);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, sanitized, .{}) catch return;
    if (parsed != .object) return;
    const object = parsed.object;

    if (object.get("include")) |include| {
        if (include == .string) {
            try appendTheme(allocator, std.fs.path.basename(include.string), rules, colors, depth + 1);
        }
    }

    if (object.get("colors")) |value| {
        if (value == .object) {
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| {
                try colors.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    if (object.get("tokenColors")) |value| {
        if (value == .array) {
            for (value.array.items) |item| try appendRule(allocator, item, rules);
        }
    }
}

fn appendRule(
    allocator: Allocator,
    item: std.json.Value,
    rules: *std.array_list.Managed(ITokenThemeRule),
) !void {
    if (item != .object) return;
    const object = item.object;
    const settings_value = object.get("settings") orelse return;
    if (settings_value != .object) return;
    const settings = settings_value.object;

    var foreground: ?[]const u8 = null;
    var background: ?[]const u8 = null;
    var font_style: ?[]const u8 = null;
    if (settings.get("foreground")) |value| {
        if (value == .string) foreground = value.string;
    }
    if (settings.get("background")) |value| {
        if (value == .string) background = value.string;
    }
    if (settings.get("fontStyle")) |value| {
        if (value == .string) font_style = value.string;
    }

    const scopes_value = object.get("scope") orelse {
        try rules.append(.{
            .token = "",
            .foreground = foreground,
            .background = background,
            .fontStyle = font_style,
        });
        return;
    };

    switch (scopes_value) {
        .string => |scope| try appendScopes(allocator, scope, rules, foreground, background, font_style),
        .array => |array| {
            for (array.items) |value| {
                if (value == .string) {
                    try appendScopes(allocator, value.string, rules, foreground, background, font_style);
                }
            }
        },
        else => {},
    }
}

fn appendScopes(
    allocator: Allocator,
    scopes: []const u8,
    rules: *std.array_list.Managed(ITokenThemeRule),
    foreground: ?[]const u8,
    background: ?[]const u8,
    font_style: ?[]const u8,
) !void {
    var iterator = std.mem.splitScalar(u8, scopes, ',');
    while (iterator.next()) |part| {
        var selector = std.mem.trim(u8, part, " \t\r\n");
        if (selector.len == 0) continue;

        // `target - excluded`: the ported trie has no exclusion support, so
        // keep the target selector.
        if (std.mem.indexOf(u8, selector, " - ")) |index| {
            selector = std.mem.trim(u8, selector[0..index], " \t\r\n");
        }
        // `parent target`: the trie matches one scope, so keep the target.
        if (std.mem.lastIndexOfScalar(u8, selector, ' ')) |index| {
            selector = std.mem.trim(u8, selector[index + 1 ..], " \t\r\n");
        }
        if (selector.len == 0) continue;

        try rules.append(.{
            .token = try allocator.dupe(u8, selector),
            .foreground = foreground,
            .background = background,
            .fontStyle = font_style,
        });
    }
}

test "syntax theme: dark+ token colors resolve" {
    var theme: SyntaxTheme = undefined;
    try theme.init(std.testing.allocator);
    defer theme.deinit();

    const colors = theme.theme.getColorMap();
    const comment = colors[theme.theme._match("comment.line.double-slash.zig").getForeground()];
    try std.testing.expectEqual(@as(u8, 106), comment.r);
    try std.testing.expectEqual(@as(u8, 153), comment.g);
    try std.testing.expectEqual(@as(u8, 85), comment.b);

    const inline_rule = colors[theme.theme._match("markup.inline.raw.string.markdown").getForeground()];
    try std.testing.expectEqual(@as(u8, 0xCE), inline_rule.r);
    try std.testing.expectEqual(@as(u8, 0x91), inline_rule.g);
    try std.testing.expectEqual(@as(u8, 0x78), inline_rule.b);
}

test "syntax theme: tokenization uses the dark+ rules" {
    var theme: SyntaxTheme = undefined;
    try theme.init(std.testing.allocator);
    defer theme.deinit();

    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    var ctx = try TestModel.init(std.testing.allocator, "const x = 1; // hi", "zig");
    defer ctx.deinit();
    ctx.model.forceTokenization(1);
    var tokens = try ctx.model.tokenization().getLineTokens(1);
    defer tokens.deinit();

    var saw_const = false;
    var saw_comment = false;
    for (0..tokens.getCount()) |i| {
        const text = tokens.getTokenText(i);
        const color = theme.theme.getColorMap()[tokens.getForeground(i)];
        if (std.mem.eql(u8, text, "const")) {
            saw_const = true;
            try std.testing.expectEqual(@as(u8, 0x56), color.r);
            try std.testing.expectEqual(@as(u8, 0x9C), color.g);
            try std.testing.expectEqual(@as(u8, 0xD6), color.b);
        } else if (std.mem.eql(u8, text, "// hi")) {
            saw_comment = true;
            try std.testing.expectEqual(@as(u8, 0x6A), color.r);
            try std.testing.expectEqual(@as(u8, 0x99), color.g);
            try std.testing.expectEqual(@as(u8, 0x55), color.b);
        }
    }
    try std.testing.expect(saw_const);
    try std.testing.expect(saw_comment);
}

test "syntax theme: markdown inline code and bold use dark+ styles" {
    var theme: SyntaxTheme = undefined;
    try theme.init(std.testing.allocator);
    defer theme.deinit();

    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    var inline_code = try TestModel.init(std.testing.allocator, "a `code` span", "markdown");
    defer inline_code.deinit();
    inline_code.model.forceTokenization(1);
    var inline_tokens = try inline_code.model.tokenization().getLineTokens(1);
    defer inline_tokens.deinit();

    var saw_inline_code = false;
    for (0..inline_tokens.getCount()) |i| {
        if (std.mem.eql(u8, inline_tokens.getTokenText(i), "`code`")) {
            saw_inline_code = true;
            const color = theme.theme.getColorMap()[inline_tokens.getForeground(i)];
            try std.testing.expectEqual(@as(u8, 0xCE), color.r);
            try std.testing.expectEqual(@as(u8, 0x91), color.g);
            try std.testing.expectEqual(@as(u8, 0x78), color.b);
        }
    }
    try std.testing.expect(saw_inline_code);

    var bold = try TestModel.init(std.testing.allocator, "**bold**", "markdown");
    defer bold.deinit();
    bold.model.forceTokenization(1);
    var bold_tokens = try bold.model.tokenization().getLineTokens(1);
    defer bold_tokens.deinit();

    var saw_bold = false;
    for (0..bold_tokens.getCount()) |i| {
        if (std.mem.eql(u8, bold_tokens.getTokenText(i), "**bold**") or std.mem.eql(u8, bold_tokens.getTokenText(i), "bold")) {
            saw_bold = true;
            try std.testing.expect(bold_tokens.getMetadata(i).fontStyle.bold);
        }
    }
    try std.testing.expect(saw_bold);

    var fenced = try TestModel.init(std.testing.allocator, "```zig\nconst x = 1;\n```\n", "markdown");
    defer fenced.deinit();
    fenced.model.forceTokenization(3);
    var fenced_tokens = try fenced.model.tokenization().getLineTokens(2);
    defer fenced_tokens.deinit();

    var saw_fenced_const = false;
    for (0..fenced_tokens.getCount()) |i| {
        if (std.mem.eql(u8, fenced_tokens.getTokenText(i), "const")) {
            saw_fenced_const = true;
            const color = theme.theme.getColorMap()[fenced_tokens.getForeground(i)];
            try std.testing.expectEqual(@as(u8, 0x56), color.r);
            try std.testing.expectEqual(@as(u8, 0x9C), color.g);
            try std.testing.expectEqual(@as(u8, 0xD6), color.b);
        }
    }
    try std.testing.expect(saw_fenced_const);
}

test "syntax theme: editor paints the dark+ colors" {
    const Editor = @import("../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
    const View = @import("../../../../tui/editorView.zig").View;

    var theme: SyntaxTheme = undefined;
    try theme.init(std.testing.allocator);
    defer theme.deinit();

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "// hi\nconst x = 1;\n", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    editor.ensureTokensVisible();
    var view = try View.init(allocator, editor);
    defer view.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;106;153;85m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;86;156;214m") != null);
}

test "syntax theme: every supported language highlights inside a fence" {
    // The sweep needs the full VS Code grammar set; without the `vscode/`
    // submodule only the vendored fallback grammars are embedded.
    if (assets.dataForScope("source.json") == null) return error.SkipZigTest;
    var theme: SyntaxTheme = undefined;
    try theme.init(std.testing.allocator);
    defer theme.deinit();

    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    const default_foreground = theme.theme._match("").getForeground();
    const cases = [_]struct { fence: []const u8, body: []const u8 }{
        .{ .fence = "zig", .body = "const x = 1;" },
        .{ .fence = "toml", .body = "key = \"value\"" },
        .{ .fence = "json", .body = "{\"key\": 1}" },
        .{ .fence = "jsonc", .body = "{\"key\": 1}" },
        .{ .fence = "javascript", .body = "const x = 1;" },
        .{ .fence = "javascriptreact", .body = "const x = <div/>;" },
        .{ .fence = "typescript", .body = "const x: number = 1;" },
        .{ .fence = "typescriptreact", .body = "const x: number = 1;" },
        .{ .fence = "python", .body = "def f(): pass" },
        .{ .fence = "rust", .body = "fn main() {}" },
        .{ .fence = "go", .body = "func main() {}" },
        .{ .fence = "c", .body = "int x = 1;" },
        .{ .fence = "cpp", .body = "int x = 1;" },
        .{ .fence = "java", .body = "class A {}" },
        .{ .fence = "html", .body = "<div>hi</div>" },
        .{ .fence = "css", .body = "body { color: red; }" },
        .{ .fence = "scss", .body = "$x: red;" },
        .{ .fence = "markdown", .body = "# Heading" },
        .{ .fence = "yaml", .body = "key: value" },
        .{ .fence = "shellscript", .body = "echo hi" },
    };

    for (cases) |case| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "```{s}\n{s}\n```\n", .{ case.fence, case.body });
        defer std.testing.allocator.free(text);
        var model = try TestModel.init(std.testing.allocator, text, "markdown");
        defer model.deinit();
        model.model.forceTokenization(3);
        var tokens = try model.model.tokenization().getLineTokens(2);
        defer tokens.deinit();

        var varied = false;
        for (0..tokens.getCount()) |i| {
            if (tokens.getForeground(i) != default_foreground) varied = true;
        }
        try std.testing.expect(varied);
    }
}

test "syntax theme: markdown list continuation keeps inline code" {
    var theme: SyntaxTheme = undefined;
    try theme.init(std.testing.allocator);
    defer theme.deinit();

    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    const text =
        "- Multi-file editing uses the ported workbench editor-group model\n" ++
        "  (`src/vs/workbench/common/editor/editorGroupModel.zig`) with a terminal tab\n" ++
        "  strip (`src/vs/workbench/browser/parts/editor/multiEditorTabsControl.zig`,\n" ++
        "  `src/vs/workbench/browser/workbench.zig`). Each tab keeps its own\n" ++
        "  `Editor`, `View` and lazy editor contributions; only the active view is\n" ++
        "  decorations. `Ctrl-W` closes the active tab (a dirty tab asks\n";
    var model = try TestModel.init(std.testing.allocator, text, "markdown");
    defer model.deinit();
    model.model.forceTokenization(5);

    const inline_rgb = [3]u8{ 206, 145, 120 };
    var line_number: usize = 2;
    while (line_number <= 5) : (line_number += 1) {
        var tokens = try model.model.tokenization().getLineTokens(line_number);
        defer tokens.deinit();
        var has_inline = false;
        for (0..tokens.getCount()) |i| {
            const color = theme.theme.getColorMap()[tokens.getForeground(i)];
            if (color.r == inline_rgb[0] and color.g == inline_rgb[1] and color.b == inline_rgb[2]) {
                has_inline = true;
            }
        }
        try std.testing.expect(has_inline);
    }
}

test "syntax theme loads through the workbench theme service" {
    const allocator = std.testing.allocator;

    var themed: SyntaxTheme = undefined;
    try themed.initFromThemeService(allocator);
    defer themed.deinit();

    var legacy: SyntaxTheme = undefined;
    try legacy.init(allocator);
    defer legacy.deinit();

    const themed_map = themed.theme.getColorMap();
    const legacy_map = legacy.theme.getColorMap();
    try std.testing.expect(themed_map.len > 1);
    try std.testing.expectEqual(legacy_map.len, themed_map.len);
}

test "declarative theme-defaults loads a token theme" {
    const registry_mod = @import("../../../workbench/services/extensions/common/extensionsRegistry.zig");
    const allocator = std.testing.allocator;
    var registry = registry_mod.scan(allocator, &.{"vscode/extensions/theme-defaults"}) catch return error.SkipZigTest;
    defer registry.deinit();
    const theme = registry.theme("Dark+") orelse return error.SkipZigTest;

    var syntax: SyntaxTheme = undefined;
    try syntax.initFromThemeFiles(allocator, theme.root, theme.path, theme.ui_theme);
    defer syntax.deinit();
    try std.testing.expect(TokenizationRegistry.instance.getColorMap() != null);
}
