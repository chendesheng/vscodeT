// Terminal adaptation of extensions/references-view/src/tree.ts. History keeps
// query inputs, so choosing an old search asks the current language providers.
const std = @import("std");
const api = @import("../../vs/workbench/api/common/extensionApi.zig");
const QuickInputService = @import("../../vs/platform/quickinput/browser/quickInputService.zig").QuickInputService;
const uri = @import("../../vs/base/common/stdUri.zig");
const TextModel = @import("../../vs/editor/common/model/textModel.zig").TextModel;
const Range = @import("../../vs/editor/common/core/range.zig").Range;
const Item = @import("../../vs/platform/quickinput/common/quickInput.zig").Item;
const Match = @import("../../vs/base/common/filters.zig").Match;
const Position = @import("../../vs/editor/common/core/position.zig").Position;
const actions = @import("../../vs/editor/contrib/gotoSymbol/browser/goToCommands.zig");
const QuickPick = @import("../../vs/platform/quickinput/browser/quickInput.zig").QuickPick;
const QuickPickItem = @import("../../vs/platform/quickinput/common/quickInput.zig").QuickPickItem;

const Query = struct {
    path: []const u8,
    word: []const u8,
    position: Position,
    kind: actions.Kind,

    fn deinit(self: Query, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.word);
    }
};

pub const History = struct {
    entries: std.ArrayList(Query) = .empty,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    fn remember(self: *History, allocator: std.mem.Allocator, query: Query) !void {
        const path = try allocator.dupe(u8, query.path);
        errdefer allocator.free(path);
        const word = try allocator.dupe(u8, query.word);
        errdefer allocator.free(word);
        try self.entries.ensureUnusedCapacity(allocator, 1);
        for (self.entries.items, 0..) |entry, i| {
            if (entry.kind == query.kind and entry.position.equals(query.position) and std.mem.eql(u8, entry.path, path)) {
                self.entries.orderedRemove(i).deinit(allocator);
                break;
            }
        }
        self.entries.appendAssumeCapacity(.{ .path = path, .word = word, .position = query.position, .kind = query.kind });
    }
};

pub const SymbolsTree = struct {
    commands: api.ICommandService,
    editors: api.IEditorService,
    window: api.IWindowService,
    workspace: api.IWorkspaceService,
    quick_input: *QuickInputService,
    allocator: std.mem.Allocator,
    picker_arena: std.heap.ArenaAllocator,
    history: History = .{},
    results: []const api.LocationLink = &.{},
    pending_search: ?api.IDisposable = null,
    registrations: [5]api.IDisposable = @splat(.none),

    pub fn init(self: *SymbolsTree, context: *const api.IExtensionContext, quick_input: *QuickInputService) !void {
        self.* = .{ .commands = context.commands, .editors = context.editors, .window = context.window, .workspace = context.workspace, .quick_input = quick_input, .allocator = context.allocator, .picker_arena = .init(context.allocator) };
        errdefer self.deinit();
        const contributions = .{
            .{ "references-view.findReferences", "Find All References", findReferences },
            .{ "references-view.findImplementations", "Find All Implementations", findImplementations },
            .{ "references-view.pickFromHistory", "Show History", showHistory },
            .{ "references-view.refresh", "Refresh", refresh },
            .{ "references-view.clearHistory", "Clear History", clear },
        };
        inline for (contributions, 0..) |command, i| {
            self.registrations[i] = try self.commands.register(command[0], command[1], .{ .context = self, .category = "References", .run = command[2] });
        }
    }

    pub fn deinit(self: *SymbolsTree) void {
        self.cancelSearch();
        for (self.registrations) |registration| registration.dispose();
        self.history.deinit(self.allocator);
        self.picker_arena.deinit();
    }

    fn cancelSearch(self: *SymbolsTree) void {
        if (self.pending_search) |pending| pending.dispose();
        self.pending_search = null;
    }

    fn beginPick(self: *SymbolsTree) std.mem.Allocator {
        self.cancelSearch();
        if (self.quick_input.isVisible()) self.quick_input.hide();
        self.results = &.{};
        _ = self.picker_arena.reset(.retain_capacity);
        return self.picker_arena.allocator();
    }
};

fn findReferences(context: *anyopaque) !void {
    try search(@ptrCast(@alignCast(context)), .references);
}

fn findImplementations(context: *anyopaque) !void {
    try search(@ptrCast(@alignCast(context)), .implementation);
}

fn search(w: *SymbolsTree, kind: actions.Kind) !void {
    const tab = w.editors.activeTextEditor() orelse return;
    const position = tab.cursorPosition();
    const arena = w.beginPick();
    const command = if (kind == .references) "vscode.executeReferenceProvider" else "vscode.executeImplementationProvider";
    const pending = try arena.create(SearchRequest);
    pending.* = .{ .owner = w, .model = tab.model, .version = tab.model.getVersionId(), .position = position, .kind = kind };
    w.pending_search = try w.commands.requestLocationProvider(arena, command, tab.model, position, .{ .context = pending, .complete = SearchRequest.ready });
}

const SearchRequest = struct {
    owner: *SymbolsTree,
    model: *TextModel,
    version: u32,
    position: Position,
    kind: actions.Kind,

    fn ready(context: *anyopaque, result: anyerror![]const api.LocationLink) void {
        const self: *SearchRequest = @ptrCast(@alignCast(context));
        const w = self.owner;
        w.pending_search = null;
        const tab = w.editors.activeTextEditor() orelse return;
        if (tab.model != self.model or tab.model.getVersionId() != self.version or !tab.cursorPosition().equals(self.position)) return;
        const results = result catch return;
        showResults(w, tab, self.position, self.kind, results) catch |err| {
            tab.setMessage(@errorName(err));
        };
    }
};

fn showResults(w: *SymbolsTree, tab: api.ITextEditor, position: Position, kind: actions.Kind, results: []const api.LocationLink) !void {
    const arena = w.picker_arena.allocator();
    const title = if (kind == .references) "References" else "Implementations";
    if (results.len == 0) {
        tab.setMessage(if (kind == .references) "No references found" else "No implementations found");
        return;
    }
    w.results = results;
    // The terminal flattens each file node into a quick-pick separator.
    var picks: std.ArrayList(QuickPickItem) = .empty;
    var active_id: ?[]const u8 = null;
    const current_uri = try uri.resourceKey(arena, tab.model.uri());
    var offset: usize = 0;
    while (offset < results.len) {
        const resource = results[offset].uri;
        const path = try resourcePath(arena, resource);
        const name = std.fs.path.basename(path);
        var end = offset + 1;
        while (end < results.len and std.mem.eql(u8, results[end].uri, resource)) end += 1;
        try picks.append(arena, .{ .separator = .{ .label = try std.fmt.allocPrint(arena, "{s} ({d})", .{ name, end - offset }) } });
        for (results[offset..end], offset..) |link, index| {
            const range = link.target_selection_range;
            var item = Item{
                .id = try std.fmt.allocPrint(arena, "{d}", .{index}),
                .label = try std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ name, range.startLineNumber, range.startColumn }),
                .description = path,
            };
            if (w.workspace.text_document_fn) |lookup| {
                if (lookup(w.workspace.context, path)) |doc| try previewChunks(arena, doc, range, &item);
            }
            if (active_id == null and std.mem.eql(u8, current_uri, resource) and range.containsPosition(&position)) active_id = item.id;
            try picks.append(arena, .{ .item = item });
        }
        offset = end;
    }
    try w.quick_input.showPick(picks.items, .{ .placeholder = title, .active_id = active_id }, reveal, w);
    var word = tab.model.getWordAtPosition(position);
    defer if (word) |*value| value.deinit();
    const anchor = if (word) |value| Position.init(position.lineNumber, value.startColumn) else position;
    try w.history.remember(w.allocator, .{
        .path = tab.path,
        .word = if (word) |value| value.word.items else "???",
        .position = anchor,
        .kind = kind,
    });
}

// Port of extensions/references-view/src/utils.ts getPreviewChunks.
// The quick picker paints the TreeItem label's match in terminal cells.
fn previewChunks(arena: std.mem.Allocator, document: *TextModel, range: Range, item: *Item) !void {
    const start = range.getStartPosition();
    const end = range.getEndPosition();
    const preview_start = Position.init(start.lineNumber, @max(1, start.column -| 8));
    var word = document.getWordAtPosition(preview_start);
    defer if (word) |*value| value.deinit();
    const before_start = if (word) |value| value.startColumn else preview_start.column;
    var before = try document.getValueInRange(Range.init(start.lineNumber, before_start, start.lineNumber, start.column), null);
    defer before.deinit();
    var inside = try document.getValueInRange(range, null);
    defer inside.deinit();
    var after = try document.getValueInRange(Range.init(end.lineNumber, end.column, end.lineNumber, end.column +| 331), null);
    defer after.deinit();
    const prefix = std.mem.trimStart(u8, before.items, " \r\n\t");
    const suffix = std.mem.trimEnd(u8, after.items, " \r\n\t");
    item.label = try std.mem.concat(arena, u8, &.{ prefix, inside.items, suffix });
    const matches = try arena.alloc(Match, 1);
    matches[0] = .{ .start = prefix.len, .end = prefix.len + inside.items.len };
    item.highlights.label = matches;
}

fn resourcePath(arena: std.mem.Allocator, resource: []const u8) ![]const u8 {
    const parsed = try std.Uri.parse(resource);
    if (!std.ascii.eqlIgnoreCase(parsed.scheme, "file")) return resource;
    return uri.fsPath(parsed, arena);
}

fn reveal(context: *anyopaque, picker: *QuickPick) !void {
    const self: *SymbolsTree = @ptrCast(@alignCast(context));
    const item = picker.selectedItem() orelse return;
    const index = std.fmt.parseUnsigned(usize, item.id, 10) catch return;
    if (index >= self.results.len) return;
    const location = self.results[index];
    const parsed = try std.Uri.parse(location.uri);
    if (!std.ascii.eqlIgnoreCase(parsed.scheme, "file")) {
        self.window.setMessage("Cannot open non-file location");
        return;
    }
    const path = try uri.fsPath(parsed, self.picker_arena.allocator());
    try self.window.openPath(path);
    if (self.editors.activeTextEditor()) |editor| {
        try editor.setCursor(location.target_selection_range.getStartPosition());
        editor.ensureCursorVisible();
    }
}

fn showHistory(context: *anyopaque) !void {
    const w: *SymbolsTree = @ptrCast(@alignCast(context));
    const arena = w.beginPick();
    const entries = w.history.entries.items;
    const items = try arena.alloc(QuickPickItem, entries.len);
    for (items, 0..) |*item, i| {
        const index = entries.len - i - 1;
        const entry = entries[index];
        item.* = .{ .item = .{
            .id = try std.fmt.allocPrint(arena, "{d}", .{index}),
            .label = entry.word,
            .description = try std.fmt.allocPrint(arena, "{s} · {s}:{d}", .{
                if (entry.kind == .references) "References" else "Implementations",
                entry.path,
                entry.position.lineNumber,
            }),
        } };
    }
    try w.quick_input.showPick(items, .{ .placeholder = "Select previous reference search" }, accept, w);
}

fn accept(context: *anyopaque, picker: *QuickPick) !void {
    const w: *SymbolsTree = @ptrCast(@alignCast(context));
    const item = picker.selectedItem() orelse return;
    const index = std.fmt.parseInt(usize, item.id, 10) catch return;
    if (index < w.history.entries.items.len) try rerun(w, w.history.entries.items[index]);
}

fn rerun(w: *SymbolsTree, entry: Query) !void {
    try w.window.openPath(entry.path);
    const tab = w.editors.activeTextEditor() orelse return;
    try tab.setCursor(entry.position);
    try search(w, entry.kind);
}

fn refresh(context: *anyopaque) !void {
    const w: *SymbolsTree = @ptrCast(@alignCast(context));
    if (w.history.entries.getLastOrNull()) |entry| try rerun(w, entry);
}

fn clear(context: *anyopaque) !void {
    const w: *SymbolsTree = @ptrCast(@alignCast(context));
    w.cancelSearch();
    if (w.quick_input.isVisible()) w.quick_input.hide();
    w.history.deinit(w.allocator);
}
