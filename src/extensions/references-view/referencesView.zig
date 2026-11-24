// Terminal adaptation of extensions/references-view/src/tree.ts. History keeps
// query inputs, so choosing an old search asks the current language providers.
const std = @import("std");
const Workbench = @import("../../vs/workbench/browser/workbench.zig").Workbench;
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

pub fn register(w: *Workbench) !void {
    inline for (.{
        .{ "references-view.findReferences", "Find All References", findReferences },
        .{ "references-view.findImplementations", "Find All Implementations", findImplementations },
        .{ "references-view.pickFromHistory", "Show History", showHistory },
        .{ "references-view.refresh", "Refresh", refresh },
        .{ "references-view.clearHistory", "Clear History", clear },
    }) |c| try w.commands.register(.{ .id = c[0], .category = "References", .label = c[1], .context = w, .run = c[2] });
}

fn findReferences(context: *anyopaque) !void {
    try search(@ptrCast(@alignCast(context)), .references);
}

fn findImplementations(context: *anyopaque) !void {
    try search(@ptrCast(@alignCast(context)), .implementation);
}

fn search(w: *Workbench, kind: actions.Kind) !void {
    const tab = w.activeTab() orelse return;
    const position = tab.editor.modelCursorPosition();
    var action = if (kind == .references) actions.find_references else actions.implementation;
    action.always_show_list = true;
    if (!try w.executeSymbolNavigation(&action)) return;
    var word = tab.editor.model.getWordAtPosition(position);
    defer if (word) |*value| value.deinit();
    const anchor = if (word) |value| Position.init(position.lineNumber, value.startColumn) else position;
    try w.reference_history.remember(w.allocator, .{
        .path = tab.editor.path,
        .word = if (word) |value| value.word.items else "???",
        .position = anchor,
        .kind = kind,
    });
}

fn showHistory(context: *anyopaque) !void {
    const w: *Workbench = @ptrCast(@alignCast(context));
    const arena = w.navigation_arena.allocator();
    const entries = w.reference_history.entries.items;
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
    try w.quick_access.inputService().showPick(items, .{ .placeholder = "Select previous reference search" }, accept, w);
}

fn accept(context: *anyopaque, picker: *QuickPick) !void {
    const w: *Workbench = @ptrCast(@alignCast(context));
    const item = picker.selectedItem() orelse return;
    const index = std.fmt.parseInt(usize, item.id, 10) catch return;
    if (index < w.reference_history.entries.items.len) try rerun(w, w.reference_history.entries.items[index]);
}

fn rerun(w: *Workbench, entry: Query) !void {
    try w.openPath(entry.path);
    const tab = w.activeTab() orelse return;
    try tab.editor.setCursorPosition(entry.position);
    try search(w, entry.kind);
}

fn refresh(context: *anyopaque) !void {
    const w: *Workbench = @ptrCast(@alignCast(context));
    if (w.reference_history.entries.getLastOrNull()) |entry| try rerun(w, entry);
}

fn clear(context: *anyopaque) !void {
    const w: *Workbench = @ptrCast(@alignCast(context));
    if (w.quick_access.isOpen()) w.quick_access.inputService().hide();
    w.reference_history.deinit(w.allocator);
}
