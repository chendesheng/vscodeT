// Port of the file-search slice of
// `src/vs/workbench/contrib/search/browser/anythingQuickAccess.ts`.
//
// Kept from upstream: the empty-prefix "Go to File" provider, recent editors
// first, workspace file results once a filter is typed, the
// "recently opened"/"file results" separators and the 512-result cap.
//
// Not ported because the corresponding services are absent in the TUI:
// workspace symbols (`@`), go-to-line (`:`), link handling, help picks,
// AI-related picks, absolute/relative path resolution, open-to-side and
// background accept, history-removal buttons and configuration
// (`includeHistory`, `preserveInput`). File results arrive asynchronously from
// `FileSearchWorker`; recent-editor scoring still uses the smaller
// `filters.fuzzyScore` helper. Both paths produce label/description highlight
// ranges.

const std = @import("std");
const Allocator = std.mem.Allocator;
const filters = @import("../../../../base/common/filters.zig");
const cancellation = @import("../../../../base/common/cancellation.zig");
const CancellationToken = cancellation.CancellationToken;
const quick_input = @import("../../../../platform/quickinput/common/quickInput.zig");
const QuickPickItem = quick_input.QuickPickItem;
const QuickPick = @import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const picker = @import("../../../../platform/quickinput/browser/pickerQuickAccess.zig");
const quick_access = @import("../../../../platform/quickinput/common/quickAccess.zig");
const Provider = quick_access.Provider;

pub const RecentFile = struct {
    path: []const u8,
    label: []const u8,
    description: []const u8 = "",
};

pub const FileMatch = struct {
    path: []const u8,
    label: []const u8,
    description: []const u8 = "",
    label_matches: []const filters.Match = &.{},
    description_matches: []const filters.Match = &.{},
};

pub const FileSource = struct {
    context: *anyopaque,
    /// Starts the per-picker file-listing session. Subsequent calls are
    /// no-ops until the session ends.
    start: *const fn (context: *anyopaque) void,
    /// Queues a filter for the background worker. Results are published
    /// asynchronously and consumed by `search`.
    request: *const fn (context: *anyopaque, filter: []const u8) void,
    /// Whether a result for exactly this filter is ready.
    has_result: *const fn (context: *anyopaque, filter: []const u8) bool,
    is_indexing: *const fn (context: *anyopaque) bool,
    recent: *const fn (
        context: *anyopaque,
        allocator: Allocator,
    ) anyerror![]RecentFile,
    /// Copies the ready worker result into the provider arena.
    search: *const fn (
        context: *anyopaque,
        filter: []const u8,
        max_results: usize,
        allocator: Allocator,
    ) anyerror![]FileMatch,
};

pub const OpenFile = struct {
    context: *anyopaque,
    open: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    on_error: ?*const fn (context: *anyopaque, message: []const u8) void = null,
};

pub const AnythingQuickAccessProvider = struct {
    pub const PREFIX = "";
    pub const MAX_RESULTS = 512;
    pub const PLACEHOLDER = "Search files by name (type > to run commands)";

    allocator: Allocator,
    source: FileSource,
    open_file: OpenFile,
    arena: std.heap.ArenaAllocator,

    pub fn init(
        allocator: Allocator,
        source: FileSource,
        open_file: OpenFile,
    ) !*AnythingQuickAccessProvider {
        const self = try allocator.create(AnythingQuickAccessProvider);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .source = source,
            .open_file = open_file,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    pub fn interface(self: *AnythingQuickAccessProvider) Provider {
        return .{
            .context = self,
            .prefix = PREFIX,
            .placeholder = PLACEHOLDER,
            .provide = provideFn,
            .refresh = refreshFn,
            .accept = acceptFn,
            .dispose = disposeFn,
        };
    }

    fn provideFn(context: *anyopaque, picker_ref: *QuickPick, token: CancellationToken) anyerror!void {
        const self: *AnythingQuickAccessProvider = @ptrCast(@alignCast(context));
        try picker.provide(self.impl(), self.options(), picker_ref, token);
    }

    fn refreshFn(context: *anyopaque, picker_ref: *QuickPick) anyerror!void {
        const self: *AnythingQuickAccessProvider = @ptrCast(@alignCast(context));
        try picker.refresh(self.impl(), self.options(), picker_ref);
    }

    fn acceptFn(context: *anyopaque, picker_ref: *QuickPick) anyerror!void {
        _ = context;
        return picker.accept(picker_ref);
    }

    fn disposeFn(context: *anyopaque) void {
        const self: *AnythingQuickAccessProvider = @ptrCast(@alignCast(context));
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn options(_: *const AnythingQuickAccessProvider) picker.PickerOptions {
        return .{
            .prefix = PREFIX,
            .no_results_pick = .{ .item = .{ .id = "", .label = "No matching results" } },
        };
    }

    fn impl(self: *AnythingQuickAccessProvider) picker.PickerImpl {
        return .{
            .context = self,
            .get_picks = getPicks,
            .is_busy = isBusy,
        };
    }

    fn isBusy(context: *anyopaque) bool {
        const self: *AnythingQuickAccessProvider = @ptrCast(@alignCast(context));
        return self.source.is_indexing(self.source.context);
    }

    fn getPicks(context: *anyopaque, filter: []const u8, _: Allocator) anyerror!?[]QuickPickItem {
        const self: *AnythingQuickAccessProvider = @ptrCast(@alignCast(context));

        // While a file search is in flight, return null before resetting the
        // arena: the picker keeps the previous items and only the busy state
        // changes (see `pickerQuickAccess.update`).
        if (filter.len > 0 and !self.source.has_result(self.source.context, filter)) {
            // `start` is idempotent; it also covers providers that were shown
            // without going through `QuickAccessService.showFilePicker`.
            self.source.start(self.source.context);
            self.source.request(self.source.context, filter);
            return null;
        }

        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();

        var items = std.array_list.Managed(QuickPickItem).init(arena);
        if (filter.len == 0) {
            const recent = try self.source.recent(self.source.context, arena);
            if (recent.len > 0) {
                try items.append(.{ .separator = .{ .label = "recently opened" } });
                for (recent) |entry| try self.appendItem(arena, &items, .{
                    .path = entry.path,
                    .label = entry.label,
                    .description = entry.description,
                });
            }
            return try items.toOwnedSlice();
        }

        // Start the lazy index only when there is something to search.
        self.source.start(self.source.context);

        const recent = try self.source.recent(self.source.context, arena);
        const recent_matches = try self.getRecentMatches(arena, filter, recent);
        if (recent_matches.len > 0) {
            try items.append(.{ .separator = .{ .label = "recently opened" } });
            for (recent_matches) |match| try self.appendItem(arena, &items, match);
        }

        const files = try self.source.search(
            self.source.context,
            filter,
            MAX_RESULTS,
            arena,
        );
        if (files.len > 0) {
            try items.append(.{ .separator = .{ .label = "file results" } });
            for (files) |file| try self.appendItem(arena, &items, file);
        }

        return try items.toOwnedSlice();
    }

    fn appendItem(
        self: *AnythingQuickAccessProvider,
        arena: Allocator,
        items: *std.array_list.Managed(QuickPickItem),
        file: FileMatch,
    ) !void {
        const accept_state = try arena.create(AcceptState);
        accept_state.* = .{ .provider = self, .path = file.path };
        try items.append(.{ .item = .{
            .id = file.path,
            .label = file.label,
            .description = file.description,
            .highlights = .{
                .label = file.label_matches,
                .description = file.description_matches,
            },
            .accept_context = accept_state,
            .accept = acceptItem,
        } });
    }

    fn getRecentMatches(
        self: *AnythingQuickAccessProvider,
        arena: Allocator,
        filter: []const u8,
        recent: []const RecentFile,
    ) ![]FileMatch {
        _ = self;
        var matches = std.array_list.Managed(ScoredRecent).init(arena);
        for (recent) |entry| {
            if (try scoreRecent(arena, filter, entry)) |scored| {
                try matches.append(.{ .file = entry, .score = scored.score, .label_matches = scored.label_matches, .description_matches = scored.description_matches });
            }
        }
        const SortContext = struct {};
        std.mem.sort(ScoredRecent, matches.items, SortContext{}, struct {
            fn lessThan(_: SortContext, a: ScoredRecent, b: ScoredRecent) bool {
                if (a.score != b.score) return a.score > b.score;
                if (a.file.label.len != b.file.label.len) return a.file.label.len < b.file.label.len;
                return std.mem.lessThan(u8, a.file.path, b.file.path);
            }
        }.lessThan);

        var result = std.array_list.Managed(FileMatch).init(arena);
        for (matches.items) |match| {
            try result.append(.{
                .path = match.file.path,
                .label = match.file.label,
                .description = match.file.description,
                .label_matches = match.label_matches,
                .description_matches = match.description_matches,
            });
        }
        return try result.toOwnedSlice();
    }

    fn acceptItem(context: *anyopaque) anyerror!void {
        const state: *AcceptState = @ptrCast(@alignCast(context));
        state.provider.open_file.open(state.provider.open_file.context, state.path) catch |err| {
            if (state.provider.open_file.on_error) |on_error| {
                on_error(state.provider.open_file.context, @errorName(err));
            }
        };
    }
};

const AcceptState = struct {
    provider: *AnythingQuickAccessProvider,
    path: []const u8,
};

const ScoredRecent = struct {
    file: RecentFile,
    score: i32,
    label_matches: []const filters.Match = &.{},
    description_matches: []const filters.Match = &.{},
};

const RecentScore = struct {
    score: i32,
    label_matches: []const filters.Match = &.{},
    description_matches: []const filters.Match = &.{},
};

fn scoreRecent(allocator: Allocator, filter: []const u8, entry: RecentFile) !?RecentScore {
    var words = std.mem.tokenizeAny(u8, filter, " \t");
    var total: i32 = 0;
    var word_count: usize = 0;

    // Prefer label matches; fall back to the description path if any word
    // does not match the label.
    var label_ok = true;
    var label_matches = std.array_list.Managed(filters.Match).init(allocator);
    var description_matches = std.array_list.Managed(filters.Match).init(allocator);

    while (words.next()) |word| {
        word_count += 1;
        const scored = (try filters.fuzzyScoreWithPositions(allocator, word, entry.label)) orelse {
            label_ok = false;
            break;
        };
        total += scored.score;
        try appendMatches(&label_matches, scored.positions);
    }

    if (label_ok and word_count > 0) {
        return .{ .score = total, .label_matches = try label_matches.toOwnedSlice() };
    }

    total = 0;
    var description_ok = true;
    var description_words = std.mem.tokenizeAny(u8, filter, " \t");
    while (description_words.next()) |word| {
        const scored = (try filters.fuzzyScoreWithPositions(allocator, word, entry.description)) orelse {
            description_ok = false;
            break;
        };
        total += scored.score;
        try appendMatches(&description_matches, scored.positions);
    }
    if (description_ok) {
        return .{
            .score = total,
            .description_matches = try description_matches.toOwnedSlice(),
        };
    }
    return null;
}

fn appendMatches(
    matches: *std.array_list.Managed(filters.Match),
    positions: []const usize,
) !void {
    for (positions) |position| {
        if (matches.items.len > 0 and matches.items[matches.items.len - 1].end == position) {
            matches.items[matches.items.len - 1].end = position + 1;
        } else {
            try matches.append(.{ .start = position, .end = position + 1 });
        }
    }
}
