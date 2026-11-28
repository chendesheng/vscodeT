// Port of src/vs/workbench/contrib/search/browser/searchTreeModel/fileMatch.ts.
// The terminal window supplies the RunOnceScheduler deadline and paints range highlights.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tree = @import("searchTreeCommon.zig");
const Match = tree.Match;
const FolderMatch = tree.FolderMatch;
const ChangeEvent = tree.ChangeEvent;
const FILE_MATCH_PREFIX = tree.FILE_MATCH_PREFIX;
const TextModel = tree.TextModel;
const search = @import("../../../../services/search/common/search.zig");
const TextSearchMatch = search.TextSearchMatch;
const helpers = @import("../../../../services/search/common/searchHelpers.zig");
const dispatch = @import("../../../../../base/common/windowDispatch.zig");
const time = @import("../../../../../base/common/timeCompat.zig");
const Emitter = @import("../../../../../base/common/event.zig").Emitter;
const ContentChange = @import("../../../../../editor/common/textModelEvents.zig").InternalModelContentChangeEvent;
const DefaultWordSeparators = @import("../../../../../editor/common/core/wordCharacterClassifier.zig").DefaultWordSeparators;

pub const FileMatch = struct {
    allocator: Allocator,
    path: []u8,
    name: []u8,
    id: []u8,
    parent_folder: *FolderMatch,
    matches_list: std.array_list.Managed(*Match),
    match_map: std.StringHashMap(*Match),
    contexts: std.AutoHashMap(usize, []u8),
    selected: ?*Match = null,
    removed_matches: std.StringHashMap(void),
    model: ?*TextModel = null,
    content_listener: usize = 0,
    dispose_listener: usize = 0,
    scheduler: dispatch.Task = .{},
    on_change: Emitter(ChangeEvent),
    on_dispose: Emitter(void),

    pub fn create(allocator: Allocator, path: []const u8, parent_folder: *FolderMatch) !*FileMatch {
        const self = try allocator.create(FileMatch);
        errdefer allocator.destroy(self);
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        const name = try allocator.dupe(u8, std.fs.path.basename(path));
        errdefer allocator.free(name);
        const id = try std.fmt.allocPrint(allocator, "{s}{s}", .{ FILE_MATCH_PREFIX, path });
        errdefer allocator.free(id);
        self.* = .{
            .allocator = allocator,
            .path = path_copy,
            .name = name,
            .id = id,
            .parent_folder = parent_folder,
            .matches_list = std.array_list.Managed(*Match).init(allocator),
            .removed_matches = std.StringHashMap(void).init(allocator),
            .match_map = std.StringHashMap(*Match).init(allocator),
            .contexts = std.AutoHashMap(usize, []u8).init(allocator),
            .on_change = Emitter(ChangeEvent).init(allocator),
            .on_dispose = Emitter(void).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *FileMatch) void {
        self.unbindModel();
        var removed = self.removed_matches.keyIterator();
        while (removed.next()) |key| self.allocator.free(key.*);
        self.removed_matches.deinit();
        self.on_dispose.fire({}) catch {};
        for (self.matches_list.items) |match| match.deinit();
        self.matches_list.deinit();
        self.match_map.deinit();
        var context_iterator = self.contexts.valueIterator();
        while (context_iterator.next()) |value| self.allocator.free(value.*);
        self.contexts.deinit();
        self.on_change.deinit();
        self.on_dispose.deinit();
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn bindModel(self: *FileMatch, model: *TextModel) !void {
        if (self.model == model) return;
        const host = self.parent_folder.heading.parent_result.model_host orelse return;
        self.unbindModel();
        const content = try model.onDidChangeContentWithContextId(self, contentChanged);
        errdefer model.removeDidChangeContentListener(content);
        self.dispose_listener = try model._onWillDispose.listen(self, modelWillDispose);
        self.content_listener = content;
        self.model = model;
        self.scheduler = .{ .queue = host.queue, .context = self, .run = updateScheduled };
    }

    fn unbindModel(self: *FileMatch) void {
        const model = self.model orelse return;
        self.scheduler.schedule(null);
        model.removeDidChangeContentListener(self.content_listener);
        model._onWillDispose.unlisten(self.dispose_listener);
        self.model = null;
    }

    fn contentChanged(_: ContentChange, self: *FileMatch) !void {
        self.scheduler.schedule(time.milliTimestamp((self.model orelse return).clockIo()) + 250);
    }

    fn modelWillDispose(_: void, self: *FileMatch) !void {
        defer self.unbindModel();
        try self.updateMatchesForModel(true);
    }

    fn updateScheduled(ctx: *anyopaque, _: i64, _: bool) bool {
        const self: *FileMatch = @ptrCast(@alignCast(ctx));
        self.updateMatchesForModel(true) catch return false;
        return true;
    }

    fn updateMatchesForModel(self: *FileMatch, notify_change: bool) !void {
        const model = self.model orelse return;
        const query = self.parent_folder.query;
        const separators = if (query.is_word_match) @constCast(@as([]const u8, DefaultWordSeparators)) else null;
        var found = try model.findMatches(query.pattern, null, query.is_regex, query.is_case_sensitive, separators, false, query.max_results);
        defer found.deinit();
        const raw = try helpers.editorMatchesToTextSearchResults(self.allocator, found.items, model, query.preview);
        defer {
            for (raw) |*item| item.deinit();
            self.allocator.free(raw);
        }
        const context = try helpers.getTextSearchMatchWithModelContext(self.allocator, raw, model, query.surrounding_context);
        defer {
            for (context) |*row| row.deinit(self.allocator);
            self.allocator.free(context);
        }

        // Keep the old nodes alive until the replacement set is complete.
        var matches_list = std.array_list.Managed(*Match).init(self.allocator);
        var match_map = std.StringHashMap(*Match).init(self.allocator);
        var selected: ?*Match = null;
        defer {
            for (matches_list.items) |match| match.deinit();
            matches_list.deinit();
            match_map.deinit();
        }
        for (raw) |result| {
            for (result.range_locations) |loc| {
                const match = try Match.create(self.allocator, self, result.preview_text, loc.preview, loc.source);
                if (self.removed_matches.contains(match.id) or match_map.contains(match.id)) {
                    match.deinit();
                    continue;
                }
                errdefer match.deinit();
                try matches_list.ensureUnusedCapacity(1);
                try match_map.put(match.id, match);
                matches_list.appendAssumeCapacity(match);
                if (self.selected) |old| {
                    if (std.mem.eql(u8, old.id, match.id)) selected = match;
                }
            }
        }
        var contexts = std.AutoHashMap(usize, []u8).init(self.allocator);
        defer {
            var values = contexts.valueIterator();
            while (values.next()) |value| self.allocator.free(value.*);
            contexts.deinit();
        }
        for (context) |row| {
            if (contexts.contains(row.line_number)) continue;
            const copy = try self.allocator.dupe(u8, row.text);
            errdefer self.allocator.free(copy);
            try contexts.put(row.line_number, copy);
        }
        std.mem.swap(@TypeOf(contexts), &contexts, &self.contexts);
        std.mem.swap(@TypeOf(match_map), &match_map, &self.match_map);
        std.mem.swap(@TypeOf(matches_list), &matches_list, &self.matches_list);
        self.selected = selected;
        if (notify_change) {
            self.on_change.fire(.{ .elements = &.{self}, .force_update_model = true }) catch {};
            self.parent_folder.onModelMatchesUpdated(self);
        }
    }

    pub fn createMatches(self: *FileMatch, results: []const TextSearchMatch) !void {
        if (self.model == null) {
            if (self.parent_folder.heading.parent_result.model_host) |host| {
                if (host.get(host.context, self.path)) |model| try self.bindModel(model);
            }
        }
        if (self.model != null) {
            try self.updateMatchesForModel(false);
            return;
        }
        try self.addRawMatches(results);
    }

    pub fn addRawMatches(self: *FileMatch, results: []const TextSearchMatch) !void {
        for (results) |raw| {
            for (raw.range_locations) |location| {
                const match = try Match.create(
                    self.allocator,
                    self,
                    raw.preview_text,
                    location.preview,
                    location.source,
                );
                try self.add(match, false);
            }
        }
    }

    pub fn addContexts(self: *FileMatch, contexts: []const search.TextSearchContext) !void {
        for (contexts) |context| {
            const copy = try self.allocator.dupe(u8, context.text);
            errdefer self.allocator.free(copy);
            const result = try self.contexts.getOrPut(context.line_number);
            if (result.found_existing) self.allocator.free(result.value_ptr.*);
            result.value_ptr.* = copy;
        }
    }

    pub fn contextForLine(self: *const FileMatch, line_number: usize) ?[]const u8 {
        return self.contexts.get(line_number);
    }

    pub fn add(self: *FileMatch, match: *Match, trigger: bool) !void {
        if (self.removed_matches.contains(match.id) or self.match_map.contains(match.id)) {
            match.deinit();
            return;
        }
        errdefer match.deinit();
        try self.matches_list.ensureUnusedCapacity(1);
        try self.match_map.put(match.id, match);
        self.matches_list.appendAssumeCapacity(match);
        if (trigger) self.notify(true, false);
    }

    pub fn remove(self: *FileMatch, match: *Match) void {
        for (self.matches_list.items, 0..) |candidate, index| {
            if (candidate == match) {
                const id = self.allocator.dupe(u8, match.id) catch return;
                self.removed_matches.put(id, {}) catch {
                    self.allocator.free(id);
                    return;
                };
                _ = self.matches_list.orderedRemove(index);
                _ = self.match_map.remove(match.id);
                if (self.selected == match) self.selected = null;
                match.deinit();
                self.notify(false, true);
                return;
            }
        }
    }

    pub fn removeAll(self: *FileMatch) void {
        for (self.matches_list.items) |match| match.deinit();
        self.matches_list.clearRetainingCapacity();
        self.match_map.clearRetainingCapacity();
        self.selected = null;
        self.notify(false, true);
    }

    pub fn setSelectedMatch(self: *FileMatch, match: ?*Match) void {
        if (match) |value| {
            if (!self.match_map.contains(value.id)) return;
        }
        self.selected = match;
    }

    pub fn getSelectedMatch(self: *const FileMatch) ?*Match {
        return self.selected;
    }

    pub fn isMatchSelected(self: *const FileMatch, match: *const Match) bool {
        return self.selected == match;
    }

    pub fn matches(self: *const FileMatch) []*Match {
        return self.matches_list.items;
    }

    pub fn textMatches(self: *const FileMatch) []*Match {
        return self.matches_list.items;
    }

    pub fn count(self: *const FileMatch) usize {
        return self.matches_list.items.len;
    }

    pub fn hasChildren(self: *const FileMatch) bool {
        return self.matches_list.items.len > 0;
    }

    pub fn resource(self: *const FileMatch) []const u8 {
        return self.path;
    }

    pub fn parent(self: *FileMatch) *FolderMatch {
        return self.parent_folder;
    }

    pub fn notify(self: *FileMatch, added: bool, removed: bool) void {
        const elements = [1]*FileMatch{self};
        self.on_change.fire(.{ .elements = &elements, .added = added, .removed = removed }) catch {};
        self.parent_folder.onFileChanged(self, removed);
    }
};
