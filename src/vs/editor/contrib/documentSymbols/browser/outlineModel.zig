// Port of `src/vs/editor/contrib/documentSymbols/browser/outlineModel.ts`.
//
// Provider promises complete through callbacks on the terminal event loop.
// Consumers share versioned models via OutlineModelService; intrusive references
// keep evicted or replaced models alive while a view still owns them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const range_mod = @import("../../../common/core/range.zig");
const Range = range_mod.Range;
const MarkerSeverity = @import("../../../../platform/markers/common/markers.zig").MarkerSeverity;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

/// Upstream `IOutlineMarker`: the range and severity of a problem attached to
/// an outline element. `textModelEvents` markers keep the same shape.
pub const OutlineMarker = struct {
    range: Range,
    severity: u32,
};

/// Upstream `OutlineElement.marker` rollup.
pub const MarkerInfo = struct {
    count: usize,
    top_severity: u32,
};

pub const OutlineElement = struct {
    /// Stable identity within the outline model, matching upstream
    /// `TreeElement.id` (provider/name/line/column with duplicate suffixes).
    id: []const u8 = "",
    symbol: languages.DocumentSymbol,
    children: []*OutlineElement = &.{},
    marker: ?MarkerInfo = null,
    /// Parent symbol for breadcrumb sibling lookup. Top-level elements keep
    /// null, matching `TreeElement.parent === OutlineModel`.
    parent: ?*OutlineElement = null,
};

pub const OutlineGroup = struct {
    id: []const u8 = "",
    label: []const u8 = "",
    order: usize = 0,
    children: []*OutlineElement = &.{},
};

pub const OutlineModel = struct {
    refs: usize = 1,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    /// Provider groups. A single non-empty provider is compacted, exactly like
    /// upstream `_compact`: `roots` then holds that provider's elements.
    groups: []*OutlineGroup = &.{},
    roots: []*OutlineElement = &.{},

    pub fn create(allocator: Allocator, model: *TextModel, provider: languages.DocumentSymbolProvider) !*OutlineModel {
        return createWithProviders(allocator, model, &.{provider});
    }

    pub fn createWithProviders(
        allocator: Allocator,
        model: *TextModel,
        providers: []const languages.DocumentSymbolProvider,
    ) !*OutlineModel {
        const self = try empty(allocator);
        errdefer self.deinit();
        const arena = self.arena.allocator();
        var groups = std.array_list.Managed(*OutlineGroup).init(arena);

        for (providers, 0..) |provider, index| {
            const group = try arena.create(OutlineGroup);
            group.* = .{
                .id = try std.fmt.allocPrint(arena, "root/provider_{d}", .{index}),
                .label = provider.display_name,
                .order = index,
            };
            const symbols = provider.provide_document_symbols(
                provider.context,
                arena,
                model,
                CancellationToken.None,
            ) catch &.{};
            group.children = try buildChildren(arena, group.id, symbols, null);
            if (group.children.len > 0) try groups.append(group);
        }

        self.groups = try groups.toOwnedSlice();
        try self.compact();
        return self;
    }

    pub fn empty(allocator: Allocator) !*OutlineModel {
        const self = try allocator.create(OutlineModel);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    fn compact(self: *OutlineModel) !void {
        const arena = self.arena.allocator();
        if (self.groups.len == 1) {
            self.roots = self.groups[0].children;
        } else if (self.groups.len > 1) {
            // The terminal outline view has one provider group per row section;
            // expose all element roots for callers that only flatten the tree.
            var roots = std.array_list.Managed(*OutlineElement).init(arena);
            for (self.groups) |group| try roots.appendSlice(group.children);
            self.roots = try roots.toOwnedSlice();
        }
    }

    fn buildChildren(arena: Allocator, parent_id: []const u8, symbols: []const languages.DocumentSymbol, parent: ?*OutlineElement) Allocator.Error![]*OutlineElement {
        const children = try arena.alloc(*OutlineElement, symbols.len);
        // Upstream TreeElement.children is an insertion-ordered Map keyed by id.
        var ids: std.StringHashMapUnmanaged(void) = .empty;
        defer ids.deinit(arena);
        try ids.ensureTotalCapacity(arena, @intCast(symbols.len));
        for (symbols, children) |symbol, *child| {
            child.* = try buildElement(arena, parent_id, symbol, ids, parent);
            ids.putAssumeCapacity(child.*.id, {});
        }
        return children;
    }

    fn buildElement(
        arena: Allocator,
        parent_id: []const u8,
        symbol: languages.DocumentSymbol,
        siblings: std.StringHashMapUnmanaged(void),
        parent: ?*OutlineElement,
    ) !*OutlineElement {
        const element = try arena.create(OutlineElement);
        element.* = .{ .symbol = symbol, .parent = parent };
        element.id = try findId(arena, parent_id, symbol, siblings);
        element.children = try buildChildren(arena, element.id, symbol.children, element);
        return element;
    }

    pub fn retain(self: *OutlineModel) void {
        self.refs += 1;
    }

    pub fn deinit(self: *OutlineModel) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Returns the root-to-deepest path whose symbol range contains `position`.
    pub fn elementChain(self: *const OutlineModel, allocator: Allocator, position: Position) ![]*OutlineElement {
        var chain = std.array_list.Managed(*OutlineElement).init(allocator);
        errdefer chain.deinit();
        var owned_position = position;
        try appendChain(&chain, self.roots, &owned_position);
        return chain.toOwnedSlice();
    }

    fn appendChain(
        chain: *std.array_list.Managed(*OutlineElement),
        elements: []*OutlineElement,
        position: *const Position,
    ) !void {
        for (elements) |element| {
            var range = element.symbol.range;
            if (!range.containsPosition(position)) continue;
            try chain.append(element);
            try appendChain(chain, element.children, position);
            return;
        }
    }

    /// Upstream `getItemEnclosingPosition`: the deepest symbol containing the
    /// cursor, or null when no symbol encloses it.
    pub fn getItemEnclosingPosition(self: *const OutlineModel, position: Position) ?*OutlineElement {
        var owned_position = position;
        return enclosingElement(self.roots, &owned_position);
    }

    fn enclosingElement(elements: []*OutlineElement, position: *const Position) ?*OutlineElement {
        for (elements) |element| {
            var range = element.symbol.range;
            if (!range.containsPosition(position)) continue;
            return enclosingElement(element.children, position) orelse element;
        }
        return null;
    }

    /// Upstream `TreeElement.size`.
    pub fn size(self: *const OutlineModel) usize {
        var count: usize = 1;
        for (self.roots) |root| count += elementSize(root);
        return count;
    }

    pub fn isEmpty(self: *const OutlineModel) bool {
        return self.roots.len == 0;
    }

    /// Upstream `updateMarker`. Markers are copied into a mutable list and
    /// recursively assigned to the deepest outline elements that contain them;
    /// only lowercased elements are rolled up into their parents.
    pub fn updateMarker(self: *OutlineModel, markers: []const OutlineMarker) !void {
        const allocator = self.allocator;
        if (self.groups.len == 0) {
            for (self.roots) |root| root.marker = null;
            return;
        }
        const sorted = try allocator.alloc(OutlineMarker, markers.len);
        defer allocator.free(sorted);
        @memcpy(sorted, markers);
        std.mem.sort(OutlineMarker, sorted, {}, struct {
            fn lessThan(_: void, a: OutlineMarker, b: OutlineMarker) bool {
                return range_mod.compareRangesUsingStarts(&a.range, &b.range) < 0;
            }
        }.lessThan);

        var work = std.array_list.Managed(?OutlineMarker).init(allocator);
        defer work.deinit();
        for (self.groups) |group| {
            work.clearRetainingCapacity();
            for (sorted) |marker| work.append(marker) catch continue;
            updateGroupMarkers(group, &work);
        }
    }

    /// Upstream `getTopLevelSymbols`.
    pub fn getTopLevelSymbols(self: *const OutlineModel, allocator: Allocator) ![]languages.DocumentSymbol {
        var roots = std.array_list.Managed(languages.DocumentSymbol).init(allocator);
        errdefer roots.deinit();
        for (self.roots) |element| try roots.append(element.symbol);
        std.mem.sort(languages.DocumentSymbol, roots.items, {}, struct {
            fn lessThan(_: void, a: languages.DocumentSymbol, b: languages.DocumentSymbol) bool {
                return range_mod.compareRangesUsingStarts(&a.range, &b.range) < 0;
            }
        }.lessThan);
        return roots.toOwnedSlice();
    }

    /// Upstream `asListOfDocumentSymbols`: a flattened, position sorted list.
    pub fn asListOfDocumentSymbols(self: *const OutlineModel, allocator: Allocator) ![]languages.DocumentSymbol {
        var bucket = std.array_list.Managed(languages.DocumentSymbol).init(allocator);
        errdefer bucket.deinit();
        for (self.roots) |root| try flattenDocumentSymbols(&bucket, root, "");
        std.mem.sort(languages.DocumentSymbol, bucket.items, {}, struct {
            fn lessThan(_: void, a: languages.DocumentSymbol, b: languages.DocumentSymbol) bool {
                const by_start = Position.compare(
                    Range.getStartPosition(&a.range),
                    Range.getStartPosition(&b.range),
                );
                if (by_start != 0) return by_start < 0;
                return Position.compare(
                    Range.getEndPosition(&a.range),
                    Range.getEndPosition(&b.range),
                ) > 0;
            }
        }.lessThan);
        return bucket.toOwnedSlice();
    }

    pub fn getItemById(self: *const OutlineModel, id: []const u8) ?*OutlineElement {
        if (id.len == 0) return null;
        for (self.roots) |root| {
            if (findElementById(root, id)) |element| return element;
        }
        return null;
    }
};

fn flattenDocumentSymbols(
    bucket: *std.array_list.Managed(languages.DocumentSymbol),
    element: *const OutlineElement,
    container_label: []const u8,
) !void {
    const symbol = element.symbol;
    try bucket.append(.{
        .name = symbol.name,
        .detail = symbol.detail,
        .kind = symbol.kind,
        .tags = symbol.tags,
        .container_name = symbol.container_name orelse if (container_label.len > 0) container_label else null,
        .range = symbol.range,
        .selection_range = symbol.selection_range,
        .children = &.{},
    });
    for (element.children) |child| try flattenDocumentSymbols(bucket, child, symbol.name);
}

fn updateGroupMarkers(group: *OutlineGroup, markers: *std.array_list.Managed(?OutlineMarker)) void {
    for (group.children) |child| updateElementMarkers(child, markers);
    compactMarkers(markers);
}

fn updateElementMarkers(
    element: *OutlineElement,
    markers: *std.array_list.Managed(?OutlineMarker),
) void {
    element.marker = null;
    var my_markers = std.array_list.Managed(?OutlineMarker).init(markers.allocator);
    defer my_markers.deinit();
    var top_severity: ?u32 = null;
    for (markers.items, 0..) |slot, index| {
        const marker = slot orelse continue;
        var element_range = element.symbol.range;
        if (!range_mod.areIntersecting(&element_range, &marker.range)) continue;
        my_markers.append(marker) catch continue;
        markers.items[index] = null;
        if (top_severity == null or marker.severity > top_severity.?) top_severity = marker.severity;
    }
    for (element.children) |child| updateElementMarkers(child, &my_markers);
    compactMarkers(&my_markers);
    if (top_severity) |severity| {
        element.marker = .{ .count = my_markers.items.len, .top_severity = severity };
    }
}

fn compactMarkers(markers: *std.array_list.Managed(?OutlineMarker)) void {
    var write: usize = 0;
    for (markers.items) |marker| {
        if (marker) |value| {
            markers.items[write] = value;
            write += 1;
        }
    }
    markers.items.len = write;
}

fn elementSize(element: *const OutlineElement) usize {
    var count: usize = 1;
    for (element.children) |child| count += elementSize(child);
    return count;
}

fn findElementById(element: *OutlineElement, id: []const u8) ?*OutlineElement {
    if (std.mem.eql(u8, element.id, id)) return element;
    for (element.children) |child| {
        if (findElementById(child, id)) |found| return found;
    }
    return null;
}

/// Upstream `TreeElement.findId`: ids include the parent path, and duplicate
/// names fall back to the symbol start line/column before the numeric suffix.
fn findId(
    arena: Allocator,
    parent_id: []const u8,
    symbol: languages.DocumentSymbol,
    siblings: std.StringHashMapUnmanaged(void),
) ![]const u8 {
    var candidate = try std.fmt.allocPrint(arena, "{s}/{s}", .{ parent_id, symbol.name });
    if (siblings.contains(candidate)) {
        candidate = try std.fmt.allocPrint(arena, "{s}/{s}_{d}_{d}", .{
            parent_id,
            symbol.name,
            symbol.range.startLineNumber,
            symbol.range.startColumn,
        });
    }
    var attempt: usize = 0;
    var id = candidate;
    while (siblings.contains(id)) : (attempt += 1) {
        id = try std.fmt.allocPrint(arena, "{s}_{d}", .{ candidate, attempt });
    }
    return id;
}

/// OutlineModel.create's Promise.all. Each ordered provider owns one group.
/// Destroying the consumer cancels its outstanding provider requests.
pub const OutlineRequest = struct {
    model: *OutlineModel,
    slots: []Slot,
    remaining: usize = 0,
    context: *anyopaque,
    complete: *const fn (*anyopaque, *OutlineModel) void,

    const Slot = struct {
        owner: *OutlineRequest,
        group: *OutlineGroup,
        pending: ?@import("../../../../base/common/lifecycle.zig").IDisposable = null,

        fn ready(context: *anyopaque, symbols: []const languages.DocumentSymbol) void {
            const slot: *Slot = @ptrCast(@alignCast(context));
            const self = slot.owner;
            slot.pending = null;
            slot.group.children = OutlineModel.buildChildren(self.model.arena.allocator(), slot.group.id, symbols, null) catch &.{};
            self.remaining -= 1;
            if (self.remaining == 0) self.finish();
        }
    };

    pub fn start(allocator: Allocator, text_model: *TextModel, providers: []const languages.DocumentSymbolProvider, context: *anyopaque, complete: *const fn (*anyopaque, *OutlineModel) void) !?*OutlineRequest {
        const model = try OutlineModel.empty(allocator);
        const arena = model.arena.allocator();
        errdefer model.deinit();
        const self = try arena.create(OutlineRequest);
        self.* = .{ .model = model, .slots = try arena.alloc(Slot, providers.len), .context = context, .complete = complete };
        model.groups = try arena.alloc(*OutlineGroup, providers.len);
        for (providers, self.slots, 0..) |provider, *slot, index| {
            const group = try arena.create(OutlineGroup);
            group.* = .{ .id = try std.fmt.allocPrint(arena, "root/provider_{d}", .{index}), .label = try arena.dupe(u8, provider.display_name), .order = index };
            slot.* = .{ .owner = self, .group = group };
            model.groups[index] = group;
        }
        errdefer self.cancelProviders();
        for (providers, self.slots) |provider, *slot| {
            if (provider.request_document_symbols) |request| {
                slot.pending = request(provider.context, arena, text_model, .{ .context = slot, .complete = Slot.ready }) catch null;
                if (slot.pending != null) self.remaining += 1;
            } else {
                const symbols = provider.provide_document_symbols(provider.context, arena, text_model, CancellationToken.None) catch &.{};
                slot.group.children = try OutlineModel.buildChildren(arena, slot.group.id, symbols, null);
            }
        }
        if (self.remaining != 0) return self;
        self.finish();
        return null;
    }

    fn finish(self: *OutlineRequest) void {
        const model = self.model;
        var n: usize = 0;
        for (model.groups) |group| {
            if (group.children.len == 0) continue;
            model.groups[n] = group;
            n += 1;
        }
        model.groups = model.groups[0..n];
        model.compact() catch {};
        self.complete(self.context, model);
    }

    fn cancelProviders(self: *OutlineRequest) void {
        for (self.slots) |slot| if (slot.pending) |pending| pending.dispose();
    }

    pub fn cancel(self: *OutlineRequest) void {
        self.cancelProviders();
        self.model.deinit();
    }
};

/// Upstream OutlineModelService.getOrCreate. A pending promise can outlive
/// its cache entry. Subscribers share the result and only the last cancelled
/// subscriber cancels the provider.
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
pub const outline_model_service_id = instantiation.ServiceIdentifier(OutlineModelService, "outlineModelService");

pub fn getOutlineModelService(accessor: instantiation.ServicesAccessor) !*OutlineModelService {
    return accessor.get(outline_model_service_id);
}

/// Upstream registers OutlineModelService as a delayed singleton.
pub fn registerSingleton(collection: *@import("../../../../platform/instantiation/common/serviceCollection.zig").ServiceCollection) !void {
    _ = try collection.setFactory(outline_model_service_id, createService, disposeService);
}

fn createService(allocator: Allocator, _: instantiation.ServicesAccessor) !*OutlineModelService {
    const service = try allocator.create(OutlineModelService);
    service.* = .init(allocator);
    return service;
}

fn disposeService(allocator: Allocator, service: *OutlineModelService) void {
    service.deinit();
    allocator.destroy(service);
}

pub const OutlineModelService = struct {
    const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
    const debounce_mod = @import("../../../common/services/languageFeatureDebounce.zig");
    const now = @import("../../../../base/common/async.zig").nowMs;
    const Provider = languages.DocumentSymbolProvider;
    const Callback = *const fn (*anyopaque, *OutlineModel) void;

    allocator: Allocator,
    entries: std.ArrayList(*Entry) = .empty,
    debounce: debounce_mod.LanguageFeatureDebounceService,
    timers: std.ArrayList(Timer) = .empty,
    timer_task: @import("../../../../base/common/windowDispatch.zig").Task = .{},
    const Timer = struct { context: *anyopaque, deadline: i64, run: *const fn (*anyopaque) void };

    pub fn init(allocator: Allocator) OutlineModelService {
        return .{ .allocator = allocator, .debounce = .init(allocator, false) };
    }
    pub fn deinit(self: *OutlineModelService) void {
        while (self.entries.items.len != 0) self.remove(self.entries.items[0]);
        self.entries.deinit(self.allocator);
        self.debounce.deinit();
        self.timer_task.schedule(null);
        self.timers.deinit(self.allocator);
    }

    pub fn attachWindow(self: *OutlineModelService, queue: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        if (self.timer_task.queue == queue) return;
        self.timer_task.schedule(null);
        self.timer_task = .{ .queue = queue, .context = self, .run = onDeadline };
        self.rearmTimer();
    }
    fn rearmTimer(self: *OutlineModelService) void {
        self.timer_task.schedule(if (self.timers.items.len == 0) null else self.timers.items[0].deadline);
    }
    // Terminal event loop adapter for TimeoutTimer.cancelAndSet.
    pub fn cancelTimer(self: *OutlineModelService, context: *anyopaque) void {
        for (self.timers.items, 0..) |timer, i| if (timer.context == context) {
            _ = self.timers.orderedRemove(i);
            self.rearmTimer();
            return;
        };
    }
    pub fn schedule(self: *OutlineModelService, context: *anyopaque, delay: i64, run: *const fn (*anyopaque) void) !void {
        self.cancelTimer(context);
        const deadline = now() + delay;
        var i: usize = 0;
        while (i < self.timers.items.len and self.timers.items[i].deadline <= deadline) i += 1;
        try self.timers.insert(self.allocator, i, .{ .context = context, .deadline = deadline, .run = run });
        self.rearmTimer();
    }
    fn onDeadline(ctx: *anyopaque, time: i64, _: bool) bool {
        const self: *OutlineModelService = @ptrCast(@alignCast(ctx));
        defer self.rearmTimer();
        var changed = false;
        while (self.timers.items.len != 0 and self.timers.items[0].deadline <= time) {
            const timer = self.timers.orderedRemove(0);
            timer.run(timer.context);
            changed = true;
        }
        return changed;
    }

    const Entry = struct {
        service: *OutlineModelService,
        model: *TextModel,
        version: u32,
        providers: []Provider,
        hashes: []u32,
        start: i64,
        remove_listener: ?usize = null,
        request: ?*OutlineRequest = null,
        result: ?*OutlineModel = null,
        subscribers: std.ArrayList(*Subscription) = .empty,
        refs: usize = 1,

        fn release(self: *Entry) void {
            self.refs -= 1;
            if (self.refs != 0) return;
            const a = self.service.allocator;
            if (self.request) |request| request.cancel();
            if (self.result) |result| result.deinit();
            self.subscribers.deinit(a);
            a.free(self.providers);
            a.free(self.hashes);
            a.destroy(self);
        }
        fn removed(_: void, self: *Entry) !void {
            self.service.remove(self);
        }
        fn ready(context: *anyopaque, result: *OutlineModel) void {
            const self: *Entry = @ptrCast(@alignCast(context));
            self.refs += 1;
            defer self.release();
            self.request = null;
            self.result = result;
            const info = self.service.debounce.for_(1, "DocumentSymbols", .{ .min = 350 }) catch null;
            if (info) |d| _ = d.update(.{ .id = @intFromPtr(self.model), .feature_hashes = self.hashes }, @floatFromInt(now() - self.start)) catch {};
            while (self.subscribers.pop()) |sub| {
                result.retain();
                sub.complete(sub.context, result);
                self.service.allocator.destroy(sub);
                self.release();
            }
        }
    };
    const Subscription = struct {
        entry: *Entry,
        context: *anyopaque,
        complete: Callback,
        fn cancel(context: *anyopaque) void {
            const self: *Subscription = @ptrCast(@alignCast(context));
            const entry = self.entry;
            for (entry.subscribers.items, 0..) |sub, i| if (sub == self) {
                _ = entry.subscribers.orderedRemove(i);
                break;
            };
            entry.service.allocator.destroy(self);
            if (entry.subscribers.items.len == 0) entry.service.remove(entry);
            entry.release();
        }
    };

    fn remove(self: *OutlineModelService, entry: *Entry) void {
        for (self.entries.items, 0..) |e, i| if (e == entry) {
            _ = self.entries.orderedRemove(i);
            if (e.remove_listener) |id| e.model._onWillDispose.unlisten(id);
            e.remove_listener = null;
            e.release();
            break;
        };
    }
    pub fn getDebounceValue(self: *OutlineModelService, model: *TextModel) i64 {
        const info = self.debounce.for_(1, "DocumentSymbols", .{ .min = 350 }) catch return 525;
        for (self.entries.items) |e| if (e.model == model) return @intFromFloat(info.get(.{ .id = @intFromPtr(model), .feature_hashes = e.hashes }));
        return @intFromFloat(info.default());
    }

    pub fn getOrCreate(self: *OutlineModelService, model: *TextModel, providers: []const Provider, context: *anyopaque, complete: Callback) !?Disposable {
        for (self.entries.items, 0..) |e, i| {
            if (e.model != model) continue;
            if (e.version != model.getVersionId() or !sameProviders(e.providers, providers)) {
                self.remove(e);
                break;
            }
            _ = self.entries.orderedRemove(i);
            self.entries.appendAssumeCapacity(e);
            if (e.result) |result| {
                result.retain();
                complete(context, result);
                return null;
            }
            return try self.subscribe(e, context, complete);
        }

        const entry = try self.makeEntry(model, providers);
        // Immediate completions can release the cache entry from a callback.
        entry.refs += 1;
        defer entry.release();
        errdefer self.remove(entry);
        const handle = try self.subscribe(entry, context, complete);
        entry.request = OutlineRequest.start(self.allocator, model, providers, entry, Entry.ready) catch |err| {
            // Drop the subscriber before releasing the cache reference.
            const sub = entry.subscribers.pop().?;
            self.allocator.destroy(sub);
            entry.release();
            return err;
        };
        return if (entry.result != null) null else handle;
    }
    fn makeEntry(self: *OutlineModelService, model: *TextModel, providers: []const Provider) !*Entry {
        const a = self.allocator;
        const e = try a.create(Entry);
        errdefer a.destroy(e);
        const copy = try a.dupe(Provider, providers);
        errdefer a.free(copy);
        const hashes = try a.alloc(u32, providers.len);
        errdefer a.free(hashes);
        for (providers, hashes) |provider, *hash| hash.* = @truncate(@intFromPtr(provider.context));
        e.* = .{ .service = self, .model = model, .version = model.getVersionId(), .providers = copy, .hashes = hashes, .start = now() };
        try self.entries.ensureUnusedCapacity(a, 1);
        e.remove_listener = try model._onWillDispose.listen(e, Entry.removed);
        self.entries.appendAssumeCapacity(e);
        if (self.entries.items.len > 15) while (self.entries.items.len > 11) self.remove(self.entries.items[0]);
        return e;
    }
    fn subscribe(self: *OutlineModelService, entry: *Entry, context: *anyopaque, complete: Callback) !Disposable {
        const sub = try self.allocator.create(Subscription);
        errdefer self.allocator.destroy(sub);
        sub.* = .{ .entry = entry, .context = context, .complete = complete };
        try entry.subscribers.append(self.allocator, sub);
        entry.refs += 1;
        return .{ .context = sub, .disposeFn = Subscription.cancel };
    }
    fn sameProviders(a: []const Provider, b: []const Provider) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (x.context != y.context or x.provide_document_symbols != y.provide_document_symbols or x.request_document_symbols != y.request_document_symbols) return false;
        return true;
    }
};
