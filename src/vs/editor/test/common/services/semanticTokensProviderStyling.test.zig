// Port of invalid/overlapping token cases from
// `src/vs/editor/test/common/services/semanticTokensProviderStyling.test.ts`.
const std = @import("std");
const styling = @import("../../../common/services/semanticTokensProviderStyling.zig");
const theme = @import("../../../../platform/theme/common/themeService.zig");
const Color = @import("../../../../base/common/color.zig").Color;
const TokenizationRegistry = @import("../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const TestModel = @import("../port/testSupport.zig").TestModel;
const TestTheme = struct {
    const values = [_]Color{ .black, .{ .r = 8, .g = 17, .b = 35, .a = 255 }, .{ .r = 247, .g = 51, .b = 70, .a = 255 } };
    fn getColor(_: *anyopaque, _: []const u8, _: bool) ?Color {
        return null;
    }
    fn defines(_: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn getTokenColor(_: *anyopaque, index: u32) ?Color {
        return if (index < values.len) values[index] else null;
    }
    fn getStyle(_: *anyopaque, token_type: []const u8, modifiers: []const []const u8, _: []const u8) ?theme.ITokenStyle {
        if (!std.mem.eql(u8, token_type, "variable")) return null;
        return .{ .foreground = 2, .bold = modifiers.len != 0, .italic = false };
    }
    fn interface(self: *TestTheme) theme.IColorTheme {
        return .{ .theme_type = .DARK, .label = "test", .context = self, .vtable = &.{ .getColor = getColor, .defines = defines, .getTokenColor = getTokenColor, .getTokenStyleMetadata = getStyle }, .semanticHighlighting = true };
    }
};

test "SemanticTokensProviderStyling: UTF-16 spans, overlapping and invalid tokens, merged metadata" {
    const a = std.testing.allocator;
    var fixture = try TestModel.init(a, "é𝄞xyz\nabc", "plaintext");
    defer fixture.deinit();
    const old = TokenizationRegistry.instance.getColorMap();
    defer if (old) |map| TokenizationRegistry.instance.setColorMap(map) else TokenizationRegistry.instance.clearColorMap();
    TokenizationRegistry.instance.setColorMap(&TestTheme.values);
    var test_theme: TestTheme = .{};
    var provider = styling.SemanticTokensProviderStyling.init(a, .{ .token_types = &.{"variable"}, .token_modifiers = &.{"declaration"} }, test_theme.interface(), "plaintext");
    defer provider.deinit();
    const pieces = try styling.toMultilineTokens2(a, &.{
        0, 1, 2, 0, 1, // astral character from UTF-16 offsets 1..3, bytes 2..6
        0, 1, 1, 0, 0, // overlaps the previous token; ignore
        0, 1, 0, 0, 0, // invalid length; ignore
        0, 0, 2, 0, 0, // x/y
        1, 0, 1, 99, 0, // invalid type; ignore
        0, 1, 1, 0,  1,
    }, &provider, fixture.model);
    defer a.free(pieces);
    try std.testing.expectEqual(@as(usize, 1), pieces.len);
    const line = pieces[0].getLineTokens(1).?;
    try std.testing.expectEqual(@as(usize, 2), line.getCount());
    try std.testing.expectEqual(@as(u32, 2), line.getStartCharacter(0));
    try std.testing.expectEqual(@as(u32, 6), line.getEndCharacter(0));
    try std.testing.expectEqual(@as(u9, 2), line.getMetadata(0).foreground);
    try std.testing.expect(line.getMetadata(0).fontStyle.bold);
    try std.testing.expect(!line.getMetadata(1).fontStyle.bold);
    try fixture.model.setSemanticTokens(pieces, true);
    try std.testing.expect(fixture.model.hasCompleteSemanticTokens() and fixture.model.hasSomeSemanticTokens());
    var merged = try fixture.model.tokenization().getLineTokens(1);
    defer merged.deinit();
    var found = false;
    for (0..merged.getCount()) |index| if (merged.getMetadata(index).foreground == 2 and merged.getMetadata(index).fontStyle.bold) {
        found = true;
        break;
    };
    try std.testing.expect(found);
}
