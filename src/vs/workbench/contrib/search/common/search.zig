// Port of the portable subset of
// `src/vs/workbench/contrib/search/common/search.ts`.
//
// `SearchStateKey` is exposed as the upstream key name and `SearchUIState`
// is carried by the search view controller. Notebook priority helpers and
// configuration-registry nodes are not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../../../../editor/common/core/range.zig").Range;

pub const SearchUIState = enum { idle, searching, slow_search };

pub const SearchStateKey = "searchState";

pub const IFilterAndRange = struct {
    /// Owned by the caller.
    filter: []u8,
    range: Range,
};

/// Port of `extractRangeFromFilter`: parses trailing `file:line`,
/// `file:line:column` and range suffixes (`20-40`, `20:3-40:5`, `(19,20)`,
/// `#20#3-40,5`). Returns null when the filter has no range suffix.
pub fn extractRangeFromFilter(
    allocator: Allocator,
    filter: []const u8,
    unless: []const []const u8,
) !?IFilterAndRange {
    if (filter.len == 0) return null;

    for (unless) |value| {
        if (value.len == 0) continue;
        if (std.mem.indexOf(u8, filter, value)) |position| {
            if (position == 0) return null;
            if (!containsRangeSuffix(filter[position + 1 ..])) return null;
        }
    }

    var index: usize = 0;
    while (index < filter.len) : (index += 1) {
        if (filter[index] != ':' and filter[index] != '#' and filter[index] != '(') continue;
        var start = index;
        if (start > 0 and filter[start - 1] == ' ') start -= 1;
        const range = parseSuffixRange(filter[index..]) orelse continue;
        const prefix = std.mem.trimEnd(u8, filter[0..start], " \t\r\n");
        return .{
            .filter = try allocator.dupe(u8, prefix),
            .range = range,
        };
    }
    return null;
}

fn containsRangeSuffix(text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != ':' and text[index] != '#' and text[index] != '(') continue;
        if (parseSuffixRange(text[index..]) != null) return true;
    }
    return false;
}

fn parseSuffixRange(suffix: []const u8) ?Range {
    var cursor: usize = 0;
    if (cursor >= suffix.len) return null;
    if (suffix[cursor] != ':' and suffix[cursor] != '#' and suffix[cursor] != '(') return null;
    cursor += 1;
    if (std.mem.startsWith(u8, suffix[cursor..], "line ")) cursor += 5;

    const start_line = parseNumber(suffix, &cursor);
    var start_column: ?usize = null;
    var end_line: ?usize = null;
    var end_column: ?usize = null;

    if (cursor < suffix.len and isSeparator(suffix[cursor])) {
        cursor += 1;
        start_column = parseNumber(suffix, &cursor);
    }
    if (cursor < suffix.len and suffix[cursor] == '-') {
        cursor += 1;
        end_line = parseNumber(suffix, &cursor);
        if (cursor < suffix.len and isSeparator(suffix[cursor])) {
            cursor += 1;
            end_column = parseNumber(suffix, &cursor);
        }
    }
    if (cursor < suffix.len and suffix[cursor] == ')') cursor += 1;
    if (cursor < suffix.len and suffix[cursor] == ':') cursor += 1;
    if (cursor != suffix.len) return null;

    var line = start_line orelse 1;
    var column = start_column orelse 1;
    if (line == 0) line = 1;
    if (column == 0) column = 1;
    var end = line;
    var end_column_value = column;
    if (end_line) |value| {
        end = if (value == 0) 1 else value;
        end_column_value = end_column orelse 1;
        if (end_column_value == 0) end_column_value = 1;
    }

    return Range.init(line, column, end, end_column_value);
}

fn parseNumber(text: []const u8, cursor: *usize) ?usize {
    const start = cursor.*;
    var value: usize = 0;
    while (cursor.* < text.len and std.ascii.isDigit(text[cursor.*])) : (cursor.* += 1) {
        value = value * 10 + (text[cursor.*] - '0');
    }
    if (cursor.* == start) return null;
    return value;
}

fn isSeparator(character: u8) bool {
    return character == ':' or character == '#' or character == ',';
}

const lifecycle = @import("../../../../base/common/lifecycle.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const IDisposable = lifecycle.IDisposable;

/// Editor ranges in workspace symbols use the protocol's one-based UTF-16
/// positions until the target model is opened.
pub const IWorkspaceSymbol = struct {
    name: []const u8,
    kind: i64,
    container_name: []const u8 = "",
    resource: []const u8,
    range: ?Range = null,
    cache_id: ?[2]i64 = null,
};

pub const WorkspaceSymbolsCallback = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, anyerror![]const IWorkspaceSymbol) void,
};

pub const ResolveWorkspaceSymbolCallback = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, anyerror!?IWorkspaceSymbol) void,
};

pub const IWorkspaceSymbolProvider = struct {
    context: *anyopaque,
    provide: *const fn (*anyopaque, Allocator, []const u8, WorkspaceSymbolsCallback) anyerror!IDisposable,
    resolve: ?*const fn (*anyopaque, Allocator, IWorkspaceSymbol, ResolveWorkspaceSymbolCallback) anyerror!IDisposable = null,
};

pub const WorkspaceSymbolItem = struct {
    symbol: IWorkspaceSymbol,
    provider: IWorkspaceSymbolProvider,
};

/// Window-owned counterpart of upstream's WorkspaceSymbolProviderRegistry.
pub const WorkspaceSymbolProviderRegistry = struct {
    allocator: Allocator,
    registrations: std.ArrayList(*Registration) = .empty,
    on_did_change: Emitter(void),

    const Registration = struct {
        owner: *WorkspaceSymbolProviderRegistry,
        provider: IWorkspaceSymbolProvider,

        fn dispose(context: *anyopaque) void {
            const self: *Registration = @ptrCast(@alignCast(context));
            const owner = self.owner;
            for (owner.registrations.items, 0..) |entry, index| {
                if (entry != self) continue;
                _ = owner.registrations.orderedRemove(index);
                break;
            }
            // Consumers detach pending callbacks before the actor frees the
            // provider's registration context.
            owner.on_did_change.fire({}) catch {};
            owner.allocator.destroy(self);
        }
    };

    pub fn init(allocator: Allocator) WorkspaceSymbolProviderRegistry {
        return .{ .allocator = allocator, .on_did_change = .init(allocator) };
    }

    pub fn deinit(self: *WorkspaceSymbolProviderRegistry) void {
        for (self.registrations.items) |entry| self.allocator.destroy(entry);
        self.registrations.deinit(self.allocator);
        self.on_did_change.deinit();
    }

    pub fn register(self: *WorkspaceSymbolProviderRegistry, provider: IWorkspaceSymbolProvider) !IDisposable {
        const registration = try self.allocator.create(Registration);
        errdefer self.allocator.destroy(registration);
        registration.* = .{ .owner = self, .provider = provider };
        try self.registrations.append(self.allocator, registration);
        self.on_did_change.fire({}) catch {};
        return .{ .context = registration, .disposeFn = Registration.dispose };
    }

    pub fn all(self: *WorkspaceSymbolProviderRegistry, allocator: Allocator) ![]IWorkspaceSymbolProvider {
        const result = try allocator.alloc(IWorkspaceSymbolProvider, self.registrations.items.len);
        for (self.registrations.items, result) |entry, *dest| dest.* = entry.provider;
        return result;
    }
};

/// The provider requests run independently and finish in any order. The
/// caller owns Request and must cancel it before dropping its arena.
pub const WorkspaceSymbolsRequest = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    pending: []Pending = &.{},
    remaining: usize = 0,
    items: std.ArrayList(WorkspaceSymbolItem) = .empty,
    callback: Callback,

    pub const Callback = struct {
        context: *anyopaque,
        complete: *const fn (*anyopaque, []const WorkspaceSymbolItem) void,
    };

    const Pending = struct {
        request: *WorkspaceSymbolsRequest,
        provider: IWorkspaceSymbolProvider,
        disposable: ?IDisposable = null,

        fn ready(context: *anyopaque, result: anyerror![]const IWorkspaceSymbol) void {
            const self: *Pending = @ptrCast(@alignCast(context));
            const request = self.request;
            self.disposable = null;
            if (result) |symbols| {
                for (symbols) |symbol| request.items.append(request.arena.allocator(), .{ .symbol = symbol, .provider = self.provider }) catch break;
            } else |_| {}
            request.remaining -= 1;
            if (request.remaining == 0) request.complete();
        }
    };

    pub fn init(allocator: Allocator, callback: Callback) !*WorkspaceSymbolsRequest {
        const self = try allocator.create(WorkspaceSymbolsRequest);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .callback = callback };
        return self;
    }

    pub fn getWorkspaceSymbols(self: *WorkspaceSymbolsRequest, registry: *WorkspaceSymbolProviderRegistry, query: []const u8) !void {
        const a = self.arena.allocator();
        const providers = try registry.all(a);
        self.pending = try a.alloc(Pending, providers.len);
        self.remaining = providers.len + 1; // synchronous failures cannot finish during setup
        for (providers, self.pending) |provider, *pending| {
            pending.* = .{ .request = self, .provider = provider };
            pending.disposable = provider.provide(provider.context, a, query, .{ .context = pending, .complete = Pending.ready }) catch {
                self.remaining -= 1;
                continue;
            };
        }
        self.remaining -= 1;
        if (self.remaining == 0) self.complete();
    }

    pub fn deinit(self: *WorkspaceSymbolsRequest) void {
        for (self.pending) |pending| if (pending.disposable) |disposable| disposable.dispose();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn complete(self: *WorkspaceSymbolsRequest) void {
        // Upstream groups by name, kind, URI, intersecting range, and
        // container, preferring resolvable entries over unresolved duplicates.
        std.mem.sort(WorkspaceSymbolItem, self.items.items, {}, lessThan);
        var count: usize = 0;
        for (self.items.items) |item| {
            if (count > 0 and compare(self.items.items[count - 1], item) == .eq) continue;
            self.items.items[count] = item;
            count += 1;
        }
        self.items.items.len = count;
        self.callback.complete(self.callback.context, self.items.items);
    }

    fn lessThan(_: void, a: WorkspaceSymbolItem, b: WorkspaceSymbolItem) bool {
        return compare(a, b) == .lt;
    }

    fn compare(a: WorkspaceSymbolItem, b: WorkspaceSymbolItem) std.math.Order {
        var order = std.mem.order(u8, a.symbol.name, b.symbol.name);
        if (order != .eq) return order;
        order = std.math.order(a.symbol.kind, b.symbol.kind);
        if (order != .eq) return order;
        order = std.mem.order(u8, a.symbol.resource, b.symbol.resource);
        if (order != .eq) return order;
        if (a.symbol.range != null and b.symbol.range != null) {
            const x = a.symbol.range.?;
            const y = b.symbol.range.?;
            if (!@import("../../../../editor/common/core/range.zig").areIntersecting(&x, &y)) {
                order = std.math.order(x.startLineNumber, y.startLineNumber);
                if (order == .eq) order = std.math.order(x.startColumn, y.startColumn);
                if (order != .eq) return order;
            }
        } else if ((a.provider.resolve != null) != (b.provider.resolve != null)) return if (a.provider.resolve != null) .lt else .gt;
        return std.mem.order(u8, a.symbol.container_name, b.symbol.container_name);
    }
};
