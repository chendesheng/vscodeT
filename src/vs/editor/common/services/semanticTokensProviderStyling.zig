// Port of `src/vs/editor/common/services/semanticTokensProviderStyling.ts`.
// The terminal syntax theme publishes one shared token palette; semantic
// foregrounds are looked up in that palette rather than using a second color
// index. Convert LSP/VS Code UTF-16 segments into the model's byte columns.
const std = @import("std");
const languages = @import("../languages.zig");
const theme_service = @import("../../../platform/theme/common/themeService.zig");
const attributes = @import("../encodedTokenAttributes.zig");
const TokenMetadata = attributes.TokenMetadata;
const SemanticMetadata = attributes.SemanticMetadata;
const color_registry = @import("../tokenizationRegistry.zig").TokenizationRegistry;
const TextModel = @import("../model/textModel.zig").TextModel;
const sparse = @import("../tokens/sparseMultilineTokens.zig");
const positions = @import("../../../base/common/utf16Position.zig");

pub const SemanticTokensProviderStyling = struct {
    allocator: std.mem.Allocator,
    legend: languages.SemanticTokensLegend,
    theme: theme_service.IColorTheme,
    language_id: []const u8,
    cache: std.AutoHashMap(u64, ?TokenMetadata),
    warned_overlap: bool = false,
    warned_invalid_length: bool = false,

    pub fn init(a: std.mem.Allocator, legend: languages.SemanticTokensLegend, theme: theme_service.IColorTheme, language_id: []const u8) SemanticTokensProviderStyling {
        return .{ .allocator = a, .legend = legend, .theme = theme, .language_id = language_id, .cache = .init(a) };
    }
    pub fn deinit(self: *SemanticTokensProviderStyling) void {
        self.cache.deinit();
    }
    pub fn getMetadata(self: *SemanticTokensProviderStyling, token_type: u32, modifier_set: u32) !?TokenMetadata {
        const key = (@as(u64, token_type) << 32) | modifier_set;
        if (self.cache.get(key)) |cached| return cached;
        const value = self.computeMetadata(token_type, modifier_set);
        try self.cache.put(key, value);
        return value;
    }
    fn computeMetadata(self: *SemanticTokensProviderStyling, token_type: u32, modifier_set: u32) ?TokenMetadata {
        if (token_type >= self.legend.token_types.len) return null;
        var modifiers: [33][]const u8 = undefined;
        var count: usize = 0;
        for (0..32) |index| {
            if ((modifier_set & (@as(u32, 1) << @intCast(index))) == 0) continue;
            modifiers[count] = if (index < self.legend.token_modifiers.len) self.legend.token_modifiers[index] else "not-in-legend";
            count += 1;
        }
        const style = self.theme.getTokenStyleMetadata(self.legend.token_types[token_type], modifiers[0..count], self.language_id) orelse return null;
        var control: SemanticMetadata = @bitCast(@as(u8, 0));
        var metadata: TokenMetadata = @bitCast(@as(u32, 0));
        if (style.italic) |value| {
            control.useItalic = true;
            metadata.fontStyle.italic = value;
        }
        if (style.bold) |value| {
            control.useBold = true;
            metadata.fontStyle.bold = value;
        }
        if (style.underline) |value| {
            control.useUnderline = true;
            metadata.fontStyle.underline = value;
        }
        if (style.strikethrough) |value| {
            control.useStrikethrough = true;
            metadata.fontStyle.strikethrough = value;
        }
        if (style.foreground) |index| if (self.theme.getTokenColor(index)) |color| {
            if (color_registry.instance.getColorMap()) |map| {
                for (map[@min(1, map.len)..], 1..) |entry, i| {
                    if (entry.r == color.r and entry.g == color.g and entry.b == color.b) {
                        if (std.math.cast(u9, i)) |id| {
                            metadata.foreground = id;
                            control.useForeground = true;
                        }
                        break;
                    }
                }
            }
        };
        metadata.languageId = @bitCast(control);
        return if (metadata.languageId == 0) null else metadata;
    }
};

/// Returned pieces own their storage; `TextModel.setSemanticTokens` takes it.
/// Keep tokens on the same line in the same piece, like upstream.
pub fn toMultilineTokens2(a: std.mem.Allocator, data: []const u32, styling: *SemanticTokensProviderStyling, model: *TextModel) ![]sparse.SparseMultilineTokens {
    var pieces: std.ArrayList(sparse.SparseMultilineTokens) = .empty;
    errdefer {
        for (pieces.items) |*piece| piece.deinit();
        pieces.deinit(a);
    }
    var tokens = std.array_list.Managed(sparse.SparseToken).init(a);
    errdefer tokens.deinit();
    var line: usize = 1;
    var start: usize = 0;
    var area_line: usize = 1;
    var previous_line: usize = 0;
    var previous_end: usize = 0;
    var indexed_line: usize = 0;
    var line_index: ?positions.LineIndex = null;
    defer if (line_index) |*index| index.deinit(a);
    const tokens_per_area = @max(400, (data.len / 5 + 1023) / 1024);
    var offset: usize = 0;
    while (offset + 5 <= data.len) : (offset += 5) {
        const delta_line = data[offset];
        const delta_start = data[offset + 1];
        line = std.math.add(usize, line, delta_line) catch break;
        start = if (delta_line == 0) std.math.add(usize, start, delta_start) catch break else delta_start;
        const end = std.math.add(usize, start, data[offset + 2]) catch continue;
        if (line > model.getLineCount()) break;
        if (end <= start) {
            if (!styling.warned_invalid_length) std.log.warn("Invalid semantic token length at line {d}", .{line});
            styling.warned_invalid_length = true;
            continue;
        }
        if (line == previous_line and start < previous_end) {
            if (!styling.warned_overlap) std.log.warn("Overlapping semantic tokens on line {d}", .{line});
            styling.warned_overlap = true;
            continue;
        }
        const metadata = (try styling.getMetadata(data[offset + 3], data[offset + 4])) orelse continue;
        if (indexed_line != line) {
            if (line_index) |*index| index.deinit(a);
            line_index = null;
            line_index = try positions.LineIndex.init(a, try model.borrowLineContent(line));
            indexed_line = line;
        }
        const byte_start = line_index.?.column(start) - 1;
        const byte_end = line_index.?.column(end) - 1;
        if (byte_end <= byte_start) continue;
        if (tokens.items.len >= tokens_per_area and line != previous_line) {
            try pieces.append(a, sparse.SparseMultilineTokens.create(area_line, tokens));
            tokens = std.array_list.Managed(sparse.SparseToken).init(a);
        }
        if (tokens.items.len == 0) area_line = line;
        try tokens.append(sparse.SparseToken.init(@intCast(line - area_line), @intCast(byte_start), @intCast(byte_end), metadata));
        previous_line = line;
        previous_end = end;
    }
    if (tokens.items.len > 0) {
        try pieces.append(a, sparse.SparseMultilineTokens.create(area_line, tokens));
        tokens = std.array_list.Managed(sparse.SparseToken).init(a);
    }
    tokens.deinit();
    return pieces.toOwnedSlice(a);
}
