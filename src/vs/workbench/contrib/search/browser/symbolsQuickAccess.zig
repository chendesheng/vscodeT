// Port of `src/vs/workbench/contrib/search/browser/symbolsQuickAccess.ts`.
// The terminal picker renders labels, descriptions and fuzzy matches; typing
// debounce and provider query/resolve cancellation use the window dispatcher.
const std = @import("std");
const search = @import("../common/search.zig");
const quick = @import("../../../../platform/quickinput/common/quickAccess.zig");
const quick_input = @import("../../../../platform/quickinput/common/quickInput.zig");
const QuickPick = @import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const cancellation = @import("../../../../base/common/cancellation.zig");
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");
const filters = @import("../../../../base/common/filters.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const IEditorService = @import("../../../services/editor/common/editorService.zig").IEditorService;
const Allocator = std.mem.Allocator;

pub const SymbolsQuickAccessProvider = struct {
    allocator: Allocator,
    registry: search.WorkspaceSymbolProviderRegistry,
    registry_listener: ?usize = null,
    editor_service: ?*const IEditorService,
    timer: dispatch.Task,
    picker: ?*QuickPick = null,
    cancellation_listener: ?IDisposable = null,
    query: ?[]u8 = null,
    request: ?*search.WorkspaceSymbolsRequest = null,
    picks: std.ArrayList(Pick) = .empty,
    resolving: ?IDisposable = null,
    resolving_symbol: ?search.IWorkspaceSymbol = null,

    const Pick = struct {
        item: search.WorkspaceSymbolItem,
        score: i32,
    };

    pub const PREFIX = "#";
    const TYPING_SEARCH_DELAY = 200;

    pub fn create(allocator: Allocator, window: ?*dispatch.Queue, editors: ?*const IEditorService) !*SymbolsQuickAccessProvider {
        const self = try allocator.create(SymbolsQuickAccessProvider);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .registry = .init(allocator),
            .editor_service = editors,
            .timer = .{ .queue = window, .context = self, .run = onTimer, .progress = true },
        };
        errdefer self.registry.deinit();
        self.registry_listener = try self.registry.on_did_change.listen(self, onRegistryChanged);
        return self;
    }

    pub fn interface(self: *SymbolsQuickAccessProvider) quick.Provider {
        return .{ .context = self, .prefix = PREFIX, .placeholder = "Type the name of a symbol to open.", .provide = provide, .refresh = refresh, .accept = accept, .dispose = destroy };
    }

    fn destroy(context: *anyopaque) void {
        const self: *SymbolsQuickAccessProvider = @ptrCast(@alignCast(context));
        self.cancelShowing();
        if (self.registry_listener) |id| self.registry.on_did_change.unlisten(id);
        self.registry.deinit();
        self.picks.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn provide(context: *anyopaque, picker: *QuickPick, token: cancellation.CancellationToken) !void {
        const self: *SymbolsQuickAccessProvider = @ptrCast(@alignCast(context));
        self.cancelShowing();
        self.picker = picker;
        self.cancellation_listener = try token.onCancellationRequested(cancellation.CancellationListener.from(SymbolsQuickAccessProvider, self, cancelShowing));
        try refresh(context, picker);
    }

    fn cancelShowing(self: *SymbolsQuickAccessProvider) void {
        if (self.cancellation_listener) |listener| listener.dispose();
        self.cancellation_listener = null;
        self.cancelQuery();
        self.picker = null;
    }

    fn cancelQuery(self: *SymbolsQuickAccessProvider) void {
        self.timer.schedule(null);
        if (self.resolving) |pending| pending.dispose();
        self.resolving = null;
        self.resolving_symbol = null;
        if (self.picker) |picker| picker.clearItems();
        self.picks.clearRetainingCapacity();
        if (self.request) |request| request.deinit();
        self.request = null;
        if (self.query) |query| self.allocator.free(query);
        self.query = null;
    }

    fn refresh(context: *anyopaque, picker: *QuickPick) !void {
        const self: *SymbolsQuickAccessProvider = @ptrCast(@alignCast(context));
        self.cancelQuery();
        const value = picker.value.items;
        const query = std.mem.trim(u8, if (std.mem.startsWith(u8, value, PREFIX)) value[PREFIX.len..] else value, " \t");
        self.query = try self.allocator.dupe(u8, query);
        picker.setBusy(true);
        if (self.timer.queue != null) {
            // Replace the deadline on each keystroke.
            self.timer.schedule(time.milliTimestamp(self.timer.queue.?.io) + TYPING_SEARCH_DELAY);
        } else try self.runQuery();
    }

    fn onRegistryChanged(_: void, self: *SymbolsQuickAccessProvider) !void {
        if (self.picker) |picker| try refresh(self, picker);
    }

    fn onTimer(context: *anyopaque, _: i64, _: bool) bool {
        const self: *SymbolsQuickAccessProvider = @ptrCast(@alignCast(context));
        self.runQuery() catch if (self.picker) |picker| picker.setBusy(false);
        return true;
    }

    fn runQuery(self: *SymbolsQuickAccessProvider) !void {
        const query = self.query orelse return;
        const request = try search.WorkspaceSymbolsRequest.init(self.allocator, .{ .context = self, .complete = resultsReady });
        self.request = request;
        const symbol_query = query[0 .. std.mem.indexOfScalar(u8, query, ' ') orelse query.len];
        try request.getWorkspaceSymbols(&self.registry, symbol_query);
    }

    fn resultsReady(context: *anyopaque, items: []const search.WorkspaceSymbolItem) void {
        const self: *SymbolsQuickAccessProvider = @ptrCast(@alignCast(context));
        self.updatePicks(items) catch if (self.picker) |picker| picker.setBusy(false);
    }

    fn updatePicks(self: *SymbolsQuickAccessProvider, items: []const search.WorkspaceSymbolItem) !void {
        const picker = self.picker orelse return;
        const query = self.query orelse return;
        const split = std.mem.indexOfScalar(u8, query, ' ') orelse query.len;
        const symbol_query = query[0..split];
        const container_query = std.mem.trim(u8, query[split..], " \t");
        const a = self.request.?.arena.allocator();
        for (items) |item| {
            const symbol = item.symbol;
            const all_score = if (query.len == 0) 0 else filters.fuzzyScore(query, symbol.name);
            var score: i32 = all_score orelse blk: {
                const name_score = filters.fuzzyScore(symbol_query, symbol.name) orelse continue;
                if (container_query.len == 0) break :blk name_score;
                const description = try std.fmt.allocPrint(a, "{s} {s}", .{ symbol.container_name, symbol.resource });
                break :blk name_score + (filters.fuzzyScore(container_query, description) orelse continue);
            };
            if (query.len == 0) score = 0;
            try self.picks.append(self.allocator, .{ .item = item, .score = score });
        }
        std.mem.sort(Pick, self.picks.items, {}, struct {
            fn less(_: void, x: Pick, y: Pick) bool {
                if (x.score != y.score) return x.score > y.score;
                return std.ascii.lessThanIgnoreCase(x.item.symbol.name, y.item.symbol.name);
            }
        }.less);
        const rows = try a.alloc(quick_input.QuickPickItem, self.picks.items.len);
        for (self.picks.items, rows) |pick, *row| {
            const symbol = pick.item.symbol;
            const uri = try std.Uri.parse(symbol.resource);
            const path = try std_uri.fsPath(uri, a);
            row.* = .{ .item = .{ .label = symbol.name, .description = if (symbol.container_name.len > 0) try std.fmt.allocPrint(a, "{s} — {s}", .{ symbol.container_name, path }) else path } };
        }
        if (rows.len == 0) {
            try picker.setItems(&.{.{ .item = .{ .label = "No matching workspace symbols" } }});
        } else try picker.setItems(rows);
        picker.setBusy(false);
    }

    fn accept(context: *anyopaque, picker: *QuickPick) !void {
        const self: *SymbolsQuickAccessProvider = @ptrCast(@alignCast(context));
        const index = picker.selected_index orelse return;
        if (index >= self.picks.items.len or self.resolving != null) return;
        const item = self.picks.items[index].item;
        if (item.provider.resolve) |resolve| {
            picker.setBusy(true);
            self.resolving_symbol = item.symbol;
            self.resolving = try resolve(item.provider.context, self.request.?.arena.allocator(), item.symbol, .{ .context = self, .complete = resolved });
        } else try self.openSymbol(item.symbol);
    }

    fn resolved(context: *anyopaque, result: anyerror!?search.IWorkspaceSymbol) void {
        const self: *SymbolsQuickAccessProvider = @ptrCast(@alignCast(context));
        self.resolving = null;
        const original = self.resolving_symbol;
        self.resolving_symbol = null;
        if (self.picker) |picker| picker.setBusy(false);
        if (result) |maybe| {
            if (maybe orelse original) |symbol| self.openSymbol(symbol) catch {};
        } else |_| {}
    }

    fn openSymbol(self: *SymbolsQuickAccessProvider, symbol: search.IWorkspaceSymbol) !void {
        const editor = self.editor_service orelse return error.EditorOpeningUnavailable;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const uri = try std.Uri.parse(try a.dupe(u8, symbol.resource));
        if (!std.mem.eql(u8, uri.scheme, "file")) return error.UnsupportedResource;
        const path = try std_uri.fsPath(uri, a);
        const position = if (symbol.range) |range| range.startPosition() else null;
        // Copy all needed data before hiding cancels and releases the query.
        if (self.picker) |picker| picker.hide();
        try editor.openEditor(path, .{ .selection_utf16 = position, .pinned = true });
    }
};
