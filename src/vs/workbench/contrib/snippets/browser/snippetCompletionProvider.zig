// Port of the extension-file portions of snippetsFile.ts and
// snippetCompletionProvider.ts. The terminal suggest model scores candidates
// and its SnippetSession owns placeholder expansion and undo.
const std = @import("std");
const Allocator = std.mem.Allocator;
const completion = @import("../../../../editor/common/languages/completion.zig");
const TextModel = @import("../../../../editor/common/model/textModel.zig").TextModel;
const Position = @import("../../../../editor/common/core/position.zig").Position;
const Range = @import("../../../../editor/common/core/range.zig").Range;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const registry = @import("../../../services/extensions/common/extensionsRegistry.zig");
const config = @import("../../../../platform/configuration/common/configurationModels.zig");
const wordStartColumn = @import("../../../../editor/contrib/suggest/browser/suggestModel.zig").wordStartColumn;

pub const SnippetCompletionProvider = struct {
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    catalog: ?*const registry.Registry = null,
    languages: std.StringHashMapUnmanaged([]const completion.CompletionItem) = .empty,

    pub fn init(allocator: Allocator, io: std.Io) SnippetCompletionProvider {
        return .{ .io = io, .arena = .init(allocator) };
    }

    pub fn deinit(self: *SnippetCompletionProvider) void {
        self.arena.deinit();
    }

    pub fn setCatalog(self: *SnippetCompletionProvider, catalog: *const registry.Registry) void {
        if (self.catalog == catalog) return;
        _ = self.arena.reset(.free_all);
        self.languages = .empty;
        self.catalog = catalog;
    }

    pub fn interface(self: *SnippetCompletionProvider) completion.CompletionItemProvider {
        return .{ .context = self, .provide_completion_items = provide };
    }

    fn forLanguage(self: *SnippetCompletionProvider, language: []const u8) ![]const completion.CompletionItem {
        const catalog = self.catalog orelse return &.{};
        if (self.languages.get(language)) |items| return items;
        const arena = self.arena.allocator();
        var items: std.ArrayList(completion.CompletionItem) = .empty;
        for (catalog.snippets) |file| {
            if (!std.mem.eql(u8, language, file.language)) continue;
            const path = try std.fs.path.join(arena, &.{ file.root, file.path });
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .unlimited) catch continue;
            const sanitized = try config.stripJsonc(arena, data);
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, sanitized, .{}) catch continue;
            if (value != .object) continue;
            var entries = value.object.iterator();
            while (entries.next()) |entry| {
                if (entry.value_ptr.* != .object) continue;
                if (entry.value_ptr.object.contains("body")) {
                    try addSnippet(arena, &items, entry.key_ptr.*, entry.value_ptr.*);
                } else {
                    var nested = entry.value_ptr.object.iterator();
                    while (nested.next()) |child| try addSnippet(arena, &items, child.key_ptr.*, child.value_ptr.*);
                }
            }
        }
        const result = try items.toOwnedSlice(arena);
        try self.languages.put(arena, try arena.dupe(u8, language), result);
        return result;
    }

    fn provide(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, trigger: completion.CompletionContext, token: CancellationToken) anyerror!completion.CompletionList {
        const self: *SnippetCompletionProvider = @ptrCast(@alignCast(context));
        if (token.isCancellationRequested()) return .{};
        const snippets = try self.forLanguage(model.getLanguageId());
        if (snippets.len == 0) return .{};
        var line = try model.getLineContent(position.lineNumber);
        defer line.deinit();
        const cursor = position.column - 1;
        const word = wordStartColumn(line.items, position.column) - 1;
        var items: std.ArrayList(completion.CompletionItem) = .empty;
        for (snippets) |snippet| {
            if (trigger.trigger_character) |ch| {
                if (!std.ascii.startsWithIgnoreCase(snippet.label, ch)) continue;
            }
            // Include punctuation belonging to a prefix such as "#region".
            var start = cursor -| snippet.label.len;
            while (start < word and !std.ascii.startsWithIgnoreCase(snippet.label, line.items[start..cursor])) start += 1;
            if (start > word) start = word;
            const typed = line.items[start..cursor];
            var end = cursor;
            if (std.ascii.startsWithIgnoreCase(snippet.label, typed)) {
                const rest = snippet.label[typed.len..];
                if (std.ascii.startsWithIgnoreCase(line.items[cursor..], rest)) end += rest.len;
            }
            var item = snippet;
            item.range = Range.init(position.lineNumber, start + 1, position.lineNumber, end + 1);
            try items.append(allocator, item);
        }
        return .{ .items = try items.toOwnedSlice(allocator) };
    }
};

fn joinedText(arena: Allocator, value: std.json.Value) !?[]const u8 {
    if (value == .string) return value.string;
    if (value != .array) return null;
    var parts: std.ArrayList([]const u8) = .empty;
    for (value.array.items) |part| {
        if (part != .string) return null;
        try parts.append(arena, part.string);
    }
    return try std.mem.join(arena, "\n", parts.items);
}

fn addSnippet(arena: Allocator, items: *std.ArrayList(completion.CompletionItem), name: []const u8, value: std.json.Value) !void {
    if (value != .object) return;
    const body = try joinedText(arena, value.object.get("body") orelse return) orelse return;
    const description = try joinedText(arena, value.object.get("description") orelse .null);
    const prefix = value.object.get("prefix") orelse return;
    const prefixes: []const std.json.Value = if (prefix == .array) prefix.array.items else &.{prefix};
    for (prefixes) |p| {
        if (p != .string or p.string.len == 0) continue;
        try items.append(arena, .{
            .label = p.string,
            .kind = .Snippet,
            .detail = name,
            .documentation = description,
            .insert_text = body,
            .insert_text_rules = @backingInt(completion.CompletionItemInsertTextRule.InsertAsSnippet),
            .sort_text = try std.fmt.allocPrint(arena, "z-{s}", .{p.string}),
        });
    }
}

test "snippet completion: scoped upstream array prefixes and multiline bodies" {
    const io = @import("../../../../base/common/timeCompat.zig").io;
    const root = "vscode/extensions/markdown-basics";
    std.Io.Dir.cwd().access(io, root, .{}) catch return error.SkipZigTest;
    var catalog = try registry.scan(std.testing.allocator, &.{root});
    defer catalog.deinit();
    var provider = SnippetCompletionProvider.init(std.testing.allocator, io);
    defer provider.deinit();
    provider.setCatalog(&catalog);
    try std.testing.expectEqual(@as(usize, 0), (try provider.forLanguage("go")).len);
    const items = try provider.forLanguage("markdown");
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "fenced math")) {
            try std.testing.expectEqualStrings("$$\n${1:${TM_SELECTED_TEXT}}\n$$", item.insert_text);
            try std.testing.expectEqual(completion.CompletionItemKind.Snippet, item.kind);
            return;
        }
    }
    return error.TestExpectedEqual;
}
